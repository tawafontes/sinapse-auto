// Fase 16.2-R4.3-R2.6.15 — rotation tick ownership, through the real
// DashcamSessionController (a driving session with the dashcam on).
//
// The contract itself is pinned on DashcamService
// (dashcam_rotation_tick_ownership_test.dart): the service must be correct by
// itself, whatever calls it. These two tests are an additional regression
// through the controller, with the same harness as
// dashcam_rotation_late_stop_session_test.dart — real controller, recorder and
// Hive, fake camera platform, the REAL segment timer — and with what the
// R2.6.14 session tests did not have: a rotation stop slow enough for several
// more ticks to fire behind it. (Fase 16.2-R4.4-R1-T-Rm: X259 delivers those
// ticks by hand — see its own note.)
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
  int fate(String name) => service.rotationTickFatesForTest[name]!;

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
      '(status=${controller.status.name}, overdue=${service.rotationStopOverdue}, pendingStop=${service.hasPendingNativeStop}, '
      'unavailable=${service.cameraKnownUnavailable}, queuedRotations=${service.queuedRotationCountForTest}, fates=${service.rotationTickFatesForTest}, '
      'lateDecision=${service.lastLateRotationDecisionForTest}, calls=${fakePlatform.calls.join(',')})',
    );
  }

  Future<void> neverDuring(Duration window, bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      if (condition()) fail('must not happen, but did after ${clock.elapsedMilliseconds} ms: $what (calls=${fakePlatform.calls.join(',')})');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void build({required Duration segment, required Duration stopDeadline}) {
    final config = DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    );
    service = DashcamService(config: config, segmentDuration: segment, stopVideoRecordingTimeout: stopDeadline);
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

  /// The rotation stop is past its deadline, still in flight, and [more] more
  /// ticks of the real timer have fired behind it.
  Future<void> waitForTicksBehindTheSlowStop({required int more}) async {
    await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation tick issuing its native stop');
    await waitUntil(() => service.rotationStopOverdue, 'the rotation stop being reported as overdue');
    await waitUntil(() => service.rotationTicksFiredForTest >= 1 + more, 'more ticks firing behind the slow stop');
    expect(service.queuedRotationCountForTest, 2, reason: 'the rotation in flight and one tick behind it, however many fired');
  }

  /// The rotation in flight and every tick behind it have left the queue.
  Future<void> waitForRotationsToDrain() {
    return waitUntil(() => service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop, 'the rotation queue draining');
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
    dir = Directory.systemTemp.createTempSync('dashcam_rotation_tick_ownership_session_test');
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
    'X258 — A/B across a slow rotation stop with ticks piled up behind it: session A is ended and session B started while '
    'A\'s stop is still in flight. No tick of A starts anything; B opens its own camera after A\'s is released and records '
    'as B; A\'s late clip is A\'s alone; ending B leaves nothing recording',
    () async {
      build(segment: const Duration(milliseconds: 150), stopDeadline: const Duration(milliseconds: 40));
      final (sessionA, gate) = await startRecordingSession();
      try {
        await waitForTicksBehindTheSlowStop(more: 3);

        await controller.stopSession().timeout(const Duration(seconds: 3));
        expect(controller.canStartSession, isTrue, reason: 'test setup: A is over as a driving session; only its camera stop is still in flight');
        final sessionB = controller.startSession();
        expect(sessionB.id, isNot(sessionA.id));
        await neverDuring(
          const Duration(milliseconds: 300),
          () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 1 || count('stopVideoRecording') != 1,
          'a camera, a start or a stop while A\'s stop is still in flight',
        );

        final callsAtRelease = fakePlatform.calls.length;
        gate.complete();
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 2, 'B reaching recording after A\'s stop returned');
        final afterRelease = fakePlatform.calls.skip(callsAtRelease).toList();
        final firstStartAfterRelease = afterRelease.indexOf('startVideoCapturing');
        expect(afterRelease.indexOf('dispose'), lessThan(afterRelease.indexOf('createCameraWithSettings')), reason: 'A\'s camera released before B\'s opens');
        expect(afterRelease.indexOf('createCameraWithSettings'), lessThan(firstStartAfterRelease), reason: 'the first start after the release is on B\'s own camera — not a tick of A on the old one');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        await waitUntil(() => indexedClips(sessionA.id).length == 1, 'A\'s late clip reaching A\'s index');
        expect(service.clips.where((c) => c.producerToken == sessionA.id), hasLength(1));

        await controller.stopSession();
        await waitUntil(() => !service.hasPendingNativeStop && recorder.state == DrivingSessionRecorderState.idle, 'B\'s stop settling');
        expect(service.previewController?.value.isRecordingVideo ?? false, isFalse, reason: 'nothing is left recording');
        expect(service.isRecording, isFalse);
        expect(service.clips.where((c) => c.producerToken == sessionA.id), hasLength(1), reason: 'no clip of A appeared after B started');
        final producedByB = service.clips.where((c) => c.producerToken == sessionB.id).length;
        expect(producedByB, greaterThanOrEqualTo(1));
        expect(service.clips, hasLength(1 + producedByB), reason: 'every clip is A\'s or B\'s');
        await waitUntil(() => indexedClips(sessionB.id).length == producedByB, 'B\'s clips reaching B\'s index');
        expect(indexedClips(sessionA.id), hasLength(1), reason: 'A\'s index is untouched by B');
        final pathsA = indexedClips(sessionA.id).map((r) => r.filePath).toSet();
        final pathsB = indexedClips(sessionB.id).map((r) => r.filePath).toSet();
        expect(pathsA.intersection(pathsB), isEmpty);

        expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'why A\'s late rotation did not start: A had been stopped');
        expect(fate('coalesced'), greaterThanOrEqualTo(2), reason: 'the ticks behind the one that waited never entered the queue');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X259 — the same session, nothing is stopped: ticks pile up behind a slow rotation stop, the user sees "câmera '
    'indisponível" meanwhile, and when the stop returns recording comes back ONCE on the same camera — no burst of '
    'rotations, and every clip the session ends with is indexed',
    () async {
      // Fase 16.2-R4.4-R1-T-Rm (R-m X259, test-only): this test used the real
      // 400 ms segment timer. Its timer is re-armed when the late restart
      // settles, so the NEXT legitimate rotation comes 400 ms after that — and
      // under load the "no rotation right after the late restart" window below
      // opened late enough to catch it, reporting the new segment's ordinary
      // rotation as a burst (reproduced by pausing before the window, T-Rm
      // 02_directed/x259_pause). The ticks are delivered by hand instead
      // (segmentTimerArmedHookForTest, the same closure the timer calls), with
      // a 10-minute segment: the piled-up ticks are still delivered behind the
      // slow stop, and after the restart no tick exists at all — any rotation
      // in the window can only come from the ones that piled up.
      build(segment: const Duration(minutes: 10), stopDeadline: const Duration(milliseconds: 60));
      final ticks = <void Function()>[];
      service.segmentTimerArmedHookForTest = ticks.add;
      final (session, gate) = await startRecordingSession();
      try {
        expect(ticks, hasLength(1), reason: 'test setup: the segment\'s timer was armed once');
        ticks.single(); // the segment's own tick: the rotation, whose native stop the gate holds
        await waitUntil(() => count('stopVideoRecording') == 1 && service.rotationStopOverdue, 'the rotation stop in flight and overdue');
        for (var i = 0; i < 3; i++) {
          ticks.first(); // three more ticks of the same timer, piling up behind the slow stop
        }
        await waitForTicksBehindTheSlowStop(more: 3);
        expect(controller.status, DashcamStatus.cameraUnavailable, reason: 'no video is being captured while the stop is slow');

        gate.complete();
        await waitForRotationsToDrain();
        expect(count('startVideoCapturing'), 2, reason: 'exactly one restart');
        expect(count('stopVideoRecording'), 1, reason: 'and no rotation of the segment that has only just begun');
        expect(count('createCameraWithSettings'), 1, reason: 'same camera');
        await waitUntil(() => controller.status == DashcamStatus.recording, 'the status returning to recording');
        expect(controller.errorMessage, isNull);
        await neverDuring(
          const Duration(milliseconds: 150),
          () => count('startVideoCapturing') != 2 || count('stopVideoRecording') != 1,
          'a rotation right after the late restart',
        );
        expect(service.lastLateRotationDecisionForTest, 'resume');
        expect(fate('absorbed'), 1, reason: 'the tick that waited found its segment already replaced');

        await controller.stopSession();
        await waitUntil(() => !service.hasPendingNativeStop && recorder.state == DrivingSessionRecorderState.idle, 'the session stop settling');
        expect(service.clips.every((c) => c.producerToken == session.id), isTrue);
        expect(service.clips, hasLength(count('stopVideoRecording')), reason: 'one clip per native stop');
        await waitUntil(() => indexedClips(session.id).length == service.clips.length, 'every clip reaching the session\'s index');
        expect(maxCamerasOpenAtOnce(), 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );
}
