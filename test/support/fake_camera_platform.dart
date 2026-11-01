import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';

/// A minimal, real (not mocked) [CameraPlatform] implementation for tests —
/// the same seam the `camera` plugin's own test suite uses
/// (`CameraPlatform.instance` is a settable static), letting Fase 15's
/// dashcam code run against a genuine `CameraController` in unit tests
/// without touching real hardware.
///
/// Only implements the subset of [CameraPlatform] that
/// `CameraController.initialize()`/`startVideoRecording()`/
/// `stopVideoRecording()`/`pausePreview()`/`resumePreview()`/`dispose()`
/// actually call (verified by reading `camera-0.12.0+2`'s own source) —
/// every other method keeps the base class's `UnimplementedError` default,
/// which is intentional: a test that exercises a path this fake doesn't
/// support should fail loudly, not silently succeed against an
/// under-specified double.
class FakeCameraPlatform extends CameraPlatform {
  FakeCameraPlatform({required this.tempDir});

  final Directory tempDir;

  List<CameraDescription> availableCamerasResult = const [
    CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90),
    CameraDescription(name: 'front', lensDirection: CameraLensDirection.front, sensorOrientation: 270),
  ];

  /// When set, [createCameraWithSettings] throws this instead of succeeding
  /// — the seam tests use to simulate `DashcamService.initialize()` failing
  /// (e.g. no camera hardware, permission denied).
  Object? failCreateCameraWith;

  /// When set, [stopVideoRecording] throws this instead of succeeding —
  /// simulates a segment finalize failing mid-recording.
  Object? failStopVideoRecordingWith;

  /// When set, [resumePreview] throws this instead of succeeding — simulates
  /// a real-device finding (Fase 16.2): resuming an old `CameraController`
  /// whose camera Android already revoked while backgrounded throws a
  /// platform exception, not a silent no-op.
  Object? failResumePreviewWith;

  /// Fase 16.2-R4.2A-R3 (§12): when set, [dispose] throws this instead of
  /// succeeding. Realistic, not invented — `CameraController.dispose()`
  /// (`camera-0.12.0+2`) awaits `CameraPlatform.instance.dispose(_cameraId)`
  /// with no `try`/`catch` of its own, so a platform-side dispose failure
  /// (the real `camera_android_camerax` plugin's own `unbindAll()` could
  /// plausibly throw) propagates directly out of `CameraController.dispose()`
  /// exactly as this fake reproduces here. Exists to test that a LATE
  /// teardown failure (`controller.dispose()` failing only after a pending
  /// native stop it was queued behind finally resolves) is still observed
  /// and reported exactly once, never left as an unhandled async error.
  Object? failDisposeWith;

  /// When set, [stopVideoRecording] awaits this before returning — lets a
  /// test simulate a camera-side finalize that's slower than other
  /// concurrent async work (e.g. `DrivingSessionRecorder.stopSession()`'s
  /// own, much lighter Hive-only path), the same real-world relative timing
  /// physical hardware testing found (Fase 15: a several-MB video file's
  /// MediaRecorder finalize + disk copy routinely outlasts the driving
  /// session's own stop bookkeeping). `null` (no delay) by default — every
  /// test that doesn't set this is unaffected.
  Duration? stopVideoRecordingDelay;

  /// Fase 16.2-R1 (independent review §18/§19): when set, [stopVideoRecording]
  /// awaits this [Completer] (in addition to [stopVideoRecordingDelay], if
  /// also set) before returning — lets a test control *exactly* when a
  /// native stop "completes", including completing it deliberately *after*
  /// `DashcamService`'s own [Duration]-based timeout has already fired and
  /// moved on (`stopVideoRecordingDelay` alone can only simulate a fixed
  /// wall-clock delay, not "complete on command" — real tests of a late
  /// native completion need the latter, or they'd need to guess a delay
  /// longer than the timeout and then simply wait it out for real, which
  /// works but is slow and timing-fragile). `null` by default — every test
  /// that doesn't set this is unaffected.
  Completer<void>? pendingStopVideoRecording;

  /// Same idea as [pendingStopVideoRecording], for [startVideoCapturing]
  /// (Fase 16.2-R1 §18, "start nativo tardio" scenarios).
  Completer<void>? pendingStartVideoCapturing;

  /// Fase 16.2-R4.2A-R6 (§23): same idea as [pendingStopVideoRecording],
  /// for [dispose] — lets a test deterministically pause teardown at the
  /// exact point `controller.dispose()` itself is in flight, instead of
  /// relying on a fixed poll interval happening to land inside whatever
  /// (otherwise near-instant) window it actually takes.
  Completer<void>? pendingDispose;

  /// When set, [startVideoCapturing] throws this instead of succeeding —
  /// simulates the platform itself rejecting a start (Fase 16.2-R1 §18
  /// scenario C, "global native recording ainda ocupado": the real
  /// `camera_android_camerax` plugin tracks a single active `Recording`
  /// internally and would reject/misbehave on a second concurrent start;
  /// this fake does not model that internal state fully, only lets a test
  /// force the same *externally observable* failure).
  Object? failStartVideoCapturingWith;

  int _nextCameraId = 0;
  int _clipIndex = 0;

  final List<String> calls = [];
  MediaSettings? lastMediaSettings;

  /// Fase 16.2-R4.3-R2.2 (§34, independent-review — "L5-S correlaciona STOP
  /// com Recording G1, não apenas 'algum STOP aconteceu'"): the `cameraId`
  /// each real [stopVideoRecording] call targeted, in call order — lets a
  /// test confirm a specific observed STOP genuinely concerned a specific
  /// controller's own camera, not merely that `calls` grew.
  final List<int> stopVideoRecordingCameraIds = [];

  /// The real [VideoCaptureOptions] most recently passed to
  /// [startVideoCapturing] — Fase 16.2-R4.1A: lets a test verify what
  /// `DashcamService` actually requests from the platform (e.g.
  /// `enablePersistentRecording`) without inventing a fake-only API.
  VideoCaptureOptions? lastStartVideoCapturingOptions;
  final List<int> disposedCameraIds = [];
  bool previewPaused = false;

  // `CameraController._initializeWithDescription` calls `.first` on both of
  // these — a stream that closes without ever emitting (e.g. `Stream.empty()`)
  // makes `.first` throw `StateError('No element')` as soon as it closes.
  // Real, never-auto-closing broadcast controllers let `.first` simply wait,
  // exactly like the real platform's error/closing channels do when nothing
  // has gone wrong — tests can push onto these directly to simulate one.
  final StreamController<CameraErrorEvent> _errorController = StreamController<CameraErrorEvent>.broadcast();
  final StreamController<CameraClosingEvent> _closingController = StreamController<CameraClosingEvent>.broadcast();

  /// Fase 16.2-R4.2B-R3 (§11/§12): when set, [availableCameras] awaits this
  /// before returning — lets a test deterministically hold device discovery
  /// open past a presentation deadline (the reviewer's own identified
  /// latency point), without a real delay. `null` (no gate) by default —
  /// every test that doesn't set this is unaffected.
  Completer<void>? pendingAvailableCameras;

  /// Fase 16.2-R4.2B-R4 (intervention — test determinism correction):
  /// completes the INSTANT [availableCameras] is called while
  /// [pendingAvailableCameras] is set — i.e. the moment discovery is
  /// genuinely about to block on that gate — so a test can `await` this
  /// as causal proof that discovery actually entered the gate, instead of
  /// inferring it from a fixed real-time delay. `null` by default — every
  /// test that doesn't explicitly set this is unaffected (this fake never
  /// reads it unless set, and never appends anything to [calls] for it).
  Completer<void>? availableCamerasEnteredForTest;

  @override
  Future<List<CameraDescription>> availableCameras() async {
    final pending = pendingAvailableCameras;
    if (pending != null) {
      availableCamerasEnteredForTest?.complete();
      await pending.future;
    }
    return availableCamerasResult;
  }

  @override
  Future<int> createCameraWithSettings(CameraDescription cameraDescription, MediaSettings mediaSettings) async {
    calls.add('createCameraWithSettings');
    lastMediaSettings = mediaSettings;
    final failure = failCreateCameraWith;
    if (failure != null) throw failure;
    return _nextCameraId++;
  }

  /// Fase 16.2-R1 (§18 scenario F, "initialize lento + dispose"): when set,
  /// [initializeCamera] awaits this before returning — controls exactly how
  /// long `CameraController.initialize()` (and therefore
  /// `DashcamService.initialize()`) takes to reach the point a concurrent
  /// [dispose] call could interleave with.
  Completer<void>? pendingInitializeCamera;

  @override
  Future<void> initializeCamera(int cameraId, {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    calls.add('initializeCamera');
    final pending = pendingInitializeCamera;
    if (pending != null) await pending.future;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) {
    return Stream.value(
      CameraInitializedEvent(cameraId, 1920, 1080, ExposureMode.auto, false, FocusMode.auto, false),
    );
  }

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errorController.stream;

  /// Lets a test simulate an asynchronous camera-lost error (e.g. hardware
  /// taken by another app mid-recording) — the exact case
  /// `DashcamService._onControllerValueChanged` exists to surface via its
  /// own `errors` stream.
  void emitCameraError(int cameraId, String description) {
    _errorController.add(CameraErrorEvent(cameraId, description));
  }

  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) => _closingController.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() {
    // Only ever `.listen()`'d (never `.first`'d) by CameraController, so —
    // unlike onCameraError/onCameraClosing above — a stream that closes
    // immediately without emitting is completely safe here.
    return const Stream<DeviceOrientationChangedEvent>.empty();
  }

  @override
  Future<void> prepareForVideoRecording() async {
    calls.add('prepareForVideoRecording');
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    calls.add('startVideoCapturing');
    lastStartVideoCapturingOptions = options;
    final failure = failStartVideoCapturingWith;
    if (failure != null) throw failure;
    final pending = pendingStartVideoCapturing;
    if (pending != null) await pending.future;
  }

  /// Fase 16.2-R4.4-R1.2 (X66, single physical STOP): native stops currently
  /// inside [stopVideoRecording] (entered, not yet returned or thrown), and the
  /// most there ever were at once. Counting only — no behavior depends on it.
  int activeStopVideoRecordingCount = 0;
  int maxConcurrentStopVideoRecording = 0;

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    calls.add('stopVideoRecording');
    stopVideoRecordingCameraIds.add(cameraId);
    activeStopVideoRecordingCount++;
    if (activeStopVideoRecordingCount > maxConcurrentStopVideoRecording) maxConcurrentStopVideoRecording = activeStopVideoRecordingCount;
    try {
      final failure = failStopVideoRecordingWith;
      if (failure != null) throw failure;
      final pending = pendingStopVideoRecording;
      if (pending != null) await pending.future;
      final delay = stopVideoRecordingDelay;
      if (delay != null) await Future<void>.delayed(delay);
      final file = File('${tempDir.path}/fake_clip_${_clipIndex++}.mp4');
      // Non-empty so DashcamService's own File.length() read has something
      // real to report — content itself is never inspected by this app.
      file.writeAsBytesSync(List<int>.filled(1024, 0));
      return XFile(file.path);
    } finally {
      activeStopVideoRecordingCount--;
    }
  }

  /// Fase 16.2-R4.3-R1 (§46, D0-approved lifecycle-generation architecture —
  /// "gates determinísticos para preview"): when set, [pausePreview] awaits
  /// this before returning. `null` (no gate) by default — every test that
  /// doesn't set this is unaffected.
  Completer<void>? pendingPausePreview;

  /// Same idea as [pendingPausePreview], for [resumePreview].
  Completer<void>? pendingResumePreview;

  /// Fase 16.2-R4.3-R1 (§46): completes the INSTANT [resumePreview] is
  /// called while [pendingResumePreview] is set — i.e. the moment this call
  /// is genuinely about to block on the gate — so a test can `await` this as
  /// causal proof that the resumed handler actually entered `resumePreview()`
  /// before releasing the gate, instead of inferring it from a fixed delay
  /// (mirrors [availableCamerasEnteredForTest]'s own established pattern).
  /// `null` by default — every test that doesn't explicitly set this is
  /// unaffected.
  Completer<void>? resumePreviewEnteredForTest;

  @override
  Future<void> pausePreview(int cameraId) async {
    calls.add('pausePreview');
    final pending = pendingPausePreview;
    if (pending != null) await pending.future;
    previewPaused = true;
  }

  @override
  Future<void> resumePreview(int cameraId) async {
    calls.add('resumePreview');
    final pending = pendingResumePreview;
    if (pending != null) {
      resumePreviewEnteredForTest?.complete();
      await pending.future;
    }
    final failure = failResumePreviewWith;
    if (failure != null) throw failure;
    previewPaused = false;
  }

  @override
  Future<void> dispose(int cameraId) async {
    calls.add('dispose');
    final failure = failDisposeWith;
    if (failure != null) throw failure;
    final pending = pendingDispose;
    if (pending != null) await pending.future;
    disposedCameraIds.add(cameraId);
  }

  // Deliberately no close()/disposeFake() for _errorController/
  // _closingController: CameraController._initializeWithDescription attaches
  // a fire-and-forget `.first` listener to each (unawaited, meant to resolve
  // only if a real error/closing event ever arrives) and never cancels it.
  // Closing the controller out from under that still-pending listener (e.g.
  // from a test's tearDown) makes `.first` complete with a `StateError('No
  // element')` — an unhandled async error that then surfaces during
  // whichever test happens to be running when it fires, not this one. Each
  // test constructs a fresh FakeCameraPlatform, so simply leaving these
  // open for the object's lifetime (garbage-collected with it) is correct,
  // not a leak.
}
