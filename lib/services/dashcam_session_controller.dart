import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

import '../models/dashcam_clip_record.dart';
import '../models/dashcam_status.dart';
import '../models/dashcam_telemetry_sample.dart';
import '../models/detected_event.dart';
import '../models/driving_session.dart';
import '../models/telemetry_snapshot.dart';
import 'dashcam_preferences.dart';
import 'dashcam_service.dart';
import 'dashcam_telemetry_writer.dart';
import 'driving_session_recorder.dart';
import 'hive_boxes.dart';

/// Binds [DrivingSessionRecorder]'s session lifecycle to [DashcamService]
/// (Fase 15) — the single entry point the UI calls to start/stop a
/// recording+driving session together, and the only new listener this phase
/// adds to the app's already-shared telemetry/event streams (never a second
/// sensor path — see this app's Fase 15 architecture notes).
///
/// **Failure isolation** (the phase's central requirement): every call into
/// [dashcamService] is wrapped in its own `try`/`catch` here and never
/// rethrown — a camera failure only ever moves [status] to
/// [DashcamStatus.error], it never stops [sessionRecorder] from starting or
/// finishing a session. Symmetrically, [sessionRecorder]/`EventDetectionEngine`
/// receive zero modifications anywhere in this phase and have no reference
/// to any dashcam type — this controller only *reads* their streams, it
/// never calls back into `SensorService`/`TelemetryEngine`, so a telemetry
/// failure has no path into the camera's call stack either.
///
/// **Sampling cadence**: [snapshotStream]'s emission rate is highly
/// non-uniform (~5Hz GPS cadence, but an unthrottled near-accelerometer-rate
/// re-emit during any g-force event — see `DashboardSensorStreams`'s own
/// doc). Rather than writing a telemetry sample on every emission, a
/// snapshot subscription only overwrites a live `_latestSnapshot` field
/// (O(1) per emission), and a separate 200ms timer — deliberately equal to
/// `DashboardSensorStreams.snapshotGpsCadenceGap` — periodically samples
/// whatever it currently holds. A [DetectedEvent] additionally writes one
/// precise, out-of-band sample immediately from its own embedded
/// [TelemetrySnapshot], tagged with its [DetectedEventType].
///
/// **No `RouteAware`/`NavigatorObserver`**: recording is a property of
/// [DashcamService]'s internal state, tied only to session start/stop, and
/// is completely independent of whether any preview widget is currently
/// mounted — entering/exiting fullscreen only mounts/unmounts a
/// `CameraPreview` reading frames, never starts/stops capture.
class DashcamSessionController extends ChangeNotifier with WidgetsBindingObserver {
  DashcamSessionController({
    required this.dashcamService,
    required this.dashcamPreferences,
    required this.sessionRecorder,
    required this.snapshotStream,
    required this.eventStream,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _serviceErrorSub = dashcamService.errors.listen(_onDashcamServiceError);
    dashcamPreferences.addListener(_onPreferencesChanged);
  }

  final DashcamService dashcamService;
  final DashcamPreferences dashcamPreferences;
  final DrivingSessionRecorder sessionRecorder;
  final Stream<TelemetrySnapshot> snapshotStream;
  final Stream<DetectedEvent> eventStream;

  DashcamStatus _liveStatus = DashcamStatus.idle;
  String? errorMessage;
  DateTime? recordingStartedAt;

  /// The session this controller is currently recording (or attempting to
  /// record) for — set synchronously at the very top of [startSession]'s
  /// camera-start attempt, *before* any `await`, and cleared only after
  /// [stopSession]'s camera-finalize path has fully resolved. Using the
  /// controller's own field (rather than reading
  /// `sessionRecorder.activeSession?.id` from inside a finalize callback)
  /// avoids a real race: by the time the *last* segment of a session
  /// finalizes, `sessionRecorder.activeSession` may already be null if
  /// `sessionRecorder.stopSession()` happened to resolve first.
  String? _recordingSessionId;

  /// Snapshot (by object identity — [DashcamClip] has no `==` override, so
  /// this is exact) of every clip [dashcamService] already held *before*
  /// this session's recording started. [dashcamService] is a long-lived,
  /// continuously loop-recording instance shared across every session in
  /// this app run, so "this session's clips" = whatever's in
  /// [DashcamService.clips] afterward that *isn't* in this set — robust
  /// regardless of quota eviction reordering the underlying list mid-session.
  Set<DashcamClip> _clipsBeforeThisSession = {};

  StreamSubscription<String>? _serviceErrorSub;
  StreamSubscription<TelemetrySnapshot>? _snapshotSub;
  StreamSubscription<DetectedEvent>? _eventSub;
  Timer? _sampleTimer;
  TelemetrySnapshot? _latestSnapshot;
  DashcamTelemetryWriter? _telemetryWriter;

  /// Set by [stopSession] for as long as [_stopCamera] is still finishing
  /// the just-ended session's camera-side teardown (finalizing the
  /// in-flight segment, persisting its `DashcamClipRecord`s). [_startCamera]
  /// awaits this first — see its own doc for the real, physically-found bug
  /// this closes.
  Future<void>? _stopCameraFuture;

  static const _sampleInterval = Duration(milliseconds: 200);

  /// [DashcamStatus.disabled] whenever the feature is switched off in
  /// Settings, regardless of any other internal state — otherwise whatever
  /// [_liveStatus] currently reflects (idle/initializing/recording/error).
  DashcamStatus get status => dashcamPreferences.enabled ? _liveStatus : DashcamStatus.disabled;

  int get totalClipBytes => dashcamService.totalClipBytes;
  int get quotaBytes => dashcamService.quotaBytes;

  void _onPreferencesChanged() => notifyListeners();

  void _onDashcamServiceError(String message) {
    _liveStatus = DashcamStatus.error;
    errorMessage = message;
    notifyListeners();
  }

  /// Starts a driving session and (if Dashcam is enabled) recording,
  /// together. [sessionRecorder.startSession] is synchronous and always
  /// succeeds (pure object construction + a Hive put — see its own doc), so
  /// a session is always startable regardless of camera health: the camera
  /// side is fired-and-forgotten, isolated by its own `try`/`catch`.
  DrivingSession startSession() {
    final session = sessionRecorder.startSession();
    if (dashcamPreferences.enabled) {
      _recordingSessionId = session.id;
      unawaited(_startCamera(session.id));
    }
    return session;
  }

  Future<void> _startCamera(String sessionId) async {
    // Wait out any still-finishing previous session's camera teardown
    // first. Physically found on real hardware (Fase 15 validation): back-
    // to-back sessions started faster than the previous one's _stopCamera
    // could finish let this method's guard below see a stale _liveStatus
    // and return early, WITHOUT ever refreshing _clipsBeforeThisSession for
    // the new session. That stale baseline (still the *previous* session's,
    // from before its own clip existed) then made the previous session's
    // already-correctly-persisted clip look "new" again to THIS session's
    // later _persistClipsForSession call, silently duplicating the same
    // clip into both sessions' DashcamClipRecord lists — the previous
    // session's own clip finalizes/persists exactly once regardless,
    // untouched by this wait, since it doesn't depend on anything this
    // method does.
    final pendingStop = _stopCameraFuture;
    if (pendingStop != null) await pendingStop;

    if (_liveStatus == DashcamStatus.initializing || _liveStatus == DashcamStatus.recording) {
      return;
    }
    _liveStatus = DashcamStatus.initializing;
    errorMessage = null;
    notifyListeners();
    try {
      await dashcamService.initialize();
      _clipsBeforeThisSession = dashcamService.clips.toSet();
      await dashcamService.startLoopRecording();

      final writer = DashcamTelemetryWriter(sessionId: sessionId);
      await writer.open();
      _telemetryWriter = writer;

      _latestSnapshot = null;
      _snapshotSub = snapshotStream.listen((snapshot) => _latestSnapshot = snapshot);
      _eventSub = eventStream.listen(_onDetectedEvent);
      _sampleTimer = Timer.periodic(_sampleInterval, (_) => _onSampleTick());

      recordingStartedAt = DateTime.now();
      _liveStatus = DashcamStatus.recording;
    } catch (error) {
      _liveStatus = DashcamStatus.error;
      errorMessage = error.toString();
    }
    notifyListeners();
  }

  void _onSampleTick() {
    final snapshot = _latestSnapshot;
    if (snapshot != null) {
      _telemetryWriter?.add(_sampleFromSnapshot(snapshot));
    }
  }

  void _onDetectedEvent(DetectedEvent event) {
    _telemetryWriter?.add(_sampleFromSnapshot(event.snapshot, eventType: event.type));
    if (event.severity == EventSeverity.high || event.severity == EventSeverity.critical) {
      unawaited(protectCurrentClip());
    }
  }

  DashcamTelemetrySample _sampleFromSnapshot(TelemetrySnapshot snapshot, {DetectedEventType? eventType}) {
    return DashcamTelemetrySample(
      timestamp: snapshot.timestamp,
      latitude: snapshot.latitude,
      longitude: snapshot.longitude,
      speedKmh: snapshot.speedKmh,
      altitudeMeters: snapshot.altitudeMeters,
      headingDegrees: snapshot.headingDegrees,
      pitchDegrees: snapshot.pitchDegrees,
      rollDegrees: snapshot.rollDegrees,
      longitudinalG: snapshot.longitudinalG,
      lateralG: snapshot.lateralG,
      verticalG: snapshot.verticalG,
      resultantG: snapshot.gForceMagnitude,
      eventType: eventType,
    );
  }

  /// Marks the clip currently being recorded as protected against quota
  /// eviction — the replacement for `DashcamService`'s previously-undone
  /// G-force-watcher hook, now driven by [EventDetectionEngine]'s own
  /// already-confirmed, already-debounced events instead of a second
  /// detector. Also reused directly as the fullscreen "Proteger este
  /// clipe" menu action. Best-effort: a failure here must never surface as
  /// an app error, it only means the clip isn't guaranteed protected.
  Future<void> protectCurrentClip() async {
    try {
      await dashcamService.markClipAsProtected();
    } catch (_) {
      // Best-effort, see doc above.
    }
  }

  /// Stops recording and finishes the driving session together.
  /// [sessionRecorder.stopSession] and the camera-finalize path run
  /// concurrently, not strictly sequentially: `DrivingSessionRecorder.stopSession()`
  /// already persists the session as part of its own call, and blocking it
  /// on a slow/hung camera finalize would itself violate this phase's
  /// failure-isolation requirement. The two paths are independent, each its
  /// own `try`/`catch`, joined only by the session id they both key off.
  Future<void> stopSession() async {
    final sessionId = _recordingSessionId;
    Future<void>? cameraStop;
    if (sessionId != null) {
      final future = _stopCamera(sessionId);
      cameraStop = future;
      // Self-clearing (same pattern as DashcamService._initializeFuture):
      // only null it back out if a newer stop hasn't already replaced it.
      _stopCameraFuture = future;
      unawaited(
        future.whenComplete(() {
          if (identical(_stopCameraFuture, future)) _stopCameraFuture = null;
        }),
      );
    }
    await Future.wait<void>([
      sessionRecorder.stopSession(),
      ?cameraStop,
    ]);
  }

  Future<void> _stopCamera(String sessionId) async {
    _snapshotSub?.cancel();
    _snapshotSub = null;
    _eventSub?.cancel();
    _eventSub = null;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _latestSnapshot = null;

    try {
      await dashcamService.stopLoopRecording();
      await _persistClipsForSession(sessionId);
      if (_liveStatus != DashcamStatus.error) {
        _liveStatus = DashcamStatus.idle;
      }
    } catch (error) {
      _liveStatus = DashcamStatus.error;
      errorMessage = error.toString();
    } finally {
      final writer = _telemetryWriter;
      _telemetryWriter = null;
      try {
        await writer?.close();
      } catch (_) {
        // Best-effort — a failure closing the telemetry file must not
        // block finishing the session.
      }
      // Fase 15 hardware-testing fix: this session is over and no new one
      // is starting — release the camera hardware now rather than leaving
      // it held open for the rest of the app process's lifetime (see
      // DashcamService.releaseIdleCamera's own doc for the physically-
      // confirmed real cost of not doing this). Best-effort, matching every
      // other cleanup step in this block: a failure here must not block
      // finishing the session, and a future session's own initialize()
      // would release/replace whatever's left held regardless.
      try {
        await dashcamService.releaseIdleCamera();
      } catch (_) {
        // Best-effort — see above.
      }
      if (_recordingSessionId == sessionId) {
        _recordingSessionId = null;
      }
      recordingStartedAt = null;
      notifyListeners();
    }
  }

  Future<void> _persistClipsForSession(String sessionId) async {
    final newClips = dashcamService.clips.where((clip) => !_clipsBeforeThisSession.contains(clip)).toList();
    if (newClips.isEmpty) return;

    final records = newClips
        .map(
          (clip) => DashcamClipRecord(
            filePath: clip.file.path,
            recordedAt: clip.recordedAt,
            durationSeconds: clip.durationSeconds,
            sizeBytes: clip.sizeBytes,
            isProtected: clip.isProtected,
            resolution: dashcamPreferences.resolution,
            audioEnabled: dashcamPreferences.audioEnabled,
          ),
        )
        .toList();

    final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
    // Same cast-on-read pattern DrivingSessionRecorder._flush already uses:
    // Hive deserializes a stored List back as plain List<dynamic>, so an
    // unchecked cast to the generic type fails at runtime even though every
    // element genuinely is one — List<T>.from performs the safe per-element
    // cast instead.
    final raw = box.get(sessionId) as List?;
    final existing = raw == null ? <DashcamClipRecord>[] : List<DashcamClipRecord>.from(raw);
    existing.addAll(records);
    await box.put(sessionId, existing);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_handleLifecycleChange(state));
  }

  Future<void> _handleLifecycleChange(AppLifecycleState state) async {
    final controller = dashcamService.previewController;
    try {
      if (state == AppLifecycleState.paused) {
        await controller?.pausePreview();
      } else if (state == AppLifecycleState.resumed) {
        await controller?.resumePreview();
        if (_liveStatus == DashcamStatus.error && _recordingSessionId != null) {
          await _attemptRecoveryRestart();
        }
      }
    } catch (_) {
      // Best-effort — a preview pause/resume failure must not crash the
      // app. Recording itself (not the preview) is what matters, and it is
      // unaffected: CameraController.startVideoRecording already defaults
      // enablePersistentRecording to true, asking the platform not to
      // auto-stop on a lifecycle event — relied on here rather than
      // reimplemented.
    }
  }

  /// Manually retries starting the camera after an error — the explicit
  /// "Tentar novamente" action in the preview UI. A no-op if there's no
  /// active recording session to retry for (e.g. the session already ended).
  Future<void> retryCamera() => _attemptRecoveryRestart();

  Future<void> _attemptRecoveryRestart() async {
    final sessionId = _recordingSessionId;
    if (sessionId == null) return;
    _liveStatus = DashcamStatus.initializing;
    errorMessage = null;
    notifyListeners();
    try {
      await dashcamService.initialize();
      await dashcamService.startLoopRecording();
      _liveStatus = DashcamStatus.recording;
    } catch (error) {
      _liveStatus = DashcamStatus.error;
      errorMessage = error.toString();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    dashcamPreferences.removeListener(_onPreferencesChanged);
    unawaited(_serviceErrorSub?.cancel());
    _snapshotSub?.cancel();
    _eventSub?.cancel();
    _sampleTimer?.cancel();
    unawaited(_telemetryWriter?.close());
    unawaited(dashcamService.dispose());
    super.dispose();
  }
}
