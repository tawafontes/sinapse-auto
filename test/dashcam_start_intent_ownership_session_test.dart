// Fase 16.2-R4.3-R2.6.16 — START intent ownership, through the real
// DashcamSessionController (a driving session with the dashcam on).
//
// The contract itself is pinned on DashcamService
// (dashcam_start_intent_ownership_test.dart): the service must be correct by
// itself, whatever calls it. This is an additional regression through the
// controller, with the same harness as
// dashcam_rotation_tick_ownership_session_test.dart — real controller, recorder
// and Hive, fake camera platform — for the one window of a START that a driving
// session can be ended in: while its native START is still in flight.
//
// It does not claim that the sequence the independent review reproduced on the
// service (a START waiting in the queue behind a stop, superseded by a stop and
// a newer START on the same camera) can be produced through the controller: a
// new session opens its own camera first.
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
      '(status=${controller.status.name}, isRecording=${service.isRecording}, pendingStop=${service.hasPendingNativeStop}, '
      'unavailable=${service.cameraKnownUnavailable}, startFates=${service.startFatesForTest}, calls=${fakePlatform.calls.join(',')})',
    );
  }

  Future<void> neverDuring(Duration window, bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      if (condition()) fail('must not happen, but did after ${clock.elapsedMilliseconds} ms: $what (calls=${fakePlatform.calls.join(',')})');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void build({required Duration stopDeadline}) {
    final config = DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    );
    service = DashcamService(config: config, segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: stopDeadline);
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

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_start_intent_ownership_session_test');
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
    fakePlatform.pendingStartVideoCapturing = null;
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
    'X290 — session A is ended while the native START of its camera is still in flight, and session B is started. When '
    'that START returns, A\'s Recording is stopped once — by the stop that ended A, not a second time by the START — and '
    'its clip is A\'s alone; B opens its own camera after A\'s is released, records as B, and ending B leaves nothing '
    'recording',
    () async {
      build(stopDeadline: const Duration(milliseconds: 40));
      await preferences.setEnabled(true);
      final startGate = Completer<void>();
      fakePlatform.pendingStartVideoCapturing = startGate;
      try {
        final sessionA = controller.startSession();
        await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A\'s camera being issued and held');

        await controller.stopSession().timeout(const Duration(seconds: 3));
        expect(controller.canStartSession, isTrue, reason: 'test setup: A is over as a driving session; only its camera START is still in flight');
        final sessionB = controller.startSession();
        expect(sessionB.id, isNot(sessionA.id));
        await neverDuring(
          const Duration(milliseconds: 200),
          () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 1 || count('stopVideoRecording') != 0,
          'a camera, a start or a stop while A\'s native START is still in flight',
        );

        final callsAtRelease = fakePlatform.calls.length;
        fakePlatform.pendingStartVideoCapturing = null;
        startGate.complete();
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 2, 'B reaching recording after A\'s START returned');

        final afterRelease = fakePlatform.calls.skip(callsAtRelease).toList();
        expect(afterRelease.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'A\'s Recording was stopped once');
        expect(afterRelease.indexOf('stopVideoRecording'), lessThan(afterRelease.indexOf('dispose')), reason: 'A\'s Recording stopped before A\'s camera is released');
        expect(afterRelease.indexOf('dispose'), lessThan(afterRelease.indexOf('createCameraWithSettings')), reason: 'A\'s camera released before B\'s opens');
        expect(afterRelease.indexOf('createCameraWithSettings'), lessThan(afterRelease.indexOf('startVideoCapturing')), reason: 'B\'s START is on B\'s own camera');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(service.previewController!.value.isRecordingVideo, isTrue);
        expect(service.clips.map((c) => c.producerToken), [sessionA.id], reason: 'the one clip so far is the Recording A\'s START produced');
        await waitUntil(() => indexedClips(sessionA.id).length == 1, 'A\'s late clip reaching A\'s index');

        await controller.stopSession();
        await waitUntil(() => !service.hasPendingNativeStop && recorder.state == DrivingSessionRecorderState.idle, 'B\'s stop settling');
        expect(service.previewController?.value.isRecordingVideo ?? false, isFalse, reason: 'nothing is left recording');
        expect(service.isRecording, isFalse);
        expect(service.hasActiveSegmentTimerForTest, isFalse);
        expect(count('startVideoCapturing'), 2, reason: 'one native START per session');
        expect(count('stopVideoRecording'), 2, reason: 'and one native stop per Recording');
        expect(service.clips.map((c) => c.producerToken), [sessionA.id, sessionB.id]);
        await waitUntil(() => indexedClips(sessionB.id).length == 1, 'B\'s clip reaching B\'s index');
        expect(indexedClips(sessionA.id), hasLength(1), reason: 'A\'s index is untouched by B');
        expect(indexedClips(sessionA.id).single.filePath, isNot(indexedClips(sessionB.id).single.filePath));

        expect(service.startFatesForTest['ownRecordingFinalized'], 0, reason: 'the stop that ended A owned A\'s Recording; the START left it to that stop');
      } finally {
        fakePlatform.pendingStartVideoCapturing = null;
        if (!startGate.isCompleted) startGate.complete();
      }
    },
  );
}
