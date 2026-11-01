// Fase 16.2-R4.3-R2.6.17 — START attempt settlement, through the real
// DashcamSessionController (a driving session with the dashcam on).
//
// The contract itself is pinned on DashcamService
// (dashcam_start_attempt_settlement_test.dart): the service must be correct by
// itself, whatever calls it. These are an additional regression through the
// controller, with the same harness as
// dashcam_start_intent_ownership_session_test.dart — real controller, recorder
// and Hive, fake camera platform — for the one thing of this round a driving
// session can meet through the app: the camera START outliving its deadline and
// succeeding afterwards.
//
// They do not claim that the two sequences the independent review reproduced on
// the service (a stale cleanup withdrawing a newer START; a second START
// accepted on the same camera after the first one's deadline) can be produced
// through the controller: it re-initializes the camera before a new START.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_camera_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeCameraPlatform fakePlatform;
  late StreamController<TelemetrySnapshot> snapshotController;
  late StreamController<DetectedEvent> eventController;
  late DrivingSessionRecorder recorder;
  late DashcamPreferences preferences;
  late DashcamService service;
  late DashcamSessionController controller;
  Timer? snapshotFeeder;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;

  /// The largest number of cameras open at the same time, from the fake
  /// platform's own call order.
  int maxCamerasOpenAtOnce() {
    var open = 0;
    var max = 0;
    for (final call in fakePlatform.calls) {
      if (call == 'createCameraWithSettings') open++;
      if (call == 'dispose') open--;
      if (open > max) max = open;
    }
    return max;
  }

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail(
      'never happened within ${within.inMilliseconds} ms: $what '
      '(status=${controller.status.name}, isRecording=${service.isRecording}, attemptSettling=${service.startAttemptSettling}, '
      'pendingStop=${service.hasPendingNativeStop}, unavailable=${service.cameraKnownUnavailable}, startFates=${service.startFatesForTest}, '
      'calls=${fakePlatform.calls.join(',')})',
    );
  }

  /// The camera START deadline is short enough to elapse within a test; every
  /// other deadline is the product's own.
  void build() {
    final config = DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    );
    service = DashcamService(config: config, segmentDuration: const Duration(minutes: 10), startVideoRecordingTimeout: const Duration(milliseconds: 60));
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  }

  /// The clips the session's own index holds, each with its file still present.
  List<DashcamClipRecord> indexedClips(String sessionId) {
    final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List?;
    final records = raw == null ? <DashcamClipRecord>[] : List<DashcamClipRecord>.from(raw);
    for (final record in records) {
      expect(File(record.filePath).existsSync(), isTrue, reason: 'indexed clip without its file: ${record.filePath}');
    }
    return records;
  }

  /// A session is started, the native START of its camera is held, and the
  /// session has seen the START deadline: its status is `error`, the native
  /// call has not returned.
  Future<(DrivingSession, Completer<void>)> startSessionAndLetTheStartDeadlineElapse() async {
    await preferences.setEnabled(true);
    final gate = Completer<void>();
    fakePlatform.pendingStartVideoCapturing = gate;
    final session = controller.startSession();
    await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of the session\'s camera being issued and held');
    await waitUntil(() => controller.status == DashcamStatus.error, 'the session seeing the START deadline');
    expect(count('startVideoCapturing'), 1, reason: 'test setup: the native START has not returned');
    expect(service.isRecording, isFalse);
    expect(service.startAttemptSettling, isTrue, reason: 'test setup: the attempt is still settling');
    expect(count('stopVideoRecording'), 0);
    return (session, gate);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_start_attempt_settlement_session_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
      Hive.registerAdapter(CameraSelectionAdapter());
      Hive.registerAdapter(VideoResolutionAdapter());
      Hive.registerAdapter(DashcamConfigAdapter());
      Hive.registerAdapter(DashcamClipRecordAdapter());
    }
    Hive.init(dir.path);
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);

    snapshotController = StreamController<TelemetrySnapshot>.broadcast();
    eventController = StreamController<DetectedEvent>.broadcast();
    recorder = DrivingSessionRecorder(snapshotController.stream);
    preferences = DashcamPreferences();
    // The session keeps receiving telemetry the whole time, as on the road.
    snapshotFeeder = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!snapshotController.isClosed) {
        snapshotController.add(
          TelemetrySnapshot(timestamp: DateTime.now(), speedKmh: 42, gForceMagnitude: 0.1, gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable),
        );
      }
    });
    build();
  });

  tearDown(() async {
    snapshotFeeder?.cancel();
    final gate = fakePlatform.pendingStartVideoCapturing;
    fakePlatform.pendingStartVideoCapturing = null;
    if (gate != null && !gate.isCompleted) gate.complete();
    try {
      controller.dispose();
    } catch (_) {}
    await waitUntil(
      () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null && !DashcamService.processOwnerIsUncertainForTest,
      'the service being released in tearDown',
      within: const Duration(seconds: 10),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await snapshotController.close();
    await eventController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    for (var attempt = 0; ; attempt++) {
      try {
        dir.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test(
    'X311 — the camera START of a session outlives its deadline and then succeeds: the session already shows the error, and '
    'the camera is not left recording behind it — the service stops the late Recording itself, once. Ending the session '
    'then releases the camera with nothing left to stop, and the late clip is the session\'s own',
    () async {
      final (session, gate) = await startSessionAndLetTheStartDeadlineElapse();
      try {
        fakePlatform.pendingStartVideoCapturing = null;
        gate.complete();
        // By cause: the attempt has finished, whatever it did with what it created.
        await waitUntil(() => !service.startAttemptSettling && !service.hasPendingNativeStop, 'the START attempt finishing');

        expect(count('stopVideoRecording'), 1, reason: 'the late Recording was stopped by the attempt that created it');
        expect(service.previewController!.value.isRecordingVideo, isFalse, reason: 'no camera left recording under an error status');
        expect(service.isRecording, isFalse);
        expect(service.hasActiveSegmentTimerForTest, isFalse);
        expect(controller.status, DashcamStatus.error, reason: 'a late success is not turned into a recording');
        expect(service.clips.map((c) => c.producerToken), [session.id]);

        await controller.stopSession();
        // R4.4-R2.1.1-F1 — ANTES: stopSession() returned after its STOP's index pass, which waits for the late clip's
        // own index write. MOTIVO: that pass is no longer awaited by the STOP (RES-1); with a slightly slower index the
        // entry was not there yet when read below (independent review, F1). DEPOIS: X311 awaits this session's passes.
        await controller.clipIndexFollowUpsSettledForTest(sessionId: session.id);
        await waitUntil(
          () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null && recorder.state == DrivingSessionRecorderState.idle,
          'ending the session releasing the camera',
          within: const Duration(seconds: 10),
        );
        expect(count('stopVideoRecording'), 1, reason: 'ending the session had nothing left to stop');
        expect(count('startVideoCapturing'), 1);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(service.clips.map((c) => c.producerToken), [session.id]);
        expect(indexedClips(session.id), hasLength(1), reason: 'the late clip reached the session\'s own index');

        expect(service.startFatesForTest['ownRecordingFinalized'], 1);
      } finally {
        fakePlatform.pendingStartVideoCapturing = null;
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X312 — "try again" while that native START is still in flight: the retry waits behind it and opens no second camera; '
    'when the native call returns, the late Recording is stopped once — by the retry\'s own teardown, not a second time '
    'by the attempt — the camera is replaced, and the same session records on the new one',
    () async {
      final (session, gate) = await startSessionAndLetTheStartDeadlineElapse();
      try {
        final firstCamera = service.previewController;
        final retry = controller.retryCamera();
        await waitUntil(() => service.pendingInitializeSettlement != null, 'the retry\'s initialize being queued');
        expect(count('createCameraWithSettings'), 1, reason: 'no second camera while the first native START is in flight');
        expect(count('startVideoCapturing'), 1);

        fakePlatform.pendingStartVideoCapturing = null;
        gate.complete();
        await retry.timeout(const Duration(seconds: 8));
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 2, 'the retry recording on a new camera');

        expect(count('stopVideoRecording'), 1, reason: 'the late Recording was stopped once');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(service.previewController, isNot(same(firstCamera)));
        expect(service.previewController!.value.isRecordingVideo, isTrue);
        expect(service.cameraKnownUnavailable, isFalse, reason: 'a fresh camera starts clean');
        expect(recorder.activeSession?.id, session.id, reason: 'the same driving session');

        await controller.stopSession();
        // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
        // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
        // pass is awaited here, where this test reads what it wrote.
        await controller.clipIndexFollowUpsSettledForTest();
        await waitUntil(
          () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null && recorder.state == DrivingSessionRecorderState.idle,
          'ending the session releasing the camera',
          within: const Duration(seconds: 10),
        );
        expect(count('stopVideoRecording'), 2);
        expect(service.clips.map((c) => c.producerToken), [session.id, session.id]);
        expect(indexedClips(session.id), hasLength(2));

        expect(service.startFatesForTest['ownRecordingFinalized'], 0, reason: 'the retry\'s teardown owned the late Recording');
      } finally {
        fakePlatform.pendingStartVideoCapturing = null;
        if (!gate.isCompleted) gate.complete();
      }
    },
  );
}
