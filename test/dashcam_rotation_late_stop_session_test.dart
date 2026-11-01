// Fase 16.2-R4.3-R2.6.14 — late STOP settlement / automatic rotation recovery,
// through the real DashcamSessionController (a driving session with the dashcam
// on): what the user is shown, how many cameras exist, and what the session
// ends up with.
//
// X230 is the scenario the Samsung SM-A326B produced on 2026-10-07 with the
// product's own numbers: a segment rotation whose native stop takes 6.95 s
// against the 5 s stopVideoRecordingTimeout and then succeeds. Before this
// round the status stayed "Câmera indisponível" and the session had no video
// from that point on. The other tests use a short deadline and wait by cause
// (the fake camera's stop is held until the service has reported the deadline).
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

  /// The largest number of cameras open at the same time, from the fake
  /// platform's own call order (open at `createCameraWithSettings`, closed at
  /// `dispose`).
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
      '(status=${controller.status.name}, overdue=${service.rotationStopOverdue}, pendingStop=${service.hasPendingNativeStop}, '
      'unavailable=${service.cameraKnownUnavailable}, lateDecision=${service.lastLateRotationDecisionForTest}, calls=${fakePlatform.calls.join(',')})',
    );
  }

  Future<void> neverDuring(Duration window, bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      if (condition()) fail('must not happen, but did after ${clock.elapsedMilliseconds} ms: $what (calls=${fakePlatform.calls.join(',')})');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Builds the service + controller under test. A `null` [stopDeadline] keeps
  /// the product's own default (5 s).
  void build({required Duration segment, Duration? stopDeadline}) {
    final config = DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    );
    service = stopDeadline == null
        ? DashcamService(config: config, segmentDuration: segment)
        : DashcamService(config: config, segmentDuration: segment, stopVideoRecordingTimeout: stopDeadline);
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  }

  /// Starts a driving session with the dashcam on and waits until it records.
  /// The native stop of the rotation(s) to come is held on the returned gate.
  Future<(DrivingSession, Completer<void>)> startRecordingSession() async {
    await preferences.setEnabled(true);
    final session = controller.startSession();
    await waitUntil(() => controller.status == DashcamStatus.recording, 'the session reaching recording');
    final gate = Completer<void>();
    fakePlatform.pendingStopVideoRecording = gate;
    return (session, gate);
  }

  Future<void> waitForOverdueRotationStop({Duration within = const Duration(seconds: 5)}) async {
    await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation tick issuing its native stop', within: within);
    await waitUntil(() => service.rotationStopOverdue, 'the rotation stop being reported as overdue', within: within);
  }

  /// The clips the session's own index holds once it has stopped, each with its
  /// file still present.
  List<DashcamClipRecord> indexedClips(String sessionId) {
    final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List?;
    final records = raw == null ? <DashcamClipRecord>[] : List<DashcamClipRecord>.from(raw);
    for (final record in records) {
      expect(File(record.filePath).existsSync(), isTrue, reason: 'indexed clip without its file: ${record.filePath}');
    }
    return records;
  }

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_rotation_late_stop_session_test');
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
    final gate = fakePlatform.pendingStopVideoRecording;
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
    'X230 — the SM-A326B scenario with the product\'s own numbers: a rotation stop of 6.95 s against the 5 s deadline. The user '
    'sees "câmera indisponível" only while the stop is slow, recording comes back by itself on the same camera, and the '
    'session ends with every segment indexed',
    () async {
      build(segment: const Duration(seconds: 9));
      expect(service.stopVideoRecordingTimeout, const Duration(seconds: 5), reason: 'this test is about the product\'s own default');
      final (session, gate) = await startRecordingSession();
      try {
        await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation tick issuing its native stop', within: const Duration(seconds: 14));
        final sinceStop = Stopwatch()..start();
        final seen = <String>[];
        final sampler = Timer.periodic(const Duration(milliseconds: 25), (_) {
          final name = controller.status.name;
          if (seen.isEmpty || seen.last != name) seen.add(name);
        });

        await waitUntil(() => service.rotationStopOverdue, 'the 5 s deadline being reported', within: const Duration(seconds: 8));
        expect(sinceStop.elapsedMilliseconds, greaterThanOrEqualTo(4900));
        expect(controller.status, DashcamStatus.cameraUnavailable, reason: 'no video is being captured: the status must not say "recording"');
        expect(recorder.isRecording, isTrue, reason: 'the driving session itself is untouched');

        final remaining = const Duration(milliseconds: 6950) - sinceStop.elapsed;
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
        expect(count('startVideoCapturing'), 1, reason: 'nothing starts while the stop is in flight');
        expect(count('createCameraWithSettings'), 1);
        gate.complete();

        await waitUntil(() => count('startVideoCapturing') == 2, 'recording coming back by itself', within: const Duration(seconds: 3));
        await waitUntil(() => controller.status == DashcamStatus.recording, 'the status returning to recording');
        sampler.cancel();
        if (seen.last != controller.status.name) seen.add(controller.status.name); // the state just waited for, if the sampler had not ticked yet
        expect(seen, ['recording', 'cameraUnavailable', 'recording'], reason: 'what the user was shown from the rotation stop on');
        expect(service.lastLateRotationDecisionForTest, 'resume');
        expect(count('createCameraWithSettings'), 1, reason: 'same camera: no re-initialization');
        expect(maxCamerasOpenAtOnce(), 1);
        expect(controller.errorMessage, isNull, reason: 'a slow stop is not an error');

        // The session goes on, then the user stops it (before the next tick).
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(service.previewController!.value.isRecordingVideo, isTrue);
        await controller.stopSession();
        await waitUntil(() => !service.hasPendingNativeStop && recorder.state == DrivingSessionRecorderState.idle, 'the session stop settling');
        await waitUntil(() => indexedClips(session.id).length == 2, 'both segments reaching the session\'s clip index');

        final stored = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(session.id)!;
        expect(stored.endTime, isNotNull);
        expect(stored.dashcamTelemetryOutcome, DashcamTelemetryOutcome.success);
        expect(service.clips.where((c) => c.producerToken == session.id), hasLength(2), reason: 'the segment before the slow stop and the one after it');
        expect(controller.status, DashcamStatus.idle);
        expect(count('createCameraWithSettings'), 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'X231 — the same scenario with a short deadline, waited by cause: degraded while the stop is slow, recording again by '
    'itself, telemetry uninterrupted, every segment indexed at the session stop',
    () async {
      build(segment: const Duration(milliseconds: 600), stopDeadline: const Duration(milliseconds: 80));
      final (session, gate) = await startRecordingSession();
      try {
        await waitForOverdueRotationStop();
        expect(controller.status, DashcamStatus.cameraUnavailable);
        expect(count('startVideoCapturing'), 1);

        gate.complete();
        await waitUntil(() => count('startVideoCapturing') == 2, 'recording coming back by itself');
        await waitUntil(() => controller.status == DashcamStatus.recording, 'the status returning to recording');
        expect(service.lastLateRotationDecisionForTest, 'resume');
        expect(count('createCameraWithSettings'), 1);

        await controller.stopSession();
        await waitUntil(() => !service.hasPendingNativeStop && recorder.state == DrivingSessionRecorderState.idle, 'the session stop settling');
        final produced = service.clips.where((c) => c.producerToken == session.id).length;
        expect(produced, greaterThanOrEqualTo(2));
        await waitUntil(() => indexedClips(session.id).length == produced, 'every segment reaching the session\'s clip index');
        final stored = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(session.id)!;
        expect(stored.dashcamTelemetryOutcome, DashcamTelemetryOutcome.success);
        expect(stored.dashcamTelemetryAcceptedCount, stored.dashcamTelemetryPersistedCount);
        expect(maxCamerasOpenAtOnce(), 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X232 — the user ends the session while the slow rotation stop is pending: the session stops without waiting for the '
    'camera, nothing restarts when the stop finally returns, and its clip still reaches the session\'s index',
    () async {
      build(segment: const Duration(milliseconds: 600), stopDeadline: const Duration(milliseconds: 80));
      final (session, gate) = await startRecordingSession();
      try {
        await waitForOverdueRotationStop();

        await controller.stopSession().timeout(const Duration(seconds: 3));
        expect(recorder.isRecording, isFalse);
        expect(service.hasPendingNativeStop, isTrue, reason: 'test setup: the stop is still in flight when the session has already ended');
        expect(count('startVideoCapturing'), 1);
        expect(indexedClips(session.id), isEmpty, reason: 'the clip does not exist yet');

        gate.complete();
        await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
        await waitUntil(() => indexedClips(session.id).length == 1, 'the late clip reaching the ended session\'s index');
        await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1, 'a native start after the session ended');
        expect(count('createCameraWithSettings'), 1);
        expect(controller.status, DashcamStatus.idle);
        expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(session.id)!.endTime, isNotNull);
        expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'and this is why it did not start');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X233 — the app goes to the background while the slow stop is pending and the stop returns there: nothing restarts on the '
    'stale lifecycle generation; back in the foreground, recovery opens ONE new camera after the old one is released and the '
    'same session records again',
    () async {
      build(segment: const Duration(milliseconds: 600), stopDeadline: const Duration(milliseconds: 80));
      final (session, gate) = await startRecordingSession();
      try {
        final generationAtStart = controller.lifecycleGenerationForTest;
        await waitForOverdueRotationStop();

        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(controller.lifecycleGenerationForTest, generationAtStart + 1, reason: 'test setup: the lifecycle generation changed during the wait');

        gate.complete();
        await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
        await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1 || count('createCameraWithSettings') != 1, 'a start or a camera while backgrounded');
        expect(controller.status, DashcamStatus.cameraUnavailable);
        expect(recorder.isRecording, isTrue, reason: 'the driving session goes on in the background');
        expect(service.lastLateRotationDecisionForTest, 'cameraUnavailable', reason: 'and this is why it did not start');

        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 2, 'foreground recovery reaching recording');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1, reason: 'the new camera opened only after the old one was disposed');
        expect(recorder.activeSession?.id, session.id, reason: 'same logical session');

        await controller.stopSession();
        await waitUntil(() => !service.hasPendingNativeStop && recorder.state == DrivingSessionRecorderState.idle, 'the session stop settling');
        await waitUntil(() => indexedClips(session.id).length == 2, 'the clip before the background and the one after recovery in the index');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X234 — background AND return while the slow stop is still in flight: the foreground recovery waits behind the stop, no '
    'second camera exists at any moment, the late rotation does not start, and recording resumes on the new camera',
    () async {
      build(segment: const Duration(milliseconds: 600), stopDeadline: const Duration(milliseconds: 80));
      final (session, gate) = await startRecordingSession();
      try {
        await waitForOverdueRotationStop();

        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await neverDuring(
          const Duration(milliseconds: 300),
          () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 1,
          'a camera or a start while the old stop is still in flight',
        );
        expect(service.hasPendingNativeStop, isTrue);

        final callsAtRelease = fakePlatform.calls.length;
        gate.complete();
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 2, 'recovery reaching recording after the stop returned');
        final afterRelease = fakePlatform.calls.skip(callsAtRelease).toList();
        expect(afterRelease.indexOf('dispose'), lessThan(afterRelease.indexOf('createCameraWithSettings')), reason: 'old camera released before the new one opens');
        expect(afterRelease.indexOf('createCameraWithSettings'), lessThan(afterRelease.indexOf('startVideoCapturing')), reason: 'the only start is the recovery\'s, on the new camera');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(recorder.activeSession?.id, session.id);
        expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'why the late rotation did not start: the recovery had already asked for a fresh camera');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X235 — retryCamera() called while the slow stop is pending (the UI offers "Tentar novamente" only in the error state, so '
    'this is the entry point itself, not a tap the degraded screen allows): the retry cannot open a second camera; it takes '
    'over once the stop returns, and exactly one camera is open at any time',
    () async {
      build(segment: const Duration(milliseconds: 600), stopDeadline: const Duration(milliseconds: 80));
      final (_, gate) = await startRecordingSession();
      try {
        await waitForOverdueRotationStop();
        expect(controller.status, DashcamStatus.cameraUnavailable);

        final retry = controller.retryCamera();
        await neverDuring(
          const Duration(milliseconds: 300),
          () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 1,
          'a camera or a start from the retry while the old stop is still in flight',
        );

        gate.complete();
        await retry;
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 2, 'the retry reaching recording');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'and this is why the late rotation did not start');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X239 — A/B isolation across a slow rotation stop: session A is ended while its rotation stop is pending and session B '
    'starts at once. B waits for A\'s camera, opens its own only after A\'s is released, and the late clip belongs to A alone',
    () async {
      build(segment: const Duration(milliseconds: 600), stopDeadline: const Duration(milliseconds: 80));
      final (sessionA, gate) = await startRecordingSession();
      try {
        await waitForOverdueRotationStop();

        await controller.stopSession().timeout(const Duration(seconds: 3));
        expect(controller.canStartSession, isTrue, reason: 'test setup: A is over as a driving session; only its camera stop is still in flight');
        final sessionB = controller.startSession();
        expect(sessionB.id, isNot(sessionA.id));
        await neverDuring(
          const Duration(milliseconds: 300),
          () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 1,
          'a camera or a start for B while A\'s stop is still in flight',
        );
        expect(recorder.activeSession?.id, sessionB.id, reason: 'B\'s driving session itself does not wait for the camera');

        final callsAtRelease = fakePlatform.calls.length;
        gate.complete();
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 2, 'B reaching recording after A\'s stop returned');
        final afterRelease = fakePlatform.calls.skip(callsAtRelease).toList();
        expect(afterRelease.indexOf('dispose'), lessThan(afterRelease.indexOf('createCameraWithSettings')), reason: 'A\'s camera released before B\'s opens');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        await waitUntil(() => indexedClips(sessionA.id).length == 1, 'A\'s late clip reaching A\'s index');
        expect(service.clips.where((c) => c.producerToken == sessionA.id), hasLength(1));
        expect(service.clips.where((c) => c.producerToken == sessionB.id), isEmpty, reason: 'nothing of A is attributed to B');
        expect(service.lateRotationSettlementCountForTest, 1);
        expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'why A\'s late rotation did not start: A had been stopped');

        await controller.stopSession();
        await waitUntil(() => !service.hasPendingNativeStop && recorder.state == DrivingSessionRecorderState.idle, 'B\'s stop settling');
        final producedByB = service.clips.where((c) => c.producerToken == sessionB.id).length;
        expect(producedByB, greaterThanOrEqualTo(1));
        await waitUntil(() => indexedClips(sessionB.id).length == producedByB, 'B\'s clips reaching B\'s index');
        expect(indexedClips(sessionA.id), hasLength(1), reason: 'A\'s index is untouched by B');
        final pathsA = indexedClips(sessionA.id).map((r) => r.filePath).toSet();
        final pathsB = indexedClips(sessionB.id).map((r) => r.filePath).toSet();
        expect(pathsA.intersection(pathsB), isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X236 — the stop never returns: the status stays degraded, no camera is opened, and the user can still end the session — '
    'it finalizes with its telemetry outcome, without a second camera',
    () async {
      build(segment: const Duration(milliseconds: 300), stopDeadline: const Duration(milliseconds: 80));
      final (session, gate) = await startRecordingSession();
      try {
        await waitForOverdueRotationStop();
        await neverDuring(
          const Duration(milliseconds: 900),
          () => controller.status != DashcamStatus.cameraUnavailable || count('startVideoCapturing') != 1 || count('createCameraWithSettings') != 1,
          'the status leaving "câmera indisponível", a start, or a camera while the stop never returns',
        );
        expect(service.lateRotationSettlementCountForTest, 0);

        await controller.stopSession().timeout(const Duration(seconds: 3));
        final stored = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(session.id)!;
        expect(stored.endTime, isNotNull);
        expect(stored.dashcamTelemetryOutcome, DashcamTelemetryOutcome.success);
        expect(service.hasPendingNativeStop, isTrue, reason: 'the camera is still owned by the stop that never returned');
        expect(count('createCameraWithSettings'), 1);
        expect(count('dispose'), 0, reason: 'nothing disposes a controller over a stop still in flight');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );
}
