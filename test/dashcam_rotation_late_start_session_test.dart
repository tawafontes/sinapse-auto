// Fase 16.2-R4.3-R2.6.20 — late rotation START settlement / automatic rearm
// (N2), through the real DashcamSessionController (a driving session with the
// dashcam on): what the user is shown, how many cameras exist, and what the
// session ends up with.
//
// X382 and X390 use the product's own numbers: a segment rotation whose restart
// START takes 6.95 s against the 5 s startVideoRecordingTimeout and then
// succeeds (X390: after a stop that also took 6.95 s). Before this round the
// status stayed "Câmera indisponível" — a state that offers no retry — and the
// session went on as one endless segment that no rotation ever closed. The
// other tests use a short deadline and wait by cause: the fake camera's START
// is held until the session SHOWS "câmera indisponível", which, with that START
// the only thing in flight, only its deadline can produce.
//
// What each test asserts first is what the user is shown and what the camera
// did; what the service itself says about the late restart (the decision it
// took) comes last, after the behaviour it explains.
//
// Rotation ticks are delivered by hand (segmentTimerArmedHookForTest): the
// segment period is 10 minutes, so no real tick fires within a test.
import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraException;
import 'package:camera_platform_interface/camera_platform_interface.dart' show CameraPlatform;
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
  Timer? statusSampler;
  void Function()? sampleStatusNow;

  /// One closure per segment timer the service armed, in order.
  final timerTicks = <void Function()>[];

  /// Every DISTINCT status the session showed, in order, from the moment
  /// [watchStatus] was called — read through [statusesShown].
  final statuses = <DashcamStatus>[];

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const manualTicksOnly = Duration(minutes: 10);
  const shortDeadline = Duration(milliseconds: 60);

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;
  bool cameraRecording() => service.previewController?.value.isRecordingVideo ?? false;

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

  String state() =>
      'status=${controller.status.name}, error=${controller.errorMessage}, unavailable=${service.cameraKnownUnavailable}, '
      'isRecording=${service.isRecording}, cameraRecording=${cameraRecording()}, timer=${service.hasActiveSegmentTimerForTest}, '
      'timersArmed=${timerTicks.length}, pendingStop=${service.hasPendingNativeStop}, restartOverdue=${service.rotationRestartOverdue}, '
      'lateDecision=${service.lastLateRestartDecisionForTest}, statuses=${statuses.map((s) => s.name).toList()}, calls=${fakePlatform.calls.join(',')}';

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail('never happened within ${within.inMilliseconds} ms: $what (${state()})');
  }

  Future<void> neverDuring(Duration window, bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      if (condition()) fail('must not happen, but did after ${clock.elapsedMilliseconds} ms: $what (${state()})');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) fail('must not happen, but did by the end of ${window.inMilliseconds} ms: $what (${state()})');
  }

  /// Builds the service + controller under test. `null` keeps the product's own
  /// deadline (5 s for START and for STOP).
  void build({Duration? startDeadline, Duration? stopDeadline}) {
    final config = DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    );
    service = DashcamService(
      config: config,
      segmentDuration: manualTicksOnly,
      startVideoRecordingTimeout: startDeadline ?? const Duration(seconds: 5),
      stopVideoRecordingTimeout: stopDeadline ?? const Duration(seconds: 5),
    );
    service.segmentTimerArmedHookForTest = timerTicks.add;
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  }

  /// Starts recording every distinct status the session shows: on each of the
  /// controller's notifications, every 2 ms, and whenever [statusesShown] is
  /// read. (The status is computed when read; a change that comes from the
  /// service alone notifies nobody, hence the timer.)
  void watchStatus() {
    statuses.clear();
    void sample() {
      final now = controller.status;
      if (statuses.isEmpty || statuses.last != now) statuses.add(now);
    }

    sample();
    sampleStatusNow = sample;
    controller.addListener(sample);
    statusSampler = Timer.periodic(const Duration(milliseconds: 2), (_) => sample());
  }

  /// The statuses shown so far, up to this very instant.
  List<DashcamStatus> statusesShown() {
    sampleStatusNow?.call();
    return List.of(statuses);
  }

  /// Starts a driving session with the dashcam on and waits until it records.
  Future<DrivingSession> startRecordingSession() async {
    await preferences.setEnabled(true);
    final session = controller.startSession();
    await waitUntil(() => controller.status == DashcamStatus.recording && cameraRecording(), 'the session reaching recording');
    expect(timerTicks, hasLength(1), reason: 'test setup: the run armed its one timer');
    watchStatus();
    return session;
  }

  /// A rotation of the current run: its tick is delivered, it stops the segment
  /// and its restart START is issued and HELD on the returned gate.
  Future<Completer<void>> rotateAndHoldTheRestart() async {
    final startsBefore = count('startVideoCapturing');
    final stopsBefore = count('stopVideoRecording');
    final gate = Completer<void>();
    fakePlatform.pendingStartVideoCapturing = gate;
    timerTicks.last();
    await waitUntil(
      () => count('stopVideoRecording') == stopsBefore + 1 && !service.hasPendingNativeStop && count('startVideoCapturing') == startsBefore + 1,
      'the rotation stopping its segment and issuing the restart START',
    );
    fakePlatform.pendingStartVideoCapturing = null;
    return gate;
  }

  /// The restart START of the rotation is past its deadline and still in
  /// flight: the session shows "câmera indisponível". With the held START the
  /// only thing in flight, only its deadline can produce that. A few sampler
  /// periods are then let pass, so the recorded status history has the state in
  /// it however quickly the test releases the START afterwards.
  Future<void> waitForTheRestartToPassItsDeadline({Duration within = const Duration(seconds: 5)}) async {
    await waitUntil(
      () => controller.status == DashcamStatus.cameraUnavailable,
      'the session showing the camera as unavailable while the restart START is in flight (its deadline)',
      within: within,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  /// The held START has returned and the rotation that issued it has run to
  /// its end.
  Future<void> waitForTheRotationToEnd() => waitUntil(() => service.queuedRotationCountForTest == 0, 'the rotation ending after its native START returned');

  /// What the service itself says about the late restart: decided exactly
  /// once, and why. Asserted LAST, after the behaviour it explains.
  void expectTheServiceDecided(String decision) {
    expect(service.lateRestartSettlementCountForTest, 1, reason: 'a late restart is decided exactly once (${state()})');
    expect(service.lastLateRestartDecisionForTest, decision, reason: 'and this is why');
    expect(service.rotationRestartOverdue, isFalse, reason: '"overdue" ends when the native call returns');
  }

  /// One ordinary rotation through the timer armed last.
  Future<void> expectOneNormalRotation(String which) async {
    final startsBefore = count('startVideoCapturing');
    final stopsBefore = count('stopVideoRecording');
    timerTicks.last();
    await waitUntil(
      () => count('startVideoCapturing') == startsBefore + 1 && cameraRecording() && service.queuedRotationCountForTest == 0,
      'the $which rotation after the late restart completing',
    );
    expect(count('stopVideoRecording'), stopsBefore + 1, reason: 'the $which rotation ended exactly one segment');
    expect(controller.status, DashcamStatus.recording, reason: 'and the session still shows recording');
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

  Future<void> waitForTheSessionToBeOver() => waitUntil(
    () =>
        service.previewController == null &&
        !service.hasPendingNativeStop &&
        DashcamService.processOwnerCurrentForTest == null &&
        recorder.state == DrivingSessionRecorderState.idle,
    'the session ending: camera released, process owner free',
    within: const Duration(seconds: 10),
  );

  setUp(() async {
    timerTicks.clear();
    statuses.clear();
    sampleStatusNow = null;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_rotation_late_start_session_test');
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
    statusSampler?.cancel();
    sampleStatusNow = null;
    for (final gate in [fakePlatform.pendingStartVideoCapturing, fakePlatform.pendingStopVideoRecording]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
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
    'X382 — the product\'s own numbers: a rotation whose restart START takes 6.95 s against the 5 s deadline. The user sees "câmera '
    'indisponível" only while the START is slow; recording comes back by itself on the same camera — no retry, no new initialize — '
    'the next TWO rotations are ordinary ones, and the session ends with every segment indexed',
    () async {
      build();
      expect(service.startVideoRecordingTimeout, const Duration(seconds: 5), reason: 'this test is about the product\'s own default');
      final session = await startRecordingSession();
      final camera = service.previewController!;
      final attemptsBefore = controller.cameraAttemptCreationCountForTest;
      final held = Stopwatch()..start();
      final gate = await rotateAndHoldTheRestart();
      try {
        await neverDuring(const Duration(milliseconds: 4500), () => controller.status != DashcamStatus.recording, 'anything but "recording" shown inside the 5 s deadline');
        await waitForTheRestartToPassItsDeadline(within: const Duration(seconds: 2));
        expect(held.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4900)));
        expect(controller.errorMessage, isNull, reason: 'slow is not an error');
        final remaining = const Duration(milliseconds: 6950) - held.elapsed;
        if (!remaining.isNegative) await Future<void>.delayed(remaining);
        expect(controller.status, DashcamStatus.cameraUnavailable, reason: 'no video is being captured: the status says so for as long as the START is slow');
        expect(cameraRecording(), isFalse);

        gate.complete();
        await waitForTheRotationToEnd();
        expect(controller.status, DashcamStatus.recording, reason: 'recording again, by itself');
        expect(controller.errorMessage, isNull);
        expect(cameraRecording(), isTrue);
        expect(service.previewController, same(camera), reason: 'the same camera');
        expect(count('createCameraWithSettings'), 1);
        expect(controller.cameraAttemptCreationCountForTest, attemptsBefore, reason: 'no retry and no recovery attempt was needed');
        expect(timerTicks, hasLength(2), reason: 'the run\'s timer was re-armed at the settlement');
        expect(statusesShown(), [DashcamStatus.recording, DashcamStatus.cameraUnavailable, DashcamStatus.recording], reason: 'and nothing else was ever shown');

        await expectOneNormalRotation('first');
        await expectOneNormalRotation('second');

        await controller.stopSession();
        await waitForTheSessionToBeOver();
        await waitUntil(() => indexedClips(session.id).length == 4, 'the four segments reaching the session\'s index');
        expect(service.clips.where((c) => c.producerToken == session.id), hasLength(4));
        expect(controller.status, DashcamStatus.idle);
        expect(maxCamerasOpenAtOnce(), 1);
        expectTheServiceDecided('adopted');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'X383 — the status at each step: "câmera indisponível" right after the deadline, "gravando" right after the late START '
    'settles, still "gravando" after the next rotation, "pronto" after the session stops — never an error, never a new '
    'initialization',
    () async {
      build(startDeadline: shortDeadline);
      final session = await startRecordingSession();
      final gate = await rotateAndHoldTheRestart();
      try {
        await waitForTheRestartToPassItsDeadline();
        expect(controller.status, DashcamStatus.cameraUnavailable, reason: 'right after the deadline');

        gate.complete();
        await waitForTheRotationToEnd();
        expect(controller.status, DashcamStatus.recording, reason: 'right after the late settlement');

        await expectOneNormalRotation('next');
        expect(controller.status, DashcamStatus.recording, reason: 'after the next rotation');

        await controller.stopSession();
        await waitForTheSessionToBeOver();
        expect(controller.status, DashcamStatus.idle, reason: 'after an ordinary stop');
        final shown = statusesShown();
        expect(shown.take(3).toList(), [DashcamStatus.recording, DashcamStatus.cameraUnavailable, DashcamStatus.recording]);
        expect(shown, isNot(contains(DashcamStatus.error)));
        expect(shown, isNot(contains(DashcamStatus.initializing)));
        expect(shown.where((s) => s == DashcamStatus.cameraUnavailable), hasLength(1), reason: 'unavailable was shown once: while the START was slow');
        expect(controller.errorMessage, isNull);
        expect(count('initializeCamera'), 1, reason: 'one camera, initialized once');
        await waitUntil(() => indexedClips(session.id).length == 3, 'the three segments reaching the index');
        expectTheServiceDecided('adopted');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X384 — provenance and index of an adopted late segment: an ordinary segment, the late one, and the one after the next '
    'rotation all belong to the session — one clip each, in order, each claimed by this session, none duplicated, none lost',
    () async {
      build(startDeadline: shortDeadline);
      final session = await startRecordingSession();
      final epoch = service.startIntentEpochForTest;
      final firstRecording = service.activeRecordingId!;
      final gate = await rotateAndHoldTheRestart();
      try {
        await waitForTheRestartToPassItsDeadline();
        gate.complete();
        await waitForTheRotationToEnd();
        expect(cameraRecording(), isTrue);
        final lateRecording = service.activeRecordingId!;
        expect(lateRecording, isNot(firstRecording), reason: 'the late segment has an identity of its own');
        expect(service.activeRecordingStartEpochForTest, epoch, reason: 'and is a segment of the session\'s own run');

        await expectOneNormalRotation('next');
        expect(service.clips, hasLength(2));
        expect(service.clips.last.recordingId, lateRecording, reason: 'the rotation ended the late segment, under the identity it was given');
        expect(service.clips.last.producerToken, session.id);

        await controller.stopSession();
        await waitForTheSessionToBeOver();
        await waitUntil(() => indexedClips(session.id).length == 3, 'the three segments reaching the index');
        final indexed = indexedClips(session.id);
        final servicePaths = [for (final clip in service.clips) clip.file.path];
        expect(service.clips.map((c) => c.producerToken), everyElement(session.id));
        expect(service.clips.map((c) => c.recordingId).toSet(), hasLength(3), reason: 'three Recordings, three identities');
        expect(indexed.map((r) => r.filePath).toList(), servicePaths, reason: 'the index holds exactly the session\'s clips, in order');
        expect(indexed.map((r) => r.filePath).toSet(), hasLength(3), reason: 'no duplicate');
        for (final path in servicePaths) {
          expect(controller.ownerOfPathForTest(path), session.id, reason: 'claimed by this session: $path');
        }
        expect(service.startIntentEpochForTest, epoch, reason: 'the whole session was one run');
        expectTheServiceDecided('adopted');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X385 — the user ends the session while the restart is overdue: the session stops without waiting for the camera; when the '
    'START finally returns the late Recording is NOT adopted — the session\'s own stop stops it, its clip still reaches the ended '
    'session\'s index, the camera is released and nothing is armed',
    () async {
      build(startDeadline: shortDeadline, stopDeadline: const Duration(milliseconds: 150));
      final session = await startRecordingSession();
      final gate = await rotateAndHoldTheRestart();
      try {
        await waitForTheRestartToPassItsDeadline();

        await controller.stopSession().timeout(const Duration(seconds: 3));
        expect(recorder.isRecording, isFalse);
        expect(count('startVideoCapturing'), 2);
        expect(cameraRecording(), isFalse, reason: 'test setup: the START is still in flight when the session has already ended');
        expect(count('dispose'), 0, reason: 'the camera cannot be let go while the native START is in flight');
        expect(DashcamService.processOwnerCurrentForTest, isNotNull);
        expect(indexedClips(session.id), hasLength(1), reason: 'the segment the rotation had ended');

        gate.complete();
        await waitUntil(() => indexedClips(session.id).length == 2, 'the late clip reaching the ended session\'s index');
        await waitForTheSessionToBeOver();
        expect(count('stopVideoRecording'), 2, reason: 'segment 1 by the rotation, the late Recording by the session\'s stop');
        expect(count('startVideoCapturing'), 2, reason: 'no START after the session ended');
        expect(count('createCameraWithSettings'), 1);
        expect(fakePlatform.disposedCameraIds, hasLength(1), reason: 'the one camera, released once');
        expect(timerTicks, hasLength(1), reason: 'no timer for a Recording nobody wanted');
        expect(service.isRecording, isFalse);
        expect(controller.status, DashcamStatus.idle);
        expect(statusesShown(), isNot(contains(DashcamStatus.error)));
        expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(session.id)!.endTime, isNotNull);
        expectTheServiceDecided('recordingNoLongerWanted');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X386 — the app goes to the background while the restart is overdue and the START returns there: nothing is adopted on the '
    'stale lifecycle generation — the late Recording is stopped, no timer, no status published as recording. Back in the '
    'foreground, recovery opens ONE new camera after the old one is released and the same session records again, as a new run',
    () async {
      build(startDeadline: shortDeadline);
      final session = await startRecordingSession();
      final epoch = service.startIntentEpochForTest;
      final gate = await rotateAndHoldTheRestart();
      try {
        final generationAtStart = controller.lifecycleGenerationForTest;
        await waitForTheRestartToPassItsDeadline();

        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(controller.lifecycleGenerationForTest, generationAtStart + 1, reason: 'test setup: the lifecycle generation changed during the wait');

        gate.complete();
        await waitUntil(
          () => count('stopVideoRecording') == 2 && !cameraRecording() && !service.hasPendingNativeStop && service.queuedRotationCountForTest == 0,
          'the late Recording being stopped by the rotation that created it',
        );
        await neverDuring(
          const Duration(milliseconds: 300),
          () => count('startVideoCapturing') != 2 || count('createCameraWithSettings') != 1 || count('dispose') != 0,
          'a start, a camera or a dispose while backgrounded',
        );
        expect(service.hasActiveSegmentTimerForTest, isFalse, reason: 'no rotation timer');
        expect(timerTicks, hasLength(1));
        expect(service.isRecording, isFalse, reason: 'the run ended; recovery is the next foreground\'s');
        expect(controller.status, DashcamStatus.cameraUnavailable);
        expect(statusesShown().sublist(1), everyElement(DashcamStatus.cameraUnavailable), reason: 'recording was never published for the late Recording');
        expect(recorder.isRecording, isTrue, reason: 'the driving session goes on in the background');
        expectTheServiceDecided('cameraUnavailable');

        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 3, 'foreground recovery reaching recording');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1, reason: 'the new camera opened only after the old one was disposed');
        expect(recorder.activeSession?.id, session.id, reason: 'same logical session');
        expect(service.startIntentEpochForTest, epoch + 1, reason: 'a new run, with its own identity');
        expect(service.activeRecordingStartEpochForTest, epoch + 1, reason: 'and the Recording is that run\'s');
        expect(timerTicks, hasLength(2), reason: 'with its own timer');

        await controller.stopSession();
        await waitForTheSessionToBeOver();
        await waitUntil(() => indexedClips(session.id).length == 3, 'the segment before, the late one and the one after recovery in the index');
        expect(service.clips.map((c) => c.producerToken), everyElement(session.id));
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X387 — background AND return while the restart is still in flight: the foreground recovery waits behind the START, no second '
    'camera exists at any moment, the late Recording is not adopted — the recovery stops it and releases its camera first — and '
    'recording resumes on the new camera',
    () async {
      build(startDeadline: shortDeadline);
      final session = await startRecordingSession();
      final gate = await rotateAndHoldTheRestart();
      try {
        await waitForTheRestartToPassItsDeadline();

        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await neverDuring(
          const Duration(milliseconds: 300),
          () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 2 || count('dispose') != 0,
          'a camera, a start or a dispose while the old START is still in flight',
        );
        expect(cameraRecording(), isFalse, reason: 'test setup: the START is still in flight');

        final callsAtRelease = fakePlatform.calls.length;
        gate.complete();
        await waitUntil(() => controller.status == DashcamStatus.recording && count('startVideoCapturing') == 3, 'recovery reaching recording after the START returned');
        final after = fakePlatform.calls.skip(callsAtRelease).toList();
        expect(after.indexOf('stopVideoRecording'), isNonNegative, reason: 'the late Recording was stopped');
        expect(after.indexOf('stopVideoRecording'), lessThan(after.indexOf('dispose')), reason: 'before its camera was released');
        expect(after.indexOf('dispose'), lessThan(after.indexOf('createCameraWithSettings')), reason: 'old camera released before the new one opens');
        expect(after.indexOf('createCameraWithSettings'), lessThan(after.indexOf('startVideoCapturing')), reason: 'the only start is the recovery\'s, on the new camera');
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(recorder.activeSession?.id, session.id);
        expect(timerTicks, hasLength(2), reason: 'the first run\'s timer and the recovery\'s: the late success armed none');
        expectTheServiceDecided('recordingNoLongerWanted');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X388 — session A ends and session B is requested while the restart of A is overdue: B is held back until A\'s native START '
    'has settled and A\'s camera is released; the late Recording is A\'s — stopped by A\'s stop, indexed under A, never B\'s; '
    'B then records on its own camera, and ending B indexes only B\'s clip',
    () async {
      build(startDeadline: shortDeadline, stopDeadline: const Duration(milliseconds: 150));
      final a = await startRecordingSession();
      final gate = await rotateAndHoldTheRestart();
      try {
        await waitForTheRestartToPassItsDeadline();
        await controller.stopSession().timeout(const Duration(seconds: 3));
        final b = controller.startSession();
        expect(b.id, isNot(a.id));
        await neverDuring(
          const Duration(milliseconds: 300),
          () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 2 || count('dispose') != 0,
          'a camera or a start for B while the native START of A is in flight',
        );
        expect(DashcamService.processOwnerCurrentForTest, isNotNull);
        expect(indexedClips(b.id), isEmpty);

        gate.complete();
        await waitUntil(() => controller.status == DashcamStatus.recording && cameraRecording() && count('startVideoCapturing') == 3, 'session B recording', within: const Duration(seconds: 8));
        expect(recorder.activeSession?.id, b.id);
        expect(count('createCameraWithSettings'), 2, reason: 'A\'s camera, and B\'s own');
        expect(fakePlatform.disposedCameraIds, [0], reason: 'A\'s camera was released; B\'s was not touched');
        expect(maxCamerasOpenAtOnce(), 1, reason: 'B\'s camera opened only after A\'s was disposed');
        expect(count('stopVideoRecording'), 2, reason: 'A\'s two Recordings; nothing stopped B');
        await waitUntil(() => indexedClips(a.id).length == 2, 'the late clip of A reaching A\'s index');
        expect(indexedClips(b.id), isEmpty, reason: 'nothing of A was attributed to B');
        expect(service.clips.where((c) => c.producerToken == a.id), hasLength(2));
        expect(service.clips.where((c) => c.producerToken == b.id), isEmpty);
        expect(timerTicks, hasLength(2), reason: 'A\'s timer and B\'s');
        expectTheServiceDecided('recordingNoLongerWanted');

        await controller.stopSession();
        await waitForTheSessionToBeOver();
        await waitUntil(() => indexedClips(b.id).length == 1, 'B\'s clip reaching B\'s index');
        expect(indexedClips(a.id), hasLength(2));
        expect(indexedClips(a.id).map((r) => r.filePath).toSet().intersection(indexedClips(b.id).map((r) => r.filePath).toSet()), isEmpty);
        expect(fakePlatform.disposedCameraIds, [0, 1]);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X389 — late FAILURE through the controller: the restart START outlives the deadline and then fails. The session shows the '
    'error (with its message — the state that offers "Tentar novamente"), nothing is recording, and the retry opens ONE new '
    'camera and records again',
    () async {
      build(startDeadline: shortDeadline);
      final session = await startRecordingSession();
      final gate = await rotateAndHoldTheRestart();
      try {
        await waitForTheRestartToPassItsDeadline();

        gate.completeError(CameraException('start_failed', 'the restart START of the rotation failed, late'));
        await waitUntil(() => controller.status == DashcamStatus.error, 'the session showing the error');
        expect(controller.errorMessage, contains('falhou após o prazo de resposta'));
        expect(cameraRecording(), isFalse);
        expect(service.isRecording, isFalse, reason: 'the run ended with the failure');
        expect(service.hasActiveSegmentTimerForTest, isFalse);
        expect(count('startVideoCapturing'), 2, reason: 'no automatic retry');
        expect(count('createCameraWithSettings'), 1);
        expectTheServiceDecided('startFailed');

        await controller.retryCamera();
        await waitUntil(() => controller.status == DashcamStatus.recording && cameraRecording() && count('startVideoCapturing') == 3, 'the retry reaching recording');
        expect(controller.errorMessage, isNull);
        expect(count('createCameraWithSettings'), 2);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(recorder.activeSession?.id, session.id);

        await controller.stopSession();
        await waitForTheSessionToBeOver();
        await waitUntil(() => indexedClips(session.id).length == 2, 'the segment before the failure and the one after the retry in the index');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'X390 — slow STOP AND slow START with the product\'s own numbers, through the controller: the rotation\'s stop takes 6.95 s and '
    'its restart START 6.95 s, both succeed. "Câmera indisponível" is shown only while each of them is slow, recording comes back '
    'by itself on the same camera, the next rotation is an ordinary one and the session ends with every segment indexed',
    () async {
      build();
      final session = await startRecordingSession();
      final camera = service.previewController!;
      final stopGate = Completer<void>();
      final startGate = Completer<void>();
      fakePlatform.pendingStopVideoRecording = stopGate;
      fakePlatform.pendingStartVideoCapturing = startGate;
      try {
        final stopHeld = Stopwatch()..start();
        timerTicks.last();
        await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation issuing its native stop');
        fakePlatform.pendingStopVideoRecording = null;
        await waitUntil(() => controller.status == DashcamStatus.cameraUnavailable, 'the session showing the camera as unavailable while the stop is slow', within: const Duration(seconds: 7));
        expect(stopHeld.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4900)));
        final stopRemaining = const Duration(milliseconds: 6950) - stopHeld.elapsed;
        if (!stopRemaining.isNegative) await Future<void>.delayed(stopRemaining);

        final startHeld = Stopwatch()..start();
        stopGate.complete();
        await waitUntil(() => count('startVideoCapturing') == 2, 'the restart START being issued after the late stop');
        fakePlatform.pendingStartVideoCapturing = null;
        await waitUntil(() => controller.status == DashcamStatus.recording, 'the status between the two: the stop is settled, the START inside its deadline');
        await waitForTheRestartToPassItsDeadline(within: const Duration(seconds: 7));
        expect(startHeld.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4900)));
        final startRemaining = const Duration(milliseconds: 6950) - startHeld.elapsed;
        if (!startRemaining.isNegative) await Future<void>.delayed(startRemaining);
        expect(controller.status, DashcamStatus.cameraUnavailable);

        startGate.complete();
        await waitForTheRotationToEnd();
        expect(controller.status, DashcamStatus.recording);
        expect(controller.errorMessage, isNull);
        expect(cameraRecording(), isTrue);
        expect(service.previewController, same(camera));
        expect(count('createCameraWithSettings'), 1);
        expect(
          statusesShown(),
          [DashcamStatus.recording, DashcamStatus.cameraUnavailable, DashcamStatus.recording, DashcamStatus.cameraUnavailable, DashcamStatus.recording],
          reason: 'unavailable only while the stop was slow and while the START was slow',
        );

        await expectOneNormalRotation('next');
        await controller.stopSession();
        await waitForTheSessionToBeOver();
        await waitUntil(() => indexedClips(session.id).length == 3, 'the three segments reaching the index');
        expect(maxCamerasOpenAtOnce(), 1);
        expect(service.lastLateRotationDecisionForTest, 'resume', reason: 'the late stop resumed (R2.6.14)');
        expectTheServiceDecided('adopted');
      } finally {
        if (!stopGate.isCompleted) stopGate.complete();
        if (!startGate.isCompleted) startGate.complete();
      }
    },
    timeout: const Timeout(Duration(seconds: 50)),
  );

  test(
    'X393 — the restart START never returns: the status stays "câmera indisponível", no second START and no second camera '
    'exist, ticks do not pile up, and the user can still end the session — it finalizes with its telemetry outcome, the camera '
    'still owned by the START that has not returned',
    () async {
      build(startDeadline: shortDeadline, stopDeadline: const Duration(milliseconds: 150));
      final session = await startRecordingSession();
      final gate = await rotateAndHoldTheRestart();
      late final int decidedWhileItWaited;
      try {
        await waitForTheRestartToPassItsDeadline();
        for (var i = 0; i < 4; i++) {
          timerTicks.last();
        }
        await neverDuring(
          const Duration(milliseconds: 600),
          () =>
              controller.status != DashcamStatus.cameraUnavailable ||
              count('startVideoCapturing') != 2 ||
              count('stopVideoRecording') != 1 ||
              count('createCameraWithSettings') != 1,
          'the status leaving "câmera indisponível", a start, a stop or a camera while the START never returns',
        );
        expect(service.queuedRotationCountForTest, 2, reason: 'the rotation that waits on its START, and ONE tick behind it');
        expect(controller.errorMessage, isNull);

        await controller.stopSession().timeout(const Duration(seconds: 3));
        final stored = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(session.id)!;
        expect(stored.endTime, isNotNull);
        expect(stored.dashcamTelemetryOutcome, DashcamTelemetryOutcome.success);
        expect(indexedClips(session.id), hasLength(1), reason: 'the segment the rotation had ended');
        expect(count('createCameraWithSettings'), 1);
        expect(count('dispose'), 0, reason: 'nothing disposes a controller over a START still in flight');
        expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'the physical authority is not let go');
        expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
        decidedWhileItWaited = service.lateRestartSettlementCountForTest;
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
      // Released for the teardown: the camera is let go once, with nothing recording.
      await waitForTheSessionToBeOver();
      expect(fakePlatform.disposedCameraIds, hasLength(1));
      expect(count('createCameraWithSettings'), 1);
      expect(decidedWhileItWaited, 0, reason: 'nothing was decided before the native call settled');
    },
  );

  test(
    'X391 — the controller is disposed while the restart is overdue: when the START finally returns nothing is adopted and '
    'nothing is published; the late Recording is stopped, its camera released and the process owner freed',
    () async {
      build(startDeadline: shortDeadline);
      await startRecordingSession();
      final gate = await rotateAndHoldTheRestart();
      try {
        await waitForTheRestartToPassItsDeadline();
        // A notification on a disposed controller throws: this test ending
        // without an error is itself the proof that nothing was published.
        controller.dispose();
        statusSampler?.cancel();
        sampleStatusNow = null;
        await neverDuring(const Duration(milliseconds: 150), () => count('dispose') != 0, 'the camera disposed while the native START is in flight');
        expect(DashcamService.processOwnerCurrentForTest, isNotNull);

        gate.complete();
        await waitUntil(
          () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
          'the teardown completing after the START returned',
        );
        expect(count('stopVideoRecording'), 2, reason: 'the late Recording was stopped before its camera was disposed');
        final calls = fakePlatform.calls;
        expect(calls.lastIndexOf('stopVideoRecording'), lessThan(calls.indexOf('dispose')));
        expect(fakePlatform.disposedCameraIds, hasLength(1));
        expect(count('createCameraWithSettings'), 1);
        expect(timerTicks, hasLength(1), reason: 'no timer for the late Recording');
        expect(service.isRecording, isFalse);
        expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
        expectTheServiceDecided('recordingNoLongerWanted');
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );
}
