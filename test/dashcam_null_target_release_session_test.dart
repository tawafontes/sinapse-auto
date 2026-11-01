// Fase 16.2-R4.3-R2.6.19 — a camera release that has no camera to name is not
// asked for (N6), through the real DashcamSessionController (a driving session
// with the dashcam on), the real recorder and Hive, over the project's fake
// camera platform.
//
// The independent review of R2.6.18 found it (N6, older than that round). The
// controller releases "the camera this operation holds" at four places — a
// stale initial attempt, a stale recovery attempt, the late-initialize watcher
// and the end of a session — and takes that camera from `previewController`.
// When the value read was `null` it was passed on, and
// `DashcamService.releaseIdleCamera(expectedController: null)` is not "release
// nothing": it is the UNTARGETED release, which disposes whatever camera is
// current when its turn in the service's queue comes. In one order of events —
// a session started while an earlier session's initialize() was stuck, and
// already waiting for it when that initialize() passed its own deadline — that
// release landed behind the NEW session's initialize() and disposed the camera
// it had just opened: the session ended in `error`, with no video.
//
// The contract pinned here:
//  * the two sequences of the review (its G6 and G7, with the product's own
//    deadlines): the new session keeps its camera and records by itself — no
//    retry, no second camera open at any time, the process owner where it
//    belongs;
//  * at each of the four places, an operation that has no camera of its own
//    asks the service for no release at all;
//  * nothing leaks by that: a camera that appears LATE (an initialize that
//    returns after its session ended, or after its deadline) is still released,
//    and released by name; and a release that does have a camera to name is
//    issued exactly as before.
//
// How the tests see "what was asked for": [_RecordingDashcamService] is the
// real service — every call goes to `super` — and only keeps, in order, which
// camera each release named. That half has no physical trace of its own in most
// flows (a release that names no camera usually finds nothing to dispose), so
// it is asserted next to the physical outcome, never instead of it.
//
// Waits are by cause (a native call observed, a deadline seen through the
// controller's own counter, a Future settled), never by elapsed time alone.
// "Held at device discovery" means the initialize() is stopped at
// `availableCameras()`, before any native camera exists.
import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraController;
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

/// One `releaseIdleCamera` the controller asked for.
class _ReleaseAsked {
  _ReleaseAsked(this.camera, {required this.wasTheCurrentCamera});

  /// The camera it named; `null` when it named none (the untargeted release).
  final CameraController? camera;

  /// Whether, at the instant it was asked for, [camera] was the service's own.
  final bool wasTheCurrentCamera;
}

/// The real [DashcamService]: every call goes to `super`, nothing is changed.
/// It only keeps, in order, the releases and the initializations it was asked
/// for.
class _RecordingDashcamService extends DashcamService {
  _RecordingDashcamService({required super.config, super.initializeCameraTimeout}) : super(segmentDuration: const Duration(minutes: 10));

  final releasesAsked = <_ReleaseAsked>[];
  int initializesAsked = 0;

  @override
  Future<void> releaseIdleCamera({CameraController? expectedController}) {
    releasesAsked.add(_ReleaseAsked(expectedController, wasTheCurrentCamera: expectedController != null && identical(expectedController, previewController)));
    return super.releaseIdleCamera(expectedController: expectedController);
  }

  @override
  Future<void> initialize({bool Function()? semanticStillValid, int? lifecycleGeneration}) {
    initializesAsked++;
    return super.initialize(semanticStillValid: semanticStillValid, lifecycleGeneration: lifecycleGeneration);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeCameraPlatform fakePlatform;
  late StreamController<TelemetrySnapshot> snapshotController;
  late StreamController<DetectedEvent> eventController;
  late DrivingSessionRecorder recorder;
  late DashcamPreferences preferences;
  late _RecordingDashcamService service;
  late DashcamSessionController controller;
  Timer? snapshotFeeder;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  /// An initialize deadline short enough to elapse within a test. It only ever
  /// elapses over an initialize() the test holds on a gate, so it cannot fire by
  /// accident. The stop deadline is never shortened here.
  const shortInitializeDeadline = Duration(milliseconds: 600);

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;
  bool cameraRecording() => service.previewController?.value.isRecordingVideo ?? false;

  /// The most cameras that were open at the same time, from the order in which
  /// the camera platform was asked to create and to dispose them.
  int mostCamerasOpenAtOnce() {
    var open = 0, most = 0;
    for (final call in fakePlatform.calls) {
      if (call == 'createCameraWithSettings') open++;
      if (call == 'dispose') open--;
      if (open > most) most = open;
    }
    return most;
  }

  String state() =>
      'status=${controller.status.name}, error=${controller.errorMessage}, cameraHeld=${service.previewController != null}, cameraRecording=${cameraRecording()}, '
      'isRecording=${service.isRecording}, initializeInFlight=${service.pendingInitializeSettlement != null}, pendingStop=${service.hasPendingNativeStop}, '
      'releasesAsked=${service.releasesAsked.map((r) => r.camera == null ? 'NO CAMERA' : 'a camera').toList()}, calls=${fakePlatform.calls.join(',')}';

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail('never happened within ${within.inMilliseconds} ms: $what (${state()})');
  }

  /// Every deadline is the product's own, unless [initializeDeadline] is given.
  void build({Duration? initializeDeadline}) {
    final config = DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    );
    service = initializeDeadline == null ? _RecordingDashcamService(config: config) : _RecordingDashcamService(config: config, initializeCameraTimeout: initializeDeadline);
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  }

  /// The next initialize() will stop at device discovery — before any native
  /// camera exists — until the returned gate is released. [entered] completes
  /// when an initialize() reaches it.
  ({Completer<void> gate, Completer<void> entered}) holdDeviceDiscovery() {
    final gate = Completer<void>();
    final entered = Completer<void>();
    fakePlatform.pendingAvailableCameras = gate;
    fakePlatform.availableCamerasEnteredForTest = entered;
    return (gate: gate, entered: entered);
  }

  Future<void> waitForTheHeldDiscovery(Completer<void> entered) async {
    await entered.future.timeout(const Duration(seconds: 5));
    fakePlatform.availableCamerasEnteredForTest = null;
  }

  void releaseDeviceDiscovery(Completer<void> gate) {
    fakePlatform.pendingAvailableCameras = null;
    if (!gate.isCompleted) gate.complete();
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

  /// The camera attempt of the session that is current has concluded one way or
  /// the other — and it must be recording, by itself: nobody asked for a retry.
  ///
  /// "Concluded in failure" is read from the attempt itself, not from the status
  /// alone: `error` may still be showing from an EARLIER session whose own
  /// initialize() passed its deadline, while this session's attempt is waiting.
  Future<void> expectTheCurrentSessionToRecordByItself(String who) async {
    await waitUntil(
      () =>
          (controller.status == DashcamStatus.recording && cameraRecording()) ||
          (controller.status == DashcamStatus.error && controller.activeCameraAttemptSessionIdForTest == null && service.pendingInitializeSettlement == null),
      'the camera attempt of $who concluding',
      within: const Duration(seconds: 8),
    );
    expect(controller.status, DashcamStatus.recording, reason: '$who was left without video: ${controller.errorMessage}');
    expect(cameraRecording(), isTrue, reason: 'the camera of $who records');
    expect(service.isRecording, isTrue);
    expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'the camera process owner is held while $who records');
    expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
  }

  /// A release that names no camera is the untargeted one.
  void expectNoReleaseWithoutACamera() {
    expect(
      service.releasesAsked.where((r) => r.camera == null),
      isEmpty,
      reason: 'the controller asked the service for a release that names no camera: it would dispose whatever camera is current when its turn comes',
    );
  }

  Future<void> waitForNothingToBeHeld({String what = 'the camera and the process owner being released'}) {
    return waitUntil(
      () =>
          service.previewController == null &&
          service.pendingInitializeSettlement == null &&
          !service.hasPendingNativeStop &&
          DashcamService.processOwnerCurrentForTest == null &&
          recorder.state == DrivingSessionRecorderState.idle,
      what,
      within: const Duration(seconds: 10),
    );
  }

  /// The end of the session that is recording: its camera is released — by a
  /// release that names it — and its clip reaches its own index.
  Future<void> endTheRecordingSession(DrivingSession session) async {
    final camera = service.previewController;
    final releasesBefore = service.releasesAsked.length;
    final disposesBefore = count('dispose');
    await controller.stopSession().timeout(const Duration(seconds: 10));
    await waitForNothingToBeHeld();
    expect(count('dispose'), disposesBefore + 1, reason: 'the camera of the session was disposed once');
    final releases = service.releasesAsked.sublist(releasesBefore);
    expect(releases, hasLength(1), reason: 'ending a session that has a camera asks for one release');
    expect(releases.single.camera, same(camera), reason: 'and it names that camera');
    await waitUntil(() => indexedClips(session.id).length == 1, 'the clip of the session reaching its index');
    expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_null_target_release_session_test');
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
    // Last-resort barrier: every test releases its own gates in a `finally`.
    fakePlatform.failCreateCameraWith = null;
    for (final gate in [
      fakePlatform.pendingAvailableCameras,
      fakePlatform.pendingInitializeCamera,
      fakePlatform.pendingStartVideoCapturing,
      fakePlatform.pendingStopVideoRecording,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    fakePlatform.pendingAvailableCameras = null;
    fakePlatform.availableCamerasEnteredForTest = null;
    fakePlatform.pendingInitializeCamera = null;
    fakePlatform.pendingStartVideoCapturing = null;
    fakePlatform.pendingStopVideoRecording = null;
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

  group('Fase 16.2-R4.3-R2.6.19 — N6: a session started behind a stuck initialize() keeps the camera it opens', () {
    test(
      'X344 — the review\'s first sequence, with the product\'s own deadlines: session A\'s initialize() is held at device '
      'discovery; A is ended; B is started and is already waiting for that initialize() when it passes its own 10 s '
      'deadline; then it unblocks. B opens its camera and KEEPS it: it records by itself, one camera created and none '
      'disposed, and the service was asked for no release that names no camera',
      () async {
        build();
        await preferences.setEnabled(true);
        final discovery = holdDeviceDiscovery();
        try {
          controller.startSession();
          await waitForTheHeldDiscovery(discovery.entered);
          final stoppingA = controller.stopSession();
          await waitUntil(() => controller.canStartSession, 'a new session being admissible', within: const Duration(seconds: 12));
          final b = controller.startSession();
          await stoppingA.timeout(const Duration(seconds: 12));
          expect(controller.lateInitializeWatcherInstallCountForTest, 0, reason: 'test setup: B starts waiting BEFORE A\'s initialize() passes its deadline');

          // By cause: A's initialize() passes its own deadline — the controller installs the late-initialize watcher.
          await waitUntil(
            () => controller.lateInitializeWatcherInstallCountForTest == 1,
            'the initialize() of A passing its own deadline',
            within: const Duration(seconds: 12),
          );
          expect(count('createCameraWithSettings'), 0, reason: 'test setup: no camera exists yet');
          expect(service.pendingInitializeSettlement, isNotNull, reason: 'test setup: A\'s initialize() is still held');

          releaseDeviceDiscovery(discovery.gate);
          await expectTheCurrentSessionToRecordByItself('session B');

          expect(count('createCameraWithSettings'), 1, reason: 'one camera was opened: B\'s');
          expect(count('dispose'), 0, reason: 'and nothing disposed it');
          expect(count('startVideoCapturing'), 1, reason: 'B\'s own native START');
          expect(mostCamerasOpenAtOnce(), 1);
          expect(controller.errorMessage, isNull);
          expect(service.releasesAsked, isEmpty, reason: 'A never had a camera: neither its end nor its stale attempt had one to release');

          await endTheRecordingSession(b);
          expectNoReleaseWithoutACamera();
          expect(count('createCameraWithSettings'), 1, reason: 'no retry, no second camera');
        } finally {
          releaseDeviceDiscovery(discovery.gate);
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'X345 — the review\'s second sequence, a slow native stop as the cause: session Z\'s native stop does not return; A is '
      'started — its initialize() waits behind that stop — and ended; B is started; A\'s initialize() passes its deadline; '
      'only then, about 15 s after it was issued, does the stop return. B keeps the camera it opens and records by itself; '
      'never two cameras open at once; Z\'s clip still reaches Z\'s index',
      () async {
        build();
        await preferences.setEnabled(true);
        final z = controller.startSession();
        await waitUntil(() => controller.status == DashcamStatus.recording && cameraRecording(), 'session Z recording');
        final cameraOfZ = service.previewController;
        final stopGate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGate;
        try {
          final stoppingZ = controller.stopSession();
          await waitUntil(() => count('stopVideoRecording') == 1 && service.hasPendingNativeStop, 'the native stop of Z being issued and held');
          fakePlatform.pendingStopVideoRecording = null;

          // Z's stop hands control back at its own 5 s response deadline; the native call stays owned by the service.
          await waitUntil(() => controller.canStartSession, 'a new session being admissible', within: const Duration(seconds: 12));
          final initializesBeforeA = service.initializesAsked;
          controller.startSession();
          await waitUntil(
            () => service.initializesAsked == initializesBeforeA + 1,
            'the initialize() of A being asked for (it waits in the service\'s queue behind the stop of Z)',
            within: const Duration(seconds: 12),
          );
          expect(service.hasPendingNativeStop, isTrue, reason: 'test setup: the native stop of Z has not returned');

          final stoppingA = controller.stopSession();
          await waitUntil(() => controller.canStartSession, 'a new session being admissible again', within: const Duration(seconds: 12));
          final b = controller.startSession();
          await stoppingA.timeout(const Duration(seconds: 12));
          expect(controller.lateInitializeWatcherInstallCountForTest, 0, reason: 'test setup: B starts waiting BEFORE A\'s initialize() passes its deadline');

          await waitUntil(
            () => controller.lateInitializeWatcherInstallCountForTest == 1,
            'the initialize() of A passing its own deadline',
            within: const Duration(seconds: 14),
          );
          expect(count('createCameraWithSettings'), 1, reason: 'test setup: the only camera so far is Z\'s');
          expect(service.hasPendingNativeStop, isTrue, reason: 'test setup: the native stop of Z is still held');

          stopGate.complete();
          await stoppingZ.timeout(const Duration(seconds: 15));
          await expectTheCurrentSessionToRecordByItself('session B');

          expect(count('createCameraWithSettings'), 2, reason: 'Z\'s camera, and B\'s');
          expect(count('dispose'), 1, reason: 'Z\'s camera, disposed by A\'s initialize() at its turn in the queue (before it was abandoned) — B\'s was not disposed');
          expect(service.previewController, isNot(same(cameraOfZ)));
          expect(count('startVideoCapturing'), 2, reason: 'Z\'s and B\'s native STARTs');
          expect(count('stopVideoRecording'), 1, reason: 'the one stop of Z; nothing stopped B');
          expect(mostCamerasOpenAtOnce(), 1, reason: 'never a second camera open at the same time');
          expect(controller.errorMessage, isNull);
          expectNoReleaseWithoutACamera();
          expect(
            service.releasesAsked.map((r) => r.camera),
            [same(cameraOfZ)],
            reason: 'the only release so far is the one A\'s end asked for, naming the camera that was there then (Z\'s) — it found that camera gone and did nothing',
          );
          await waitUntil(() => indexedClips(z.id).length == 1, 'the clip of Z reaching Z\'s index once its stop settled');

          await endTheRecordingSession(b);
          expectNoReleaseWithoutACamera();
          expect(count('createCameraWithSettings'), 2, reason: 'no retry, no third camera');
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('Fase 16.2-R4.3-R2.6.19 — an operation that has no camera of its own asks for no release', () {
    test(
      'X346 — a stale INITIAL attempt: session A\'s initialize() is held at device discovery, A is ended, B is started, and the '
      'initialize() unblocks inside its deadline — abandoned, without a camera. Neither A\'s end nor A\'s stale attempt '
      'asks for a release; B records by itself',
      () async {
        build();
        await preferences.setEnabled(true);
        final discovery = holdDeviceDiscovery();
        try {
          controller.startSession();
          await waitForTheHeldDiscovery(discovery.entered);
          final stoppingA = controller.stopSession();
          await waitUntil(() => controller.canStartSession, 'a new session being admissible', within: const Duration(seconds: 12));
          final b = controller.startSession();
          await stoppingA.timeout(const Duration(seconds: 12));
          expect(service.pendingInitializeSettlement, isNotNull, reason: 'test setup: A\'s initialize() is still held');
          expect(service.releasesAsked, isEmpty, reason: 'A was ended without a camera: its end has none to release');

          releaseDeviceDiscovery(discovery.gate);
          await expectTheCurrentSessionToRecordByItself('session B');

          expect(controller.lateInitializeWatcherInstallCountForTest, 0, reason: 'test setup: the initialize() of A never passed its deadline');
          expect(service.releasesAsked, isEmpty, reason: 'A\'s initialize() produced no camera: its stale attempt has none to release');
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0);
          expect(mostCamerasOpenAtOnce(), 1);

          await endTheRecordingSession(b);
          expectNoReleaseWithoutACamera();
        } finally {
          releaseDeviceDiscovery(discovery.gate);
        }
      },
    );

    test(
      'X347 — a stale RECOVERY attempt: session A records, the app goes to the background and returns, the recovery\'s '
      'initialize() is held at device discovery, A is ended, B is started, and the initialize() unblocks — abandoned. '
      'No release that names no camera is asked for; B records by itself',
      () async {
        build();
        await preferences.setEnabled(true);
        controller.startSession();
        await waitUntil(() => controller.status == DashcamStatus.recording && cameraRecording(), 'session A recording');
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await waitUntil(() => controller.status == DashcamStatus.cameraUnavailable, 'A seeing the background');
        final discovery = holdDeviceDiscovery();
        try {
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await waitForTheHeldDiscovery(discovery.entered);
          expect(service.previewController, isNull, reason: 'test setup: the recovery\'s initialize() has released A\'s first camera and has none yet');
          final releasesBeforeTheEnd = service.releasesAsked.length;

          final stoppingA = controller.stopSession();
          await waitUntil(() => controller.canStartSession, 'a new session being admissible', within: const Duration(seconds: 12));
          final b = controller.startSession();
          await stoppingA.timeout(const Duration(seconds: 12));
          expect(service.pendingInitializeSettlement, isNotNull, reason: 'test setup: the recovery\'s initialize() is still held');

          releaseDeviceDiscovery(discovery.gate);
          await expectTheCurrentSessionToRecordByItself('session B');

          expect(service.releasesAsked.sublist(releasesBeforeTheEnd), isEmpty, reason: 'neither A\'s end nor its stale recovery had a camera to release');
          expectNoReleaseWithoutACamera();
          expect(count('createCameraWithSettings'), 2, reason: 'A\'s first camera, and B\'s');
          expect(count('dispose'), 1, reason: 'A\'s first camera, by the recovery\'s own initialize()');
          expect(mostCamerasOpenAtOnce(), 1);

          await endTheRecordingSession(b);
          expectNoReleaseWithoutACamera();
        } finally {
          releaseDeviceDiscovery(discovery.gate);
        }
      },
    );

    test(
      'X348 — the late-initialize watcher, running BEFORE the next session waits: session A\'s initialize() passes a short '
      'deadline while held at device discovery, A is ended, B is started, and the initialize() unblocks — abandoned. The '
      'watcher asks for no release; B records by itself',
      () async {
        build(initializeDeadline: shortInitializeDeadline);
        await preferences.setEnabled(true);
        final discovery = holdDeviceDiscovery();
        try {
          controller.startSession();
          await waitForTheHeldDiscovery(discovery.entered);
          await waitUntil(() => controller.status == DashcamStatus.error, 'A publishing its initialize deadline');
          expect(controller.lateInitializeWatcherInstallCountForTest, 1, reason: 'test setup: the watcher of A is installed before B exists');

          final stoppingA = controller.stopSession();
          await waitUntil(() => controller.canStartSession, 'a new session being admissible', within: const Duration(seconds: 12));
          final b = controller.startSession();
          await stoppingA.timeout(const Duration(seconds: 12));
          expect(service.pendingInitializeSettlement, isNotNull, reason: 'test setup: A\'s initialize() is still held');

          releaseDeviceDiscovery(discovery.gate);
          await expectTheCurrentSessionToRecordByItself('session B');

          expect(service.releasesAsked, isEmpty, reason: 'A\'s late initialize() produced no camera: its watcher has none to release');
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0);

          await endTheRecordingSession(b);
          expectNoReleaseWithoutACamera();
        } finally {
          releaseDeviceDiscovery(discovery.gate);
        }
      },
    );

    test(
      'X349 — the end of a session that never had a camera: its initialize() is held at device discovery when it is '
      'ended. stopSession() returns with that initialize() still held and asks the service for nothing; when the '
      'initialize() unblocks nothing is created, nothing is held, and the next session records',
      () async {
        build();
        await preferences.setEnabled(true);
        final discovery = holdDeviceDiscovery();
        try {
          controller.startSession();
          await waitForTheHeldDiscovery(discovery.entered);

          await controller.stopSession().timeout(const Duration(seconds: 12));
          expect(service.pendingInitializeSettlement, isNotNull, reason: 'the session ended while its initialize() was still held');
          expect(service.releasesAsked, isEmpty, reason: 'a session that has no camera has none to release when it ends');
          expect(controller.status, DashcamStatus.idle);

          releaseDeviceDiscovery(discovery.gate);
          await waitForNothingToBeHeld(what: 'the abandoned initialize() finishing with nothing held');
          expect(count('createCameraWithSettings'), 0, reason: 'the initialize() of a session that was ended creates no camera');
          expect(service.releasesAsked, isEmpty, reason: 'and its stale attempt has none to release either');

          final next = controller.startSession();
          await expectTheCurrentSessionToRecordByItself('the next session');
          await endTheRecordingSession(next);
          expectNoReleaseWithoutACamera();
        } finally {
          releaseDeviceDiscovery(discovery.gate);
        }
      },
    );

    test(
      'X350 — one session, background and foreground: its initialize() is held at device discovery, the app goes to the '
      'background and returns, the initialize() passes a short deadline, and then it unblocks — abandoned, its attempt '
      'stale. The watcher asks for no release, and the session records by itself on the camera its next attempt opens',
      () async {
        build(initializeDeadline: shortInitializeDeadline);
        await preferences.setEnabled(true);
        final discovery = holdDeviceDiscovery();
        try {
          final session = controller.startSession();
          await waitForTheHeldDiscovery(discovery.entered);
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await waitUntil(() => controller.lateInitializeWatcherInstallCountForTest == 1, 'the first initialize() passing its deadline');
          expect(service.pendingInitializeSettlement, isNotNull, reason: 'test setup: the first initialize() is still held');
          expect(count('createCameraWithSettings'), 0);

          releaseDeviceDiscovery(discovery.gate);
          await expectTheCurrentSessionToRecordByItself('the session');

          expect(service.releasesAsked, isEmpty, reason: 'the first initialize() produced no camera: its watcher has none to release');
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0);

          await endTheRecordingSession(session);
          expectNoReleaseWithoutACamera();
        } finally {
          releaseDeviceDiscovery(discovery.gate);
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.19 — nothing leaks: a camera that appears late is released, by name', () {
    test(
      'X351 — a session is ended while its NATIVE initialize is in flight: when it returns, the camera it produced is '
      'released by the stale attempt, naming it. One camera created, one disposed, nothing held, the process owner free',
      () async {
        build();
        await preferences.setEnabled(true);
        final nativeInitialize = Completer<void>();
        fakePlatform.pendingInitializeCamera = nativeInitialize;
        try {
          controller.startSession();
          await waitUntil(() => count('initializeCamera') == 1, 'the native initialize being issued and held');

          await controller.stopSession().timeout(const Duration(seconds: 12));
          expect(service.releasesAsked, isEmpty, reason: 'the session had no camera yet when it was ended');
          expect(service.pendingInitializeSettlement, isNotNull, reason: 'test setup: the native initialize has not returned');

          fakePlatform.pendingInitializeCamera = null;
          nativeInitialize.complete();
          await waitForNothingToBeHeld(what: 'the late camera being released');

          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 1, reason: 'the camera that appeared late was disposed');
          expect(count('startVideoCapturing'), 0, reason: 'nothing was started on it');
          expect(service.releasesAsked, hasLength(1), reason: 'the stale attempt asked for one release');
          expect(service.releasesAsked.single.camera, isNotNull, reason: 'naming the camera its initialize() produced');
          expect(service.releasesAsked.single.wasTheCurrentCamera, isTrue);
          expect(controller.status, DashcamStatus.idle);
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!nativeInitialize.isCompleted) nativeInitialize.complete();
        }
      },
    );

    test(
      'X352 — the same past the initialize deadline: the native initialize is held past a short deadline, the session is '
      'ended, and then it returns. The late-initialize watcher releases the camera it produced, naming it',
      () async {
        build(initializeDeadline: shortInitializeDeadline);
        await preferences.setEnabled(true);
        final nativeInitialize = Completer<void>();
        fakePlatform.pendingInitializeCamera = nativeInitialize;
        try {
          controller.startSession();
          await waitUntil(() => count('initializeCamera') == 1, 'the native initialize being issued and held');
          await waitUntil(() => controller.status == DashcamStatus.error, 'the session publishing its initialize deadline');
          expect(controller.lateInitializeWatcherInstallCountForTest, 1, reason: 'test setup: the watcher owns the retained initialize()');

          await controller.stopSession().timeout(const Duration(seconds: 12));
          expect(service.releasesAsked, isEmpty, reason: 'the session had no camera yet when it was ended');

          fakePlatform.pendingInitializeCamera = null;
          nativeInitialize.complete();
          await waitForNothingToBeHeld(what: 'the late camera being released');

          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 1, reason: 'the camera that appeared late was disposed');
          expect(count('startVideoCapturing'), 0);
          expect(service.releasesAsked, hasLength(1), reason: 'the watcher asked for one release');
          expect(service.releasesAsked.single.camera, isNotNull, reason: 'naming the camera the late initialize() produced');
          expect(service.releasesAsked.single.wasTheCurrentCamera, isTrue);
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!nativeInitialize.isCompleted) nativeInitialize.complete();
        }
      },
    );

    test(
      'X353 — the recovery path: a session records, the app goes to the background and returns, and the session is ended '
      'while the recovery\'s NATIVE initialize is in flight. When it returns, the camera it produced is released by the '
      'stale recovery, naming it',
      () async {
        build();
        await preferences.setEnabled(true);
        controller.startSession();
        await waitUntil(() => controller.status == DashcamStatus.recording && cameraRecording(), 'the session recording');
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await waitUntil(() => controller.status == DashcamStatus.cameraUnavailable, 'the session seeing the background');
        final nativeInitialize = Completer<void>();
        fakePlatform.pendingInitializeCamera = nativeInitialize;
        try {
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await waitUntil(() => count('initializeCamera') == 2, 'the native initialize of the recovery being issued and held');
          expect(service.previewController, isNull, reason: 'test setup: the first camera is gone and the recovery\'s is not there yet');
          final releasesBeforeTheEnd = service.releasesAsked.length;

          await controller.stopSession().timeout(const Duration(seconds: 12));
          expect(service.releasesAsked.sublist(releasesBeforeTheEnd), isEmpty, reason: 'the session had no camera when it was ended');

          fakePlatform.pendingInitializeCamera = null;
          nativeInitialize.complete();
          await waitForNothingToBeHeld(what: 'the recovery\'s late camera being released');

          expect(count('createCameraWithSettings'), 2);
          expect(count('dispose'), 2, reason: 'the first camera, and the one the recovery produced late');
          expect(count('startVideoCapturing'), 1, reason: 'nothing was started on the recovery\'s camera');
          final releases = service.releasesAsked.sublist(releasesBeforeTheEnd);
          expect(releases, hasLength(1), reason: 'the stale recovery asked for one release');
          expect(releases.single.camera, isNotNull, reason: 'naming the camera its initialize() produced');
          expect(releases.single.wasTheCurrentCamera, isTrue);
          expectNoReleaseWithoutACamera();
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!nativeInitialize.isCompleted) nativeInitialize.complete();
        }
      },
    );

    test(
      'X354 — dispose: the controller is disposed while the native initialize of its session is in flight. When it '
      'returns, the camera is disposed once and the process owner is free — nothing is left held',
      () async {
        build();
        await preferences.setEnabled(true);
        final nativeInitialize = Completer<void>();
        fakePlatform.pendingInitializeCamera = nativeInitialize;
        try {
          controller.startSession();
          await waitUntil(() => count('initializeCamera') == 1, 'the native initialize being issued and held');

          controller.dispose();
          fakePlatform.pendingInitializeCamera = null;
          nativeInitialize.complete();
          await waitUntil(
            () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
            'the camera and the process owner being released after the dispose',
            within: const Duration(seconds: 10),
          );

          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 1);
          expect(count('startVideoCapturing'), 0);
          expectNoReleaseWithoutACamera();
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!nativeInitialize.isCompleted) nativeInitialize.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.19 — a release that has a camera to name is asked for as before', () {
    test(
      'X355 — camera unavailable: a session whose camera became unavailable in the background is ended there. Its end '
      'asks for one release, naming that camera; the camera is disposed and the clip reaches the session\'s index',
      () async {
        build();
        await preferences.setEnabled(true);
        final session = controller.startSession();
        await waitUntil(() => controller.status == DashcamStatus.recording && cameraRecording(), 'the session recording');
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await waitUntil(() => controller.status == DashcamStatus.cameraUnavailable, 'the session seeing the background');
        expect(service.previewController, isNotNull, reason: 'test setup: the session still holds its camera');

        await endTheRecordingSession(session);
        expect(count('createCameraWithSettings'), 1);
        expectNoReleaseWithoutACamera();
      },
    );

    test(
      'X356 — no camera at all, legitimately: the initialize() of a session FAILS, and the session is ended. Its end asks '
      'for no release — there is no camera — nothing is held, and the next session opens its own camera, records, and '
      'releases it by name when it ends',
      () async {
        build();
        await preferences.setEnabled(true);
        fakePlatform.failCreateCameraWith = CameraException('camera_error', 'the camera could not be created');
        try {
          controller.startSession();
          await waitUntil(() => controller.status == DashcamStatus.error, 'the session publishing the failure of its initialize()');
          fakePlatform.failCreateCameraWith = null;
          expect(service.previewController, isNull);

          await controller.stopSession().timeout(const Duration(seconds: 12));
          await waitForNothingToBeHeld();
          expect(service.releasesAsked, isEmpty, reason: 'a session whose camera never existed has none to release');

          final next = controller.startSession();
          await expectTheCurrentSessionToRecordByItself('the next session');
          await endTheRecordingSession(next);
          expectNoReleaseWithoutACamera();
        } finally {
          fakePlatform.failCreateCameraWith = null;
        }
      },
    );
  });
}
