// Fase 16.2-R4.3-R2.6.20 — preservation of R2.6.19, written BEFORE the service
// was touched for N2: the window the pre-review microaudit of R2.6.19 and its
// independent review confirmed, now as permanent regressions. Real
// DashcamSessionController (a driving session with the dashcam on), real
// recorder and Hive, over the project's fake camera platform.
//
// The window: session A is ended while it has no camera yet — its NATIVE
// initialize() is still in flight, so a camera WILL appear — and `stopSession()`
// returns at once (since R2.6.19 `_stopCamera` asks the service for no release
// when there is no camera to name, so it no longer waits behind that
// initialize). Session B is requested while A's native call is still in flight.
// From then on the Future of `stopSession(A)` holds nothing back; what does is
// the controller's claim on the initialize() in flight (`_observedInitialize`,
// taken when the initialize is asked for and cleared only when it settles) and
// the service's serial queue.
//
// What every test here pins, physically:
//  * B is held back for as long as A's initialize is in flight: it asks the
//    service for no initialize() of its own and joins none; nothing of B exists
//    on the camera platform;
//  * A's late camera is cleaned up exactly once, by a release that NAMES it, and
//    it is disposed before B's camera is created — never two cameras open;
//  * that cleanup does not touch B: B's camera is not disposed, nothing stops
//    B's recording, B records by itself (no retry);
//  * the process owner is held while the initialize is in flight and while B
//    records, and is free — never "uncertain" — once B has ended.
//
// The orders, which differ in where A's cleanup lands in the service's queue:
//  X357  inside A's initialize deadline: the stale attempt of A (registered on
//        that initialize first) asks for the release AHEAD of B's initialize;
//  X358  past A's 10 s deadline with B already waiting: the late-initialize
//        watcher is registered AFTER B, so its release lands BEHIND B's
//        initialize — which has by then disposed A's late camera itself;
//  X359  past A's deadline BEFORE B is requested: the watcher is registered
//        first and its release lands ahead of B's initialize;
//  X360  B's attempt is born through the RECOVERY path (a `retryCamera()` called
//        re-entrantly, inside the recorder's own notification of the new
//        session): the one case in which only the recovery path's wait for the
//        claim holds B back.
//
// How the tests see "what was asked for": [_RecordingDashcamService] is the real
// service — every call goes to `super` — and only keeps, in order, which camera
// each release named and how many initialize() calls had been made by then.
// Waits are by cause; the only fixed delays are windows in which something must
// NOT happen.
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

/// One `releaseIdleCamera` the controller asked for.
class _ReleaseAsked {
  _ReleaseAsked(this.camera, {required this.wasTheCurrentCamera, required this.initializesAskedBefore});

  /// The camera it named; `null` when it named none (the untargeted release).
  final CameraController? camera;

  /// Whether, at the instant it was asked for, [camera] was the service's own.
  final bool wasTheCurrentCamera;

  /// How many `initialize()` calls the controller had made by then — which
  /// tells whether this release was asked for ahead of, or behind, the next
  /// session's own initialize.
  final int initializesAskedBefore;
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
    releasesAsked.add(
      _ReleaseAsked(
        expectedController,
        wasTheCurrentCamera: expectedController != null && identical(expectedController, previewController),
        initializesAskedBefore: initializesAsked,
      ),
    );
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
  /// elapses over a native initialize the test holds on a gate, so it cannot
  /// fire by accident. The stop deadline is never shortened here.
  const shortInitializeDeadline = Duration(milliseconds: 600);

  /// The fake camera platform numbers the cameras it creates from 0.
  const cameraOfA = 0;
  const cameraOfB = 1;

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
      'isRecording=${service.isRecording}, initializeInFlight=${service.pendingInitializeSettlement != null}, initializesAsked=${service.initializesAsked}, '
      'releasesAsked=${service.releasesAsked.map((r) => r.camera == null ? 'NO CAMERA' : 'a camera').toList()}, disposed=${fakePlatform.disposedCameraIds}, '
      'calls=${fakePlatform.calls.join(',')}';

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

  /// Session A is started and the NATIVE initialize of its camera is held: the
  /// camera already exists on the platform and WILL become the service's camera
  /// when that call returns.
  Future<({DrivingSession session, Completer<void> nativeInitialize})> startSessionAWithItsNativeInitializeHeld() async {
    final gate = Completer<void>();
    fakePlatform.pendingInitializeCamera = gate;
    final a = controller.startSession();
    await waitUntil(() => count('initializeCamera') == 1, 'the native initialize of A being issued and held');
    // Only that native initialize is held: the fake captured the gate when the
    // call was made.
    fakePlatform.pendingInitializeCamera = null;
    expect(service.previewController, isNull, reason: 'test setup: A has no camera yet');
    return (session: a, nativeInitialize: gate);
  }

  /// The end of A is requested with A's native initialize in flight, and its
  /// Future completes while that call is still in flight: nothing was asked of
  /// the service, and nothing was let go.
  Future<void> endSessionAWhileItsNativeInitializeIsInFlight() async {
    await controller.stopSession().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('stopSession(A) did not return while the native initialize of A was in flight (${state()})'),
    );
    expect(service.pendingInitializeSettlement, isNotNull, reason: 'stopSession(A) returned with the native initialize of A still in flight');
    expect(service.previewController, isNull);
    expect(service.releasesAsked, isEmpty, reason: 'A had no camera when it was ended: its end asked the service for no release');
    expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'the process owner stays held while that initialize is in flight');
  }

  /// What must hold for as long as A's native initialize is in flight and B
  /// waits: B asked the service for nothing, and nothing of B exists.
  void expectBIsHeldBackByTheInitializeOfA(DrivingSession b) {
    expect(controller.activeCameraAttemptSessionIdForTest, b.id, reason: 'B has its camera attempt, and it is waiting (${state()})');
    expect(
      service.initializesAsked,
      1,
      reason: 'B asked for no initialize() of its own — and joined none — while the initialize of A is in flight (${state()})',
    );
    expect(service.pendingInitializeSettlement, isNotNull, reason: 'test setup: the native initialize of A is still in flight');
    expect(count('createCameraWithSettings'), 1, reason: 'the only camera on the platform is the one the initialize of A is opening');
    expect(count('startVideoCapturing'), 0);
    expect(count('dispose'), 0);
    expect(controller.status, isNot(DashcamStatus.recording));
    expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'the process owner is held while the initialize of A is in flight');
    expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
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

  /// After A's native initialize returned: B records by itself; A's late camera
  /// got exactly one cleanup, by name, and was disposed before B's camera was
  /// created; nothing of that touched B. Then B is ended and nothing is left.
  ///
  /// [cleanupOfAAheadOfTheInitializeOfB] is the order this test is about: was
  /// A's cleanup asked of the service before B asked for its own initialize
  /// (`true`), or after (`false`)?
  Future<void> expectBRecordsAloneAndTheLateCameraOfAWasCleanedOnce(DrivingSession b, {required bool cleanupOfAAheadOfTheInitializeOfB}) async {
    // The camera attempt of B concludes one way or the other; `error` may still
    // be showing from A's own deadline while B's attempt is waiting, so a
    // failure is read from the attempt, not from the status alone.
    await waitUntil(
      () =>
          (controller.status == DashcamStatus.recording && cameraRecording()) ||
          (controller.status == DashcamStatus.error && controller.activeCameraAttemptSessionIdForTest == null && service.pendingInitializeSettlement == null),
      'the camera attempt of session B concluding',
      within: const Duration(seconds: 8),
    );
    expect(controller.status, DashcamStatus.recording, reason: 'session B was left without video: ${controller.errorMessage} (${state()})');
    expect(cameraRecording(), isTrue, reason: 'the camera of B records');
    expect(service.isRecording, isTrue);
    expect(controller.errorMessage, isNull);
    expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'the process owner is held while B records');
    expect(DashcamService.processOwnerIsUncertainForTest, isFalse);

    // B physically: its own initialize, its own camera, its own native START —
    // once each, and nothing stopped or disposed it.
    expect(service.initializesAsked, 2, reason: 'the initialize of A and the one B asked for itself: no retry, no third');
    expect(count('createCameraWithSettings'), 2, reason: 'the late camera of A, and the camera of B');
    expect(count('startVideoCapturing'), 1, reason: 'the native START of B; nothing was ever started on the late camera of A');
    expect(count('stopVideoRecording'), 0, reason: 'nothing stopped the recording of B');

    // The late camera of A: exactly one cleanup, by name, disposed exactly once
    // and before the camera of B was created.
    expect(service.releasesAsked, hasLength(1), reason: 'the late camera of A got exactly one cleanup request (${state()})');
    final cleanupOfA = service.releasesAsked.single;
    expect(cleanupOfA.camera, isNotNull, reason: 'and it NAMES a camera: the controller asks for no untargeted release');
    expect(cleanupOfA.wasTheCurrentCamera, isTrue, reason: 'the camera it names was the service\'s own when it was asked for: the late camera of A');
    expect(cleanupOfA.camera, isNot(same(service.previewController)), reason: 'it did not name the camera of B');
    expect(
      cleanupOfA.initializesAskedBefore,
      cleanupOfAAheadOfTheInitializeOfB ? 1 : 2,
      reason: cleanupOfAAheadOfTheInitializeOfB
          ? 'test setup: in this order the cleanup of A is asked for AHEAD of the initialize of B'
          : 'test setup: in this order the cleanup of A is asked for BEHIND the initialize of B',
    );
    expect(fakePlatform.disposedCameraIds, [cameraOfA], reason: 'the late camera of A was disposed exactly once; the camera of B was not');
    final calls = fakePlatform.calls;
    final disposeOfA = calls.indexOf('dispose');
    final createOfB = calls.indexOf('createCameraWithSettings', calls.indexOf('createCameraWithSettings') + 1);
    expect(disposeOfA, lessThan(createOfB), reason: 'the late camera of A was disposed BEFORE the camera of B was created ($calls)');
    expect(mostCamerasOpenAtOnce(), 1, reason: 'never two cameras open at the same time');

    // The end of B: its camera is released — by a release that names it — its
    // clip reaches its own index, and nothing is left.
    final cameraOfSessionB = service.previewController;
    await controller.stopSession().timeout(const Duration(seconds: 10));
    await waitUntil(
      () =>
          service.previewController == null &&
          service.pendingInitializeSettlement == null &&
          !service.hasPendingNativeStop &&
          DashcamService.processOwnerCurrentForTest == null &&
          recorder.state == DrivingSessionRecorderState.idle,
      'the camera and the process owner being released at the end of B',
      within: const Duration(seconds: 10),
    );
    expect(service.releasesAsked, hasLength(2), reason: 'ending B asks for one release');
    expect(service.releasesAsked.last.camera, same(cameraOfSessionB), reason: 'and it names the camera of B');
    expect(service.releasesAsked.where((r) => r.camera == null), isEmpty, reason: 'no release without a camera was ever asked for');
    expect(fakePlatform.disposedCameraIds, [cameraOfA, cameraOfB], reason: 'each camera was disposed exactly once');
    expect(count('createCameraWithSettings'), 2, reason: 'no camera is left open, and none was opened besides the two');
    expect(count('stopVideoRecording'), 1, reason: 'the one stop of B');
    expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
    await waitUntil(() => indexedClips(b.id).length == 1, 'the clip of B reaching the index of B');
  }

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_stop_return_barrier_session_test');
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
    // Last-resort barrier: every test releases its own gate in a `finally`.
    final gate = fakePlatform.pendingInitializeCamera;
    if (gate != null && !gate.isCompleted) gate.complete();
    fakePlatform.pendingInitializeCamera = null;
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

  group('Fase 16.2-R4.3-R2.6.20 (preservation of R2.6.19) — stopSession(A) returns with the native initialize of A in flight and B already requested', () {
    test(
      'X357 — the late camera of A appears INSIDE the initialize deadline of A: B is held back until then; the stale attempt of A asks '
      'for its cleanup, by name, AHEAD of the initialize of B; that camera is disposed once, before the camera of B is created; '
      'B records by itself and its end leaves nothing open',
      () async {
        build();
        await preferences.setEnabled(true);
        final a = await startSessionAWithItsNativeInitializeHeld();
        try {
          await endSessionAWhileItsNativeInitializeIsInFlight();
          final b = controller.startSession();
          expectBIsHeldBackByTheInitializeOfA(b);
          // A window in which nothing may move: B stays held back for as long as
          // the native initialize of A is in flight.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expectBIsHeldBackByTheInitializeOfA(b);
          expect(controller.lateInitializeWatcherInstallCountForTest, 0, reason: 'test setup: the initialize of A is inside its own deadline');

          a.nativeInitialize.complete();
          await expectBRecordsAloneAndTheLateCameraOfAWasCleanedOnce(b, cleanupOfAAheadOfTheInitializeOfB: true);
          expect(controller.lateInitializeWatcherInstallCountForTest, 0, reason: 'the cleanup was the stale attempt\'s own: no watcher was ever installed');
          expect(indexedClips(a.session.id), isEmpty, reason: 'A never recorded');
        } finally {
          if (!a.nativeInitialize.isCompleted) a.nativeInitialize.complete();
        }
      },
    );

    test(
      'X358 — B is ALREADY WAITING when the initialize of A passes its own 10 s deadline (the product\'s), and the late camera appears '
      'after that: the late-initialize watcher is registered behind B, so its cleanup — by name — is asked for BEHIND the initialize of B. '
      'The late camera is still disposed exactly once and before the camera of B is created; the cleanup finds another camera current and '
      'touches nothing; B keeps its camera and records by itself',
      () async {
        build();
        await preferences.setEnabled(true);
        final a = await startSessionAWithItsNativeInitializeHeld();
        try {
          await endSessionAWhileItsNativeInitializeIsInFlight();
          final b = controller.startSession();
          expectBIsHeldBackByTheInitializeOfA(b);
          expect(controller.lateInitializeWatcherInstallCountForTest, 0, reason: 'test setup: B starts waiting BEFORE the initialize of A passes its deadline');

          // By cause: the initialize of A passes its own deadline — the
          // controller installs the late-initialize watcher, behind B.
          await waitUntil(
            () => controller.lateInitializeWatcherInstallCountForTest == 1,
            'the initialize of A passing its own deadline',
            within: const Duration(seconds: 12),
          );
          expectBIsHeldBackByTheInitializeOfA(b);

          a.nativeInitialize.complete();
          await expectBRecordsAloneAndTheLateCameraOfAWasCleanedOnce(b, cleanupOfAAheadOfTheInitializeOfB: false);
          expect(controller.lateInitializeWatcherInstallCountForTest, 1);
        } finally {
          if (!a.nativeInitialize.isCompleted) a.nativeInitialize.complete();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'X359 — the initialize of A passes a short deadline BEFORE A is ended and B requested: the late-initialize watcher is registered '
      'first, so when the late camera appears its cleanup — by name — is asked for AHEAD of the initialize of B. Disposed once, before '
      'the camera of B is created; B records by itself',
      () async {
        build(initializeDeadline: shortInitializeDeadline);
        await preferences.setEnabled(true);
        final a = await startSessionAWithItsNativeInitializeHeld();
        try {
          await waitUntil(() => controller.status == DashcamStatus.error, 'A publishing its initialize deadline');
          expect(controller.lateInitializeWatcherInstallCountForTest, 1, reason: 'test setup: the watcher of A is installed before B exists');

          await endSessionAWhileItsNativeInitializeIsInFlight();
          final b = controller.startSession();
          expectBIsHeldBackByTheInitializeOfA(b);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expectBIsHeldBackByTheInitializeOfA(b);

          a.nativeInitialize.complete();
          await expectBRecordsAloneAndTheLateCameraOfAWasCleanedOnce(b, cleanupOfAAheadOfTheInitializeOfB: true);
          expect(controller.lateInitializeWatcherInstallCountForTest, 1, reason: 'the cleanup was the watcher\'s: no second one was installed');
        } finally {
          if (!a.nativeInitialize.isCompleted) a.nativeInitialize.complete();
        }
      },
    );

    test(
      'X360 — the camera attempt of B is born through the RECOVERY path (retryCamera() called re-entrantly, inside the recorder\'s own '
      'notification of the new session) while the native initialize of A is in flight: the recovery path holds B back the same way. '
      'The late camera of A is cleaned once, by name, before the camera of B is created; B records by itself',
      () async {
        build();
        await preferences.setEnabled(true);
        final a = await startSessionAWithItsNativeInitializeHeld();
        var retriedInsideTheNotificationOfB = false;
        void onRecorderNotification() {
          final active = recorder.activeSession;
          if (retriedInsideTheNotificationOfB || active == null || active.id == a.session.id) return;
          retriedInsideTheNotificationOfB = true;
          unawaited(controller.retryCamera());
        }

        try {
          await endSessionAWhileItsNativeInitializeIsInFlight();
          final attemptsBeforeB = controller.cameraAttemptCreationCountForTest;
          recorder.addListener(onRecorderNotification);
          final b = controller.startSession();
          expect(retriedInsideTheNotificationOfB, isTrue, reason: 'test setup: the re-entrant retryCamera() fired inside the notification of B');
          expect(
            controller.cameraAttemptCreationCountForTest,
            attemptsBeforeB + 1,
            reason: 'test setup: B has ONE camera attempt — the one the retry created; the initial start found it and added none',
          );
          expectBIsHeldBackByTheInitializeOfA(b);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expectBIsHeldBackByTheInitializeOfA(b);

          a.nativeInitialize.complete();
          await expectBRecordsAloneAndTheLateCameraOfAWasCleanedOnce(b, cleanupOfAAheadOfTheInitializeOfB: true);
        } finally {
          recorder.removeListener(onRecorderNotification);
          if (!a.nativeInitialize.isCompleted) a.nativeInitialize.complete();
        }
      },
    );
  });
}
