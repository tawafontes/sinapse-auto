// Fase 16.2-R4.3-R2.6.18 — cleanup ownership, through the real
// DashcamSessionController (a driving session with the dashcam on).
//
// The contract itself is pinned on DashcamService
// (dashcam_cleanup_ownership_test.dart): the service must be correct by itself,
// whatever calls it. These pin the CALLER's half: whenever the controller
// cleans up a camera START it no longer wants, it names that START — the
// identity the service handed out when the START was accepted — and nothing
// else. Until this round it named the service's camera and whatever Recording
// id the service held after the START returned.
//
// That half has no physical trace of its own: in every flow a driving session
// can go through, something else stops the same Recording too (the stop that
// ends the session, the teardown of the camera, or the START attempt itself).
// So these tests read WHICH START each cleanup named from the service's own
// record of the stop requests it received (`stopIntentsForTest`), next to the
// physical outcome.
//
// They do not claim that the sequences the review reproduced on the service
// (R1: a cleanup that names only the camera withdrawing a newer START) can be
// produced through the controller: every camera attempt opens its own camera.
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
import 'support/index_queue_isolation.dart';

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

  /// [shortStartDeadline] makes the camera START deadline short enough to elapse
  /// within a test (it only ever elapses over a native START the test holds);
  /// every other deadline is the product's own.
  void build({bool shortStartDeadline = false}) {
    final config = DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    );
    service = shortStartDeadline
        ? DashcamService(config: config, segmentDuration: const Duration(minutes: 10), startVideoRecordingTimeout: const Duration(milliseconds: 60))
        : DashcamService(config: config, segmentDuration: const Duration(minutes: 10));
    // The service's own record of every stop request it receives from here on.
    service.trackStopIntentsForTest = true;
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  }

  /// The START each cleanup the service received was issued for, in order — a
  /// `null` entry is a cleanup that named a camera or a Recording instead.
  List<int?> startsNamedByTheCleanups() => [
    for (final intent in service.stopIntentsForTest)
      if (intent.purpose == 'targetedCleanup') intent.attemptEpoch,
  ];

  /// The clips the session's own index holds, each with its file still present.
  List<DashcamClipRecord> indexedClips(String sessionId) {
    final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List?;
    final records = raw == null ? <DashcamClipRecord>[] : List<DashcamClipRecord>.from(raw);
    for (final record in records) {
      expect(File(record.filePath).existsSync(), isTrue, reason: 'indexed clip without its file: ${record.filePath}');
    }
    return records;
  }

  Future<void> waitForTheCameraToBeReleased() {
    return waitUntil(
      () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null && recorder.state == DrivingSessionRecorderState.idle,
      'the camera being released and the session being over',
      within: const Duration(seconds: 10),
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_cleanup_ownership_session_test');
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
    // Fase 16.2-R4.4-R2.1.1-F1-R (test isolation): every camera is released, so
    // no late STOP pass can still queue; the index turns this test left (a test
    // that does not read the index does not wait for them) settle here, against
    // this test's boxes and directory — never inside the next test's FIFO.
    await indexQueueSettledForTest();
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
    'X338 — a session is ended while the native START of its camera is in flight. When that START returns, the controller '
    'cleans up the attempt it no longer wants by naming THAT START — once, and never the camera or a Recording id. The '
    'Recording is stopped once, its clip reaches the session\'s index, and nothing is left recording',
    () async {
      build();
      await preferences.setEnabled(true);
      final gate = Completer<void>();
      fakePlatform.pendingStartVideoCapturing = gate;
      try {
        final session = controller.startSession();
        await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of the session\'s camera being issued and held');
        final theStart = service.startIntentEpochForTest;

        final stopping = controller.stopSession();
        // By cause: the stop that ends the session has taken the camera START's intent down.
        await waitUntil(() => !service.isRecording, 'the session\'s stop reaching the service');
        expect(startsNamedByTheCleanups(), isEmpty, reason: 'test setup: the START has not returned, the controller has cleaned up nothing yet');

        fakePlatform.pendingStartVideoCapturing = null;
        gate.complete();
        await stopping.timeout(const Duration(seconds: 8));
        await waitForTheCameraToBeReleased();

        expect(count('startVideoCapturing'), 1);
        expect(count('stopVideoRecording'), 1, reason: 'the Recording that START produced was stopped once');
        expect(service.isRecording, isFalse);
        expect(service.clips.map((c) => c.producerToken), [session.id]);
        await waitUntil(() => indexedClips(session.id).length == 1, 'the late clip reaching the session\'s index');
        expect(startsNamedByTheCleanups(), [theStart], reason: 'the controller cleaned up exactly the START it had issued');
      } finally {
        fakePlatform.pendingStartVideoCapturing = null;
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X339 — the camera START of a session outlives its deadline: the controller, seeing no recording, cleans up by naming '
    'that START. Nothing is stopped by that cleanup — there is nothing yet — and when the native call returns the '
    'service stops the late Recording itself',
    () async {
      build(shortStartDeadline: true);
      await preferences.setEnabled(true);
      final gate = Completer<void>();
      fakePlatform.pendingStartVideoCapturing = gate;
      try {
        final session = controller.startSession();
        await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of the session\'s camera being issued and held');
        final theStart = service.startIntentEpochForTest;
        await waitUntil(() => controller.status == DashcamStatus.error, 'the session seeing the START deadline');

        expect(startsNamedByTheCleanups(), [theStart], reason: 'the cleanup of a START that produced no Recording still names that START — not the camera');
        expect(count('stopVideoRecording'), 0, reason: 'there was nothing to stop yet');
        expect(service.startAttemptSettling, isTrue, reason: 'test setup: the native START has not returned');

        fakePlatform.pendingStartVideoCapturing = null;
        gate.complete();
        await waitUntil(() => !service.startAttemptSettling && !service.hasPendingNativeStop, 'the START attempt finishing');
        expect(count('stopVideoRecording'), 1, reason: 'the late Recording was stopped by the attempt that created it');
        expect(service.previewController!.value.isRecordingVideo, isFalse);
        expect(controller.status, DashcamStatus.error);

        await controller.stopSession();
        // R4.4-R2.1.1-F1 — ANTES: stopSession() returned after its STOP's index pass, which waits for the late clip's
        // own index write. MOTIVO: that pass is no longer awaited by the STOP (RES-1); with a slightly slower index the
        // entry was not there yet when read below (independent review, F1). DEPOIS: X339 awaits this session's passes.
        await controller.clipIndexFollowUpsSettledForTest(sessionId: session.id);
        await waitForTheCameraToBeReleased();
        expect(count('stopVideoRecording'), 1);
        expect(indexedClips(session.id), hasLength(1));
        expect(startsNamedByTheCleanups(), [theStart], reason: 'ending the session cleaned up no other START');
      } finally {
        fakePlatform.pendingStartVideoCapturing = null;
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X340 — the recovery path: the app goes to the background and returns, the recovery opens a new camera, and the session '
    'is ended while the native START of that recovery is in flight. The controller cleans up by naming the recovery\'s own '
    'START — a later one than the session\'s first — and nothing is left recording',
    () async {
      build();
      await preferences.setEnabled(true);
      final gate = Completer<void>();
      try {
        final session = controller.startSession();
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 1, 'the session recording');
        final theFirstStart = service.startIntentEpochForTest;

        final firstCamera = service.previewController;
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await waitUntil(() => controller.status == DashcamStatus.cameraUnavailable, 'the session seeing the background');
        fakePlatform.pendingStartVideoCapturing = gate;
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of the recovery being issued and held');
        final theRecoveryStart = service.startIntentEpochForTest;
        expect(theRecoveryStart, greaterThan(theFirstStart), reason: 'test setup: the recovery is a START of its own');
        expect(service.previewController, isNot(same(firstCamera)), reason: 'test setup: on a camera of its own');
        expect(startsNamedByTheCleanups(), isEmpty, reason: 'test setup: nothing was cleaned up by name so far');
        final stopsBeforeTheEnd = count('stopVideoRecording');

        final stopping = controller.stopSession();
        await waitUntil(() => !service.isRecording, 'the session\'s stop reaching the service');
        fakePlatform.pendingStartVideoCapturing = null;
        gate.complete();
        await stopping.timeout(const Duration(seconds: 8));
        await waitForTheCameraToBeReleased();

        expect(count('startVideoCapturing'), 2);
        expect(count('stopVideoRecording'), stopsBeforeTheEnd + 1, reason: 'the Recording the recovery\'s START produced was stopped once');
        expect(service.isRecording, isFalse);
        expect(service.clips.map((c) => c.producerToken), everyElement(session.id));
        expect(startsNamedByTheCleanups(), [theRecoveryStart], reason: 'the controller cleaned up exactly the recovery\'s START');
      } finally {
        fakePlatform.pendingStartVideoCapturing = null;
        if (!gate.isCompleted) gate.complete();
      }
    },
  );
}
