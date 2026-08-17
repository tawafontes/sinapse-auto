import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';

import '../models/dashcam_config.dart';

/// A single recorded loop-recording segment on disk.
class DashcamClip {
  DashcamClip({
    required this.file,
    required this.recordedAt,
    required this.sizeBytes,
    this.durationSeconds = 0,
    this.isProtected = false,
  });

  final File file;

  /// The wall-clock instant `CameraController.startVideoRecording()` was
  /// called for this segment — not when it was finalized. Using the start
  /// instant (rather than the finalize instant, up to [DashcamService.segmentDuration]
  /// later) is what makes a video position lineable up against telemetry at
  /// all (Fase 15).
  final DateTime recordedAt;
  final int sizeBytes;
  final int durationSeconds;

  /// Protected clips are never deleted by quota enforcement. Set via
  /// [DashcamService.markClipAsProtected].
  bool isProtected;
}

/// Loop recording via [camera], on-disk storage-quota management, and clip
/// protection — the low-level camera driver for the Fase 15 Dashcam feature.
///
/// This class owns exactly one [CameraController] for its whole lifetime
/// (see [initialize]/[dispose]) and knows nothing about driving
/// sessions/telemetry/app lifecycle — that orchestration (tying recording to
/// session start/stop, pausing on backgrounding, isolating camera failures
/// from the rest of the app) is `DashcamSessionController`'s job, one layer
/// up. This class's own responsibilities:
///  * [startLoopRecording] / [stopLoopRecording] drive continuous recording
///    by rotating video files every [segmentDuration].
///  * [_enforceStorageQuota] deletes the oldest unprotected clips once
///    total clip size exceeds [DashcamConfig.storageQuotaMb].
///  * [markClipAsProtected] is the hook called by whatever listens for a
///    high/critical-severity [DetectedEvent] (see `DashcamSessionController`)
///    so the clip containing that moment survives quota cleanup.
///  * [errors] surfaces out-of-band failures with no direct call site to
///    catch them at (see its own doc) — `DashcamSessionController` is the
///    sole listener, mapping any emission to a user-visible error state.
class DashcamService {
  DashcamService({
    required DashcamConfig config,
    this.segmentDuration = const Duration(minutes: 3),
  }) : _config = config;

  DashcamConfig _config;
  final Duration segmentDuration;

  CameraController? _controller;
  Timer? _segmentTimer;
  bool _isRecording = false;
  DateTime? _segmentStartedAt;
  bool _protectNextFinalizedClip = false;
  bool _lastKnownHasError = false;

  final List<DashcamClip> _clips = [];
  List<DashcamClip> get clips => List.unmodifiable(_clips);

  bool get isRecording => _isRecording;

  /// The live camera controller, once [initialize] has completed — `null`
  /// beforehand/after [dispose]. Callers (preview widgets, settings) only
  /// ever *read* this; construction/disposal stay exclusively inside this
  /// class (see this class's own doc).
  CameraController? get previewController => _controller;

  int get totalClipBytes => _clips.fold<int>(0, (sum, clip) => sum + clip.sizeBytes);

  int get quotaBytes => _config.storageQuotaMb * 1024 * 1024;

  final StreamController<String> _errorsController = StreamController<String>.broadcast();

  /// Out-of-band failures that have no corresponding direct call site to
  /// catch: asynchronous camera-lost errors the plugin itself reports via
  /// [CameraValue.hasError] (e.g. the hardware being taken by another app
  /// mid-recording — not something a `try`/`catch` around a single call
  /// would ever see), and a best-effort segment-finalize failure during
  /// [dispose] (which, by Flutter convention, must not itself throw).
  ///
  /// Ordinary failures from [initialize]/[startLoopRecording]/
  /// [stopLoopRecording] are NOT funneled through this stream — they throw
  /// normally, and `DashcamSessionController`'s own `try`/`catch` around
  /// each direct call is the sole handler for those (see its own doc for
  /// why: catching-and-swallowing here as well would leave two
  /// independently-timed error paths for the same failure).
  Stream<String> get errors => _errorsController.stream;

  void _reportError(String message) {
    if (!_errorsController.isClosed) _errorsController.add(message);
  }

  void updateConfig(DashcamConfig config) {
    _config = config;
  }

  Future<void>? _initializeFuture;

  /// Picks a camera per [DashcamConfig.cameraSelection] and initializes the
  /// controller. Must be called (and awaited) before [startLoopRecording].
  ///
  /// Re-entrant-safe: a second call while one is already in flight returns
  /// the same in-flight [Future] instead of constructing a second
  /// [CameraController] — the structural half of this app's "no duplicate
  /// CameraController" guarantee (the other half is that only
  /// `DashcamSessionController` ever calls this method at all).
  ///
  /// Also safe to call again *sequentially* after a previous call already
  /// completed — e.g. a new driving session starting reuses this same
  /// long-lived [DashcamService], so [DashcamSessionController] calls this
  /// once per session, not just once per app run (see its own doc). Each
  /// call always constructs a fresh [CameraController] (so a config change
  /// made in Settings between sessions — resolution, camera selection —
  /// takes effect on the next session), but does so via [_releaseController]
  /// first, which properly disposes whatever controller is already held.
  /// Physically confirmed on-device (Fase 15 hardware validation) that
  /// without this, each subsequent session leaked the previous
  /// [CameraController]: its native camera2 session was silently pruned by
  /// the platform's own device manager rather than released by this code,
  /// its `_onControllerValueChanged` listener was never removed (so the
  /// leaked controller was kept alive indefinitely by that registration),
  /// and — because that listener reads the *current* [_controller] field
  /// rather than the instance that actually fired — any late error from the
  /// stale controller would have been checked against the wrong
  /// controller's state instead of reported.
  Future<void> initialize() {
    final inFlight = _initializeFuture;
    if (inFlight != null) return inFlight;
    final future = _initialize();
    _initializeFuture = future;
    return future.whenComplete(() => _initializeFuture = null);
  }

  Future<void> _initialize() async {
    await _releaseController();

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available on this device');
    }

    final selected = _pickCamera(cameras);
    final controller = CameraController(
      selected,
      _resolutionPresetFor(_config.resolution),
      enableAudio: _config.audioEnabled,
      fps: _config.frameRate,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    _controller = controller;
    _lastKnownHasError = controller.value.hasError;
    controller.addListener(_onControllerValueChanged);
  }

  /// Edge-triggered: only reports a *new* transition into the error state
  /// (e.g. the hardware being taken by another app mid-recording — an
  /// asynchronous camera-lost error the plugin reports this way, not
  /// something a `try`/`catch` around a single call would ever see), not
  /// every listener tick while already in one.
  void _onControllerValueChanged() {
    final controller = _controller;
    if (controller == null) return;
    final hasError = controller.value.hasError;
    if (hasError && !_lastKnownHasError) {
      _reportError(controller.value.errorDescription ?? 'Erro desconhecido da câmera');
    }
    _lastKnownHasError = hasError;
  }

  CameraDescription _pickCamera(List<CameraDescription> cameras) {
    final direction = switch (_config.cameraSelection) {
      CameraSelection.front => CameraLensDirection.front,
      CameraSelection.rear => CameraLensDirection.back,
      // "both" is not supported by a single CameraController; default to
      // the rear camera until dual-camera capture is implemented.
      CameraSelection.both => CameraLensDirection.back,
    };
    return cameras.firstWhere(
      (camera) => camera.lensDirection == direction,
      orElse: () => cameras.first,
    );
  }

  ResolutionPreset _resolutionPresetFor(VideoResolution resolution) {
    return switch (resolution) {
      VideoResolution.sd480 => ResolutionPreset.medium,
      VideoResolution.hd720 => ResolutionPreset.high,
      VideoResolution.fhd1080 => ResolutionPreset.veryHigh,
      VideoResolution.uhd4k => ResolutionPreset.ultraHigh,
    };
  }

  /// Starts continuous loop recording: a new video segment is started every
  /// [segmentDuration], the previous one is finalized to disk, and storage
  /// quota is enforced after each rotation.
  Future<void> startLoopRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('DashcamService.initialize() must complete first');
    }
    if (_isRecording) return;

    _isRecording = true;
    _segmentStartedAt = DateTime.now();
    await controller.startVideoRecording();
    _segmentTimer = Timer.periodic(segmentDuration, (_) => _rotateSegment());
  }

  Future<void> stopLoopRecording() async {
    if (!_isRecording) return;
    _segmentTimer?.cancel();
    _segmentTimer = null;
    await _finalizeCurrentSegment();
    _isRecording = false;
  }

  Future<void> _rotateSegment() async {
    await _finalizeCurrentSegment();
    final controller = _controller;
    if (controller != null && _isRecording) {
      _segmentStartedAt = DateTime.now();
      await controller.startVideoRecording();
    }
  }

  Future<void> _finalizeCurrentSegment() async {
    final controller = _controller;
    if (controller == null || !controller.value.isRecordingVideo) return;

    final startedAt = _segmentStartedAt ?? DateTime.now();
    // Stamped *before* stopVideoRecording()'s own await, mirroring exactly
    // how [startedAt]/[_segmentStartedAt] is itself stamped before
    // startVideoRecording()'s await in startLoopRecording() (see DashcamClip
    // .recordedAt's own doc for why that symmetry matters) — Fase 15
    // hardware-testing fix: the original code stamped durationSeconds with a
    // fresh DateTime.now() taken at the very end, *after* both
    // stopVideoRecording()'s own finalize latency and the
    // _moveToClipsDirectory() disk copy of the whole video file had already
    // elapsed, silently inflating every clip's stored duration by that
    // finalize+copy time (confirmed physically: a real recorded clip's
    // stored durationSeconds read consistently ~2s longer than the same
    // file's own actual playable length per VideoPlayerController).
    final stoppedAt = DateTime.now();
    final rawFile = await controller.stopVideoRecording();
    final storedFile = await _moveToClipsDirectory(rawFile);
    final size = await storedFile.length();

    _clips.add(
      DashcamClip(
        file: storedFile,
        recordedAt: startedAt,
        sizeBytes: size,
        durationSeconds: stoppedAt.difference(startedAt).inSeconds,
        isProtected: _protectNextFinalizedClip,
      ),
    );
    _protectNextFinalizedClip = false;

    await _enforceStorageQuota();
  }

  Future<File> _moveToClipsDirectory(XFile source) async {
    final directory = await _clipsDirectory();
    final destinationPath =
        '${directory.path}/clip_${DateTime.now().millisecondsSinceEpoch}.mp4';
    return File(source.path).copy(destinationPath);
  }

  Future<Directory> _clipsDirectory() async {
    final documentsDir = await getApplicationDocumentsDirectory();
    final clipsDir = Directory('${documentsDir.path}/dashcam_clips');
    if (!await clipsDir.exists()) {
      await clipsDir.create(recursive: true);
    }
    return clipsDir;
  }

  /// Marks the current clip as protected, so quota enforcement will never
  /// delete it — called when a high/critical-severity event is detected.
  ///
  /// A just-fired event almost always falls inside the segment that's
  /// *currently recording*, not yet finalized into [clips] (segments rotate
  /// every [segmentDuration], typically minutes; events resolve in
  /// milliseconds to a few seconds). Marking only [clips].last would
  /// therefore protect the wrong, usually-irrelevant *previous* segment
  /// while leaving the one that actually contains the event exposed to
  /// deletion. This marks both: [clips].last retroactively (covers the rare
  /// case the event landed right at a segment boundary), and sets a flag so
  /// the segment currently being recorded is also marked protected the
  /// moment it finalizes.
  Future<void> markClipAsProtected() async {
    if (_clips.isNotEmpty) {
      _clips.last.isProtected = true;
    }
    _protectNextFinalizedClip = true;
  }

  /// Deletes oldest unprotected clips until total size is back within
  /// [DashcamConfig.storageQuotaMb].
  Future<void> _enforceStorageQuota() async {
    final quota = quotaBytes;
    var totalBytes = totalClipBytes;
    if (totalBytes <= quota) return;

    final deletable = _clips.where((clip) => !clip.isProtected).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

    for (final clip in deletable) {
      if (totalBytes <= quota) break;
      if (await clip.file.exists()) {
        await clip.file.delete();
      }
      totalBytes -= clip.sizeBytes;
      _clips.remove(clip);
    }
  }

  /// Releases whatever [CameraController] is currently held (a no-op if
  /// none is). Best-effort finalizes a currently-recording segment first
  /// (properly moving/sizing/indexing it, same as a normal
  /// [stopLoopRecording]) rather than bare-calling `stopVideoRecording()`
  /// and discarding the returned file, so a mid-recording teardown (e.g.
  /// widget-tree disposal without process death) doesn't silently lose the
  /// in-flight segment. Wrapped so a finalize failure never blocks
  /// releasing the hardware. Shared by [_initialize] (releasing a previous
  /// session's controller before starting a new one) and [dispose].
  Future<void> _releaseController() async {
    _segmentTimer?.cancel();
    _segmentTimer = null;
    final controller = _controller;
    if (controller != null) {
      if (controller.value.isRecordingVideo) {
        try {
          await _finalizeCurrentSegment();
        } catch (error) {
          _reportError('Falha ao finalizar clipe ao trocar de câmera: $error');
        }
      }
      controller.removeListener(_onControllerValueChanged);
      await controller.dispose();
    }
    _controller = null;
    _isRecording = false;
  }

  /// Releases the camera hardware once a session has ended and none is
  /// about to start — unlike [dispose], this [DashcamService] instance stays
  /// fully alive and reusable (its [errors] stream stays open, and the very
  /// next [initialize] call works exactly as normal; [_releaseController]
  /// is itself idempotent/a no-op if nothing is currently held).
  ///
  /// Fase 15 hardware-testing fix: before this existed, the controller
  /// created by a session's [initialize] call was left held open for the
  /// *rest of the app process's lifetime* once that session ended, if no
  /// further session ever started — [DashcamSessionController] only ever
  /// disposed the *previous* controller as a side effect of a *new* one
  /// starting (see [initialize]'s own doc) or on full app teardown
  /// ([dispose] below), with no path at all for "session over, camera no
  /// longer needed, but the app itself keeps running" — the overwhelmingly
  /// common case (`DashcamPreviewView`'s own idle empty-state never even
  /// reads [previewController] while idle, so nothing was gained by keeping
  /// it open). Confirmed physically via `adb shell dumpsys media.camera`:
  /// this app's own idle, held-open camera-0 client was directly, repeatedly
  /// blocking an unrelated system service (Samsung's own adaptive-brightness
  /// component) from opening a *different* camera on the same device,
  /// logged by the platform's own camera service as "Too many cameras
  /// already open" — a real, externally-visible resource cost, not just a
  /// theoretical one.
  Future<void> releaseIdleCamera() => _releaseController();

  /// Releases the camera hardware for good (see [_releaseController]) and
  /// closes [errors] — call only when this [DashcamService] itself is being
  /// torn down (app/widget-tree disposal). Between sessions while the app
  /// keeps running, use [releaseIdleCamera] instead (this method's own
  /// closing of [errors] would otherwise permanently break every later
  /// session in the same app run); a *new* session starting releases
  /// whatever's still held as a side effect of its own [initialize] call
  /// regardless (see its own doc), so [releaseIdleCamera] and a future
  /// [initialize] never conflict.
  Future<void> dispose() async {
    await _releaseController();
    await _errorsController.close();
  }
}
