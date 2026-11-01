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
import 'package:synapse_auto/screens/sessions/session_recording_screen.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_clip_index.dart' show runInClipIndexQueue;
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/unit_preferences.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_preview_view.dart';

import 'support/fake_camera_platform.dart';
import 'support/held_deadlines.dart';
import 'support/hive_box_io_gate.dart';
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

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  TelemetrySnapshot snapshot({
    DateTime? timestamp,
    double? speedKmh,
    double? gForceMagnitude,
  }) {
    return TelemetrySnapshot(
      timestamp: timestamp ?? DateTime.now(),
      speedKmh: speedKmh,
      gForceMagnitude: gForceMagnitude,
      gnssQuality: GnssQuality.good,
      altitudeTrend: AltitudeTrend.stable,
    );
  }

  DetectedEvent detectedEvent({required EventSeverity severity, required DetectedEventType type}) {
    return DetectedEvent(type: type, timestamp: DateTime.now(), severity: severity, snapshot: snapshot(speedKmh: 99));
  }

  /// Fase 16.2-R4.2B-R2 (§22, test-fragility fix — not a product defect):
  /// polls for [DashcamSessionController.status] to reach [expected],
  /// instead of guessing a fixed delay is enough. A handful of this file's
  /// own tests previously used a flat 30ms wait after triggering an
  /// asynchronous recovery, which was demonstrated (via repeated runs under
  /// `--test-randomize-ordering-seed=42`) to be an occasionally-too-tight
  /// margin, not evidence of a real product regression — recovery's own
  /// underlying `DashcamService` calls remain reentrant/near-instant in
  /// every one of these scenarios; only the WAIT was flaky, never the
  /// outcome. Fails the test explicitly (via `fail()`) on timeout, matching
  /// `dashcam_service_test.dart`'s own established `waitFor*` contract.
  Future<void> waitForStatus(
    DashcamStatus expected, {
    DashcamSessionController? on,
    int maxIterations = 200,
    Duration step = const Duration(milliseconds: 10),
    String? label,
  }) async {
    final target = on ?? controller;
    for (var i = 0; i < maxIterations; i++) {
      if (target.status == expected) return;
      await Future<void>.delayed(step);
    }
    fail(
      'waitForStatus${label == null ? '' : ' [$label]'}: status never reached $expected after ${maxIterations * step.inMilliseconds}ms '
      '(currently ${target.status}, errorMessage: ${target.errorMessage}, nativeCalls: ${fakePlatform.calls.join(',')})',
    );
  }

  /// Fase 16.2-R4.4-R1-T-Rm: polls [condition] until it holds, failing the test
  /// (never returning silently) after a finite bound — for a test that must
  /// wait for a state the code publishes, instead of a fixed delay guessing it
  /// has been reached.
  Future<void> waitForCondition(bool Function() condition, String label, {int maxIterations = 300}) async {
    for (var i = 0; i < maxIterations; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('waitForCondition: "$label" never held after ${maxIterations * 10}ms (calls: ${fakePlatform.calls.join(',')})');
  }

  /// Fase 16.2-R4.4-R1-T-Rm: how many times the fake camera saw [call].
  int callCount(String call) => fakePlatform.calls.where((c) => c == call).length;

  /// Fase 16.2-R4.4-R1-T-Rm: a PREPARATION stop that must settle normally —
  /// "G1 settles normally", the first clip the rest of the test builds on. With
  /// a short `stopVideoRecordingTimeout` (the scenario needs it for a LATER
  /// stop), the clip's processing — its promotion is real file I/O since
  /// R4.4-R1 — could outlast the deadline under load: the stop then returned
  /// before the clip existed, and the service marked the camera generation
  /// untrusted, which is not the scenario these tests set up (reproduced by
  /// delaying only the promotion's rename, T-Rm 02_directed/screen_rename).
  /// Its deadlines are held ([HeldDeadlines]) for this one call: it returns once
  /// the stop really completed, and nothing may still be held afterwards.
  Future<void> stopNormally(DashcamService target, Future<void> Function() stop) async {
    final held = HeldDeadlines.upTo(target.stopVideoRecordingTimeout);
    await held.run(stop);
    expect(held.pending, 0, reason: 'test setup check: the preparation stop completed before any of its deadlines had to elapse');
  }

  /// Fase 16.2-R4.2B-R3 (§39/§40/§48, independent review — "polling helper
  /// pode retornar silenciosamente" / "G/I/N sem prova terminal em todos os
  /// failure paths"), strengthened in Fase 16.2-R4.2B-R4 (§37-§41,
  /// independent review P2-B — "waitForServiceSettled não prova settlement
  /// completo"): the R3-era condition (`previewController == null` AND
  /// owner not equal to [target]'s OWN token) could pass while [target]'s
  /// own `initialize()` was still genuinely awaiting ADMISSION (never
  /// having touched the backend yet — `previewController` starts `null`
  /// regardless) or while a COMPLETELY DIFFERENT instance's own token was
  /// still the GLOBAL coordinator owner — neither is real settlement, and
  /// the second is exactly the cross-test contamination this harness
  /// exists to catch, not silently pass through. The terminal condition now
  /// requires ALL of: (1) `target.pendingInitializeSettlement == null` — no
  /// retained native initialize() operation left for [target], pending or
  /// otherwise; (2) `target.previewController == null`; (3)
  /// `DashcamService.processOwnerCurrentForTest == null` — the coordinator
  /// is GLOBALLY free, not merely "not [target]'s own token" (§39: ANY
  /// owner remaining means SOME instance still holds the backend, which is
  /// cross-test contamination regardless of which instance it is); (4)
  /// `!DashcamService.processOwnerIsUncertainForTest` (redundant with (3) in
  /// this coordinator's own current implementation — `_owner` only ever
  /// becomes `null` when NOT uncertain — but asserted explicitly so the
  /// invariant is documented here, not merely implied by another class's
  /// internals). Fails the test explicitly (`fail()`) on timeout —
  /// PROHIBITED to return silently after exhausting [maxIterations] (an
  /// earlier version of this file's own `drainLocal` did exactly that).
  Future<void> waitForServiceSettled(
    DashcamService target, {
    int maxIterations = 200,
    Duration step = const Duration(milliseconds: 10),
  }) async {
    for (var i = 0; i < maxIterations; i++) {
      if (target.pendingInitializeSettlement == null &&
          target.previewController == null &&
          DashcamService.processOwnerCurrentForTest == null &&
          !DashcamService.processOwnerIsUncertainForTest) {
        return;
      }
      await Future<void>.delayed(step);
    }
    fail(
      'waitForServiceSettled: never settled after ${maxIterations * step.inMilliseconds}ms '
      '(pendingInitializeSettlement=${target.pendingInitializeSettlement}, '
      'previewController=${target.previewController}, owner=${DashcamService.processOwnerCurrentForTest}, '
      'uncertain=${DashcamService.processOwnerIsUncertainForTest})',
    );
  }

  // Fase 16.2-R4.2B-R3: moved to top-level scope (were previously local to
  // the R2 group only) so both that group's and this round's own new tests
  // can share them without duplication.
  DashcamService buildLocalService({
    Duration initializeCameraTimeout = const Duration(seconds: 10),
    Duration stopVideoRecordingTimeout = const Duration(seconds: 5),
  }) {
    return DashcamService(
      config: DashcamConfig(
        cameraSelection: CameraSelection.rear,
        storageQuotaMb: 1024,
        audioEnabled: false,
        resolution: VideoResolution.hd720,
        frameRate: 30,
        enabled: true,
      ),
      segmentDuration: const Duration(minutes: 10),
      initializeCameraTimeout: initializeCameraTimeout,
      stopVideoRecordingTimeout: stopVideoRecordingTimeout,
    );
  }

  DashcamSessionController buildLocalController(DashcamService localService) {
    return DashcamSessionController(
      dashcamService: localService,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  }

  // Fase 16.2-R4.2B-R3 (§40): thin wrapper over the shared, explicitly-
  // failing `waitForServiceSettled` — see its own doc. An earlier, R2-era
  // version of this helper duplicated that same polling logic but returned
  // SILENTLY after exhausting its iteration budget instead of failing the
  // test, exactly the anti-pattern the reviewer flagged.
  Future<void> drainLocal(DashcamSessionController localController, DashcamService localService) async {
    try {
      localController.dispose();
    } catch (_) {}
    await waitForServiceSettled(localService);
  }

  /// Fase 16.2-R4.4-R2: every index write and storage-quota pass queued so far
  /// has settled. Call after `stopSession()` returned: the pass of the clip it
  /// published is queued (by that clip's own index write, which the STOP's
  /// pass waited behind) — two empty turns of the index FIFO land after it.
  Future<void> storagePassesSettled() async {
    await runInClipIndexQueue(() async {});
    await runInClipIndexQueue(() async {});
  }

  /// Fase 16.2-R4.3-R2.6.3 (test-fragility fix — R2.6.3 matrix #1, full suite
  /// random seed 42, X51-obligationRetained), shared file-wide since
  /// R2.6.3-T1: a public stopSession() returns at the STOP's PRESENTATION
  /// deadline (50ms in the short-stop services used by the R2.6.1/R2.6.2
  /// groups), not when the clip is finalized, so reading [DashcamService.clips]
  /// right after it races the physical STOP under load (reproduced
  /// deterministically with a 150ms native STOP). Same class as the
  /// pre-audit's TG-2 / R2.6.1-H1. Waits for the causal state instead — no
  /// native STOP left in flight (the service clears it only once its clip was
  /// processed, success or failure) and at least [atLeast] clips of [token]
  /// (the producing session's id) present — and fails explicitly after a
  /// finite bound. Call it only after the stop that produces the awaited clip
  /// was issued (i.e. after that `stopSession()` returned); never use it to
  /// wait for a clip the contract says must not exist.
  Future<List<DashcamClip>> settledClipsOf(DashcamService service, Object? token, {int atLeast = 0}) async {
    for (var i = 0; i < 300; i++) {
      final clips = service.clips.where((c) => c.producerToken == token).toList();
      if (!service.hasPendingNativeStop && clips.length >= atLeast) return clips;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('settledClipsOf: $token never settled with >= $atLeast clip(s) (pendingNativeStop=${service.hasPendingNativeStop}, clips=${service.clips.length})');
  }

  setUp(() async {
    // Fase 16.2-R4.3-R1 (§6, D0-approved lifecycle-generation architecture):
    // `WidgetsBinding.instance.lifecycleState` is `null` (indeterminate) by
    // default in a bare `flutter_test` environment — DashcamSessionController's
    // own constructor now deliberately treats that conservatively (NOT
    // eligible — see its own doc), which is correct in production but does
    // not reflect this test suite's own implicit assumption that a
    // constructed controller starts in a normal, foreground-running app.
    // Establishing a real `resumed` state here, once, before any controller
    // in ANY test is constructed, makes every test's own starting condition
    // match that realistic assumption — exactly like this block's own
    // existing Hive/path_provider setup already establishes other realistic
    // preconditions. Tests that specifically exercise background/lifecycle
    // transitions (§18-K/L/M/N and this round's own L-series) drive further
    // transitions explicitly from this same starting point.
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_session_controller_test');
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
    service = DashcamService(
      config: DashcamConfig(
        cameraSelection: CameraSelection.rear,
        storageQuotaMb: 1024,
        audioEnabled: false,
        resolution: VideoResolution.hd720,
        frameRate: 30,
        enabled: true,
      ),
      segmentDuration: const Duration(minutes: 10),
    );
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  });

  tearDown(() async {
    // One test below disposes the controller itself to assert on the
    // hardware-release call directly — ChangeNotifier disallows a second
    // dispose(), so this guard makes tearDown safe for every other test too.
    try {
      controller.dispose();
    } catch (_) {}
    // Fase 16.2-R4.2B-R2 (§22/§37, independent review — cross-test static
    // coordinator leak), hardened in Fase 16.2-R4.2B-R3 (§46, independent
    // review — "teardown compartilhado... não pode retornar
    // silenciosamente"): `controller.dispose()` fires
    // `dashcamService.dispose()` unawaited — a flat 30ms guess is not
    // evidence that it (and therefore `_DashcamProcessOwner.release`) has
    // actually run by the time the NEXT test's own, DIFFERENT
    // `DashcamService` instance calls `initialize()`. `waitForServiceSettled`
    // fails this test EXPLICITLY if that never happens, rather than silently
    // letting a leaked owner surface as a confusing failure in some later,
    // unrelated test — the flat delay below remains only as a floor for
    // this file's other, non-coordinator cleanup (streams/Hive) that
    // already relied on it.
    await waitForServiceSettled(service);
    // Fase 16.2-R4.4-R2.1.1-F1-R (test isolation): every camera is released, so
    // no late STOP pass can still queue; the index turns this test left (a test
    // that does not read the index does not wait for them) settle here, against
    // this test's boxes and directory — never inside the next test's FIFO.
    await indexQueueSettledForTest();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await snapshotController.close();
    await eventController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('status is disabled while DashcamPreferences.enabled is false, regardless of session state', () async {
    expect(controller.status, DashcamStatus.disabled);
    controller.startSession();
    expect(controller.status, DashcamStatus.disabled);
    expect(recorder.isRecording, isTrue, reason: 'the driving session itself must still start');
    expect(fakePlatform.calls, isEmpty, reason: 'no camera hardware should be touched while disabled');
  });

  test('enabling the feature starts the camera together with the session, reaching recording', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    // _startCamera is fired-and-forgotten from startSession(); its own
    // notifyListeners calls happen on real microtask/await boundaries.
    // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
    // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
    await waitForStatus(DashcamStatus.recording, on: controller);

    expect(controller.status, DashcamStatus.recording);
    expect(fakePlatform.calls, contains('createCameraWithSettings'));
    expect(fakePlatform.calls, contains('startVideoCapturing'));
  });

  test(
    'a camera failure never stops the driving session from starting or recording '
    '(Fase 15 failure-isolation requirement)',
    () async {
      await preferences.setEnabled(true);
      fakePlatform.failCreateCameraWith = CameraException('no_camera', 'forced failure for this test');

      final session = controller.startSession();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(recorder.isRecording, isTrue);
      expect(recorder.activeSession, session);
      expect(controller.status, DashcamStatus.error);
      expect(controller.errorMessage, isNotNull);
    },
  );

  test('stopping the session finalizes the camera and returns status to idle', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
    // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
    await waitForStatus(DashcamStatus.recording, on: controller);
    expect(controller.status, DashcamStatus.recording);

    await controller.stopSession();

    expect(controller.status, DashcamStatus.idle);
    expect(recorder.isRecording, isFalse);
    expect(fakePlatform.calls, contains('stopVideoRecording'));
  });

  test(
    'stopping the session releases the camera hardware, not just the recording (Fase 15 — '
    'regression for a real bug found via physical hardware testing: the controller created by a '
    'session\'s initialize() was left held open for the REST OF THE APP PROCESS\'s lifetime once '
    'that session ended, if no further session ever started — confirmed on-device via '
    '`adb shell dumpsys media.camera` that this genuinely, repeatedly blocked an unrelated system '
    'service, Samsung\'s own adaptive-brightness component, from opening a DIFFERENT camera on the '
    'same device, logged by the platform\'s own camera service as "Too many cameras already open")',
    () async {
      await preferences.setEnabled(true);
      controller.startSession();
      // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
      // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
      await waitForStatus(DashcamStatus.recording, on: controller);
      expect(controller.status, DashcamStatus.recording);

      await controller.stopSession();

      expect(controller.status, DashcamStatus.idle);
      expect(
        fakePlatform.disposedCameraIds,
        contains(0),
        reason:
            'the camera opened for this session must be disposed once the session ends, not left '
            'held open indefinitely just because the app itself keeps running',
      );
    },
  );

  test('a session recorded with dashcam enabled gets a clip indexed in the dashcamSessionVideos box', () async {
    await preferences.setEnabled(true);
    final session = controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await controller.stopSession();
    // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
    // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
    // pass is awaited here, where this test reads what it wrote.
    await controller.clipIndexFollowUpsSettledForTest();

    final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
    final raw = box.get(session.id) as List?;
    expect(raw, isNotNull);
    final records = List<DashcamClipRecord>.from(raw!);
    expect(records, hasLength(1));
    expect(records.single.resolution, VideoResolution.hd720);
  });

  test('a session recorded with dashcam disabled has no entry in the dashcamSessionVideos box', () async {
    final session = controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await controller.stopSession();

    final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
    expect(box.get(session.id), isNull);
  });

  test('telemetry samples are written at the sampling cadence while recording', () async {
    await preferences.setEnabled(true);
    final session = controller.startSession();
    // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): the 30 ms guessed that
    // the initial START had installed the telemetry (after the file's open,
    // real file I/O); under load the snapshot below arrived before the sampler
    // existed and nothing was written (reproduced by delaying only that open,
    // T-Rm 09_round2/screens). `recording` is published once the sampler is
    // installed. The 260 ms that follows is ordered, not guessed: the
    // sampler's next tick is due at most 200 ms after the snapshot and timers
    // fire in deadline order.
    await waitForStatus(DashcamStatus.recording, on: controller);

    snapshotController.add(snapshot(timestamp: DateTime.now(), speedKmh: 55));
    // Real Timer.periodic(200ms) sampler — wait past one tick.
    await Future<void>.delayed(const Duration(milliseconds: 260));

    await controller.stopSession();

    final samples = await loadDashcamTelemetry(session.id);
    expect(samples, isNotEmpty);
    expect(samples.any((s) => s.speedKmh == 55), isTrue);
  });

  test(
    'a DetectedEvent writes one precise out-of-band sample immediately, tagged with its type',
    () async {
      await preferences.setEnabled(true);
      final session = controller.startSession();
      // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): the 30 ms guessed that
      // the initial START had installed the telemetry (after the file's open,
      // real file I/O); under load the event arrived before anything listened
      // for it (reproduced by delaying only that open, T-Rm 09_round2/screens).
      // `recording` is published once the telemetry is installed. The 30 ms
      // after the event is ordered: the event reaches the listener in a
      // microtask, before any timer fires.
      await waitForStatus(DashcamStatus.recording, on: controller);

      eventController.add(detectedEvent(severity: EventSeverity.warning, type: DetectedEventType.hardCorneringLeft));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await controller.stopSession();

      final samples = await loadDashcamTelemetry(session.id);
      expect(samples.any((s) => s.eventType == DetectedEventType.hardCorneringLeft && s.speedKmh == 99), isTrue);
    },
  );

  test('high/critical severity events protect the current clip; info severity does not', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): the 30 ms guessed that
    // the initial START had reached `recording` (it includes the telemetry
    // file's open, real file I/O); under load the critical event arrived while
    // no segment was recording yet — there was no current clip to protect
    // (reproduced by delaying only that open, T-Rm 09_round2/screens).
    await waitForStatus(DashcamStatus.recording, on: controller);

    eventController.add(detectedEvent(severity: EventSeverity.info, type: DetectedEventType.stopped));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(service.clips.any((c) => c.isProtected), isFalse);

    eventController.add(detectedEvent(severity: EventSeverity.critical, type: DetectedEventType.highResultantG));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await controller.stopSession();
    expect(service.clips.single.isProtected, isTrue);
  });

  test('starting a session twice in a row does not create two cameras', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));
  });

  test(
    'starting a new session before the previous one\'s camera-stop has fully settled does not '
    'duplicate the previous session\'s clip into the new session\'s Hive record (Fase 15 — '
    'regression for a real bug found via physical hardware testing: two back-to-back sessions, '
    'the second started faster than the first\'s _stopCamera could finish, resulted in the SAME '
    'clip file being persisted under BOTH sessions\' dashcamSessionVideos entries — because the '
    'second session\'s _startCamera hit its "already starting/recording" guard and returned '
    'before ever refreshing _clipsBeforeThisSession, so when IT later stopped, it still saw the '
    'first session\'s now-finalized clip as "new" against its own stale, pre-first-session '
    'baseline)',
    () async {
      await preferences.setEnabled(true);
      final sessionA = controller.startSession();
      // Fase 16.2-R4.4-R1-T-Rm (R-m CT:470, test-only): every fixed delay of this
      // test (30/10/30/30 ms) guessed that some step had already happened. Under
      // parallel load the 10 ms one did not hold: the recorder had not finished
      // closing A, so startSession() for B was REFUSED (SessionAdmissionRejected,
      // "still being ended") before the race this test exists for was ever
      // reached — reproduced deterministically by delaying only the recorder's
      // finalization (T-Rm 02_directed/recorder_delay). Each wait now observes
      // the state it was guessing.
      await waitForStatus(DashcamStatus.recording, on: controller);

      // Physical hardware testing found this race with a real several-MB
      // video file whose MediaRecorder finalize + disk copy took genuinely
      // longer than DrivingSessionRecorder's own (Hive-only) stopSession()
      // — long enough that a fresh "Iniciar sessão" tap landed while the
      // previous session's camera-side teardown was still in flight. A's
      // native STOP is HELD here (it used to be delayed 50 ms) until B has
      // started: the camera side of A is still in flight by construction, not
      // by winning a real race.
      final stopGateA = Completer<void>();
      fakePlatform.pendingStopVideoRecording = stopGateA;

      // Deliberately NOT awaited before starting the next session.
      final stopAFuture = controller.stopSession();
      // B may start once A is over as a driving session — the recorder closed
      // it, which is what canStartSession (the UI's own signal) reports — while
      // A's camera-side stop is still held: _stopCamera(A) is in flight when
      // session B starts.
      await waitForCondition(
        () => callCount('stopVideoRecording') == 1 && controller.canStartSession,
        'A\'s native STOP entered and held, and A closed by the recorder',
      );
      final sessionB = controller.startSession();
      expect(sessionB.id, isNot(equals(sessionA.id)), reason: 'test setup check: must be a genuinely new session');
      expect(stopGateA.isCompleted, isFalse, reason: 'test setup check: B started while A\'s camera stop was still in flight');

      fakePlatform.pendingStopVideoRecording = null;
      stopGateA.complete();
      await stopAFuture;
      await waitForStatus(DashcamStatus.recording, on: controller);
      expect(controller.status, DashcamStatus.recording, reason: 'session B must reach its own recording state');

      await controller.stopSession();
      final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
      await waitForCondition(
        () => !service.hasPendingNativeStop && box.get(sessionA.id) != null && box.get(sessionB.id) != null,
        'both sessions\' clips settled and indexed',
      );

      final rawA = box.get(sessionA.id) as List?;
      final rawB = box.get(sessionB.id) as List?;
      expect(rawA, isNotNull, reason: 'session A must have its own clip recorded');
      expect(rawB, isNotNull, reason: 'session B must have its own clip recorded');

      final clipsA = List<DashcamClipRecord>.from(rawA!);
      final clipsB = List<DashcamClipRecord>.from(rawB!);
      expect(clipsA, hasLength(1));
      expect(clipsB, hasLength(1));
      expect(
        clipsA.single.filePath,
        isNot(equals(clipsB.single.filePath)),
        reason: 'each session must be attributed its OWN clip file, never share the other session\'s',
      );
    },
  );

  test('backgrounding pauses the preview; resuming un-pauses it, without stopping the driving session', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): the three fixed 30 ms
    // delays guessed. The first assumed the initial START had reached
    // `recording` — it includes the telemetry file's open (real file I/O) —
    // and under load `paused` arrived while it was still `initializing`: the
    // status stayed `initializing` (natural failure, campaign D seed 9001;
    // reproduced by delaying only that open, T-Rm 09_round2/screens). Each
    // state is awaited as the event it is; a pause/un-pause that never happens
    // still fails, after a finite bound.
    await waitForStatus(DashcamStatus.recording, on: controller);

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await waitForCondition(() => fakePlatform.previewPaused, 'the preview paused by backgrounding');
    expect(fakePlatform.previewPaused, isTrue);
    // Fase 16.2-R1 (P1-5): backgrounding must not stop the *driving session*
    // itself — but it also marks the camera known-unavailable, so the
    // truthful status is cameraUnavailable, not a stale "recording" (no
    // video is actually being captured). See DashcamSessionController.status's
    // own doc; this replaces this test's pre-R1 assertion of `recording`
    // here, which was exactly the "false REC" gap the independent review
    // found.
    expect(controller.status, DashcamStatus.cameraUnavailable);
    expect(recorder.isRecording, isTrue, reason: 'backgrounding must not stop the driving session itself');

    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await waitForCondition(() => !fakePlatform.previewPaused, 'the preview un-paused by resuming');
    expect(fakePlatform.previewPaused, isFalse);
  });

  test('dispose() releases the camera hardware', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    // Fase 16.2-R4.4-R1-T-Rm (R-m "dispose hardware", test-only): both fixed
    // 30 ms delays guessed. The release of a recording camera first stops its
    // segment and promotes the clip (real file I/O since R4.4-R1) and only then
    // disposes the native camera — under load that took longer than 30 ms and
    // the assertion ran before the dispose it was waiting for (reproduced by
    // delaying only the promotion's rename, T-Rm 02_directed/screen_rename).
    // The camera must really be recording before dispose(), and the native
    // dispose is awaited as the event it is (a dispose that never happens still
    // fails, after a finite bound).
    await waitForStatus(DashcamStatus.recording, on: controller);
    expect(service.previewController?.value.isRecordingVideo, isTrue, reason: 'test setup check: the camera was really acquired and recording');

    controller.dispose();
    await waitForCondition(() => fakePlatform.calls.contains('dispose'), 'the native camera dispose');

    expect(fakePlatform.calls, contains('dispose'));
  });

  group('Fase 16.2 — background camera loss vs. segment rotation', () {
    test(
      'backgrounding while recording marks the camera as known-unavailable on the underlying '
      'DashcamService, without tearing down the session or status (DashcamSessionController is the '
      'only thing that knows the app was backgrounded, so it must be the one to tell DashcamService '
      'before its segment-rotation timer could next fire)',
      () async {
        await preferences.setEnabled(true);
        controller.startSession();
        // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): see "backgrounding
        // pauses the preview" — the 30 ms guessed that the initial START had
        // reached `recording`; under load `paused` hit it still `initializing`
        // (reproduced by delaying only the telemetry file's open, T-Rm
        // 09_round2/screens). Both states are awaited.
        await waitForStatus(DashcamStatus.recording, on: controller);
        expect(service.cameraKnownUnavailable, isFalse);

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await waitForCondition(() => service.cameraKnownUnavailable, 'the background loss registered');

        expect(service.cameraKnownUnavailable, isTrue);
        // Fase 16.2-R1 (P1-5): the session itself is untouched by
        // backgrounding (recorder.isRecording stays true — see the next
        // assertion), but the *status* must truthfully reflect that no
        // video is actually being captured right now, not a stale
        // "recording" (see DashcamSessionController.status's own doc).
        expect(controller.status, DashcamStatus.cameraUnavailable);
        expect(recorder.isRecording, isTrue, reason: 'backgrounding alone must not tear down the driving session');
      },
    );

    test(
      'recovery still runs on resume even when resumePreview() itself throws on the old, '
      'camera-revoked controller (physical-device finding: resuming a CameraController whose '
      'camera Android already closed while backgrounded throws a platform exception — if that '
      'exception reached the outer best-effort catch before the recovery check ran, recovery would '
      'be silently skipped every time, leaving DashcamStatus stuck reporting a stale "recording" '
      'that was never actually re-established: no fresh camera, no saved clip on the next stop)',
      () async {
        await preferences.setEnabled(true);
        controller.startSession();
        // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): the fixed 30/20/30 ms delays
        // guessed. The recovery first releases the old camera — stops its
        // segment and promotes the clip (real file I/O since R4.4-R1) — and only
        // then opens the new one; under load the assertions ran before that
        // (reproduced by delaying only the promotion's rename, T-Rm
        // 02_directed/screen_rename). Each wait now observes the state it
        // guessed: recording before backgrounding, the background loss
        // registered, and the new camera opened and recording after resume (a
        // recovery that never happens still fails, after a finite bound).
        await waitForStatus(DashcamStatus.recording, on: controller);

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await waitForCondition(() => service.cameraKnownUnavailable, 'the background loss registered');

        fakePlatform.failResumePreviewWith = CameraException('camera_not_found', 'the underlying camera session is gone');
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await waitForCondition(() => callCount('createCameraWithSettings') == 2 && controller.status == DashcamStatus.recording, 'the recovery\'s new camera recording');

        expect(
          fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
          hasLength(2),
          reason: 'recovery must still reinitialize the camera even though resumePreview() on the old controller threw',
        );
        expect(controller.status, DashcamStatus.recording);
        expect(service.cameraKnownUnavailable, isFalse);
      },
    );

    test(
      'returning to foreground after a background camera loss automatically reinitializes the '
      'camera and resumes recording — the driving session and telemetry are never interrupted '
      'throughout (§7/§11: recovery must not require a manual retry, and camera failure must never '
      'reach sessionRecorder/telemetry)',
      () async {
        await preferences.setEnabled(true);
        final session = controller.startSession();
        // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): the 30/20 ms guessed
        // that the initial START had installed the telemetry (after the file's
        // open, real file I/O) and that the background loss had registered;
        // under load the snapshot below arrived before the sampler existed and
        // the 42 km/h sample was never written (reproduced by delaying only
        // that open, T-Rm 09_round2/screens). Both states are awaited. The
        // 260 ms after the snapshot is ordered (the sampler's next tick is due
        // at most 200 ms later; timers fire in deadline order).
        await waitForStatus(DashcamStatus.recording, on: controller);
        final camerasBefore = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length;

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await waitForCondition(() => service.cameraKnownUnavailable, 'the background loss registered');

        // Telemetry keeps flowing throughout — this test simulates only the
        // camera-loss side effect of backgrounding, not an actual OS-level
        // suspension of Dart execution (which doesn't happen on a real
        // device either: the process stays alive, which is the whole
        // premise of the Fase 16.1 bug this phase fixes).
        snapshotController.add(snapshot(timestamp: DateTime.now(), speedKmh: 42));
        await Future<void>.delayed(const Duration(milliseconds: 260)); // past a sample tick

        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        // Fase 16.2-R4.2B-R2 (§22, test-fragility fix — see waitForStatus's
        // own doc): a fixed 30ms wait here was demonstrated flaky under
        // random-order runs — recovery's own underlying calls are still
        // reentrant/near-instant; only the fixed guess was too tight.
        await waitForStatus(DashcamStatus.recording);

        expect(controller.status, DashcamStatus.recording, reason: 'recovery must complete automatically, without a manual retryCamera() call');
        expect(service.cameraKnownUnavailable, isFalse);
        expect(
          fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length,
          greaterThan(camerasBefore),
          reason: 'a genuinely fresh camera must be opened on recovery, not the old (lost) one reused',
        );
        expect(recorder.isRecording, isTrue, reason: 'the driving session itself was never affected by the camera loss');

        await controller.stopSession();
        final samples = await loadDashcamTelemetry(session.id);
        expect(samples.any((s) => s.speedKmh == 42), isTrue, reason: 'telemetry recorded during the camera-unavailable window must be preserved');
      },
    );

    test(
      'status never reports recording while the camera is known-unavailable, and visibly passes '
      'through initializing on the way back — never a stale/false REC (§10: no false REC indicator)',
      () async {
        await preferences.setEnabled(true);
        controller.startSession();
        // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): the fixed 30/20/30 ms delays
        // guessed; under load the final read happened while the recovery was
        // still `initializing` (its release of the old camera promotes a clip —
        // real file I/O since R4.4-R1; reproduced by delaying only the rename,
        // T-Rm 02_directed/screen_rename). The waits observe the states instead.
        await waitForStatus(DashcamStatus.recording, on: controller);

        final statusesSeen = <DashcamStatus>[];
        controller.addListener(() => statusesSeen.add(controller.status));

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await waitForCondition(() => service.cameraKnownUnavailable, 'the background loss registered');
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await waitForStatus(DashcamStatus.recording, on: controller, label: 'the recovery back to recording');

        expect(
          statusesSeen,
          contains(DashcamStatus.initializing),
          reason: 'recovery must visibly pass through initializing, never silently stay on a stale recording status',
        );
        expect(controller.status, DashcamStatus.recording);
      },
    );

    test(
      'end-to-end regression: RECORDING → app backgrounded (CAMERA_UNAVAILABLE) → segment-rotation '
      'TIMER FIRES → must not issue a ROTATION REQUEST (stopVideoRecording) against the lost camera '
      '(§16 — explicit regression test for the confirmed Fase 16.1 root cause, driven through the '
      'real production entry point, WidgetsBindingObserver.didChangeAppLifecycleState, not a direct '
      'service call). Fase 16.2-R4.2B-R2 (§22, independent review — cross-test static-coordinator '
      'leak found via random-order failures): `addTearDown(localController.dispose)` alone does not '
      'wait for `dashcamService.dispose()`\'s own real, unawaited background work to actually reach '
      '`_DashcamProcessOwner.release()` before this test ends — a LATER test\'s own, DIFFERENT '
      '`DashcamService` instance could then have to wait behind this one\'s still-lingering ownership. '
      'Drained explicitly below instead, the same way this file\'s own §18-G/§18-I/§18-N tests already '
      'are.',
      () async {
        // A dedicated service/controller pair whose rotation ticks this test
        // delivers itself. Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): this
        // used a real 25 ms segment timer, armed at the native START. If the
        // initial START took longer than that to be confirmed (it includes the
        // telemetry file's open, real file I/O) a rotation ran first — its clip
        // promotion is real file I/O too — and the session ended in "Camera
        // stopped recording before it could be confirmed" before the scenario
        // existed (reproduced by delaying those steps together, T-Rm
        // 09_round2/screens_final combo60). The ticks are delivered by hand
        // (segmentTimerArmedHookForTest: the same closure the timer calls —
        // still a real rotation tick), only once the app is backgrounded, with a
        // 10-minute segment.
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        final ticks = <void Function()>[];
        localService.segmentTimerArmedHookForTest = ticks.add;
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
          // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.status, DashcamStatus.recording);
          final callsBeforeBackground = fakePlatform.calls.length;

          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          expect(localService.cameraKnownUnavailable, isTrue, reason: 'test setup check: the background loss registered');
          // Several rotation ticks of the segment's timer while backgrounded —
          // exactly the logical shape of the real bug, compressed from 3
          // minutes down to a fast, deterministic unit test — then a window in
          // which no native stop may appear.
          expect(ticks, hasLength(1), reason: 'test setup: the segment\'s timer was armed once');
          for (var i = 0; i < 4; i++) {
            ticks.single();
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(
            fakePlatform.calls.skip(callsBeforeBackground),
            isNot(contains('stopVideoRecording')),
            reason: 'the rotation timer must not call stopVideoRecording() against a camera the app knows it lost',
          );

          await localController.stopSession();
        } finally {
          try {
            localController.dispose();
          } catch (_) {}
          await waitForServiceSettled(localService);
        }
      },
    );
  });

  group('Fase 16.2-R1 — post-review hardening (recovery ownership, stopSession idempotency, REC truthfulness)', () {
    test(
      '§18-G: a recovery attempt superseded by stopSession() while its own initialize() is genuinely '
      'stuck (native call never returns, exactly like a real hung camera setup) does not deadlock '
      'stopSession() forever, does not resurrect the already-stopped session, and does not leak the '
      'camera the stuck recovery opened (P1-2, and — found while writing this test — a genuine '
      'deadlock risk in initializeCameraTimeout\'s absence: see that field\'s own doc). Fase '
      '16.2-R4.2A-R4 (§4/§7/§8): the recovery\'s own initialize() call still releases the PRIOR '
      '(backgrounded) controller first, via DashcamService\'s own _FinalizeReason.teardown — that '
      'release now properly collects the segment that was genuinely recording before backgrounding, '
      'instead of silently discarding it; this test\'s own concern is that the STUCK, SUPERSEDED '
      'recovery attempt itself must not additionally resurrect the session or persist a second, '
      'phantom clip. Fase 16.2-R4.2B-R2 (§32-§34, independent review — "não confundir test timeout com '
      'contract"): a genuinely stuck native initialize() is now, by design (Fase 16.2-R4.2B-R1/R2), '
      'RETAINED forever rather than detached — stopSession() itself still has its own bounded '
      'presentation contract (DashcamService.releaseIdleCamera\'s own discovery-timeout mechanism '
      'already bounds it even while queued behind a stuck initialize — no NEW production code was '
      'needed for this), but the OLD version of this test raced its own 5s external timeout against '
      'DashcamService\'s own internal ~5s default stopVideoRecordingTimeout — two budgets of the same '
      'duration, exactly the "corrida de budgets iguais" class of flakiness this codebase already '
      'avoids everywhere else (see e.g. _awaitTeardown\'s own doc). Retimed below: both configured '
      'short and unequal, with the external bound derived from them with a comfortable margin — and '
      'the gate is drained, with full local teardown, in this test\'s own `finally`, so nothing is '
      'left running in the background to interfere with a LATER test sharing this same static, '
      'process-wide coordinator (see DashcamService\'s own _DashcamProcessOwner doc).',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): the recovery's presentation
          // deadline is no longer a real 50 ms (see [HeldDeadlines]): this test
          // needs the recovery STUCK in its native initialize when stopSession()
          // supersedes it, and a 50 ms deadline elapsing during the release of
          // the old camera (its segment's stop and clip promotion — real file
          // I/O since R4.4-R1) made the service abandon the attempt before
          // emitting anything, so the premise was never built (reproduced by
          // delaying only the promotion's rename, T-Rm 02_directed). Held here,
          // it never elapses during the test. The STOP deadline stays a real
          // 50 ms: stopSession() is bounded by it while the FIFO is blocked by
          // the gated initialize, which is deterministic.
          initializeCameraTimeout: const Duration(milliseconds: 9500),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGate = Completer<void>();
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        try {
          await preferences.setEnabled(true);
          final session = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate; // never completed during this test's own observation window
          final initsBefore = callCount('initializeCamera');
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));
          await waitForCondition(() => callCount('initializeCamera') == initsBefore + 1, 'the recovery stuck in its native initialize');

          // Must not hang forever — bounded by stopVideoRecordingTimeout's
          // own discovery-timeout mechanism (50ms above) with a comfortable
          // margin, not an equal-duration race against it.
          await localController.stopSession().timeout(const Duration(milliseconds: 500));
          expect(recorder.isRecording, isFalse);

          expect(localController.status, DashcamStatus.idle, reason: 'the superseded recovery must not resurrect the already-stopped session');

          final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
          // The pre-backgrounding segment is collected by the recovery's release
          // of the old camera; its clip reaches the index once that settles —
          // read after it, not after a guess.
          await waitForCondition(() => !localService.hasPendingNativeStop && box.get(session.id) != null, 'the pre-backgrounding segment collected and indexed');
          final raw = box.get(session.id) as List?;
          // Fase 16.2-R4.2A-R4: exactly ONE clip, not zero — the segment
          // that was genuinely recording before backgrounding is now
          // properly collected by the recovery initialize()'s own release
          // of the prior controller (see this test's own doc above), not
          // silently discarded. This test's real concern — the stuck,
          // superseded recovery itself must not additionally resurrect the
          // session or persist a second, phantom clip — is what the
          // length-1 bound proves.
          expect(raw, isNotNull, reason: 'the segment that genuinely recorded before backgrounding must be preserved');
          expect(
            List<DashcamClipRecord>.from(raw!),
            hasLength(1),
            reason: 'exactly the one real pre-backgrounding segment — the stuck, superseded recovery must not attribute any additional, phantom clip to this session',
          );
        } finally {
          // Fase 16.2-R4.2B-R2 (§34): release the gate and fully drain —
          // queue, controller, and process ownership — before this test
          // ends, so nothing bleeds into a later test. Fase 16.2-R4.2B-R3
          // (§39/§41): `waitForServiceSettled` fails explicitly if that
          // never happens, rather than silently moving on.
          if (!initGate.isCompleted) initGate.complete();
          try {
            localController.dispose();
          } catch (_) {}
          await waitForServiceSettled(localService);
        }
      },
    );

    test(
      '§18-I: a recovery attempt superseded by controller.dispose() while its own initialize() is '
      'genuinely stuck does not touch the disposed ChangeNotifier and does not hang (P1-2). Fase '
      '16.2-R4.2B-R2 (§35): the gate is released and fully drained in this test\'s own `finally` — see '
      '§18-G\'s own identical doc for why: this test may keep initialize() genuinely stuck for the '
      'whole of its own assertion window, but must not leak that into a LATER test once it ends.',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
        );
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 30));

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate; // never completed during this test's own observation window
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          localController.dispose(); // supersedes the in-flight recovery
          await Future<void>.delayed(const Duration(milliseconds: 80)); // let the stuck initialize()'s own timeout settle

          // No crash reaching here (notifyListeners() on a disposed
          // ChangeNotifier throws) is itself the primary assertion.
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            localController.dispose();
          } catch (_) {}
          await waitForServiceSettled(localService);
        }
      },
    );

    test(
      '§18-J: two genuinely concurrent stopSession() calls share a single stop operation instead of '
      'each running their own — no duplicate _stopCamera(), no duplicate clip persistence (P1-6)',
      () async {
        await preferences.setEnabled(true);
        final session = controller.startSession();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 30); // widen the race window
        final firstStop = controller.stopSession();
        final secondStop = controller.stopSession(); // issued before the first has any chance to resolve
        await Future.wait([firstStop, secondStop]);
        // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
        // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
        // pass is awaited here, where this test reads what it wrote.
        await controller.clipIndexFollowUpsSettledForTest();

        expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));

        final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
        final raw = box.get(session.id) as List?;
        expect(raw, isNotNull);
        expect(List<DashcamClipRecord>.from(raw!), hasLength(1), reason: 'the same clip must not be persisted twice');
      },
    );

    test(
      '§18-M: status reads cameraUnavailable, never a stale recording, at the exact instant the '
      'camera becomes known-unavailable — not only eventually, once a recovery attempt gets around '
      'to updating it (P1-5)',
      () async {
        await preferences.setEnabled(true);
        controller.startSession();
        // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
        // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
        await waitForStatus(DashcamStatus.recording, on: controller);
        expect(controller.status, DashcamStatus.recording);

        service.notifyAppBackgrounded();
        // No await/delay at all — checking the very next microtask.
        expect(controller.status, DashcamStatus.cameraUnavailable);
      },
    );

    test(
      '§18-N: a native stop timeout (not just backgrounding) also downgrades status away from a '
      'stale recording (P1-5). Fase 16.2-R4.2B-R2 (§36-§37, independent review — "N isolado passa; N → '
      'recuperação sobreposta falha"): the original version of this test used a REAL 2-second '
      '`stopVideoRecordingDelay` — since a timed-out native stop is now correctly RETAINED (not '
      'detached — Fase 16.2-R4.2A/R4.2B), that 2-second background operation kept running past this '
      'test\'s own end, into whichever test randomly landed next, including (confirmed by the reviewer) '
      're-pointing at a DIFFERENT `FakeCameraPlatform` once that next test\'s own `setUp` reassigned '
      '`CameraPlatform.instance` — genuine cross-test contamination. Retimed below with a deterministic '
      'gate instead of a real delay (the same fix already applied throughout dashcam_service_test.dart '
      'for the identical class of problem), drained fully in `finally` before this test ends.',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final stopGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
          // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.status, DashcamStatus.recording);

          fakePlatform.pendingStopVideoRecording = stopGate; // never completed during this test's own observation window
          await localController.stopSession(); // times out, marks the camera unavailable — but the session did stop

          // stopSession() itself already moves status to idle once the
          // session is over (not cameraUnavailable) — the timeout's effect on
          // status is only observable while a session still wants Dashcam.
          // Re-check the narrower, still-recording case directly at the
          // service level instead, matching what an in-flight rotation's own
          // timeout would look like from a live session's perspective.
          expect(localService.cameraKnownUnavailable, isTrue);
        } finally {
          // Fase 16.2-R4.2B-R3 (§43): `waitForServiceSettled` is the
          // terminal proof this needs — it cannot become true while the
          // real, gated `stopVideoRecording()` and its own subsequent
          // `_doFinalizeCurrentSegment` processing are still queued ahead of
          // the release that would otherwise clear the coordinator owner.
          if (!stopGate.isCompleted) stopGate.complete();
          try {
            localController.dispose();
          } catch (_) {}
          await waitForServiceSettled(localService);
        }
      },
    );

    test(
      'physical-validation finding (Samsung SM-A326B): two overlapping recovery attempts (e.g. two '
      '"resumed" lifecycle dispatches landing close together — observed on-device) must not leave '
      'status reporting recording while no native recording is actually active. _attemptRecoveryRestart '
      'has no dedup of its own (unlike initialize()\'s _initializeFuture or stopSession()\'s '
      '_stopSessionFuture) — two callers can share the same underlying initialize() future and then '
      'both call startLoopRecording() back-to-back; DashcamService.startLoopRecording()\'s own '
      '`if (_isRecording) return Future<void>.value();` guard is keyed on intent alone, so whichever '
      'call loses that race silently no-ops without ever calling native startVideoRecording() — this '
      'must not happen for the call that "wins" (sessionId still current) either.',
      () async {
        await preferences.setEnabled(true);
        controller.startSession();
        // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): the fixed 30/20/10/50 ms
        // delays guessed; under stronger directed load (T-Rm
        // 05_hardened/screen_full3, 120 ms on the clip promotion and the
        // recorder) the final read happened while the recovery was still
        // `initializing` — it first releases the old camera, whose clip
        // promotion is real file I/O since R4.4-R1. The waits observe the
        // states instead; the first recovery is proven held at its native
        // initialize before the overlapping second one arrives (this test's
        // own premise: "both genuinely in flight together").
        await waitForStatus(DashcamStatus.recording, on: controller);

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await waitForCondition(() => service.cameraKnownUnavailable, 'the background loss registered');
        service.notifyAppBackgrounded();
        expect(service.cameraKnownUnavailable, isTrue);

        // Force initialize() to hang so both recovery attempts are genuinely
        // in flight together, sharing the same _initializeFuture, rather
        // than relying on unguaranteed microtask timing to interleave them.
        final initCompleter = Completer<void>();
        fakePlatform.pendingInitializeCamera = initCompleter;
        final initsBefore = callCount('initializeCamera');

        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await waitForCondition(() => callCount('initializeCamera') == initsBefore + 1, 'the first recovery held at its native initialize');
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed); // second, overlapping recovery
        await Future<void>.delayed(const Duration(milliseconds: 10));

        initCompleter.complete();
        await waitForStatus(DashcamStatus.recording, on: controller, label: 'the overlapping recoveries settled');

        expect(controller.status, DashcamStatus.recording);
        expect(
          service.previewController?.value.isRecordingVideo,
          isTrue,
          reason: 'status must not report recording unless a native recording is genuinely active on the current controller',
        );

        await controller.stopSession();
      },
    );

    test(
      '§18-Q: dispatching AppLifecycleState.paused/resumed through the real Flutter WidgetsBinding '
      'observer mechanism (not calling the observer method directly) still triggers the same '
      'background-loss detection and recovery',
      () async {
        await preferences.setEnabled(true);
        controller.startSession();
        // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
        // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
        await waitForStatus(DashcamStatus.recording, on: controller);
        expect(controller.status, DashcamStatus.recording);

        // Fase 16.2-R4.4-R1-T-Rm (R-m §18-Q, test-only): the two fixed 30 ms
        // delays below guessed how long the binding-dispatched handlers take.
        // Under load the recovery was still `initializing` 30 ms after resume —
        // it first releases the old camera, whose clip promotion is real file
        // I/O since R4.4-R1 (reproduced by delaying only the rename, T-Rm
        // 02_directed/screen_rename). Each wait now observes its state; the
        // recovery must also be a genuine one (a new native START on the
        // current controller), not just the label.
        final startsBeforeLoss = callCount('startVideoCapturing');
        // ignore: invalid_use_of_visible_for_testing_member
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await waitForCondition(() => service.cameraKnownUnavailable, 'the background loss registered through the binding');
        expect(service.cameraKnownUnavailable, isTrue, reason: 'dispatched through the real binding, not a direct observer call');

        // ignore: invalid_use_of_visible_for_testing_member
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await waitForStatus(DashcamStatus.recording, on: controller, label: '§18-Q recovery through the binding');
        expect(controller.status, DashcamStatus.recording, reason: 'recovery must complete the same way regardless of dispatch mechanism');
        expect(callCount('startVideoCapturing'), startsBeforeLoss + 1, reason: 'a genuine recovery: one new native START');
        expect(service.previewController?.value.isRecordingVideo, isTrue);

        await controller.stopSession();
      },
    );
  });

  group('Fase 16.2-R4.2B-R2 — recovery contract: late/never-resolving initialize, retry suppression, coordinator drain', () {

    test(
      'P7 — late initialize + session active: a recovery presentation timeout converges to error, no '
      'second native initialize is ever requested, and once the real, retained initialize eventually '
      'succeeds late, recording actually resumes for the still-active session',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m P7, test-only): the recovery's presentation
        // deadline used to be a real 50 ms, followed by a 100 ms sleep "past the
        // deadline". But the recovery's initialize() first releases the old,
        // recording camera — its segment's stop and its clip's promotion (real
        // file I/O since R4.4-R1) — and the deadline counts from the call: under
        // load the 50 ms ran out during that release, the service correctly
        // abandoned the attempt BEFORE any native initialize (its pre-emission
        // checkpoints), and the premise below ("only ONE native initialize from
        // the recovery") read 0 (reproduced by delaying only the promotion's
        // rename, T-Rm 02_directed/screen_rename). The deadline is now held
        // ([HeldDeadlines]) and elapses right after the native initialize is
        // proven to have been reached and retained.
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 9500));
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
          // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.status, DashcamStatus.recording);
          // Baseline AFTER the initial session-start's own legitimate
          // native initialize() call — this test's own assertions below
          // are about the RECOVERY attempt specifically not adding a
          // second one of ITS OWN, not about the total since process start.
          final callsBeforeRecovery = fakePlatform.calls.where((c) => c == 'initializeCamera').length;

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));
          await waitForCondition(() => callCount('initializeCamera') == callsBeforeRecovery + 1, 'the recovery\'s native initialize reached and held');
          expect(deadline.expire(), 1, reason: 'the recovery\'s presentation deadline elapses now — its one view');
          await waitForStatus(DashcamStatus.error, on: localController, label: 'P7 presentation timeout');

          expect(localController.status, DashcamStatus.error, reason: 'the recovery attempt\'s own presentation deadline elapsed');
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length - callsBeforeRecovery,
            1,
            reason: 'only ONE native initialize attempt from the recovery — a mere presentation timeout must not trigger a second one',
          );

          initGate.complete(); // the real, retained native initialize now genuinely succeeds, late
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length - callsBeforeRecovery,
            1,
            reason: 'still only the ONE native call from the recovery — the late success is handled by the SAME retained operation, not a fresh one',
          );
          expect(
            localService.previewController?.value.isRecordingVideo,
            isTrue,
            reason: 'recording must actually, genuinely have resumed, not just the status label',
          );
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'P8 — late initialize + session stopped: stopSession() called before the retained native '
      'initialize resolves is not resurrected once it later, genuinely succeeds — the now-unwanted '
      'camera is released instead',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): see P7. The 30 ms
        // after startSession() guessed that the initial START had reached
        // `recording` (it includes the telemetry file's open, real file I/O):
        // under load the backgrounding/resume below hit a START still
        // `initializing` and the status read `cameraUnavailable` (reproduced by
        // delaying only that open, T-Rm 09_round2/screens). And with the real
        // 50 ms recovery deadline the attempt could also be abandoned before
        // its native initialize (P7's mechanism) — then nothing was retained
        // and "released after the late success" held vacuously. The initial
        // START is awaited; the recovery's deadline is held and elapses once
        // its native initialize is proven retained.
        final localService = buildLocalService(
          initializeCameraTimeout: const Duration(milliseconds: 9500),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final callsBeforeRecovery = callCount('initializeCamera');

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));
          await waitForCondition(() => callCount('initializeCamera') == callsBeforeRecovery + 1, 'the recovery\'s native initialize reached and held');
          expect(deadline.expire(), 1, reason: 'the recovery\'s presentation deadline elapses now');
          await waitForStatus(DashcamStatus.error, on: localController, label: 'P8 presentation timeout');
          expect(localController.status, DashcamStatus.error);

          await localController.stopSession(); // supersedes the still-pending recovery
          // Fase 16.2-R4.2B-R2: stopSession() deliberately does NOT clear a
          // pre-existing DashcamStatus.error back to idle (see
          // DashcamSessionController._stopCamera's own
          // `if (_liveStatus != DashcamStatus.error)` guard — pre-existing,
          // established behavior, not something this round changed) — the
          // property this test actually cares about is "no resurrection to
          // recording", checked below, not the exact non-recording status.
          expect(localController.status, isNot(DashcamStatus.recording));

          initGate.complete(); // the retained native initialize now genuinely succeeds, late, for a session nobody wants anymore
          // Fase 16.2-R4.2B-R3 (§61): wait for the real, causal settlement
          // evidence (fails explicitly on its own if it never arrives)
          // before asserting — not just previewController, which alone
          // would already read null before the late continuation even runs.
          await waitForServiceSettled(localService);
          expect(
            localService.previewController,
            isNull,
            reason: 'a late success for an already-stopped session must release the camera, not leave it open and untracked',
          );
          expect(localController.status, isNot(DashcamStatus.recording), reason: 'no resurrection');
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'P9 — never-resolving initialize + stopSession(): stopSession() still reaches its own bounded, '
      'logical terminality (recorder stopped, never a stale recording status) even though the '
      'underlying native initialize never resolves during this test\'s own observation window',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m P9, test-only): see P7 — the real 50 ms
        // presentation deadline could run out during the recovery's release of
        // the old camera, the attempt was then abandoned before emission and
        // released the coordinator, and the assertion below read `null`
        // (reproduced by delaying only the promotion's rename). The initial
        // acquisition is awaited instead of a 30 ms guess, and the presentation
        // deadline is held ([HeldDeadlines]) and elapses once the native
        // initialize is proven retained. The STOP deadline stays a real 50 ms:
        // stopSession()'s boundedness is this test's subject.
        final localService = buildLocalService(
          initializeCameraTimeout: const Duration(milliseconds: 9500),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>(); // deliberately left incomplete during observation
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final initsBefore = callCount('initializeCamera');

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));
          await waitForCondition(() => callCount('initializeCamera') == initsBefore + 1, 'the recovery\'s native initialize reached and held');
          expect(deadline.expire(), 1, reason: 'the recovery\'s presentation deadline elapses now');
          await waitForStatus(DashcamStatus.error, on: localController, label: 'P9 presentation timeout');
          expect(DashcamService.processOwnerCurrentForTest, same(localService.processOwnerTokenForTest), reason: 'the coordinator stays occupied — no fake release just because a presentation deadline elapsed');

          await localController.stopSession().timeout(const Duration(milliseconds: 500));
          expect(recorder.isRecording, isFalse, reason: 'the SESSION itself reaches terminality on its own bounded contract');
          // Fase 16.2-R4.2B-R2: not necessarily idle — the recovery's own
          // presentation timeout already moved status to error before
          // stopSession() ran, and stopSession() deliberately preserves an
          // existing error rather than papering over it (pre-existing
          // behavior — see P8's own identical doc). What matters here is
          // that it never falsely claims recording.
          expect(localController.status, isNot(DashcamStatus.recording));
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'P10 — retries do not accumulate: repeated resumed dispatches and retryCamera() calls while a '
      'recovery\'s own native initialize is genuinely pending never trigger a second native call, and '
      'the eventual late success is still handled by that SAME single operation',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m P10, test-only): see P7. Here the 30 ms
        // guess for the initial acquisition was also too short under load: the
        // baseline below was then read before the initial initialize, and the
        // recovery joined the still-running initial setup instead of issuing its
        // own call (0 instead of 1). The acquisition is awaited, and the
        // presentation deadline is held ([HeldDeadlines]) and elapses once the
        // recovery's native initialize is proven retained.
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 9500));
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final callsBeforeRecovery = fakePlatform.calls.where((c) => c == 'initializeCamera').length;

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));
          await waitForCondition(() => callCount('initializeCamera') == callsBeforeRecovery + 1, 'the recovery\'s native initialize reached and held');
          expect(deadline.expire(), 1, reason: 'the first attempt\'s own presentation deadline elapses now');
          await waitForStatus(DashcamStatus.error, on: localController, label: 'P10 presentation timeout');
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera').length - callsBeforeRecovery, 1);

          // Several more retries/resumes while still genuinely pending.
          await localController.retryCamera();
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await localController.retryCamera();
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length - callsBeforeRecovery,
            1,
            reason: 'retries while genuinely pending must never trigger a second native initializeCamera call',
          );

          initGate.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length - callsBeforeRecovery,
            1,
            reason: 'the eventual success is still the SAME, single retained operation',
          );
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'P11 — §18-G cleanup: after a fully-drained run of the §18-G scenario, the process-wide '
      'coordinator is completely free — no owner, not uncertain',
      () async {
        final localService = buildLocalService(
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 30));

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          await localController.stopSession().timeout(const Duration(milliseconds: 500));
          expect(recorder.isRecording, isFalse);
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
        expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'fully drained — no callback/pending op left behind for a later test to trip over');
        expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
      },
    );

    test(
      'P12 — §18-I cleanup: after a fully-drained run of the §18-I scenario (recovery superseded by '
      'controller.dispose()), the process-wide coordinator is completely free',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 30));

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          localController.dispose(); // supersedes the in-flight recovery — no crash is the primary assertion
          await Future<void>.delayed(const Duration(milliseconds: 20));
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
        expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'fully drained — no callback/pending op left behind for a later test to trip over');
        expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
      },
    );

    test(
      'P13 — N → overlapping recovery: running §18-N\'s own scenario (native stop timeout) immediately '
      'followed, in the SAME test, by two overlapping recovery attempts — the exact reviewer repro for '
      'the cross-test leak this round fixed (see §18-N\'s own updated doc) — both halves pass together, '
      'not just in isolation',
      () async {
        // --- Half 1: §18-N's own scenario, fully drained before Half 2 starts. ---
        final nService = buildLocalService(stopVideoRecordingTimeout: const Duration(milliseconds: 50));
        final nController = buildLocalController(nService);
        final stopGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          nController.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
          // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
          await waitForStatus(DashcamStatus.recording, on: nController);
          expect(nController.status, DashcamStatus.recording);

          fakePlatform.pendingStopVideoRecording = stopGate;
          await nController.stopSession();
          expect(nService.cameraKnownUnavailable, isTrue);
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
          await drainLocal(nController, nService);
        }
        expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'Half 1 must not leave the coordinator occupied for Half 2');

        // --- Half 2: two overlapping recovery attempts (the pre-existing "physical-validation
        // finding" test's own scenario), immediately after, sharing this same test's process. ---
        final overlapService = buildLocalService();
        final overlapController = buildLocalController(overlapService);
        // Fase 16.2-R4.2B-R3 (§44, independent review — "P13 gate não
        // garantido pelo finally"): declared BEFORE the try block, not
        // inside it — an R2-era version declared this gate inline, so any
        // assertion failing before it was ever completed left `finally`
        // unable to reach it at all, permanently gating
        // `fakePlatform.pendingInitializeCamera` and leaking the static
        // coordinator into every later, randomly-ordered test.
        final initCompleter = Completer<void>();
        try {
          overlapController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 30));

          overlapController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          overlapService.notifyAppBackgrounded();
          expect(overlapService.cameraKnownUnavailable, isTrue);

          fakePlatform.pendingInitializeCamera = initCompleter;

          overlapController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          overlapController.didChangeAppLifecycleState(AppLifecycleState.resumed); // second, overlapping recovery
          await Future<void>.delayed(const Duration(milliseconds: 10));

          initCompleter.complete();
          await waitForStatus(DashcamStatus.recording, on: overlapController);

          expect(
            overlapService.previewController?.value.isRecordingVideo,
            isTrue,
            reason: 'status must not report recording unless a native recording is genuinely active on the current controller',
          );

          await overlapController.stopSession();
        } finally {
          if (!initCompleter.isCompleted) initCompleter.complete();
          await drainLocal(overlapController, overlapService);
        }
      },
    );
  });

  group('Fase 16.2-R4.2B-R3 — initial _startCamera late settlement, retry dedup, late failure', () {
    test(
      'R3-A (§32/§59) — initial late success + active: the FIRST startSession()\'s own initialize() '
      'crosses its presentation deadline while the session remains active; ZERO second initialize; '
      'resolving the gate converges to a genuine, single recording start with the FULL initial setup '
      '(telemetry writer, subscriptions, sample timer) — not merely the status label',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          final session = localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(localController.status, DashcamStatus.error);
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1));

          initGate.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(1),
            reason: 'still the SAME single retained operation',
          );
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          // Confirm the FULL initial setup genuinely happened, not just the
          // status label — recovery's own tail deliberately does NOT redo
          // this (it reuses what's already open), but the very first start
          // must create it.
          snapshotController.add(snapshot(timestamp: DateTime.now(), speedKmh: 77));
          await Future<void>.delayed(const Duration(milliseconds: 260));
          await localController.stopSession();
          final samples = await loadDashcamTelemetry(session.id);
          expect(
            samples.any((s) => s.speedKmh == 77),
            isTrue,
            reason: 'the telemetry writer/sample timer genuinely started, not merely the status label',
          );
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R3-B (§33/§59) — initial late success + stopped: stopSession() called before the FIRST '
      'startSession()\'s own retained native initialize() resolves is not resurrected once it later, '
      'genuinely succeeds — the now-unwanted camera is released instead, no START ever issued',
      () async {
        final localService = buildLocalService(
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(localController.status, DashcamStatus.error);

          await localController.stopSession(); // supersedes the still-pending initial start
          expect(localController.status, isNot(DashcamStatus.recording));

          initGate.complete(); // the retained native initialize now genuinely succeeds, late, for a session nobody wants anymore
          await waitForServiceSettled(localService);
          expect(
            localService.previewController,
            isNull,
            reason: 'a late success for an already-stopped session must release the camera, not leave it open and untracked',
          );
          expect(
            fakePlatform.calls,
            isNot(contains('startVideoCapturing')),
            reason: 'no START must ever be issued for a session nobody wants anymore',
          );
          expect(localController.status, isNot(DashcamStatus.recording));
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R3-C (§34/§59) — initial late success + disposed: dispose() called before the FIRST '
      'startSession()\'s own retained native initialize() resolves does not touch the disposed '
      'ChangeNotifier and does not resurrect anything once it later, genuinely succeeds',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(localController.status, DashcamStatus.error);

          localController.dispose(); // supersedes the still-pending initial start
          initGate.complete();
          await Future<void>.delayed(const Duration(milliseconds: 100));

          // No crash reaching here (notifyListeners() on a disposed
          // ChangeNotifier throws) is itself the primary assertion.
          await waitForServiceSettled(localService);
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            localController.dispose();
          } catch (_) {}
          await waitForServiceSettled(localService);
        }
      },
    );

    test(
      'R3-D (§35/§60) — initial late failure: the FIRST startSession()\'s own retained native '
      'initialize() ultimately fails, late — the error is observed, no unhandled async error, zero '
      'START is ever attempted, and owner/queue eventually converge',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(localController.status, DashcamStatus.error);

          initGate.completeError(CameraException('native_initialize_failed', 'late initial failure'));
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(
            fakePlatform.calls,
            isNot(contains('startVideoCapturing')),
            reason: 'a late FAILURE must never lead to a START attempt',
          );
          expect(localController.status, isNot(DashcamStatus.recording));
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R3-E (§35/§60) — recovery late failure: a recovery attempt\'s own retained native initialize() '
      'ultimately fails, late — the error is observed, no unhandled async error, zero START, and no '
      'resurrection',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m R3-E, test-only): with a real 50 ms
        // presentation deadline, the recovery could be abandoned before its
        // native initialize (the deadline ran out while it released the old
        // camera — clip promotion is real file I/O since R4.4-R1): nothing ever
        // awaited the gate, so completing it with an error below raised an
        // UNHANDLED CameraException — this test's natural R-m signature,
        // reproduced by delaying only the promotion's rename. The gate is now
        // failed only once the native initialize is proven to be waiting on it,
        // and the presentation deadline is held ([HeldDeadlines]) and elapses
        // at that point. "No unhandled async error" stays enforced by the test
        // zone itself.
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 9500));
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
          // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.status, DashcamStatus.recording);
          final initsBefore = callCount('initializeCamera');

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));
          await waitForCondition(() => callCount('initializeCamera') == initsBefore + 1, 'the recovery\'s native initialize reached and waiting on the gate');
          expect(deadline.expire(), 1, reason: 'the recovery\'s presentation deadline elapses now');
          await waitForStatus(DashcamStatus.error, on: localController, label: 'R3-E presentation timeout');
          expect(localController.status, DashcamStatus.error);

          initGate.completeError(CameraException('native_initialize_failed', 'late recovery failure'));
          // The late failure is asserted on once it has settled, not after a guess.
          await waitForCondition(() => localService.pendingInitializeSettlement == null, 'the late failure settled');
          await pumpEventQueue(times: 20);

          expect(localController.status, isNot(DashcamStatus.recording));
          expect(callCount('startVideoCapturing'), 1, reason: 'a late FAILURE never leads to a START — only the initial one');
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R3-F (§36) — retry/resume while the FIRST startSession()\'s own initialize is genuinely pending '
      'never triggers a second native initialize, and the eventual late success is still handled by '
      'that SAME single operation',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1));

          await localController.retryCamera();
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await localController.retryCamera();
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(1),
            reason: 'retries while the FIRST attempt is genuinely pending must never trigger a second native call',
          );

          initGate.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1));
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.2B-R4 — raw initialize operation identity, watcher dedup, session A→B transition', () {
    test(
      'A→B late SUCCESS (§14/§15/§23/§28, MANDATORY GATE — exact reviewer reproduction of P1-C) — '
      'session A\'s own retained initialize() resolves successfully only AFTER session B has already '
      'started: B never adopts A\'s settlement as its own; B gets its OWN, genuinely NEW '
      'create/initialize/START; B reaches recording only via that real native START (never merely the '
      'status label — §49); the final owner correctly belongs to B',
      () async {
        service = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        controller = DashcamSessionController(
          dashcamService: service,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateA;

          final sessionA = controller.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100)); // A's own presentation timeout fires
          expect(controller.status, DashcamStatus.error);
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1));

          // stopSession(A) returns via the bounded presentation contract —
          // A's own real camera teardown stays queued behind A's still-
          // pending raw initialize().
          await controller.stopSession();

          // Session B starts BEFORE A's raw settlement.
          final sessionB = controller.startSession();
          expect(sessionB.id, isNot(sessionA.id));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(1),
            reason: 'B must not touch the backend while A\'s own raw settlement is still pending',
          );

          // A's raw initialize() now genuinely, finally resolves — late.
          initGateA.complete();

          await waitForStatus(DashcamStatus.recording, on: controller);

          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(2),
            reason: 'A\'s own original controller, plus exactly one genuinely NEW controller for B',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(1),
            reason: 'exactly one real native START, and it is B\'s own — never discarded, never A\'s',
          );
          expect(
            service.previewController?.value.isRecordingVideo,
            isTrue,
            reason: 'native isRecordingVideo must be true, not merely the status label (§49 — status alone is not proof of START)',
          );
          expect(recorder.activeSession?.id, sessionB.id);

          await controller.stopSession();
        } finally {
          if (!initGateA.isCompleted) initGateA.complete();
          await drainLocal(controller, service);
        }
      },
    );

    test(
      'A→B late FAILURE (§16/§29, MANDATORY GATE) — session A\'s own retained initialize() ultimately '
      'FAILS only after session B has already started: A\'s error is observed and does not leak into B; '
      'B proceeds with its own operation per the normal contract; no unhandled async error',
      () async {
        service = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        controller = DashcamSessionController(
          dashcamService: service,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateA;

          final sessionA = controller.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(controller.status, DashcamStatus.error);

          await controller.stopSession();

          final sessionB = controller.startSession();
          expect(sessionB.id, isNot(sessionA.id));
          await Future<void>.delayed(const Duration(milliseconds: 30));

          initGateA.completeError(CameraException('native_initialize_failed', 'A\'s own late failure'));
          // Fase 16.2-R4.2B-R4: clear the fake's own gate field once A's
          // completer has settled — otherwise B's own, genuinely NEW
          // `initializeCamera()` call would ALSO await the SAME, already-
          // errored `Completer` (unlike a successfully-completed one, which
          // is harmless to re-await, an errored one re-throws on every
          // subsequent await) — a test-fixture artifact, not a production
          // behavior this test means to exercise.
          fakePlatform.pendingInitializeCamera = null;

          await waitForStatus(DashcamStatus.recording, on: controller);
          expect(
            service.previewController?.value.isRecordingVideo,
            isTrue,
            reason: 'B must still reach genuine recording via its own operation, unaffected by A\'s late failure',
          );
          expect(recorder.activeSession?.id, sessionB.id);

          await controller.stopSession();
        } finally {
          if (!initGateA.isCompleted) initGateA.complete();
          await drainLocal(controller, service);
        }
      },
    );

    test(
      'W1 (§20-§22/§47) — initial start + retry BEFORE its own presentation timeout observe the SAME '
      'raw Future: exactly one logical watcher is ever installed, never two',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 10)); // well before the 50ms deadline

          await localController.retryCamera(); // races in before initial's own timeout — same raw Future
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(1),
            reason: 'retry before timeout must not create a second native call',
          );

          await Future<void>.delayed(const Duration(milliseconds: 80)); // now past the 50ms deadline
          expect(localController.status, DashcamStatus.error);

          initGate.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1));
          expect(
            localController.lateInitializeWatcherInstallCountForTest,
            1,
            reason: 'exactly one logical watcher, despite the retry racing in before the timeout',
          );
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'W2 (§20-§22/§47) — recovery + a SECOND retry, both before the first\'s own presentation timeout, '
      'observe the SAME raw Future: exactly one logical watcher',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m W2, test-only): see P7 — with a real 50 ms
        // deadline the recovery could be abandoned before its native initialize
        // (the deadline ran out while it released the old camera), and "both
        // before the first's own presentation timeout" was a race with the
        // host's speed. The deadline is held ([HeldDeadlines]): the second
        // retry comes in while recovery #1's native initialize is proven held,
        // and the deadline elapses afterwards, when the test says so.
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 9500));
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
          // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.status, DashcamStatus.recording);
          final initsBefore = callCount('initializeCamera');

          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate;
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed)); // recovery #1
          await waitForCondition(() => callCount('initializeCamera') == initsBefore + 1, 'recovery #1\'s native initialize reached and held');
          // Recovery #2, before #1's own timeout — it joins #1's in-flight
          // recovery, so its Future resolves only once that deadline elapses.
          final retry = deadline.run(() => localController.retryCamera());
          final callsBeforeTimeout = fakePlatform.calls.where((c) => c == 'initializeCamera').length;

          expect(deadline.expire(), greaterThanOrEqualTo(1), reason: 'the presentation deadline elapses now, after both');
          await retry;
          await waitForStatus(DashcamStatus.error, on: localController, label: 'W2 presentation timeout');
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera').length, callsBeforeTimeout);

          initGate.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera').length, callsBeforeTimeout);
          expect(
            localController.lateInitializeWatcherInstallCountForTest,
            1,
            reason: 'exactly one logical watcher across both recovery attempts',
          );
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'W4 (§32/§47) — a genuinely NEW raw Future for the SAME session (a second, independent recovery '
      'cycle after the first fully settled) is allowed its own new watcher',
      () async {
        // Fase 16.2-R4.3-R2.6 (§60, test-only fragility fix — found by this
        // round's random-order matrix, reproduced 3/20 on this repo's R2.6 code
        // AND 8/20 on the untouched R2.5 code, 0/30 for this test alone): the
        // presentation deadline used to be 50ms. A recovery `initialize()` must
        // FIRST tear down the current controller — a real native STOP plus a real
        // `File.copy` of the clip through DashcamService's FIFO — and the
        // deadline is measured from the `initialize()` call, so a filesystem
        // hiccup pushing that teardown past 50ms makes DashcamService abandon the
        // operation BEFORE any native `initializeCamera()` call, by design (R4.2B-R3
        // pre-emission checkpoints: an expired deadline never emits a stale
        // native call). The late-success continuation then finds no controller
        // (`initialize() must complete first`) and the status stays `error` —
        // correct product behavior, but not this test's premise ("the raw
        // initialize is genuinely HELD at the native call"). 500ms keeps the
        // deadline far from the teardown time; the test now also asserts the
        // premise explicitly instead of assuming it.
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 500));
        final localController = buildLocalController(localService);
        // Fase 16.2-R4.2B-R5 (§39-§41, P2 — W4 gate cleanup): BOTH gates
        // declared BEFORE the try, not inline mid-block — if any assertion
        // below throws before its own normal `.complete()` call, `finally`
        // must still be able to see and release every gate that might be
        // holding a real native call open. Leaving `initGate1` un-released
        // on an early assertion failure left `initializeCamera()` stuck
        // forever, which in turn hung `stopSession()`/`drainLocal` behind
        // it — the test then reported a confusing secondary cleanup
        // timeout instead of the actual assertion failure.
        final initGate1 = Completer<void>();
        final initGate2 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): a causal poll for the initial acquisition to reach
          // recording, instead of a fixed 30ms guess that intermittently under-waits under full-suite load.
          await waitForStatus(DashcamStatus.recording, on: localController, label: 'W4 initial acquisition');
          expect(localController.status, DashcamStatus.recording);

          // First recovery cycle: times out, then resolves late.
          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate1;
          final nativeInitsBeforeCycle1 = fakePlatform.calls.where((c) => c == 'initializeCamera').length;
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await waitForStatus(DashcamStatus.error, on: localController, label: 'W4 cycle 1 presentation timeout');
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length,
            nativeInitsBeforeCycle1 + 1,
            reason: 'premise: cycle 1\'s raw initialize reached the native call and is held by the gate (not abandoned before emission)',
          );
          initGate1.complete();
          await waitForStatus(DashcamStatus.recording, on: localController, label: 'W4 recovery cycle 1 (late success)');
          expect(localController.lateInitializeWatcherInstallCountForTest, 1);

          // Second, independent recovery cycle for the SAME session — a
          // genuinely NEW raw Future.
          localService.notifyAppBackgrounded();
          fakePlatform.pendingInitializeCamera = initGate2;
          final nativeInitsBeforeCycle2 = fakePlatform.calls.where((c) => c == 'initializeCamera').length;
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await waitForStatus(DashcamStatus.error, on: localController, label: 'W4 cycle 2 presentation timeout');
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length,
            nativeInitsBeforeCycle2 + 1,
            reason: 'premise: cycle 2\'s raw initialize reached the native call and is held by the gate (not abandoned before emission)',
          );
          initGate2.complete();
          await waitForStatus(DashcamStatus.recording, on: localController, label: 'W4 recovery cycle 2 (late success)');

          expect(
            localController.lateInitializeWatcherInstallCountForTest,
            2,
            reason: 'a genuinely new raw Future for the same session is allowed its own new watcher',
          );
        } finally {
          // Fase 16.2-R4.2B-R5 (§40): release BOTH gates first — before any
          // stop/dispose/drain — so a failed assertion above can never
          // leave a real native call stuck open behind this test's own
          // cleanup.
          if (!initGate1.isCompleted) initGate1.complete();
          if (!initGate2.isCompleted) initGate2.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'Deadline pré-emissão (Fase 16.2-R4.3-R2.6-EVIDENCE-CLOSURE §1 — mirror of W4 at this '
      'controller\'s own integration layer, W4 itself untouched/not widened): a recovery '
      'attempt whose own raw initialize() is retained INSIDE availableCameras() (device '
      'discovery) — i.e. BEFORE controller.initialize() is ever reached, the mirror image of '
      'W4\'s "genuinely held at the native call" premise — must be abandoned cleanly once its '
      'presentation deadline elapses: zero native initializeCamera() call is ever emitted for '
      'this cycle (proven directly, not inferred), status becomes error (never a silent hang '
      'nor a resurrected recording), and once discovery finally, genuinely completes late, '
      'still no native call is emitted and no improper retry happens on its own. Deliberately '
      'uses the SAME [fakePlatform.pendingAvailableCameras]/[availableCamerasEnteredForTest] '
      'seam as dashcam_service_test.dart\'s own R3-3 (MANDATORY, service layer) — gating '
      'discovery, a real await boundary that runs before any teardown/file-copy work, needs no '
      'timing margin beyond the deadline itself, unlike W4\'s own native-call gate (which sits '
      'downstream of a real STOP + File.copy and is why W4 alone needed 500ms — see its own '
      'doc); this test intentionally keeps a short, ordinary 50ms deadline to prove the '
      'pre-emission path is NOT timing-fragile the way W4\'s post-emission path was.',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m CT:1963, test-only): this test's premise —
        // "gating discovery runs before any teardown/file-copy work" — does not
        // hold: the recovery's initialize() releases the old, recording camera
        // (its segment's stop and its clip's promotion, real file I/O since
        // R4.4-R1) BEFORE its first checkpoint and before discovery. Under load
        // the real 50 ms deadline ran out during that release, the attempt was
        // abandoned at its first checkpoint, discovery was never entered, and
        // the 5 s wait for it below timed out — this test's natural R-m
        // signature (reproduced by delaying only the promotion's rename, T-Rm
        // 02_directed/screen_rename). The deadline is now held ([HeldDeadlines])
        // and elapses once discovery is proven entered: the abandonment then
        // happens exactly where this test means it to — the pre-emission
        // checkpoint after discovery, through the service's own
        // `presentationExpired` — and still emits no native call.
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 9500));
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final discoveryGate = Completer<void>();
        final discoveryEntered = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController, label: 'discovery-abandon initial acquisition');
          expect(localController.status, DashcamStatus.recording);

          // Recovery cycle: gate device discovery itself — the checkpoint
          // BEFORE any native camera call (DashcamService._doInitializeController
          // calls availableCameras() before createCameraWithSettings()/
          // initializeCamera() — same code path for the initial start and for
          // a recovery restart) — so the presentation deadline elapses while
          // the raw initialize() is retained there, never having reached
          // controller.initialize() at all.
          localService.notifyAppBackgrounded();
          fakePlatform.pendingAvailableCameras = discoveryGate;
          fakePlatform.availableCamerasEnteredForTest = discoveryEntered;
          final nativeInitsBefore = fakePlatform.calls.where((c) => c == 'initializeCamera').length;
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));

          // Causal proof that discovery genuinely entered the gate — not
          // inferred from a fixed delay (mirrors R3-3's own established
          // pattern in dashcam_service_test.dart).
          await discoveryEntered.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('discovery was never entered (the recovery did not reach availableCameras())'),
          );

          expect(deadline.expire(), 1, reason: 'the presentation deadline elapses now, with the raw initialize held inside discovery');
          await waitForStatus(DashcamStatus.error, on: localController, label: 'discovery-abandon presentation timeout');
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length,
            nativeInitsBefore,
            reason: 'the deadline elapsed BEFORE any native initializeCamera() call — abandonment must never emit a stale native op',
          );

          discoveryGate.complete(); // only now — after the presentation view has objectively already expired

          // Causal proof, not a margin: wait for the raw operation itself
          // (now unblocked in availableCameras()) to genuinely settle.
          await localService.pendingInitializeSettlement?.catchError((_) {}).timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('the raw initialize never settled after discovery was released'),
          );
          await waitForServiceSettled(localService);

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length,
            nativeInitsBefore,
            reason: 'discovery completing late must not authorize a stale initialize() emission either',
          );
          expect(
            localController.status,
            DashcamStatus.error,
            reason: 'no improper retry: the late, abandoned settlement must not resurrect recording on its own',
          );
        } finally {
          if (!discoveryGate.isCompleted) discoveryGate.complete();
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.2B-R5 — session camera attempt single-flight, false-REC guard', () {
    test(
      'A pending → B start → retryCamera() during B\'s own barrier-wait for A → A settle (§4-§11/§27, '
      'MANDATORY GATE — exact reviewer reproduction of P1) — a PUBLIC retryCamera() call arriving while '
      'B\'s own INITIAL attempt is still only waiting on A\'s stale settlement (i.e. before B has its '
      'own raw initialize Future at all) must NOT spawn a concurrent recovery attempt: B performs at '
      'most one create/initialize and at most one START of its own, no STOP ever lands between B\'s own '
      'START and its own recording publication, and B reaches recording only via genuine native '
      '`isRecordingVideo == true`',
      () async {
        service = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        controller = DashcamSessionController(
          dashcamService: service,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateA;

          final sessionA = controller.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100)); // A's own presentation timeout fires
          expect(controller.status, DashcamStatus.error);

          // stopSession(A) returns via the bounded presentation contract —
          // A's own real camera teardown stays queued behind A's still-
          // pending raw initialize().
          await controller.stopSession();

          // Session B starts BEFORE A's raw settlement — B's own INITIAL
          // attempt is claimed synchronously (Fase 16.2-R4.2B-R5 §7),
          // before it ever waits on A, then blocks on A's stale settlement.
          final sessionB = controller.startSession();
          expect(sessionB.id, isNot(sessionA.id));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(
            controller.activeCameraAttemptSessionIdForTest,
            sessionB.id,
            reason: 'B\'s own INITIAL attempt must already be claimed, even though it has no raw Future of its own yet',
          );
          expect(controller.activeCameraAttemptIsInitialForTest, isTrue);
          final creationCountBeforeRetry = controller.cameraAttemptCreationCountForTest;

          // The exact reviewer scenario: a PUBLIC retryCamera() call, once,
          // while B's own initial attempt is still only waiting on A.
          final retryFuture = controller.retryCamera();

          expect(
            controller.cameraAttemptCreationCountForTest,
            creationCountBeforeRetry,
            reason: 'retryCamera() during B\'s own active initial attempt must NOT create a second, concurrent attempt',
          );
          expect(controller.activeCameraAttemptIsInitialForTest, isTrue, reason: 'first purpose (initial) must never convert to recovery');

          // A's raw initialize() now genuinely, finally resolves — late.
          initGateA.complete();
          await retryFuture;

          await waitForStatus(DashcamStatus.recording, on: controller);

          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(2),
            reason: 'A\'s own original controller, plus exactly ONE genuinely new controller for B — never a second, competing one from the retry',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(2),
            reason: 'B performs at most one real native initialize of its own',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(1),
            reason: 'B performs at most one real native START',
          );
          final startIndex = fakePlatform.calls.indexOf('startVideoCapturing');
          final stopIndexAfterStart = fakePlatform.calls.indexOf('stopVideoRecording', startIndex);
          expect(
            stopIndexAfterStart,
            -1,
            reason: 'no recovery-triggered STOP may ever land between B\'s own START and its recording publication',
          );
          expect(
            service.previewController?.value.isRecordingVideo,
            isTrue,
            reason: 'B reaches recording only via genuine native isRecordingVideo == true, never merely the status label',
          );
          expect(recorder.activeSession?.id, sessionB.id);

          await controller.stopSession();
        } finally {
          if (!initGateA.isCompleted) initGateA.complete();
          await drainLocal(controller, service);
        }
      },
    );

    test(
      'repeated retryCamera()/resumed calls while B\'s own initial attempt awaits A (§8/§31) — no '
      'proportional growth of attempts/initialize/START/recoveryFuture; exactly one attempt for B',
      () async {
        service = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        controller = DashcamSessionController(
          dashcamService: service,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateA;

          final sessionA = controller.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(controller.status, DashcamStatus.error);
          await controller.stopSession();

          final sessionB = controller.startSession();
          expect(sessionB.id, isNot(sessionA.id));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          final creationCountBefore = controller.cameraAttemptCreationCountForTest;

          await controller.retryCamera();
          await controller.retryCamera();
          controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await controller.retryCamera();

          expect(
            controller.cameraAttemptCreationCountForTest,
            creationCountBefore,
            reason: 'repeated retries/resume during B\'s own active attempt must never accumulate additional attempts',
          );

          initGateA.complete();
          await waitForStatus(DashcamStatus.recording, on: controller);

          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(2), reason: 'A + exactly one for B');
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1));
          expect(service.previewController?.value.isRecordingVideo, isTrue);

          await controller.stopSession();
        } finally {
          if (!initGateA.isCompleted) initGateA.complete();
          await drainLocal(controller, service);
        }
      },
    );

    test(
      'initial attempt active + retryCamera() (§8/§9/§36) — a retry arriving while THIS session\'s own '
      'initial attempt is genuinely in flight (already past admission, waiting on its own raw '
      'initializeCamera()) must not create a concurrent recovery attempt, and first purpose (initial) '
      'is preserved',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          final session = localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(localController.activeCameraAttemptSessionIdForTest, session.id);
          expect(localController.activeCameraAttemptIsInitialForTest, isTrue);
          final creationCountBefore = localController.cameraAttemptCreationCountForTest;

          await localController.retryCamera(); // immediate no-op — an attempt is already active

          expect(localController.cameraAttemptCreationCountForTest, creationCountBefore);
          expect(localController.activeCameraAttemptIsInitialForTest, isTrue, reason: 'retry must not convert INITIAL into RECOVERY');

          initGate.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1));
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'legitimate LATER recovery after the initial attempt genuinely concludes (§13/§14/§32) — the '
      'single-flight slot frees once B is genuinely recording, and a real camera loss afterward can '
      'still create a brand-new recovery attempt',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(
            localController.activeCameraAttemptSessionIdForTest,
            isNull,
            reason: 'the initial attempt must have cleared itself once recording was genuinely confirmed',
          );
          final creationCountAfterInitial = localController.cameraAttemptCreationCountForTest;

          // A real camera loss — legitimate recovery scenario, explicitly
          // still required to work (§14).
          localService.notifyAppBackgrounded();
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            localController.cameraAttemptCreationCountForTest,
            greaterThan(creationCountAfterInitial),
            reason: 'the single-flight guard must not block a genuinely NEW, later recovery attempt',
          );
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'A late FAILURE + retryCamera() during B\'s own wait (§9/§33) — serialization is preserved: one '
      'attempt for B, A\'s error never leaks into B, B proceeds once via its own operation',
      () async {
        service = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        controller = DashcamSessionController(
          dashcamService: service,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateA;

          final sessionA = controller.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(controller.status, DashcamStatus.error);
          await controller.stopSession();

          final sessionB = controller.startSession();
          expect(sessionB.id, isNot(sessionA.id));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          final creationCountBeforeRetry = controller.cameraAttemptCreationCountForTest;

          final retryFuture = controller.retryCamera();
          expect(controller.cameraAttemptCreationCountForTest, creationCountBeforeRetry);

          initGateA.completeError(CameraException('native_initialize_failed', 'A\'s own late failure'));
          // Test-fixture artifact, not production behavior — see the A→B
          // late FAILURE test's own identical doc.
          fakePlatform.pendingInitializeCamera = null;
          await retryFuture;

          await waitForStatus(DashcamStatus.recording, on: controller);
          expect(
            service.previewController?.value.isRecordingVideo,
            isTrue,
            reason: 'B must still reach genuine recording via its own operation, unaffected by A\'s late failure',
          );
          expect(recorder.activeSession?.id, sessionB.id);

          await controller.stopSession();
        } finally {
          if (!initGateA.isCompleted) initGateA.complete();
          await drainLocal(controller, service);
        }
      },
    );

    test(
      'stopSession(B) while B\'s own initial attempt still awaits A (§22/§34) — zero resurrection: '
      'after A finally settles, B performs zero initialize/START of its own, and the attempt cleanly '
      'concludes',
      () async {
        service = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        controller = DashcamSessionController(
          dashcamService: service,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateA;

          controller.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(controller.status, DashcamStatus.error);
          await controller.stopSession();

          final sessionB = controller.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): B's attempt is
          // claimed synchronously by startSession(); draining the event queue
          // (not a fixed 30ms guess) lets it reach its wait on A's retained raw
          // initialize deterministically, whatever the machine load.
          await pumpEventQueue();
          expect(controller.activeCameraAttemptSessionIdForTest, sessionB.id);
          final callsBeforeStopB = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length;

          await controller.stopSession(); // stops B while it is STILL waiting on A

          expect(
            controller.activeCameraAttemptSessionIdForTest,
            isNull,
            reason: 'stopSession must semantically invalidate B\'s own attempt immediately (§22)',
          );

          initGateA.complete(); // A finally resolves — must not resurrect anything for B
          await Future<void>.delayed(const Duration(milliseconds: 200));

          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length,
            callsBeforeStopB,
            reason: 'zero new initialize for B once it was stopped mid-wait',
          );
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), isEmpty, reason: 'zero START for B');
          expect(controller.status, isNot(DashcamStatus.recording));
        } finally {
          if (!initGateA.isCompleted) initGateA.complete();
          await drainLocal(controller, service);
        }
      },
    );

    test(
      'dispose() while B\'s own initial attempt still awaits A (§23/§35) — zero resurrection, no '
      'notifier-after-dispose',
      () async {
        service = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        controller = DashcamSessionController(
          dashcamService: service,
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final initGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateA;

          controller.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(controller.status, DashcamStatus.error);
          await controller.stopSession();

          final sessionB = controller.startSession();
          // Fase 16.2-R4.3-R2.5 (§55, test-only fragility fix): see the sibling
          // stopSession(B) test above.
          await pumpEventQueue();
          expect(controller.activeCameraAttemptSessionIdForTest, sessionB.id);
          final callsBeforeDispose = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length;

          controller.dispose(); // disposes while B is STILL waiting on A

          initGateA.complete(); // A finally resolves — must not resurrect/notify anything
          await Future<void>.delayed(const Duration(milliseconds: 200));

          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length,
            callsBeforeDispose,
            reason: 'zero new initialize for B once its controller was disposed mid-wait',
          );
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), isEmpty);
          // No crash/unhandled error reaching here is itself the proof that
          // no `notifyListeners()` (or any other ChangeNotifier access)
          // happened on the disposed controller.
        } finally {
          // Fase 16.2-R4.2B-R5.1 (P2, independent review — "dispose-B
          // cleanup não é failure-safe"): if any assertion above threw
          // BEFORE `initGateA.complete()` at its normal call site, the gate
          // must still be released HERE — otherwise the raw native
          // `initializeCamera()` call this test deliberately gated stays
          // stuck forever, `waitForServiceSettled` below can never observe
          // it settle, and the runner reports a confusing secondary
          // cleanup timeout instead of the actual assertion failure (the
          // exact same class of bug W4's own finally already closed — see
          // its doc). Also covers `controller.dispose()` itself: if an
          // assertion failed before line 2289's call, the controller was
          // never disposed and `dashcamService.dispose()` was never
          // triggered — `drainLocal`'s own `try`/`catch` around a second,
          // idempotent `dispose()` call (safe even if already disposed
          // once) guarantees that real teardown still runs before this
          // helper drains the service, matching the established G/I/W4
          // pattern: release artificial gates, then local cleanup, then
          // real drain, then global-owner-null.
          if (!initGateA.isCompleted) initGateA.complete();
          await drainLocal(controller, service);
        }
      },
    );
  });

  group(
    'Fase 16.2-R4.3-R1/R2 — lifecycle generation, semantic authorization, cross-generation raw ownership, '
    'session-lifetime clip baseline, targeted stale cleanup, error scope model',
    () {
    test(
      'L1 (§18/§47) — a resumed handler stuck inside resumePreview() while its own generation goes '
      'stale (another full background→foreground cycle happens before it resolves) must not, once '
      'resolved: start recovery, publish state, release the CURRENT controller, or touch the current '
      'generation\'s own attempt',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        // Fase 16.2-R4.3-R1 (coverage-closure intervention §23, failure-safety
        // audit): declared BEFORE the try — required so `finally` can
        // release it if an assertion throws before this test's own normal
        // `.complete()` call site.
        final resumeGateG1 = Completer<void>();
        final resumeEnteredG1 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final controllerBeforeG1 = localService.previewController;

          // Background — generation G0 -> G1 (ineligible), cameraKnownUnavailable set.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          expect(localService.cameraKnownUnavailable, isTrue);

          // Gate resumePreview — G1's own resumed handler will get stuck
          // inside it.
          fakePlatform.pendingResumePreview = resumeGateG1;
          fakePlatform.resumePreviewEnteredForTest = resumeEnteredG1;

          // Foreground — generation stays G1, now eligible. Launches G1's
          // own resumed handler, which captures generation=G1 and blocks
          // inside resumePreview().
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await resumeEnteredG1.future.timeout(const Duration(seconds: 5));

          // While G1's own resumed handler is still stuck: a full second
          // background->foreground cycle — generation G1 -> G2, then
          // eligible again. This is what makes G1's own captured
          // generation stale.
          fakePlatform.pendingResumePreview = null; // G2's own resumePreview must not also gate
          fakePlatform.resumePreviewEnteredForTest = null;
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          // Let G2's own, genuinely current, legitimate recovery run to
          // completion first — this is the REAL, expected reaction to
          // cameraKnownUnavailable, and must not be confused with G1's own
          // stale one below.
          await waitForStatus(DashcamStatus.recording, on: localController);
          final creationCountAfterG2 = localController.cameraAttemptCreationCountForTest;
          final activeAfterG2 = localController.activeCameraAttemptSessionIdForTest;
          final controllerAfterG2 = localService.previewController;
          expect(
            identical(controllerAfterG2, controllerBeforeG1),
            isFalse,
            reason: 'G2\'s own legitimate recovery must have produced a genuinely new controller',
          );

          // NOW resolve G1's own, long-stale resumePreview().
          resumeGateG1.complete();
          await Future<void>.delayed(const Duration(milliseconds: 200));

          expect(
            localController.cameraAttemptCreationCountForTest,
            creationCountAfterG2,
            reason: 'G1\'s own stale resumed handler must not start a second, redundant recovery attempt',
          );
          expect(
            localController.activeCameraAttemptSessionIdForTest,
            activeAfterG2,
            reason: 'G1 must not touch G2\'s own attempt bookkeeping',
          );
          expect(
            identical(localService.previewController, controllerAfterG2),
            isTrue,
            reason: 'G1 must not release/replace G2\'s own CURRENT controller',
          );
          expect(localController.status, DashcamStatus.recording, reason: 'G1 must not have corrupted G2\'s own published status');
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          fakePlatform.pendingResumePreview = null;
          if (!resumeGateG1.isCompleted) resumeGateG1.complete();
          if (!resumeEnteredG1.isCompleted) resumeEnteredG1.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L3 (§17/§49, MANDATORY GATE — D0\'s own critical "progresso após stale op" hazard) — a recovery '
      'G1\'s own raw initialize() is retained past a presentation timeout; lifecycle advances (G1 -> G2, '
      'foreground) WHILE it is still pending; G1 finally settles successfully. Expected: G1\'s raw '
      'settles and is released (never adopted); the CURRENT generation G2 automatically continues on '
      'its own — with NO manual retryCamera() call — reaching genuine recording via its own, genuinely '
      'new native operation',
      () async {
        // Fase 16.2-R4.4-R1-T-Rm (R-m L3, test-only): see P7 — with a real 50 ms
        // deadline G1 could be abandoned before its native initialize (the
        // deadline ran out while it released the old camera, whose clip
        // promotion is real file I/O since R4.4-R1): status still went to
        // `error`, but no raw op was retained, so the attempt checks below read
        // a finished attempt / a second attempt (reproduced by delaying only
        // the promotion's rename). G1's presentation deadline is now held
        // ([HeldDeadlines]) and elapses once its native initialize is proven
        // retained. G2's own attempt later gets a fresh, held deadline that its
        // success cancels.
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 9500));
        final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
        final localController = buildLocalController(localService);
        final initGateG1 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final controllerBeforeLoss = localService.previewController;
          final initsBefore = callCount('initializeCamera');

          // Background -> foreground: triggers a REAL recovery (G1, since
          // camera is now known-unavailable). Gate its own raw initialize.
          fakePlatform.pendingInitializeCamera = initGateG1;
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          expect(localService.cameraKnownUnavailable, isTrue);
          deadline.run(() => localController.didChangeAppLifecycleState(AppLifecycleState.resumed));

          // G1's own presentation timeout fires — status goes to error, but
          // the raw native initializeCamera() stays gated/retained.
          await waitForCondition(() => callCount('initializeCamera') == initsBefore + 1, 'G1\'s native initialize reached and held');
          expect(deadline.expire(), 1, reason: 'G1\'s presentation deadline elapses now');
          await waitForStatus(DashcamStatus.error, on: localController);
          final creationCountAtG1Timeout = localController.cameraAttemptCreationCountForTest;
          expect(localController.activeCameraAttemptSessionIdForTest, isNotNull, reason: 'G1\'s own attempt must still be active — the raw op is retained');

          // Lifecycle advances to G2 (foreground) WHILE G1's raw is STILL
          // pending. A second resumed dispatch here (the SAME real trigger
          // path production uses) must NOT create a second, concurrent
          // attempt — the single-flight still correctly recognizes G1's
          // own attempt as active.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            localController.cameraAttemptCreationCountForTest,
            creationCountAtG1Timeout,
            reason: 'no second, concurrent attempt must be created while G1\'s own raw op is still retained',
          );

          // G1's raw initialize() FINALLY settles successfully — late.
          initGateG1.complete();

          // Fase 16.2-R4.3-R1 (§17): NO manual retryCamera() call here —
          // this must recover fully automatically, via the hand-off.
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            localController.cameraAttemptCreationCountForTest,
            greaterThan(creationCountAtG1Timeout),
            reason: 'the CURRENT generation must have created its own, genuinely new attempt after G1 drained',
          );
          expect(
            identical(localService.previewController, controllerBeforeLoss),
            isFalse,
            reason: 'the current controller must be a genuinely new one, never the original',
          );
          expect(localService.previewController?.value.isRecordingVideo, isTrue);
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(3),
            reason: 'initial + G1\'s own (settled late, released, never adopted) + the current generation\'s own genuinely new one',
          );

          await localController.stopSession();
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGateG1.isCompleted) initGateG1.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L4a (§50) — session continuity: the same sessionId survives a full background->foreground '
      'recovery cycle; already-installed telemetry is never reinstalled/duplicated',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final session = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.initialSetupInstallCountForTest, 1);

          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(recorder.activeSession?.id, session.id, reason: 'sessionId must survive the generation change unchanged');
          expect(
            localController.lifecycleGenerationForTest,
            greaterThan(0),
            reason: 'the lifecycle generation itself must have advanced',
          );
          expect(
            localController.initialSetupInstallCountForTest,
            1,
            reason: 'recovery must reuse the already-installed telemetry setup, never reinstall/duplicate it',
          );

          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L4b (§22/§23/§50, MANDATORY GATE — D0\'s own "initial incompleto através do background" gate) — '
      'INITIAL setup is still incomplete (raw initialize() itself never even finished) when a full '
      'background->foreground cycle invalidates that attempt; the new, current generation must complete '
      'the FULL initial setup exactly once — not merely a recovery path that presumes it already exists '
      '— with the session\'s own clip baseline correctly established',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGateG0 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateG0;

          localController.startSession();
          // G0's own presentation timeout fires — the very FIRST initialize()
          // this session ever attempted is still retained, unresolved.
          await waitForStatus(DashcamStatus.error, on: localController);
          expect(localController.initialSetupInstallCountForTest, 0, reason: 'initial setup was never reached at all yet');

          // Full background->foreground cycle WHILE G0's own raw initialize
          // is still pending.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // G0's raw initialize() finally, genuinely succeeds — late.
          initGateG0.complete();

          // The hand-off must complete the FULL initial setup automatically
          // — no manual retryCamera() call.
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            localController.initialSetupInstallCountForTest,
            1,
            reason: 'the current generation must complete the missing INITIAL setup exactly once',
          );
          expect(localService.previewController?.value.isRecordingVideo, isTrue);
          // The session's own clip baseline must reflect THIS (the only
          // real) install, not be left uninitialized/stale — proven by
          // stopSession() below being able to persist a clip for this
          // session without throwing/losing anything.
          await localController.stopSession();
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGateG0.isCompleted) initGateG0.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L5-S (§51) — START retention: a recovery G1\'s own raw startVideoCapturing() stays genuinely '
      'retained (never cancelled) while lifecycle advances mid-flight; it must not promote status/be '
      'treated as the current recording once it does resolve, and its own now-unwanted Recording is '
      'properly torn down (never orphaned) — the current generation G2 then reaches genuine recording '
      'via its own, separate native operation. Each of the three native START calls is correlated to '
      'its own genuinely distinct controller identity, not merely counted.',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final startGateG1 = Completer<void>();
        // Fase 16.2-R4.3-R2 (§21, failure-safety discipline): declared
        // BEFORE the try, alongside startGateG1, so `finally` can always
        // release it regardless of where an assertion might throw.
        final cleanupStopGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final controllerG0 = localService.previewController;

          // Background -> foreground: triggers a REAL recovery (G1). Its
          // own initialize() is NOT gated (resolves fast); its own native
          // START is gated instead.
          fakePlatform.pendingStartVideoCapturing = startGateG1;
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);

          // Causal proof that G1's own recovery genuinely reached the
          // native START call (now gated) — polling real, observable state
          // (the call is logged synchronously, before awaiting the gate),
          // never a fixed delay presumed "long enough".
          for (var i = 0; i < 200 && fakePlatform.calls.where((c) => c == 'startVideoCapturing').length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(2),
            reason: 'G1\'s own recovery must have genuinely reached the native START call (G0\'s own + G1\'s own, now gated)',
          );
          final controllerG1 = localService.previewController!;
          expect(identical(controllerG0, controllerG1), isFalse, reason: 'G1\'s own controller is already a genuinely distinct identity from G0\'s');

          // WHILE G1's own raw START is still pending: a full lifecycle
          // cycle to G2.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Fase 16.2-R4.3-R2 (§24-§26, independent-review P2-A regression
          // proof): gate G1's OWN targeted-cleanup STOP too, so the window
          // immediately after G1's raw START resolves — but BEFORE that
          // cleanup finishes — is directly observable.
          fakePlatform.pendingStopVideoRecording = cleanupStopGate;

          // G1's own raw START finally, genuinely resolves — late.
          fakePlatform.pendingStartVideoCapturing = null;
          startGateG1.complete();

          // Causal proof G1's own targeted cleanup genuinely reached its own
          // native STOP call (now gated) — the exact window §26 requires.
          //
          // Fase 16.2-R4.3-R2.2 (§34, independent-review audit — "L5-S
          // correlaciona STOP com Recording G1, não apenas 'algum STOP
          // aconteceu'"): polling for "any stopVideoRecording call" alone is
          // ambiguous — G1's own recovery `initialize()` call, earlier in
          // this very test, already released G0's own (backgrounded, still
          // recording) controller via DashcamService's own teardown path,
          // which itself issues a REAL, EARLIER, UNGATED stop against G0's
          // camera (cameraId 0) — by the time this loop is reached, `calls`
          // may already contain that entry regardless of whether G1's own
          // targeted cleanup has started. Polling/asserting on
          // [FakeCameraPlatform.stopVideoRecordingCameraIds] containing
          // G1's own [controllerG1.cameraId] specifically is what actually
          // proves the window this test's own name claims.
          for (var i = 0; i < 300 && !fakePlatform.stopVideoRecordingCameraIds.contains(controllerG1.cameraId); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            fakePlatform.stopVideoRecordingCameraIds,
            contains(controllerG1.cameraId),
            reason: 'G1\'s own targeted cleanup must have genuinely reached its own native STOP, correlated to G1\'s own controller — not merely "some" STOP (which could be G0\'s own, earlier, teardown-triggered one)',
          );
          expect(
            localService.hasActiveSegmentTimerForTest,
            isFalse,
            reason: 'Fase 16.2-R4.3-R2 (§24/§25, P2-A fix): a purely-semantically-stale START must never arm the rotation timer',
          );
          expect(
            localService.activeRecordingId,
            isNotNull,
            reason: 'the physical Recording G1\'s own raw START produced is still tracked (never fabricated/discarded)',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(2),
            reason: 'still only G0\'s own + G1\'s own retained START — the current generation has not emitted its own yet',
          );

          // Release G1's own targeted cleanup.
          cleanupStopGate.complete();

          // The hand-off must reach genuine recording automatically, via a
          // SEPARATE, new native operation for the current generation.
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(3),
            reason: 'G0\'s own original + G1\'s own retained START (never cancelled) + the current generation\'s own separate one',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            isNotEmpty,
            reason: 'G1\'s own now-unwanted Recording must be properly torn down, not orphaned',
          );
          final controllerG2 = localService.previewController;
          expect(controllerG2?.value.isRecordingVideo, isTrue);
          // Fase 16.2-R4.3-R1 (§21, coverage-closure intervention): each of
          // the three START calls correlates to its OWN, pairwise-distinct
          // controller identity — not merely a length-3 count.
          expect(identical(controllerG1, controllerG2), isFalse, reason: 'G2\'s own controller is genuinely distinct from G1\'s abandoned one');
          expect(identical(controllerG0, controllerG2), isFalse, reason: 'G2\'s own controller is genuinely distinct from G0\'s original one');

          await localController.stopSession();
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!startGateG1.isCompleted) startGateG1.complete();
          if (!cleanupStopGate.isCompleted) cleanupStopGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L6 (§52) — rapid resumed/paused cycles: generation increments only on the FIRST exit from an '
      'eligible epoch, repeated events cause no churn, only the current epoch starts semantic work, no '
      'attempt leaks, and stop/dispose mid-sequence remains terminal',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          expect(localController.lifecycleGenerationForTest, 0);
          expect(localController.lifecycleEligibleForTest, isTrue, reason: 'setUp establishes a real resumed state');

          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.cameraAttemptCreationCountForTest, 1);

          // resumed -> paused -> resumed -> paused -> resumed.
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleGenerationForTest, 0, reason: 'resumed while already eligible must never increment');
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          expect(localController.lifecycleGenerationForTest, 1);
          expect(localController.lifecycleEligibleForTest, isFalse);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleGenerationForTest, 1, reason: 'resumed never increments, only marks eligible');
          expect(localController.lifecycleEligibleForTest, isTrue);
          // Let the real recovery this resumed dispatch triggers settle
          // before advancing further, so it doesn't race the NEXT paused.
          await waitForStatus(DashcamStatus.recording, on: localController);
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          expect(localController.lifecycleGenerationForTest, 2);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleGenerationForTest, 2, reason: 'repeated hidden/paused/resumed events cause no extra churn');
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            localController.activeCameraAttemptSessionIdForTest,
            isNull,
            reason: 'no attempt leak — everything concluded cleanly',
          );

          // stop/dispose mid-sequence remains terminal. Fase 16.2-R4.3-R2
          // (§38, independent-review P2-D fix — "L6/L7 não garantem dispose
          // no finally"): disposal itself now happens exclusively in
          // `finally` (via `drainLocal`, already idempotent/try-catch-guarded
          // — see its own doc), so an assertion failure ABOVE this point
          // still reaches real cleanup instead of leaking `localController`'s
          // own native camera resources/observer into later tests.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L7 (§53) — event dedup: resumed->resumed, inactive->resumed, resumed->hidden->paused, repeated '
      'hidden->paused, detached — generation increments follow the architectural rule (first exit from '
      'eligible), never raw callback count',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          expect(localController.lifecycleGenerationForTest, 0);

          // resumed -> resumed: no increment, stays eligible.
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleGenerationForTest, 0);
          expect(localController.lifecycleEligibleForTest, isTrue);

          // inactive -> resumed: inactive is a pure no-op (§9); resumed
          // then confirms/no-ops eligibility.
          localController.didChangeAppLifecycleState(AppLifecycleState.inactive);
          expect(localController.lifecycleGenerationForTest, 0);
          expect(localController.lifecycleEligibleForTest, isTrue, reason: 'inactive must never flip eligibility');
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleGenerationForTest, 0);

          // resumed -> hidden -> paused: exactly ONE increment (the FIRST
          // exit — hidden), paused (already ineligible) is a no-op.
          localController.didChangeAppLifecycleState(AppLifecycleState.hidden);
          expect(localController.lifecycleGenerationForTest, 1);
          expect(localController.lifecycleEligibleForTest, isFalse);
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          expect(localController.lifecycleGenerationForTest, 1, reason: 'hidden already consumed the exit — paused must not increment again');

          // Repeated hidden->paused (still ineligible): no further increments.
          localController.didChangeAppLifecycleState(AppLifecycleState.hidden);
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          expect(localController.lifecycleGenerationForTest, 1);

          // resumed: renews eligibility for generation 1, no increment.
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleGenerationForTest, 1);
          expect(localController.lifecycleEligibleForTest, isTrue);

          // detached: a fresh exit from eligible — increments once.
          localController.didChangeAppLifecycleState(AppLifecycleState.detached);
          expect(localController.lifecycleGenerationForTest, 2);
          expect(localController.lifecycleEligibleForTest, isFalse);
          // A second detached (already ineligible): no further increment.
          localController.didChangeAppLifecycleState(AppLifecycleState.detached);
          expect(localController.lifecycleGenerationForTest, 2);

          // Fase 16.2-R4.3-R2 (§38, independent-review P2-D fix): disposal
          // moved to `finally` — see L6's own identical doc.
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L9-start-boundary (§55, useful regression, NOT alone a closure of the writer.open() hazard — see '
      'L9-real below) — setup/cleanup own: G1\'s own INITIAL setup is still mid-flight (its own native '
      'START genuinely retained) when lifecycle invalidates it; once resolved, G1 tears down only ITS '
      'OWN local setup — the current generation\'s own, separately-installed setup is never touched, '
      'closed, or cancelled',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final initGateG1 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateG1;
          localController.startSession();
          // Causal proof G1's own initialize() genuinely reached the native
          // call (now gated) before advancing lifecycle.
          for (var i = 0; i < 200 && fakePlatform.calls.where((c) => c == 'initializeCamera').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(fakePlatform.calls, contains('initializeCamera'));
          expect(localController.initialSetupInstallCountForTest, 0, reason: 'G1\'s own INITIAL setup has not run at all yet');

          // Lifecycle invalidates G1 WHILE its own raw initialize is still
          // pending.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // G1's own raw initialize() finally, genuinely succeeds — late.
          initGateG1.complete();

          // The hand-off must complete the FULL initial setup automatically
          // for the current generation, exactly once.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.initialSetupInstallCountForTest, 1);
          final createCountAfterFirstInstall = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length;

          // A SECOND, genuinely later background->foreground cycle — proves
          // the current generation's own setup survives untouched, and is
          // never redundantly reinstalled by anything left over from G1.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            localController.initialSetupInstallCountForTest,
            1,
            reason: 'the current generation\'s own already-installed setup must never be reinstalled/duplicated by G1\'s own late resolution',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length,
            greaterThan(createCountAfterFirstInstall),
            reason: 'the second cycle\'s own legitimate recovery must have produced its own genuinely new controller',
          );
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGateG1.isCompleted) initGateG1.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L9-real (§7-§9, MANDATORY GATE, coverage-closure intervention; gate ordering corrected in Fase '
      '16.2-R4.3-R2 §32/§33 per independent-review P2-G — "gateia ANTES de writer.open() começar"; '
      'ordering audited in Fase 16.2-R4.3-R2.2 §31-§33 per independent-review — see this test\'s own '
      'doc, below, for why "G2 fully installed before G1\'s own gate releases" is structurally '
      'impossible for THIS specific path, proven via real ordering rather than assumed) — writer.open() '
      'boundary: G1\'s own LOCAL writer instance has genuinely, really CALLED open() (the real async '
      'file boundary itself, invoked first and unconditionally — not gated before it even starts) when '
      'lifecycle invalidates it; once open() resolves, G1 closes only its own local writer — never '
      'installs it as current, never touches the current generation\'s own subscriptions/timer — and '
      'the current generation\'s own setup happens exactly once',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final writerGateG1 = Completer<void>();
        final writerEnteredG1 = Completer<void>();
        final writerEnteredG2 = Completer<void>();
        var openCallIndex = 0;
        try {
          await preferences.setEnabled(true);
          // Fase 16.2-R4.3-R2 (§32/§33, independent-review P2-G fix — "L9-real
          // gateia ANTES de writer.open() começar"): [openCall] — the REAL
          // `writer.open` tear-off — is invoked FIRST, unconditionally,
          // starting the genuine operation immediately; only THIS
          // continuation's own await of its result is gated, never the call
          // itself. Fase 16.2-R4.3-R2.2 (§31-§33, audit): distinguishes G1's
          // own call (first, gated) from any LATER one (G2's own, if it ever
          // arrives while this hook is still installed) purely for this
          // test's own observability below.
          localController.openTelemetryWriterHookForTest = (writer, openCall) async {
            final realOpen = openCall();
            final index = openCallIndex++;
            if (index == 0) {
              writerEnteredG1.complete();
              await writerGateG1.future;
            } else if (!writerEnteredG2.isCompleted) {
              writerEnteredG2.complete();
            }
            await realOpen;
          };
          localController.startSession();

          // Causal proof G1's own writer.open() boundary was genuinely
          // entered — real async gate, not a fixed delay.
          await writerEnteredG1.future.timeout(const Duration(seconds: 5));
          expect(localController.initialSetupInstallCountForTest, 0, reason: 'G1\'s own setup has not durably installed yet — still mid writer.open()');

          // Lifecycle invalidates G1 WHILE its own writer.open() is still
          // pending.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Fase 16.2-R4.3-R2.2 (§31-§33, independent-review audit — "L9
          // ainda não prova G2 instalado antes de G1 cleanup tardio"): proven
          // here, via REAL ordering, rather than assumed impossible or
          // assumed possible: G2's own attempt cannot even be CREATED while
          // G1's own [_CameraAttempt] is still active — [_activeCameraAttempt]
          // is single-flight per session (Fase 16.2-R4.2B-R5, unchanged/
          // frozen this round), and G1's own attempt only reaches its
          // terminal, attempt-clearing checkpoint from WITHIN this very
          // writer.open() continuation, once it resumes past this hook's own
          // gate and recognizes its own staleness. So no second `openCall()`
          // can possibly land on this hook while [writerGateG1] is still
          // held — confirmed directly: [writerEnteredG2] has NOT fired, and
          // exactly one setup attempt (G1's own, still pending) exists.
          expect(writerEnteredG2.isCompleted, isFalse, reason: 'G2 cannot start (let alone reach writer.open()) while G1\'s own attempt is still the single active one');
          expect(localController.initialSetupInstallCountForTest, 0, reason: 'no install has happened yet — only G1\'s own, still-pending attempt exists');

          // G1's own writer.open() finally, genuinely resolves — the REAL
          // file boundary completes, late. From here on, the hook must not
          // interfere with the CURRENT generation's own writer — clear it
          // before letting the hand-off's own new attempt reach this same
          // checkpoint.
          localController.openTelemetryWriterHookForTest = null;
          writerGateG1.complete();

          // The hand-off must complete the FULL initial setup automatically
          // — no manual retryCamera() call.
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            localController.initialSetupInstallCountForTest,
            1,
            reason: 'the current generation must complete initial setup exactly once — G1\'s own late writer.open() must not count as an install',
          );
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          // The session must still be able to persist a clip cleanly —
          // proof the CURRENT generation's own writer/subscriptions/timer
          // were never touched/closed by G1's own late cleanup.
          await localController.stopSession();
        } finally {
          localController.openTelemetryWriterHookForTest = null;
          if (!writerGateG1.isCompleted) writerGateG1.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L10-B (§56, MANDATORY GATE) — lifecycleCamera, current: an error whose scope is lifecycleCamera and '
      'whose origin/generation ARE the current controller/generation still publishes normally — the REAL, '
      'natural async camera-lost delivery path (dashcamService.originatedErrors -> DashcamSessionController\'s '
      'own production listener), not the direct-consumer seam',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          // An error whose origin IS the CURRENT controller still publishes
          // normally — the async camera-lost path. The current controller's
          // own cameraId is whatever createCameraWithSettings most recently
          // assigned (0-indexed by call count).
          final currentCameraId = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length - 1;
          fakePlatform.emitCameraError(currentCameraId, 'simulated current-generation camera-lost error');
          for (var i = 0; i < 200 && localController.status != DashcamStatus.error; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(localController.status, DashcamStatus.error, reason: 'a current-generation-scoped error must still publish normally');

          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L10-A (§10-§14, MANDATORY GATE, coverage-closure intervention — "prova direta do consumidor '
      'stale") — lifecycleCamera scope, origin G1 (no longer the current controller) AND generation G1 '
      '(no longer the current generation) delivered via the EXACT SAME production consumer '
      '(deliverServiceErrorForTest forwards to _onDashcamServiceError itself, no duplicated logic) must '
      'NOT publish DashcamStatus.error over the current, genuine G2 recording',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final controllerG1 = localService.previewController;
          final generationG1 = localController.lifecycleGenerationForTest;
          expect(controllerG1, isNotNull);

          // A REAL, genuinely later recovery — the current controller (G2)
          // is now a DIFFERENT, genuinely new instance, and the generation
          // has genuinely advanced.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await waitForStatus(DashcamStatus.recording, on: localController);
          final controllerG2 = localService.previewController;
          expect(identical(controllerG1, controllerG2), isFalse);
          expect(localController.lifecycleGenerationForTest, greaterThan(generationG1));

          // Deliver a stale-origin, stale-generation error (G1's own, no
          // longer current in either dimension) through the SAME production
          // consumer method.
          localController.deliverServiceErrorForTest(
            DashcamServiceError(
              'G1\'s own stale, orphaned failure',
              scope: DashcamServiceErrorScope.lifecycleCamera,
              origin: controllerG1,
              generation: generationG1,
            ),
          );

          expect(
            localController.status,
            DashcamStatus.recording,
            reason: 'a lifecycleCamera error whose origin/generation are no longer current must not overwrite the current, genuine recording',
          );
          expect(localController.errorMessage, isNot(contains('orphaned')));

          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L10-C (§43, MANDATORY GATE, independent-review P2-C fix) — recordingResult scope: a REAL rotation '
      'finalize failure (a Recording\'s own outcome, not camera-acquisition health) genuinely reaches BOTH '
      'the legacy .errors AND typed .originatedErrors channels, yet must never, on its own, flip a healthy '
      'CURRENT camera to DashcamStatus.error',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): this test used the
          // real 60 ms segment timer, armed at the native START — the first
          // rotation could fire before the initial START was even confirmed
          // (it includes the telemetry file's open, real file I/O) and the
          // session ended in "Camera stopped recording before it could be
          // confirmed" instead of reaching this scenario (reproduced by
          // delaying only that open, T-Rm 09_round2/screens). The tick is
          // delivered by hand (segmentTimerArmedHookForTest: the same closure
          // the timer calls — still a REAL rotation), with a 10-minute segment.
          segmentDuration: const Duration(minutes: 10),
        );
        final ticks = <void Function()>[];
        localService.segmentTimerArmedHookForTest = ticks.add;
        final localController = buildLocalController(localService);
        // Fase 16.2-R4.3-R2 (§21, failure-safety discipline): declared
        // BEFORE the try, as nullable, so `finally` can always cancel
        // whichever of these was actually installed regardless of where an
        // assertion might throw.
        StreamSubscription<String>? legacySub;
        StreamSubscription<DashcamServiceError>? typedSub;
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          final legacyMessages = <String>[];
          legacySub = localService.errors.listen(legacyMessages.add);
          final typedScopes = <DashcamServiceErrorScope>[];
          typedSub = localService.originatedErrors.listen((e) => typedScopes.add(e.scope));

          // A REAL rotation-triggered finalize failure — this Recording's
          // own outcome, tagged recordingResult (see _doRotateSegment's own
          // doc) — never a fact about the CURRENT controller's own
          // acquisition health.
          fakePlatform.failStopVideoRecordingWith = CameraException('finalize_failed', 'forced rotation finalize failure');
          expect(ticks, hasLength(1), reason: 'test setup: the segment\'s timer was armed once');
          ticks.single(); // the segment's own rotation tick
          for (var i = 0; i < 300 && legacyMessages.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fakePlatform.failStopVideoRecordingWith = null;

          expect(legacyMessages, isNotEmpty, reason: 'a rotation finalize failure must genuinely reach the existing legacy .errors channel');
          expect(
            typedScopes,
            contains(DashcamServiceErrorScope.recordingResult),
            reason: 'the SAME failure must be tagged recordingResult in the typed channel',
          );
          // Fase 16.2-R4.3-R2: a rotation finalize failure ALSO, separately,
          // sets `cameraKnownUnavailable` (an established, Fase 16.2-R1
          // truthfulness mechanism, unrelated to error-scope filtering —
          // see `status`'s own doc) — `status` may legitimately downgrade to
          // `cameraUnavailable` for that reason, but the underlying
          // `_liveStatus` field this recordingResult error is being tested
          // AGAINST must never have been driven to `error` — `status`'s own
          // downgrade only ever triggers when `_liveStatus == recording` in
          // the first place, so `cameraUnavailable` here is itself proof
          // `_liveStatus` stayed `recording`.
          expect(
            localController.status,
            isNot(DashcamStatus.error),
            reason: 'recordingResult must never, on its own, poison a healthy CURRENT camera into DashcamStatus.error',
          );

          await localController.stopSession();
        } finally {
          fakePlatform.failStopVideoRecordingWith = null;
          await legacySub?.cancel();
          await typedSub?.cancel();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L10-D (§44, MANDATORY GATE) — backendGlobal scope: a global/backend error delivered via the SAME '
      'production consumer remains visible/blocking REGARDLESS of lifecycle generation — never filtered as '
      'if it were merely lifecycle-scoped',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          // A full lifecycle cycle first, so this is genuinely a LATER
          // generation than when the session started — the global error
          // must still land regardless.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.deliverServiceErrorForTest(
            const DashcamServiceError('backend uncertain — global, fail-closed', scope: DashcamServiceErrorScope.backendGlobal),
          );

          expect(
            localController.status,
            DashcamStatus.error,
            reason: 'a backendGlobal error must always publish, independent of generation — never a synthetic null substitute for a real backend fact',
          );
          expect(localController.errorMessage, contains('backend uncertain'));
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L2 (§4/§37, MANDATORY GATE, coverage-closure intervention, hardened in Fase 16.2-R4.3-R2 per '
      'independent review §37 — "tick esperando ATRÁS de outra operação", since the R4.3-R1 version had '
      'its own single tick ALREADY executing, blocked INSIDE its own stop, rather than genuinely queued '
      'behind a prior operation) — rotation/FIFO: a REAL rotation tick #1 occupies the FIFO, genuinely '
      'blocked inside its own native finalize; a SECOND real tick (#2 — the tick under test) fires and is '
      'enqueued strictly BEHIND it, never itself started while lifecycle advances and a genuinely current '
      'recovery is requested; releasing tick #1 lets BOTH ticks drain in their own correct FIFO position — '
      'both still against G1, since the queued recovery has not run yet — and only THEN does recovery '
      'proceed to create G2; neither tick ever issues a STOP against the FOLLOWING (G2) controller — no '
      'private callback invoked manually, no fabricated ordering',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          // Fase 16.2-R4.4-R1-T-Rm (R-m round 2, test-only): this test used the
          // real 60 ms segment timer, armed at the native START. If the initial
          // START took longer than one segment to be confirmed (it includes the
          // telemetry file's open, real file I/O), a first rotation ran — not
          // gated, the gate below is installed only after `recording` — and
          // "tick #1" then counted that one, while the gated stop was really
          // the next tick's: "tick #2" found a second native stop (reproduced
          // by delaying only that open, T-Rm 09_round2/screens). Both ticks are
          // delivered by hand (segmentTimerArmedHookForTest: the same closure
          // the periodic timer calls, twice — still REAL ticks, still nothing
          // private invoked), with a 10-minute segment.
          segmentDuration: const Duration(minutes: 10),
        );
        final ticks = <void Function()>[];
        localService.segmentTimerArmedHookForTest = ticks.add;
        final localController = buildLocalController(localService);
        final tick1StopGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final controllerG1 = localService.previewController;

          // Gate the native finalize-stop BEFORE the first rotation tick
          // fires — tick #1 becomes the PRIOR operation occupying the FIFO,
          // genuinely blocked inside its own native finalize.
          fakePlatform.pendingStopVideoRecording = tick1StopGate;
          expect(ticks, hasLength(1), reason: 'test setup: the segment\'s timer was armed once');
          ticks.single(); // tick #1

          // Causal proof tick #1 genuinely fired and reached its own native
          // finalize (now gated) — polling real, observable state, never a
          // fixed "wait long enough" delay.
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(fakePlatform.calls, contains('stopVideoRecording'), reason: 'tick #1 must have genuinely fired and reached its own native finalize');
          final stopCallsAfterTick1Entered = fakePlatform.calls.where((c) => c == 'stopVideoRecording').length;

          // A SECOND tick of the same periodic timer — it enqueues tick #2's
          // own _doRotateSegment call strictly BEHIND tick #1's still-blocked
          // one. Tick #2 itself never starts running (its own turn in the
          // FIFO has not arrived) — confirmed by the stop count staying
          // unchanged over the observation window below.
          ticks.single(); // tick #2
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(stopCallsAfterTick1Entered),
            reason: 'tick #2 must be genuinely queued BEHIND tick #1 — no second native finalize call issued while tick #1 still blocks the FIFO',
          );

          // Lifecycle advances WHILE tick #2 is still only queued (never
          // itself started) — background sets cameraKnownUnavailable,
          // foreground requests a genuinely current recovery, whose own
          // initialize() must queue BEHIND tick #2's own not-yet-run work
          // (the SAME FIFO discipline R4.2A already established — untouched
          // this round).
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Release tick #1 — both ticks now drain, each in its own correct
          // FIFO position, strictly BEFORE the queued recovery's own
          // initialize() (already-completed completers resolve instantly,
          // so tick #2's own finalize is not itself gated).
          tick1StopGate.complete();

          await waitForStatus(DashcamStatus.recording, on: localController);
          final controllerG2 = localService.previewController;
          expect(identical(controllerG1, controllerG2), isFalse, reason: 'the current generation must be a genuinely new controller');
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!tick1StopGate.isCompleted) tick1StopGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'L5-T (§5/§35/§36, MANDATORY GATE, coverage-closure intervention, gate ordering corrected in Fase '
      '16.2-R4.3-R2 per independent review §35 — the R4.3-R1 version advanced lifecycle without first '
      'confirming the native STOP had genuinely been entered) — STOP retention across generation: a REAL '
      'native stopVideoRecording() already, genuinely, causally-confirmed ENTERED for G1 (via explicit '
      'stopSession) stays retained (never cancelled/abandoned) while lifecycle advances; the old clip is '
      'still correctly collected AND indexed into session A\'s own persisted record, generation never '
      'interferes with the pending-stop/RecordingId identity, and no obligation belonging to the CURRENT '
      'generation is ever torn down by it',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          // Fase 16.2-R4.3-R2.1 (§23, independent-review fix — "reverter o
          // artifício de L5-T"): back to a genuinely SHORT presentation
          // deadline. Fase 16.2-R4.3-R2's own version of this test widened
          // this to 5s as a workaround for a real gap discovered while
          // adding this test's own persistence assertion: with a short
          // deadline, `stopLoopRecording()`'s own presentation view resolved
          // BEFORE the still-gated real native stop, so `_persistClipsForSession`'s
          // own IMMEDIATE pass ran against a clip that did not exist yet —
          // and R4.3-R2 had no mechanism to persist it later. Fase
          // 16.2-R4.3-R2.1's own late-settlement continuation
          // (`DashcamService.pendingStopHandle`/[DashcamSessionController
          // ._watchLateStopSettlement]) now closes exactly that gap — this
          // test passes with a short deadline BECAUSE of that continuation,
          // not because the race was avoided.
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final clipsBeforeA = localService.clips.length;

          // A REAL, explicit stopSession() — its own native STOP is gated,
          // genuinely retained past its own presentation deadline.
          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();

          // Fase 16.2-R4.3-R2 (§35, independent-review fix): causal proof
          // the native STOP genuinely ENTERED before advancing lifecycle —
          // capturing session A's own RecordingId/controller identity at
          // that exact moment, not merely gating-then-immediately-advancing.
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(fakePlatform.calls, contains('stopVideoRecording'), reason: 'session A\'s own explicit STOP must have genuinely entered the native call');
          final recordingIdA = localService.activeRecordingId;
          final controllerA = localService.previewController;
          expect(recordingIdA, isNotNull);
          expect(controllerA, isNotNull);

          // Lifecycle advances WHILE session A's own native STOP is still
          // genuinely pending/retained.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          // Fase 16.2-R4.4-R1-T-Rm (R-m L5-T, test-only): a fixed 20 ms delay
          // guessed that the recorder had already closed A; under load it had
          // not, and startSession() for B was REFUSED ("still being ended")
          // before the scenario was reached — reproduced by delaying only the
          // recorder's finalization (T-Rm 02_directed/recorder_delay). B starts
          // once A is over as a driving session (canStartSession, the UI's own
          // signal), with A's native STOP still held by its gate.
          await waitForCondition(() => localController.canStartSession, 'A closed by the recorder, its native STOP still held');
          expect(stopGateA.isCompleted, isFalse, reason: 'test setup check: A\'s native STOP is still retained');

          // A genuinely current session B starts — must not be affected by
          // A's own still-pending native STOP in any way.
          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(sessionA.id));
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // A's own native STOP finally, genuinely resolves — late. Never
          // cancelled/abandoned by the lifecycle change in between. Session
          // A's own RecordingId/controller identity are UNCHANGED by the
          // lifecycle transition in between — proving generation never
          // interfered with the pending-stop identity itself (§5/§22).
          expect(localService.activeRecordingId, recordingIdA, reason: 'RecordingId identity must survive the lifecycle transition unchanged');
          stopGateA.complete();
          await stopFutureA;

          // B must reach genuine recording, untouched by A's own late STOP.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localService.previewController?.value.isRecordingVideo, isTrue);
          expect(recorder.activeSession?.id, sessionB.id);

          // Fase 16.2-R4.3-R2 (§36), closed for real in Fase 16.2-R4.3-R2.1
          // (§23 — see this test's own `stopVideoRecordingTimeout` doc
          // above): session A's own clip must be genuinely collected AND
          // correctly indexed into session A's own persisted record —
          // reinforces P1-2 (the session's own baseline correctly stayed
          // A's own, never contaminated by B's later existence). With a
          // genuinely SHORT presentation deadline, this now arrives via the
          // LATE continuation — asynchronous relative to `stopFutureA`'s own
          // (presentation-bounded) resolution above — so both checks poll.
          for (var i = 0; i < 300 && localService.clips.length == clipsBeforeA; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(localService.clips.length - clipsBeforeA, 1, reason: 'session A\'s own STOP must have produced exactly one real clip');
          final boxA = Hive.box(HiveBoxNames.dashcamSessionVideos);
          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = boxA.get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(1), reason: 'session A\'s own clip must be indexed under session A\'s own id, not lost or misattributed to B');

          await localController.stopSession();
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'I0-A (§16, MANDATORY GATE, coverage-closure intervention) — initial lifecycle: a controller '
      'constructed while the REAL Flutter binding reports a non-resumed state (detached) starts '
      'INELIGIBLE; a session started in that state emits ZERO native camera calls; the logical driving '
      'session still starts normally; and once a genuine resumed event arrives, the session '
      'automatically, correctly acquires the camera for the first time (a real gap this intervention\'s '
      'own required coverage found and fixed: the FIRST attempt\'s own pre-native ineligibility '
      'abandonment previously left nothing to re-trigger a later resumed)',
      () async {
        // Override this file's own setUp() resumed baseline — the whole
        // point of this test is to start from a genuinely non-resumed
        // binding state.
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.detached);
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          expect(localController.lifecycleEligibleForTest, isFalse, reason: 'a real, known non-resumed state must never authorize the camera');
          expect(localController.lifecycleGenerationForTest, 0);

          await preferences.setEnabled(true);
          final session = localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(fakePlatform.calls, isEmpty, reason: 'zero native camera work while genuinely ineligible');
          expect(recorder.activeSession?.id, session.id, reason: 'the logical driving session still starts normally, independent of camera eligibility');

          // A genuine resumed event — the session must now automatically
          // acquire the camera for the first time.
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleEligibleForTest, isTrue);

          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(fakePlatform.calls, contains('initializeCamera'));
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
          // Restore a resumed binding state for any LATER test in this
          // file relying on this file's own setUp() baseline.
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
      },
    );

    test(
      'I0-C (§18) — initial lifecycle: a controller constructed while the binding already reports '
      'resumed starts ELIGIBLE at generation 0 — preserves this file\'s own established setUp() baseline '
      'for every historical test',
      () async {
        expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed, reason: 'this file\'s own setUp() establishes this');
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          expect(localController.lifecycleEligibleForTest, isTrue);
          expect(localController.lifecycleGenerationForTest, 0);
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'I0-B (§39, MANDATORY GATE, independent-review P2-H fix — "I0-B foi classificado como impossível, '
      'mas o Flutter test binding possui resetInternalState() que restaura lifecycleState para null") — '
      'initial lifecycle, REAL null state: SchedulerBinding.resetInternalState() genuinely restores '
      'WidgetsBinding.instance.lifecycleState to null (not merely "detached", the nearest R4.3-R1 could '
      'reach); a controller constructed in that exact, genuinely-null state starts INELIGIBLE, emits ZERO '
      'native camera calls; the logical driving session still starts normally; a genuine resumed event '
      'then acquires the camera for the first time',
      () async {
        // Fase 16.2-R4.3-R2 (§39): a REAL API this file's own R4.3-R1 round
        // did not know about — genuinely resets the binding's own internal
        // state, not merely reaching the "nearest reproducible" ineligible
        // value (I0-A's own `detached`).
        TestWidgetsFlutterBinding.instance.resetInternalState();
        expect(
          WidgetsBinding.instance.lifecycleState,
          isNull,
          reason: 'resetInternalState() must genuinely restore the null, indeterminate default this test needs',
        );
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          expect(localController.lifecycleEligibleForTest, isFalse, reason: 'a genuinely null/indeterminate state must never authorize the camera');
          expect(localController.lifecycleGenerationForTest, 0);

          await preferences.setEnabled(true);
          final session = localController.startSession();
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(fakePlatform.calls, isEmpty, reason: 'zero native camera work while genuinely ineligible');
          expect(recorder.activeSession?.id, session.id, reason: 'the logical driving session still starts normally, independent of camera eligibility');

          // A genuine resumed event — the session must now automatically
          // acquire the camera for the first time.
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleEligibleForTest, isTrue);

          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(fakePlatform.calls, contains('initializeCamera'));
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          await drainLocal(localController, localService);
          // Restore a resumed binding state for any LATER test in this file
          // relying on this file's own setUp() baseline.
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
      },
    );

    test(
      'X1 (§8/§14, MANDATORY GATE, independent-review P1-1 EXACT regression — "raw claim precisa incluir '
      'generation") — the reviewer\'s own exact reproduction: G1\'s own raw initialize() is REALLY '
      'emitted and gated; lifecycle advances (G1 -> G2) BEFORE G1\'s own presentation timeout is even '
      'handled (not after, unlike L3); G1\'s own catch/hand-off then runs. Expected: attempt G1 != attempt '
      'G2 (a genuinely new attempt is created); G2 does NOT adopt raw G1 as its own — while G1\'s raw stays '
      'pending, the native initializeCamera count stays at 1 (G2 never emits before G1\'s settlement); once '
      'G1 resolves, G2 automatically emits its OWN, genuinely separate raw and reaches real recording — '
      'with ZERO manual retryCamera() call',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGateG1 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateG1;
          final attemptCountBefore = localController.cameraAttemptCreationCountForTest;

          localController.startSession();
          // Causal proof G1's own raw initialize() genuinely reached the
          // native call (now gated) — before its own presentation timeout
          // has any chance to fire.
          for (var i = 0; i < 200 && fakePlatform.calls.where((c) => c == 'initializeCamera').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(fakePlatform.calls, contains('initializeCamera'));
          expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1));

          // Fase 16.2-R4.3-R2 (§14 point 3/4, the EXACT reviewer scenario —
          // NOT waiting for the presentation timeout first, unlike L3):
          // lifecycle advances to G2 IMMEDIATELY, while G1's own raw is
          // still well within its own presentation deadline.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);

          // NOW let G1's own presentation timeout actually fire (50ms) —
          // its own catch/hand-off runs, discovering it is already stale.
          await Future<void>.delayed(const Duration(milliseconds: 80));

          // Fase 16.2-R4.3-R2 (§14 point 6/7, THE critical assertion): a
          // genuinely NEW attempt (G2) must have been created (never merely
          // G1's own, reused) — and, while G1's own raw is STILL pending
          // (gated), G2 must NOT have emitted its own initialize() —
          // proving it never adopted G1's raw as its own.
          expect(
            localController.cameraAttemptCreationCountForTest,
            attemptCountBefore + 2,
            reason: 'exactly two DISTINCT attempts must have been created — G1\'s own original, then G2\'s own, genuinely separate one',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(1),
            reason: 'G2 must NOT emit its own native initialize() while G1\'s own raw is still genuinely pending — it only waits on it as a barrier',
          );

          // G1's own raw initialize() FINALLY, genuinely resolves — late.
          initGateG1.complete();

          // G2 must automatically emit its OWN, genuinely separate raw and
          // reach real recording — ZERO manual retryCamera() call anywhere
          // in this test.
          await waitForStatus(DashcamStatus.recording, on: localController);

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(2),
            reason: 'G1\'s own (released, never adopted) + G2\'s own genuinely new, separate native initialize()',
          );
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGateG1.isCompleted) initGateG1.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X2 (§15, MANDATORY GATE, independent-review fix — "variante timeout enquanto ineligible") — G1\'s '
      'own raw initialize() is emitted and gated; the app backgrounds BEFORE G1\'s own presentation '
      'timeout fires; that timeout is then handled WHILE lifecycle is genuinely ineligible (raw stays '
      'pending). Expected: G1\'s own watcher exists (installed regardless of eligibility); no raw '
      'ownership is lost; ZERO new attempt/native call is emitted while still in background; once resumed, '
      'the CURRENT generation automatically registers/continues the desire; after G1 genuinely settles, '
      'recovery starts automatically and reaches real recording',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 50));
        final localController = buildLocalController(localService);
        final initGateG1 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGateG1;

          localController.startSession();
          for (var i = 0; i < 200 && fakePlatform.calls.where((c) => c == 'initializeCamera').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(fakePlatform.calls, contains('initializeCamera'));

          // The app backgrounds BEFORE G1's own presentation timeout has any
          // chance to fire — generation advances, eligibility drops.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          expect(localController.lifecycleEligibleForTest, isFalse);

          // NOW let G1's own presentation timeout fire WHILE still
          // genuinely ineligible.
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(
            localController.lateInitializeWatcherInstallCountForTest,
            1,
            reason: 'G1\'s own watcher must be installed regardless of eligibility — never skipped',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(1),
            reason: 'ZERO new attempt/native call must be emitted while still genuinely in background',
          );
          expect(
            localController.activeCameraAttemptSessionIdForTest,
            isNull,
            reason: 'the hand-off itself is a safe no-op while ineligible — nothing left claiming an active attempt slot',
          );

          // A genuine resumed event — the CURRENT generation must register/
          // continue the desire automatically (via _cameraAcquisitionNeeded,
          // never a status-based hack).
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(localController.lifecycleEligibleForTest, isTrue);

          // G1's own raw initialize() FINALLY, genuinely resolves — late,
          // only after resumed already registered the desire.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          initGateG1.complete();

          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localService.previewController?.value.isRecordingVideo, isTrue);

          await localController.stopSession();
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGateG1.isCompleted) initGateG1.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X3 (§18-§22, MANDATORY GATE, independent-review P1-2 EXACT regression — "baseline é da sessão, não '
      'do attempt") — the SAME logical session spans G1 (reaches a REAL, physically-started Recording, '
      'then its own targeted stale-cleanup STOP finalizes a genuine clip, WITHOUT ever reaching durable '
      'install) and G2 (resumes the FULL initial setup, per isInitial: !_initialSetupDone, and produces a '
      'second clip). The session\'s own clip baseline — captured exactly once, at session birth — must '
      'never be recaptured by G2\'s own _finishInitialStart: G1\'s own clip must be indexed into this '
      'session\'s own persisted record, never silently absorbed into a later-recaptured baseline',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final writerGateG1 = Completer<void>();
        final writerEnteredG1 = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final clipsBeforeSession = localService.clips.length;
          localController.openTelemetryWriterHookForTest = (writer, openCall) async {
            final realOpen = openCall();
            writerEnteredG1.complete();
            await writerGateG1.future;
            await realOpen;
          };
          final session = localController.startSession();

          // Causal proof G1's own native START genuinely succeeded (a real
          // Recording exists) before its own writer.open() boundary.
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'startVideoCapturing').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(fakePlatform.calls, contains('startVideoCapturing'));
          await writerEnteredG1.future.timeout(const Duration(seconds: 5));
          expect(localController.initialSetupInstallCountForTest, 0, reason: 'G1 has not durably installed yet — still mid writer.open()');

          // Lifecycle invalidates G1 WHILE its own writer.open() is still
          // pending.
          localController.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(Duration.zero);
          localController.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // G1's own writer.open() resolves — its own targeted stale-cleanup
          // now fires, issuing a STOP against its own, already-started
          // Recording — a REAL clip is produced.
          localController.openTelemetryWriterHookForTest = null;
          writerGateG1.complete();

          // G2 (hand-off) must resume the FULL initial setup — never merely
          // a recovery path — and reach genuine recording on its own.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(
            localController.initialSetupInstallCountForTest,
            1,
            reason: 'G2 must be the ONE genuine initial-setup install for this session — G1 never durably installed',
          );

          // Produce G2's own second clip via the session's own final stop.
          await localController.stopSession();
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
          // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
          // pass is awaited here, where this test reads what it wrote.
          await localController.clipIndexFollowUpsSettledForTest();

          expect(
            localService.clips.length - clipsBeforeSession,
            2,
            reason: 'G1\'s own targeted-cleanup clip and G2\'s own final clip — both real, both collected',
          );

          final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
          final indexed = List<DashcamClipRecord>.from(box.get(session.id) as List? ?? const []);
          expect(
            indexed,
            hasLength(2),
            reason: 'BOTH clips (G1\'s own, produced before durable install, and G2\'s own) must be indexed '
                'into this session\'s own persisted record — G1\'s clip must never be silently absorbed into '
                'a later-recaptured baseline',
          );
        } finally {
          localController.openTelemetryWriterHookForTest = null;
          if (!writerGateG1.isCompleted) writerGateG1.complete();
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.1 — late STOP native settlement to exact-session clip persistence ownership', () {
    test(
      'R2.1-X1 (§2/§12, MANDATORY GATE, independent-review gap — "late STOP to session persistence '
      'ownership") — session A\'s own explicit stop: the native STOP genuinely outlives its own '
      'presentation deadline (still retained, never abandoned/cancelled); stopSession(A) itself still '
      'returns bounded; the clip does NOT physically exist yet at that point; once the native STOP '
      'genuinely resolves, the clip appears in service.clips AND is indexed into session A\'s own Hive '
      'record exactly once — with NO later session ever needed to trigger it',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final clipsBeforeA = localService.clips.length;

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();

          // Causal proof the native STOP genuinely entered.
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(fakePlatform.calls, contains('stopVideoRecording'), reason: 'session A\'s own STOP must have genuinely entered the native call');

          // stopSession(A) itself still returns BOUNDED (its own
          // presentation deadline elapses) WHILE the native STOP stays
          // gated — proving this test genuinely crosses the defective
          // window (presentation resolution strictly before raw settlement).
          await stopFutureA;
          expect(
            localService.clips.length,
            clipsBeforeA,
            reason: 'the clip must NOT physically exist yet — the native STOP is still genuinely retained/gated',
          );
          final indexedDuringGate = List<DashcamClipRecord>.from(
            Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List? ?? const [],
          );
          expect(indexedDuringGate, isEmpty, reason: 'nothing to index yet — the clip has not been produced');

          // NOW resolve the native STOP — genuinely, for real.
          stopGateA.complete();
          for (var i = 0; i < 300 && localService.clips.length == clipsBeforeA; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(localService.clips.length, clipsBeforeA + 1, reason: 'the clip must now physically, genuinely exist');

          // The late continuation must persist it into session A's own
          // record — poll for the async Hive write; NO session B involved.
          List<DashcamClipRecord> indexedAfter = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedAfter = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedAfter.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedAfter, hasLength(1), reason: 'session A\'s own late clip must be indexed under A\'s own id, exactly once');
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.1-X2 (§3/§13, MANDATORY GATE, independent-review gap) — session A\'s own native STOP is still '
      'genuinely pending when session B is requested; B\'s own initialize() is genuinely queued BEHIND '
      'A\'s own still-in-flight enqueued operation (DashcamService\'s own established FIFO — unchanged), '
      'so B only reaches recording once A\'s own late STOP genuinely settles. Clip A must be indexed ONLY '
      'under A\'s own Hive record, never under B\'s; clip B remains indexed only under B\'s own record',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          // stopSession(A) itself still returns bounded, WHILE A's own
          // native STOP stays gated — A's own enqueued operation (still
          // running, still awaiting the gate deep inside it) keeps
          // DashcamService's own FIFO occupied.
          await stopFutureA;

          // Session B is requested WHILE A's native STOP is still genuinely
          // pending/gated — per DashcamService's own established FIFO
          // (R4.2A, unchanged), B's own initialize() cannot progress past
          // releasing the prior controller until A's own still-in-flight
          // enqueued operation (the gated STOP itself) finishes.
          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(sessionA.id));
          // Fase 16.2-R4.3-R2.6 (§48, test-only fragility fix — independent
          // review: "R2.1-X2 ainda usa fixed delayed(30ms) para provar que B
          // não gravou, sem provar causalmente que B atingiu sua barrier"): a
          // fixed sleep proves nothing about WHERE B is. Poll for the causal
          // evidence instead — B's own raw initialize() exists (B passed A's
          // stop barrier and reached DashcamService) while A's native STOP is
          // still pending (so that initialize() is genuinely queued behind it)
          // — and only then assert B has not recorded.
          for (var i = 0; i < 300 && localService.pendingInitializeSettlement == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(localService.pendingInitializeSettlement, isNotNull, reason: 'B reached its barrier: its raw initialize() is registered and queued');
          expect(localService.hasPendingNativeStop, isTrue, reason: 'A\'s native STOP is still pending — the FIFO barrier B waits behind');
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'B has not created its own camera — only A\'s exists');
          expect(
            localController.status,
            isNot(DashcamStatus.recording),
            reason: 'B must still be queued behind A\'s own gated native STOP, not yet recording',
          );

          // Resolve A's own late STOP now — genuinely, for real. This frees
          // A's own queue slot, letting B\'s own initialize() finally proceed.
          stopGateA.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(recorder.activeSession?.id, sessionB.id);

          // Wait for A's own late clip to be indexed under A's own id.
          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(1), reason: 'session A\'s own late clip must be indexed under A\'s own id');

          // Stop B normally — produces its own clip. B's own stop is bound by
          // the SAME short stopVideoRecordingTimeout as A's (§13/§18 above)
          // — under heavy full-suite load, B's own real native STOP can
          // genuinely outlive that presentation deadline too, exactly the
          // late-settlement scenario this test's own title is about for A.
          // Fase 16.2-R4.3-R2.6-EVIDENCE-FINAL (§2/§3, test-fragility fix —
          // reproduced 1/6 under `--test-randomize-ordering-seed=42`
          // full-suite runs, never in isolation/standalone or with any other
          // seed tried — see EVIDENCE_CLOSURE_R2_6.md §6/EVIDENCE_FINAL_R2_6.md
          // for the full diagnosis): the ORIGINAL version of this assertion
          // read Hive exactly once, UNGUARDED, immediately after
          // stopSession() returned — asymmetric with A's own already-correct
          // poll two blocks above, and exactly the "presentation resolved,
          // late persistence still catching up" window B's own stop can land
          // in under load. Fixed the same way A's already is: bounded,
          // objective-deadline poll (this file's own established idiom,
          // already used by every other late-persistence assertion in this
          // suite) — never an unbounded wait, never "keep retrying until it
          // passes" (an exhausted loop still fails the `expect` below, loudly
          // and promptly, exactly like A's own).
          final stopsBeforeB = fakePlatform.calls.where((c) => c == 'stopVideoRecording').length;
          await localController.stopSession();
          // Causal proof B's own native STOP was genuinely EXERCISED, not
          // merely "eventually some Hive entry showed up": beginStopLoopRecording()
          // issues the raw native call synchronously, before stopSession()'s
          // own presentation-bounded wait even begins (see DashcamService's
          // own doc), so this is already true the instant stopSession()
          // returns — asserted explicitly so a genuine regression ("B's own
          // STOP never issued at all") fails HERE, distinctly, rather than
          // being indistinguishable from "issued, persistence still late"
          // three lines below.
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording').length,
            stopsBeforeB + 1,
            reason: 'B\'s own native STOP must have been issued by the time stopSession() returns, even though it is bound only by presentation, not by real settlement',
          );
          List<DashcamClipRecord> indexedB = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
            indexedB = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedB.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            indexedB,
            hasLength(1),
            reason: 'session B\'s own clip must be indexed under B\'s own id, exactly once — including when its own native STOP genuinely outlives its own presentation deadline under load, exactly like A\'s already does above',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(2),
            reason: 'exactly one START for A\'s own Recording and one for B\'s — no duplicate/undue START on either side',
          );

          expect(
            indexedA.single.filePath,
            isNot(indexedB.single.filePath),
            reason: 'A and B must never share the same clip file path in either record — no cross-attribution either direction',
          );
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.1-X3 (§16, MANDATORY GATE, independent-review gap) — session A\'s own native STOP genuinely '
      'outlives its own presentation deadline (stopSession(A) itself already returned bounded), then '
      'ultimately terminates in FAILURE (not success) once it finally settles: zero phantom clip path — '
      'nothing is ever indexed; the failure is reported exactly once as recordingResult (never poisons the '
      'CURRENT camera); no hang; the process owner/native obligation converge normally afterward',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        StreamSubscription<DashcamServiceError>? typedSub;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final clipsBeforeA = localService.clips.length;

          final typedScopes = <DashcamServiceErrorScope>[];
          typedSub = localService.originatedErrors.listen((e) => typedScopes.add(e.scope));

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          // Bounded return, WHILE the native STOP stays gated.
          await stopFutureA;
          expect(localService.clips.length, clipsBeforeA, reason: 'nothing produced yet');

          // The native STOP now, genuinely, ultimately FAILS (not succeeds).
          stopGateA.completeError(CameraException('native_stop_failed', 'forced late STOP failure for R2.1-X3'));

          // No hang — the process eventually converges (owner free, no
          // pending native stop left).
          await waitForServiceSettled(localService);

          expect(localService.clips.length, clipsBeforeA, reason: 'zero phantom clip — the failed STOP must never fabricate one');
          final indexedA = List<DashcamClipRecord>.from(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List? ?? const []);
          expect(indexedA, isEmpty, reason: 'zero phantom path — nothing to index for a STOP that never produced a real clip');
          expect(
            typedScopes,
            contains(DashcamServiceErrorScope.recordingResult),
            reason: 'the late STOP failure must be reported as recordingResult — this Recording\'s own outcome',
          );
          expect(
            localController.status,
            isNot(DashcamStatus.error),
            reason: 'a recordingResult-scoped late failure for an already-finished session must not retroactively poison anything',
          );
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await typedSub?.cancel();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.1-X4 (§18, dispose behavior audit) — session A\'s own native STOP is still genuinely pending '
      'when this controller is disposed: the late continuation must still complete session A\'s own '
      'historical indexing (this is A\'s own already-ended session\'s history, not live UI state) — no '
      'ChangeNotifier-after-dispose error, no crash, no hang',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          // Bounded return, WHILE the native STOP stays gated.
          await stopFutureA;

          // Dispose THIS controller WHILE session A's own native STOP is
          // still genuinely pending — must not crash, must not touch a
          // disposed ChangeNotifier.
          expect(() => localController.dispose(), returnsNormally);

          // Resolve A's own late STOP now — genuinely, for real.
          stopGateA.complete();

          // The late continuation must still complete session A's own
          // historical indexing despite this controller's own disposal.
          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            indexedA,
            hasLength(1),
            reason: 'session A\'s own late clip is its own history — disposal of the (unrelated, live-UI-facing) '
                'ChangeNotifier must not prevent it from being indexed',
          );
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.2 — exact-session persistence transaction: early context capture, atomic clip claim', () {
    test(
      'R2.2-X6 (§16/§48, MANDATORY GATE, independent-review P1 exact reproduction — "baseline A '
      'substituído por B") — session A\'s own native STOP has already, genuinely, fully settled (the '
      'clip physically exists); execution is paused right BEFORE A\'s own immediate persistence pass; a '
      'REAL startSession() for B lands in that exact window, replacing the shared "current session" '
      'baseline/context; A then resumes. Expected: A\'s own clip is indexed under A\'s own id — never '
      'silently redirected onto B\'s own baseline/record',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final gate = Completer<void>();
        final entered = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.beforeImmediatePersistenceHookForTest = () async {
            if (!entered.isCompleted) entered.complete();
            await gate.future;
          };

          final stopFutureA = localController.stopSession();
          // Causal proof: this hook only ever runs AFTER A's own native STOP
          // has genuinely resolved (see its own doc) — no artificial native
          // gate is used here at all.
          await entered.future.timeout(const Duration(seconds: 5));
          expect(
            Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id),
            isNull,
            reason: 'test setup check: A\'s own immediate persistence pass has not run yet',
          );

          // A REAL startSession() for B, landing exactly in this window.
          //
          // Fase 16.2-R4.3-R2.2 (independent-review audit finding): B's own
          // CAMERA acquisition ([_startCamera]) cannot itself progress past
          // this point — it structurally waits for THIS session's own
          // [_stopCameraFuture] first (a pre-existing Fase 15 guard,
          // unchanged/frozen this round — see [_startCamera]'s own doc).
          // What CAN and does race ahead, synchronously, inside
          // [startSession] itself, BEFORE that wait is ever reached, is B's
          // own baseline/[_SessionPersistenceContext] creation (via
          // [_ensureClipsBaselineForSession]) — exactly the reviewer's own
          // reproduction: it is THIS moment, not B's eventual recording,
          // that threatens to silently redirect A's own still-pending
          // immediate persistence pass onto B's baseline.
          //
          // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): the recorder closes A
          // concurrently with this camera-side window; B used to start without
          // waiting for it, and with a slower recorder finalization
          // startSession() is REFUSED ("still being ended") before the race
          // exists (found by delaying only the recorder's finalization, T-Rm
          // 05_hardened/recorder_latent). B starts once A is over as a driving
          // session (canStartSession), A's immediate pass still held.
          await waitForCondition(() => localController.canStartSession, 'A closed by the recorder, its immediate pass still held');
          expect(gate.isCompleted, isFalse, reason: 'test setup check: A\'s immediate persistence pass is still held');
          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(sessionA.id));

          // A resumes. This also, structurally, is what unblocks B's own
          // [_startCamera] (paused on THIS session's [_stopCameraFuture]) to
          // finally proceed with its own, separate camera acquisition.
          localController.beforeImmediatePersistenceHookForTest = null;
          gate.complete();
          await stopFutureA;
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
          // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
          // pass is awaited here, where this test reads what it wrote.
          await localController.clipIndexFollowUpsSettledForTest();

          final rawA = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
          final indexedA = rawA == null ? const <DashcamClipRecord>[] : List<DashcamClipRecord>.from(rawA);
          expect(indexedA, hasLength(1), reason: 'A\'s own clip must be indexed under A\'s own id, never silently absorbed by B\'s baseline');

          // B genuinely, separately reaches recording now that A has
          // concluded.
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localService.previewController?.value.isRecordingVideo, isTrue);
          expect(recorder.activeSession?.id, sessionB.id);

          final rawBDuring = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
          final indexedBDuring = rawBDuring == null ? const <DashcamClipRecord>[] : List<DashcamClipRecord>.from(rawBDuring);
          expect(indexedBDuring, isEmpty, reason: 'B must not have claimed A\'s own clip');

          // B still works normally afterward.
          await localController.stopSession();
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
          // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
          // pass is awaited here, where this test reads what it wrote.
          await localController.clipIndexFollowUpsSettledForTest();
          final rawB = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
          final indexedB = rawB == null ? const <DashcamClipRecord>[] : List<DashcamClipRecord>.from(rawB);
          expect(indexedB, hasLength(1), reason: 'B\'s own clip must still be indexed under B\'s own id');
          expect(indexedA.single.filePath, isNot(indexedB.single.filePath));
        } finally {
          localController.beforeImmediatePersistenceHookForTest = null;
          if (!gate.isCompleted) gate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.2-X7 (§18/§49, MANDATORY GATE, independent-review P1 — "atomic clip claim, A-late vs '
      'B-immediate") — session A\'s own late STOP settlement resolves and its own late continuation '
      'claims + begins writing its own clip into Hive, but that Hive write itself is held open; while it '
      'is still open, session B starts, records, and stops quickly for real, running its OWN immediate '
      'persistence pass WHILE A\'s own write is still in flight. Expected: B never claims/indexes A\'s '
      'own path (the claim happened synchronously, before any await, well before A\'s own write even '
      'started); once A\'s own write is released, A\'s Hive record contains its own path exactly once, '
      'B\'s Hive record contains only its own',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        final writeGateA = Completer<void>();
        final writeEnteredA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            final realWrite = writeCall();
            if (sessionId == sessionA.id) {
              if (!writeEnteredA.isCompleted) writeEnteredA.complete();
              await writeGateA.future;
            }
            await realWrite;
          };

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          // A's own native STOP outlives its presentation deadline — bounded
          // return, gate still held.
          await stopFutureA;

          // Resolve A's own late STOP for real — its own late continuation
          // claims A's path synchronously and enters the (now gated) write.
          stopGateA.complete();
          await writeEnteredA.future.timeout(const Duration(seconds: 5));

          // Session B starts, records, and stops quickly for real — WHILE
          // A's own Hive write is still held open.
          final sessionB = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
          // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: B's
          // pass is awaited here — B's only: A's is held by this test's own gate on purpose.
          await localController.clipIndexFollowUpsSettledForTest(sessionId: sessionB.id);

          final rawBDuring = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
          final indexedBDuring = rawBDuring == null ? const <DashcamClipRecord>[] : List<DashcamClipRecord>.from(rawBDuring);
          expect(indexedBDuring, hasLength(1), reason: 'B\'s own immediate pass must have already persisted its OWN clip');

          // Release A's own held-open write now.
          writeGateA.complete();
          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(1), reason: 'A\'s own late clip must be indexed exactly once, under A\'s own id');

          final rawB = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
          final indexedB = rawB == null ? const <DashcamClipRecord>[] : List<DashcamClipRecord>.from(rawB);
          expect(indexedB, hasLength(1), reason: 'B\'s own record must still contain only its own clip — never A\'s');
          expect(
            indexedA.single.filePath,
            isNot(indexedB.single.filePath),
            reason: 'B must never have claimed/indexed A\'s own path, even though B\'s own immediate pass ran WHILE A\'s write was still in flight',
          );
        } finally {
          localController.persistClipIndexHookForTest = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          if (!writeGateA.isCompleted) writeGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.2-X8 (§19, complementary interleaving) — session A\'s own late continuation claims and begins '
      'writing its own clip (Hive write held open); session B\'s own STOP is ALSO genuinely late/gated, '
      'and its own late continuation reaches its own claim/write attempt WHILE A\'s own write is still '
      'in flight and B\'s own baseline predates A\'s clip (so B would otherwise treat it as "new"). '
      'Expected: B\'s own late continuation still cannot claim A\'s own path — ownership is decided by '
      'claim order, not by which write happens to finish first',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        final stopGateB = Completer<void>();
        final writeGateA = Completer<void>();
        final writeEnteredA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            final realWrite = writeCall();
            if (sessionId == sessionA.id) {
              if (!writeEnteredA.isCompleted) writeEnteredA.complete();
              await writeGateA.future;
            }
            await realWrite;
          };

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await stopFutureA;

          // B starts WHILE A's own native STOP is still gated — B's own
          // baseline is captured now, BEFORE A's own clip physically exists.
          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(sessionA.id));

          // Resolve A's own late STOP — its own late continuation claims A's
          // path synchronously and enters the (now gated) write.
          stopGateA.complete();
          await writeEnteredA.future.timeout(const Duration(seconds: 5));

          // B only reaches recording once A's own gated native STOP (the
          // enqueued operation ahead of it in DashcamService's own FIFO)
          // finishes — already resolved above.
          await waitForStatus(DashcamStatus.recording, on: localController);

          // Now make B's OWN STOP late/gated too, and stop B — its own late
          // continuation will attempt to claim/persist WHILE A's own write
          // is still held open, with a baseline that predates A's clip.
          fakePlatform.pendingStopVideoRecording = stopGateB;
          final stopFutureB = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await stopFutureB;
          stopGateB.complete();

          // Let B's own late continuation genuinely run its own claim
          // attempt while A's write is still gated.
          await Future<void>.delayed(const Duration(milliseconds: 50));

          // Release A's own held-open write now.
          writeGateA.complete();

          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(1), reason: 'A\'s own late clip must be indexed exactly once, under A\'s own id');

          List<DashcamClipRecord> indexedB = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
            indexedB = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedB.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedB, hasLength(1), reason: 'B\'s own late clip must be indexed exactly once, under B\'s own id');
          expect(
            indexedA.single.filePath,
            isNot(indexedB.single.filePath),
            reason: 'B\'s own late continuation must never have captured A\'s own path, regardless of which write finishes first',
          );
        } finally {
          localController.persistClipIndexHookForTest = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          if (!stopGateB.isCompleted) stopGateB.complete();
          if (!writeGateA.isCompleted) writeGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.2-X11 (§14/§38, MANDATORY GATE) — late Hive write failure: session A\'s own native STOP '
      'settlement succeeds for real, but the persistence layer\'s own Hive write then fails. Expected: '
      'zero unhandled async error; the failure is observed exactly once, scoped recordingResult; the '
      'CURRENT camera/session stays healthy; the claim is rolled back (not left as a permanent zombie) — '
      'a LATER session is free to claim the same path if it should ever be a candidate again',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            throw StateError('forced Hive write failure for R2.2-X11');
          };

          final typedErrors = <DashcamServiceError>[];
          final typedSub = localService.originatedErrors.listen(typedErrors.add);
          // Fase 16.2-R4.3-R2.5 (§55, test-only): released even if an assertion below fails
          // before the explicit cancel — no leaked listener into the next test.
          addTearDown(typedSub.cancel);

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await stopFutureA;
          stopGateA.complete();

          // Let the late continuation genuinely run its (forced-failing)
          // persistence attempt.
          for (var i = 0; i < 300 && typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult).isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await typedSub.cancel();

          expect(
            typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult),
            isNotEmpty,
            reason: 'the Hive write failure must be observed exactly once, scoped recordingResult',
          );
          expect(
            Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id),
            isNull,
            reason: 'zero phantom index entry — the write genuinely failed',
          );
          expect(localController.status, isNot(DashcamStatus.error), reason: 'a recordingResult-scoped failure must never poison the CURRENT camera/session');

          // The claim must have been rolled back — a fresh session recorded
          // afterward must still be able to record/persist normally (proves
          // no permanent zombie state was left behind). The forced-failure
          // hook is no longer needed for this part.
          localController.persistClipIndexHookForTest = null;
          final sessionB = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
          // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
          // pass is awaited here, where this test reads what it wrote.
          await localController.clipIndexFollowUpsSettledForTest();
          final rawB = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
          expect(rawB, isNotNull, reason: 'a later session must still be able to persist normally after an earlier claim rollback');
        } finally {
          localController.persistClipIndexHookForTest = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.2-X11b (§40, immediate-pass Hive write failure) — the SAME failure/rollback/observability '
      'contract as R2.2-X11, but for the IMMEDIATE persistence pass (native STOP resolves within its own '
      'presentation deadline, no lateness involved at all)',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            throw StateError('forced immediate Hive write failure for R2.2-X11b');
          };

          final typedErrors = <DashcamServiceError>[];
          final typedSub = localService.originatedErrors.listen(typedErrors.add);
          // Fase 16.2-R4.3-R2.5 (§55, test-only): released even if an assertion below fails
          // before the explicit cancel — no leaked listener into the next test.
          addTearDown(typedSub.cancel);

          await localController.stopSession();
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
          // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
          // pass is awaited here, where this test reads what it wrote.
          await localController.clipIndexFollowUpsSettledForTest();
          await typedSub.cancel();

          expect(
            typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult),
            isNotEmpty,
            reason: 'the immediate-pass Hive write failure must be observed exactly once, scoped recordingResult',
          );
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id), isNull, reason: 'zero phantom index entry');
          expect(localController.status, isNot(DashcamStatus.error));

          localController.persistClipIndexHookForTest = null;
          final sessionB = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
          // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
          // pass is awaited here, where this test reads what it wrote.
          await localController.clipIndexFollowUpsSettledForTest();
          final rawB = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
          expect(rawB, isNotNull, reason: 'a later session must still be able to persist normally after an earlier claim rollback');
        } finally {
          localController.persistClipIndexHookForTest = null;
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.2-X12 (§10/§42/§50, MANDATORY GATE, Checkpoint C — "fast STOP handle") — the native STOP '
      'begins and settles essentially immediately (no gate at all). Even so, the caller (this session\'s '
      'own _stopCamera) still ends up with a correct, immutable handle/settlement, and its own clip is '
      'persisted correctly — production never depends on reading DashcamService.pendingStopHandle again '
      'after the fact',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          // No native gate of any kind — the STOP resolves as fast as this
          // fake platform can make it.
          await localController.stopSession();

          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(1), reason: 'a fast-settling STOP must still result in exactly-once persistence, correctly attributed to A');
          expect(localService.hasPendingNativeStop, isFalse, reason: 'nothing left pending after a genuinely fast settle');
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.2-memory (§24, structural boundedness) — N sequential sessions, each producing and persisting '
      'its own clip, leave [claimedPathOwnersCountForTest] bounded by however many clips currently exist '
      '(never growing proportionally to the total number of sessions this controller has ever recorded). '
      'Uses a near-zero storage quota so DashcamService\'s own established eviction genuinely deletes old '
      'clips during the run — otherwise this app\'s own generous default quota would keep every tiny fake '
      'clip on disk regardless, making this test prove nothing about [_pruneClaimedPathOwners] itself',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 0,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          const sessionCount = 12;
          for (var i = 0; i < sessionCount; i++) {
            final session = localController.startSession();
            await waitForStatus(DashcamStatus.recording, on: localController);
            await localController.stopSession();
            // R4.4-R2.1.1-F1 — ANTES: each stopSession() returned after its STOP's index pass, so each clip was
            // indexed — and the quota pass queued behind its write was ahead of the next session's write — before
            // the next session started. MOTIVO: that pass is no longer awaited by the STOP (RES-1); with a slower
            // index the twelve sessions outran their writes and no quota pass had pruned yet (independent review,
            // F1). DEPOIS: R2.2-memory awaits each session's own passes before the next one — the same sequence.
            await localController.clipIndexFollowUpsSettledForTest(sessionId: session.id);
          }
          expect(
            localController.claimedPathOwnersCountForTest,
            lessThanOrEqualTo(localService.clips.length + 1),
            reason: 'the claim registry must stay bounded by however many clips currently exist on disk (plus at '
                'most one very recent write still settling), never by total sessions ever recorded ($sessionCount)',
          );
          expect(
            localController.claimedPathOwnersCountForTest,
            lessThan(sessionCount),
            reason: 'after $sessionCount sequential sessions under an aggressively-evicting quota, the claim '
                'registry must not have grown one-for-one with session count',
          );
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.3-memory-precise (§18/§36, strengthened — "claim existente → eviction → prune", the exact '
      'sequence the previous round\'s own memory test only proved in aggregate, across an aggressively-'
      'evicting quota, never step by step) — session A\'s own clip is claimed (registry length 1) under '
      'a GENEROUS quota; the quota is THEN tightened (updateConfig, taking effect only once quota '
      'enforcement next actually runs — never retroactively); session B\'s own STOP is what triggers '
      'real enforcement, physically evicting A\'s own clip file; session B\'s own persistence pass is '
      'what then runs [_pruneClaimedPathOwners] — and ONLY at that point does A\'s own claim entry '
      'disappear',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);

          // Session A: generous quota — its own clip survives.
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();

          expect(localService.clips, hasLength(1), reason: 'test setup check: A\'s own clip physically exists');
          expect(localController.claimedPathOwnersCountForTest, 1, reason: 'A\'s own clip is genuinely claimed');

          // Tighten the quota — takes effect only once enforcement next
          // actually runs (never retroactively touches A's already-existing
          // clip on its own).
          localService.updateConfig(
            DashcamConfig(
              cameraSelection: CameraSelection.rear,
              storageQuotaMb: 0,
              audioEnabled: false,
              resolution: VideoResolution.hd720,
              frameRate: 30,
              enabled: true,
            ),
          );
          expect(localController.claimedPathOwnersCountForTest, 1, reason: 'tightening the quota alone must not retroactively prune anything — enforcement has not run yet');

          // Fase 16.2-R4.4-R2 — ADAPTED (owner decision O4; D0 RK2).
          // BEFORE: B's STOP ran the service's in-FIFO quota, which evicted
          //   every clip (A's and B's own): `clips` empty, no claim left.
          // WHY superseded: the quota never evicts the newest clip, and its
          //   effective value is at least two segments (D0 §9); it runs after
          //   each published clip is indexed, in the index FIFO, and the
          //   eviction drops the clip's claim in the same slice.
          // AFTER: B's clip makes two segments — within the effective quota,
          //   nothing evicted, A's claim still there. C's clip makes three: its
          //   pass evicts A (the oldest), A's file and claim go, B and C stay.
          // NEGATIVE CONTROL: newest evictable (M3) → C's or B's file goes;
          //   eviction without the claim prune → A's claim stays.
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          await storagePassesSettled();
          expect(localService.clips, hasLength(2), reason: 'two segments: within Q_eff = max(0, 2 × segment) — nothing evicted');
          expect(localController.claimedPathOwnersCountForTest, 2, reason: 'no eviction, no prune: A\'s claim is still there');
          final pathA = localService.clips.first.file.path;

          // Session C: its clip is the third segment — the pass after it is
          // what evicts A's own (now over-quota) clip file for real.
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          await storagePassesSettled();

          expect(File(pathA).existsSync(), isFalse, reason: 'the oldest clip — A\'s — was genuinely evicted from the disk');
          expect(localService.clips.map((c) => c.file.path), isNot(contains(pathA)));
          expect(localService.clips, hasLength(2), reason: 'B and C stay: the newest is immune and two segments fit');
          expect(
            localController.ownerOfPathForTest(pathA),
            isNull,
            reason: 'the eviction dropped A\'s claim in the same step — only at that point does it disappear',
          );
          expect(localController.claimedPathOwnersCountForTest, 2);
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.3 — preexisting STOP attachment + persistence error exactly-once', () {
    test(
      'X13 (§11/§38, MANDATORY GATE, independent-review P1-A exact reproduction — "preexisting STOP '
      'obligation lost") — some OTHER "stale/cleanup G1" caller (represented directly here by a raw '
      'DashcamService.stopLoopRecording() call — the reviewer\'s own P1-A is a property of '
      'beginStopLoopRecording() itself, independent of WHICH caller reaches it first) has ALREADY '
      'claimed the intent to stop A\'s current segment and genuinely reached the native '
      'stopVideoRecording() call (now gated) — `_isRecording` is already false, a real '
      '_PendingNativeStop already exists for G1 — when the public stopSession() is called in exactly '
      'that window, it must ADOPT G1\'s own existing obligation (never conclude "nothing is '
      'recording"), never emit a second, duplicate native STOP, and the ONE physical clip G1\'s own '
      'STOP produces must end up indexed in A\'s own Hive record exactly once',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        final localController = buildLocalController(localService);
        final stopGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final recordingIdG1 = localService.activeRecordingId;
          final controllerG1 = localService.previewController;
          expect(recordingIdG1, isNotNull);

          // "Cleanup G1": some OTHER caller (independent of stopSession())
          // already claims the intent to stop this exact Recording and
          // genuinely reaches the native call — now gated.
          fakePlatform.pendingStopVideoRecording = stopGate;
          unawaited(localService.stopLoopRecording(expectedRecordingId: recordingIdG1, expectedController: controllerG1));
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(fakePlatform.calls, contains('stopVideoRecording'), reason: 'G1\'s own cleanup must have genuinely reached its own native STOP');

          // The exact preexisting-obligation state the reviewer's own P1-A
          // reproduction describes.
          expect(localService.isRecording, isFalse, reason: '_isRecording already false — G1\'s own cleanup already claimed the intent to stop this Recording');
          expect(localService.hasPendingNativeStop, isTrue, reason: 'a REAL native STOP is genuinely, physically pending for G1');
          expect(localService.activeRecordingId, recordingIdG1, reason: 'the pending STOP concerns the SAME Recording identity');

          // The public stopSession() call, issued PUBLICLY, in exactly this
          // window.
          final stopFuture = localController.stopSession();

          // No duplicate native STOP is ever emitted while G1's own real
          // one stays gated.
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'stopSession() must ADOPT G1\'s own existing STOP obligation, never emit a second, independent native STOP',
          );
          expect(localService.previewController, same(controllerG1), reason: 'G1\'s own controller is untouched while its own real STOP is still gated');

          final clipsBefore = localService.clips.length;
          stopGate.complete();
          await stopFuture;

          expect(localService.clips.length, clipsBefore + 1, reason: 'the ONE physical clip G1\'s own STOP produces must now genuinely exist');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'still exactly one native STOP total, for the whole scenario');

          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(1), reason: 'G1\'s own physical clip must be indexed under session A\'s own id exactly once — never lost, never left as an untracked orphan file');
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGate.isCompleted) stopGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X13-B (§7/§13, announced but not materialized) — TWO calls to '
      'DashcamService.beginStopLoopRecording() land back-to-back, synchronously, with no `await` in '
      'between: the FIRST claims the shared stop announcement and enqueues its own closure (not yet '
      'run); the SECOND, targeted at the exact same Recording/controller, must adopt that SAME '
      'announcement rather than concluding nothing exists yet — never a second, independent native STOP',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        try {
          await localService.initialize();
          await localService.startLoopRecording();
          final controllerG1 = localService.previewController!;
          final recordingIdG1 = localService.activeRecordingId;

          final outcome1 = localService.beginStopLoopRecording();
          // Causal proof: outcome1's own enqueued closure has not run yet —
          // only announced, not yet materialized.
          expect(localService.hasPendingNativeStop, isFalse, reason: 'test setup check: outcome1\'s own closure has not had a chance to run yet');
          final outcome2 = localService.beginStopLoopRecording(expectedRecordingId: recordingIdG1, expectedController: controllerG1);

          final handle2 = await outcome2.handle.timeout(const Duration(seconds: 2));
          expect(handle2, isNotNull, reason: 'outcome2 must adopt the SAME announcement outcome1 already claimed');
          expect(handle2!.recordingId, recordingIdG1);
          expect(identical(handle2.controller, controllerG1), isTrue);

          await outcome1.presentation;
          await outcome2.presentation;
          await handle2.settlement;

          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'exactly one native STOP total — both calls resolved to the SAME real operation');
          expect(localService.clips, hasLength(1));
        } finally {
          await localService.dispose().catchError((_) {});
        }
      },
    );

    test(
      'X15 (§28/§38, MANDATORY GATE, exact count — "immediate Hive failure exactly-once") — the '
      'IMMEDIATE persistence pass\'s own Hive write fails (native STOP resolves within its own '
      'presentation deadline, no lateness involved at all). Expected: recordingResult error count for '
      'this failure is EXACTLY 1 — never repeated by the redundant late-settlement watcher this class\'s '
      'own R4.3-R2.2 design still installs even for an already-settled STOP',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          var writeAttempts = 0;
          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            writeAttempts++;
            throw StateError('forced immediate Hive write failure for X15');
          };

          final typedErrors = <DashcamServiceError>[];
          final typedSub = localService.originatedErrors.listen(typedErrors.add);
          // Fase 16.2-R4.3-R2.5 (§55, test-only): released even if an assertion below fails
          // before the explicit cancel — no leaked listener into the next test.
          addTearDown(typedSub.cancel);

          await localController.stopSession();
          // R4.4-R2.1.1-F1 — ANTES: stopSession() returned after the immediate pass (its retry waits for the
          // publication's write), so the 100 ms below only had to cover the late pass. MOTIVO: no pass is awaited by
          // the STOP any more (RES-1); with a slower index the 100 ms ran out before the three attempts (independent
          // review, F1). DEPOIS: X15 awaits A's passes — immediate and late, each after the write before it — and the
          // 100 ms below is left to what it is for: a retry that must not happen.
          await localController.clipIndexFollowUpsSettledForTest(sessionId: sessionA.id);
          // Give any (incorrect) redundant retry a real chance to happen —
          // the late-settlement watcher, if it were to wrongly re-attempt,
          // would do so within a handful of microtasks/short delays, not
          // require a long wait.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await typedSub.cancel();

          final recordingResultErrors = typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult).toList();
          expect(recordingResultErrors, hasLength(1), reason: 'exactly one recordingResult report for this ONE failed path — never repeated by a redundant late pass');
          // Fase 16.2-R4.4-R1 (adapted — see the R4.4-R1 report, TESTES
          // ADAPTADOS): a clip not yet indexed is RETRIED by every in-process
          // trigger that meets it — its segment's publication, the STOP's
          // immediate pass, the late pass — never by a timer or a loop; the
          // failure is still reported once. Until R1 the stop's passes excluded
          // a path they had failed on, so the hook ran once.
          expect(writeAttempts, 3, reason: 'one attempt per in-process trigger (publication, immediate pass, late pass) — and none after them');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id), isNull, reason: 'zero phantom index entry');
          expect(localController.status, isNot(DashcamStatus.error));
        } finally {
          localController.persistClipIndexHookForTest = null;
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X16 (§29/§38, MANDATORY GATE, exact count — "late Hive failure exactly-once") — the clip only '
      'appears once the native STOP\'s own real settlement resolves (late, past the presentation '
      'deadline); the late continuation\'s own Hive write fails. Expected: recordingResult error count '
      'for this failure is EXACTLY 1',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          var writeAttempts = 0;
          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            writeAttempts++;
            throw StateError('forced late Hive write failure for X16');
          };

          final typedErrors = <DashcamServiceError>[];
          final typedSub = localService.originatedErrors.listen(typedErrors.add);
          // Fase 16.2-R4.3-R2.5 (§55, test-only): released even if an assertion below fails
          // before the explicit cancel — no leaked listener into the next test.
          addTearDown(typedSub.cancel);

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await stopFutureA;
          stopGateA.complete();

          for (var i = 0; i < 300 && typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult).isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          // Give any (incorrect) duplicate attempt a real chance to happen.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await typedSub.cancel();

          final recordingResultErrors = typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult).toList();
          expect(recordingResultErrors, hasLength(1), reason: 'exactly one recordingResult report for this ONE failed path');
          // Fase 16.2-R4.4-R1 (adapted — see X15 and the R4.4-R1 report): the
          // immediate pass ran before this clip existed, so its triggers are its
          // publication and the late pass.
          expect(writeAttempts, 2, reason: 'one attempt per in-process trigger that met the clip (publication, late pass) — and none after them');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id), isNull, reason: 'zero phantom index entry');
          expect(localController.status, isNot(DashcamStatus.error));
        } finally {
          localController.persistClipIndexHookForTest = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.4 — durable announcement resolution, session-level (P1-A #2)', () {
    test(
      'X17 (§13/§14, session-level persistence completion) — G1 settles session A normally; a fresh '
      'recording G2 is then started with its own native START gated (occupying the FIFO); an '
      'unqualified stop is announced and enqueued behind it; a second caller adopts that announcement '
      'with a short stopVideoRecordingTimeout — its own handle must NOT resolve to null just because '
      'presentation timed out. Once the FIFO frees and G2\'s own STOP genuinely materializes, the '
      'adopter receives the real handle, and once session A is finally closed via stopSession(), BOTH '
      'G1\'s and G2\'s own physical clips must end up indexed under session A exactly once each — no '
      'clip is ever lost to the expired presentation deadline',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final recordingIdG1 = localService.activeRecordingId;
          final controllerG1 = localService.previewController;
          expect(recordingIdG1, isNotNull);

          // G1 ends normally — first physical clip. Fase 16.2-R4.4-R1-T-Rm (R-m,
          // test-only): see [stopNormally].
          await stopNormally(localService, () => localService.stopLoopRecording(expectedRecordingId: recordingIdG1, expectedController: controllerG1));
          expect(localService.clips, hasLength(1), reason: 'test setup check: G1\'s own clip genuinely exists');

          // G2 begins — its own native START is gated, occupying the FIFO.
          // Fase 16.2-R4.3-R2.5: G2 is started directly on the service here;
          // in production this START is issued by the session controller
          // (recovery of the SAME logical session), which always supplies the
          // session's own producer token — passed explicitly so G2's clip
          // carries session A's provenance, exactly as it would in production.
          fakePlatform.pendingStartVideoCapturing = startGate;
          unawaited(localService.startLoopRecording(clipOwnerToken: sessionA.id));
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'startVideoCapturing').length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(2), reason: 'test setup check: G2\'s own native START has genuinely been reached');
          expect(localService.isRecording, isTrue, reason: 'test setup check');

          // An unqualified stop is announced/enqueued BEHIND the gated START.
          unawaited(localService.stopLoopRecording());
          expect(localService.isRecording, isFalse, reason: 'test setup check');
          expect(localService.hasPendingNativeStop, isFalse, reason: 'test setup check: nothing has materialized yet — queued behind the gated START');

          // A second, independent caller adopts the SAME announcement.
          final outcome = localService.beginStopLoopRecording();
          var handleResolved = false;
          unawaited(outcome.handle.then((_) => handleResolved = true));

          await Future<void>.delayed(const Duration(milliseconds: 300));
          await outcome.presentation.timeout(
            const Duration(milliseconds: 1),
            onTimeout: () => fail('presentation must already be resolved (bounded by the short stopVideoRecordingTimeout) well before this point'),
          );
          expect(handleResolved, isFalse, reason: 'the presentation deadline expiring must never retroactively resolve the physical handle discovery as null — G2\'s own real STOP is still genuinely pending behind the gated START');

          // Release the FIFO — G2's own native START resolves, then its own
          // STOP finalize closure finally gets its turn.
          startGate.complete();
          final handle = await outcome.handle.timeout(const Duration(seconds: 2));
          expect(handle, isNotNull, reason: 'once the announcement genuinely materializes, the durable continuation must still deliver the real handle for G2');
          await handle!.settlement.timeout(const Duration(seconds: 2));
          await outcome.presentation;

          expect(localService.clips, hasLength(2), reason: 'BOTH G1\'s and G2\'s own physical clips genuinely exist now');

          // Session A is finally closed — its own persistence pass diffs
          // against A's own baseline and must claim/persist BOTH new paths,
          // regardless of which raw calls actually produced them.
          await localController.stopSession();

          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.length >= 2) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(2), reason: 'both G1\'s and G2\'s own physical clips must be indexed under session A\'s own id exactly once each — G2\'s clip is never lost just because its own adopter\'s presentation deadline expired first');
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.4 — clip provenance ownership (P1-B #2)', () {
    test(
      'X18 (§24/§25, MANDATORY GATE, independent-review P1-B #2 exact reproduction — "failed write '
      'transfere provenance") — session B starts and reaches recording BEFORE session A\'s own late '
      'clip materializes (B\'s own baseline cannot possibly contain it); A\'s clip then materializes, '
      'A\'s own persistence pass claims/owns its path, A\'s own Hive write fails (reported exactly '
      'once); ONLY THEN does B stop and run its own persistence pass. Expected: B\'s own Hive record '
      'contains ONLY its own clip — A\'s path, despite being genuinely "new" against B\'s own stale '
      'baseline too, is never captured by B, because A\'s own provenance claim stays sticky through '
      'the write failure',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        // Fase 16.2-R4.3-R2.5 (§55, test-only — independent review: "X18
        // subscription cleanup não está totalmente em finally"): declared
        // OUTSIDE the try so the `finally` below can always cancel it, even if
        // an assertion fails before the explicit mid-test cancel.
        StreamSubscription<DashcamServiceError>? typedSubX18;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            if (sessionId == sessionA.id) {
              throw StateError('forced Hive write failure for A (X18)');
            }
            await writeCall();
          };

          // A's own STOP reaches the real native call, gated — its clip does
          // NOT exist yet.
          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(localService.clips, isEmpty, reason: 'test setup check: A\'s own clip has not materialized yet');
          // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): B used to start as soon as
          // A's native STOP was entered, assuming the recorder had already
          // closed A; with a slower recorder finalization startSession() is
          // REFUSED ("still being ended") before the scenario exists (found by
          // delaying only the recorder's finalization, T-Rm
          // 05_hardened/recorder_latent). B starts once A is over as a driving
          // session (canStartSession), A's native STOP still held.
          await waitForCondition(() => localController.canStartSession, 'A closed by the recorder, its native STOP still held');
          expect(stopGateA.isCompleted, isFalse, reason: 'test setup check: A\'s clip still cannot exist');

          // B starts NOW — its own baseline is captured synchronously, at
          // this exact instant (_ensureClipsBaselineForSession's own doc),
          // while A's own clip still does not exist — B's own baseline
          // genuinely cannot contain it. B's own REAL native recording
          // cannot actually begin yet — its own startLoopRecording() is
          // queued strictly BEHIND A's own still-running finalize closure in
          // the SAME shared DashcamService FIFO — so this deliberately does
          // NOT wait for recording status here.
          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(equals(sessionA.id)), reason: 'test setup check');

          final typedErrors = <DashcamServiceError>[];
          typedSubX18 = localService.originatedErrors.listen(typedErrors.add);

          // Release A's gate — A's clip materializes; A's own immediate
          // persistence pass (inside stopFutureA itself) claims its path and
          // fails to write it. Only once THIS closure fully concludes can
          // B's own queued startLoopRecording() finally get its turn.
          stopGateA.complete();
          await stopFutureA;
          await waitForStatus(DashcamStatus.recording, on: localController);
          // R4.4-R2.1.1-F1 — ANTES: B's START waited for A's STOP, index pass included, so A's failure was reported
          // before B recorded. MOTIVO: that wait is gone on purpose (RES-1: the index never holds the next session's
          // camera); with a slower index nothing was reported yet here (independent review, F1). DEPOIS: X18 awaits
          // A's passes — A's only — before the count below, and still before B stops.
          await localController.clipIndexFollowUpsSettledForTest(sessionId: sessionA.id);

          final recordingResultErrors = typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult).toList();
          expect(recordingResultErrors, hasLength(1), reason: 'A\'s own write failure reported exactly once (§8)');
          expect(localService.clips, hasLength(1), reason: 'test setup check: only A\'s own clip physically exists so far');
          final pathA = localService.clips.single.file.path;
          expect(localController.ownerOfPathForTest(pathA), sessionA.id, reason: 'test setup check: A\'s own provenance claim stayed sticky through the write failure');

          // ONLY NOW does B stop — its own persistence pass runs with A\'s
          // clip already physically existing (and already claimed).
          await localController.stopSession();
          await typedSubX18.cancel();

          expect(localService.clips, hasLength(2), reason: 'test setup check: B\'s own clip now also physically exists');
          final pathB = localService.clips.firstWhere((c) => c.file.path != pathA).file.path;

          List<DashcamClipRecord> indexedA = const [];
          final rawA = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
          indexedA = rawA == null ? const [] : List<DashcamClipRecord>.from(rawA);
          expect(
            indexedA.map((r) => r.filePath),
            isNot(contains(pathA)),
            reason: 'A\'s own explicit, reported storage failure — legitimately no index entry for it (never silently lost, never migrated)',
          );

          List<DashcamClipRecord> indexedB = const [];
          for (var i = 0; i < 300; i++) {
            final rawB = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
            indexedB = rawB == null ? const [] : List<DashcamClipRecord>.from(rawB);
            if (indexedB.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedB, hasLength(1), reason: 'B\'s own Hive record must contain ONLY its own clip');
          expect(indexedB.single.filePath, pathB);
          expect(
            indexedB.map((r) => r.filePath),
            isNot(contains(pathA)),
            reason: 'B must NEVER capture A\'s own physical clip, even though it is genuinely "new" against B\'s own stale baseline too — this is the exact P1-B #2 misattribution, reproduced and closed',
          );
        } finally {
          await typedSubX18?.cancel();
          localController.persistClipIndexHookForTest = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X19 (§26, "owner permanece após write failure") — after A\'s own Hive write fails and before '
      'B ever persists, A\'s own provenance claim over its path is directly, explicitly observable — '
      'ownerOfPathForTest(pathA) == sessionA.id — for as long as the clip remains physically tracked '
      'in DashcamService.clips',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            throw StateError('forced Hive write failure for A (X19)');
          };

          await localController.stopSession();

          expect(localService.clips, hasLength(1));
          final pathA = localService.clips.single.file.path;
          expect(localController.ownerOfPathForTest(pathA), sessionA.id, reason: 'A\'s own provenance claim must be directly observable, explicitly, right after the write failure');
        } finally {
          localController.persistClipIndexHookForTest = null;
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X20 (§27, "quota poda provenance falha") — after A\'s own Hive write fails, its own provenance '
      'claim stays sticky while the clip physically exists; once storage-quota enforcement genuinely '
      'evicts that clip (removes it from DashcamService.clips), a later persistence pass\'s own prune '
      'must drop the now-stale provenance claim too — boundedness preserved for the failure path, '
      'exactly like the already-established success path (R2.2/R2.3-memory tests)',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
        );
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            throw StateError('forced Hive write failure for A (X20)');
          };
          await localController.stopSession();
          // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass, so A's retry failed under
          // this hook. MOTIVO: that pass is no longer awaited by the STOP. DEPOIS: it is awaited here, before the hook
          // goes — A stays unindexed, the premise of this test.
          await localController.clipIndexFollowUpsSettledForTest();
          localController.persistClipIndexHookForTest = null;

          expect(localService.clips, hasLength(1));
          final pathA = localService.clips.single.file.path;
          expect(localController.ownerOfPathForTest(pathA), sessionA.id, reason: 'test setup check: sticky claim after failure');

          // Tighten the quota to (near) zero — takes effect only once
          // enforcement next actually runs, on a LATER session's own STOP
          // (matching this file's own established R2.3-memory-precise
          // pattern).
          localService.updateConfig(
            DashcamConfig(
              cameraSelection: CameraSelection.rear,
              storageQuotaMb: 0,
              audioEnabled: false,
              resolution: VideoResolution.hd720,
              frameRate: 30,
              enabled: true,
            ),
          );
          expect(localController.ownerOfPathForTest(pathA), sessionA.id, reason: 'tightening the quota alone must not retroactively prune anything — enforcement has not run yet');

          // Fase 16.2-R4.4-R2 — ADAPTED (owner decision O4; D0 RK2).
          // BEFORE: B's STOP ran the service's in-FIFO quota, which evicted
          //   A's clip (its index write had failed), and the next prune
          //   dropped A's sticky claim.
          // WHY superseded: A's clip, whose write failed, is a canonical clip
          //   that is NOT indexed (class B, D0 §6): the physical quota never
          //   evicts it — it would take video no index names — and the next
          //   start indexes it. It stays on disk, so its claim stays too:
          //   bounded by the clip that exists, as before.
          // AFTER: B's and C's sessions follow under the near-zero quota; C's
          //   pass evicts B (the oldest INDEXED clip), never A; A's file,
          //   clip and sticky claim stay; B's claim goes with B.
          // NEGATIVE CONTROL: an unindexed (or orphan) clip treated as
          //   evictable (M4) → A is evicted → this test fails.
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          await storagePassesSettled();
          final pathB = localService.clips.last.file.path;
          localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          await storagePassesSettled();

          expect(File(pathB).existsSync(), isFalse, reason: 'B, the oldest indexed clip, was evicted');
          expect(localController.ownerOfPathForTest(pathB), isNull, reason: 'B\'s claim went with it — boundedness');
          expect(File(pathA).existsSync(), isTrue, reason: 'A is unindexed: never a candidate');
          expect(localService.clips.any((c) => c.file.path == pathA), isTrue);
          expect(localController.ownerOfPathForTest(pathA), sessionA.id, reason: 'A\'s sticky claim stays exactly as long as A\'s clip exists');
        } finally {
          localController.persistClipIndexHookForTest = null;
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X21 (§41, combination — "announcement tardio + session transition") — G1 (session A) settles '
      'normally; a fresh G2 recording (still under session A) begins with its own native START '
      'genuinely gated, occupying the FIFO; an unqualified stop for G2 is announced/enqueued behind it '
      'and adopted by a second, independent caller with a short stopVideoRecordingTimeout — the '
      'adopter\'s own presentation deadline expires well before G2\'s real STOP does (P1-A #2), yet its '
      'own handle is never lost. Once the gate releases and G2 genuinely settles, session A\'s own '
      'stopSession() concludes normally, claiming BOTH G1\'s and G2\'s own clips — ONLY THEN does a '
      'genuinely new session B begin (this file\'s own established "B cannot begin until the previous '
      'session\'s own _stopCameraFuture resolves" ordering — a NEW session starting WHILE A\'s own is '
      'still current is not how this app\'s own session lifecycle works; see this test\'s own doc). '
      'Expected: G2\'s own clip is indexed ONLY under session A — B\'s own Hive record contains only '
      'its own, later clip',
      () async {
        final localService = DashcamService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final recordingIdG1 = localService.activeRecordingId;
          final controllerG1 = localService.previewController;

          // G1 ends normally — A's own first clip. Fase 16.2-R4.4-R1-T-Rm (R-m
          // X21, test-only): see [stopNormally].
          await stopNormally(localService, () => localService.stopLoopRecording(expectedRecordingId: recordingIdG1, expectedController: controllerG1));
          expect(localService.clips, hasLength(1));

          // G2 begins — its own native START is gated, occupying the FIFO.
          // Fase 16.2-R4.3-R2.5: started directly on the service, so the
          // session's own producer token is passed explicitly — see this file's
          // other G2 start (X17 session-level) for why.
          fakePlatform.pendingStartVideoCapturing = startGate;
          unawaited(localService.startLoopRecording(clipOwnerToken: sessionA.id));
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'startVideoCapturing').length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(localService.isRecording, isTrue, reason: 'test setup check');

          // An unqualified stop for G2 is announced/enqueued behind the
          // gated START.
          unawaited(localService.stopLoopRecording());
          expect(localService.isRecording, isFalse, reason: 'test setup check');
          expect(localService.hasPendingNativeStop, isFalse, reason: 'test setup check');

          // The adopter: a second, independent caller — representing e.g. a
          // generation-invalidated cleanup that reached the announcement
          // first. Its own presentation deadline (short) will expire well
          // before G2's own real STOP does.
          final outcome = localService.beginStopLoopRecording();
          var handleResolved = false;
          unawaited(outcome.handle.then((_) => handleResolved = true));

          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(handleResolved, isFalse, reason: 'G2\'s own real STOP is still genuinely pending behind the gated START — the presentation deadline expiring must not have resolved this as null');

          // Release the FIFO — G2 settles.
          startGate.complete();
          final handle = await outcome.handle.timeout(const Duration(seconds: 2));
          expect(handle, isNotNull);
          await handle!.settlement.timeout(const Duration(seconds: 2));
          await outcome.presentation;
          expect(localService.clips, hasLength(2), reason: 'G2\'s own clip now genuinely exists');

          // Session A concludes NOW — its own persistence pass diffs against
          // A's own baseline and claims BOTH G1's and G2's own paths, exactly
          // like this file's own X17 (session-level) already establishes.
          // Only AFTER this — a genuinely SEQUENTIAL session boundary, the
          // only way a second, independent session realistically begins in
          // this app (this method's own doc: "B genuinely cannot begin its
          // own operation until THIS session's own _stopCameraFuture
          // resolves") — does session B start.
          await localController.stopSession();

          List<DashcamClipRecord> indexedA = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id) as List?;
            indexedA = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedA.length >= 2) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedA, hasLength(2), reason: 'both of A\'s own clips (G1 and G2) end up indexed under session A');

          // Session B — genuinely fresh, only now.
          final sessionB = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();

          List<DashcamClipRecord> indexedB = const [];
          for (var i = 0; i < 300; i++) {
            final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
            indexedB = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
            if (indexedB.isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexedB, hasLength(1), reason: 'B\'s own Hive record contains only its own clip — never G2\'s, which genuinely belongs to A');
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.5/R2.6 — stop intent identity, late handle legitimacy, producer-bound clip provenance, session stop request identity', () {
    DashcamService buildShortStopService() {
      return DashcamService(
        config: DashcamConfig(
          cameraSelection: CameraSelection.rear,
          storageQuotaMb: 1024,
          audioEnabled: false,
          resolution: VideoResolution.hd720,
          frameRate: 30,
          enabled: true,
        ),
        segmentDuration: const Duration(minutes: 10),
        stopVideoRecordingTimeout: const Duration(milliseconds: 50),
      );
    }

    Future<List<DashcamClipRecord>> waitForIndexedCount(String sessionId, int expected) async {
      List<DashcamClipRecord> indexed = const [];
      for (var i = 0; i < 300; i++) {
        final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List?;
        indexed = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
        if (indexed.length >= expected) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return indexed;
    }

    /// Reproduces the reviewer's P1-2 setup: session A's Recording #1 has
    /// already produced a clip (A's first clip), then a START for Recording #2
    /// is issued directly on the service and left genuinely retained (gated) —
    /// so `activeRecordingId` still names #1 while A's own `stopSession()` is
    /// issued. Returns the pre-stop snapshot of `activeRecordingId`.
    Future<int?> arrangeRetainedSecondStart(
      DashcamService localService,
      DashcamSessionController localController,
      Completer<void> startGate,
      String sessionId,
    ) async {
      await waitForStatus(DashcamStatus.recording, on: localController);
      final recordingIdG1 = localService.activeRecordingId;
      final controllerG1 = localService.previewController;
      await localService.stopLoopRecording(expectedRecordingId: recordingIdG1, expectedController: controllerG1);
      // Fase 16.2-R4.3-R2.6.1 (§5, pre-audit TG-2 — "arrangeRetainedSecondStart
      // frágil"): `stopLoopRecording` returns at its PRESENTATION deadline
      // (`buildShortStopService`: 50ms), not when the physical STOP concludes.
      // With a native STOP slower than that (>=120ms reproduced) the clip does
      // not exist yet when it returns, and the old immediate
      // `expect(clips, hasLength(1))` failed with `[]` — a harness assumption,
      // not a product defect (X35-session/X40 are among the tests that share
      // this helper). The setup's precondition is a CAUSAL state — the physical
      // STOP has settled and its clip is published — so wait on exactly that,
      // never on a sleep that "should be long enough". Bounded, and fails
      // explicitly if the state never arrives.
      for (var i = 0; i < 300 && (localService.hasPendingNativeStop || localService.clips.isEmpty); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(localService.hasPendingNativeStop, isFalse, reason: 'test setup: Recording #1\'s physical STOP has settled');
      expect(localService.clips, hasLength(1), reason: 'test setup: A\'s own first clip (Recording #1)');

      // START #2 is issued directly on the service here; in production it is
      // the session controller's own recovery START, which always carries the
      // session's producer token — so the token is passed explicitly.
      fakePlatform.pendingStartVideoCapturing = startGate;
      unawaited(localService.startLoopRecording(clipOwnerToken: sessionId));
      for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'startVideoCapturing').length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(2), reason: 'test setup: START #2 was issued');
      expect(localService.activeRecordingId, recordingIdG1, reason: 'test setup: Recording #2 has not materialized — the snapshot still names #1');
      return recordingIdG1;
    }

    test(
      'X23 (§18, MANDATORY GATE, independent-review P1-2 exact reproduction — "handle legítimo rejeitado por '
      'RecordingId snapshot antigo") — session A\'s Recording #1 already produced its clip; a START for '
      'Recording #2 is retained (gated) while activeRecordingId still names #1; A\'s stopSession() is issued in '
      'that window: _stopCamera\'s stop intent is enqueued BEHIND the START, its presentation expires (short '
      'stopVideoRecordingTimeout) and stopSession() returns bounded. The START then finishes, the stop intent '
      'materializes a REAL stop of Recording #2, and its handle is legitimate — belonging to A\'s own intent — '
      'even though its recordingId differs from the pre-issuance snapshot. Expected: the late persistence '
      'watcher IS installed, exactly one physical STOP for #2, and A\'s Hive record ends up with BOTH clips',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          final snapshotBeforeStop = await arrangeRetainedSecondStart(localService, localController, startGate, sessionA.id);

          await localController.stopSession().timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('stopSession() must return bounded even though its own stop is still queued behind a retained START'),
          );
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'only #1\'s own STOP so far — #2\'s STOP is still queued behind the gated START');

          startGate.complete();
          final indexedA = await waitForIndexedCount(sessionA.id, 2);
          expect(indexedA, hasLength(2), reason: 'P1-2: the legitimate late handle must not be discarded — Recording #2\'s clip is indexed under A');
          expect(indexedA.map((r) => r.filePath).toSet(), localService.clips.map((c) => c.file.path).toSet());

          final explicitIntents = localService.stopIntentsForTest.where((i) => i.purpose == 'explicitStop').toList();
          expect(explicitIntents, hasLength(1), reason: 'exactly one untargeted (session-stop) intent was issued');
          expect(explicitIntents.single.resolved, isTrue);
          expect(explicitIntents.single.resolvedRecordingId, isNotNull);
          expect(explicitIntents.single.resolvedRecordingId, isNot(equals(snapshotBeforeStop)), reason: 'the intent stopped Recording #2 — the old snapshot names #1');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'exactly one physical STOP for #1 and one for #2');
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X23-dispose (§19, MANDATORY variant) — same scenario as X23, but the SessionController is disposed AFTER '
      'stopSession() has returned bounded and BEFORE the retained START (and therefore the stop intent\'s own '
      'materialization) completes. Expected: the intent still materializes and its historical persistence '
      'concludes — every clip of A indexed — with zero notifyListeners after dispose and zero unhandled async '
      'error',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        var notifications = 0;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await arrangeRetainedSecondStart(localService, localController, startGate, sessionA.id);

          await localController.stopSession().timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('stopSession() must return bounded'),
          );
          localController.addListener(() => notifications++);
          localController.dispose();
          final notificationsAtDispose = notifications;

          startGate.complete();
          final indexedA = await waitForIndexedCount(sessionA.id, 2);
          expect(indexedA, hasLength(2), reason: 'every clip of A is indexed even though the controller was disposed before the stop materialized');
          expect(indexedA.map((r) => r.filePath).toSet(), localService.clips.map((c) => c.file.path).toSet());
          expect(notifications, notificationsAtDispose, reason: 'zero notifyListeners after dispose');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2));
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X25 (§36, MANDATORY GATE, independent-review P1-1 exact reproduction — "B tries first") — session A '
      'issues a STOP whose native call is gated; A\'s stopSession() returns bounded (its presentation deadline) '
      'and installs its late-persistence watcher. Session B is born WHILE A\'s clip does not exist yet (so B\'s '
      'baseline provably precedes it). A\'s native STOP is released: A\'s clip is produced and PUBLISHED, and A\'s '
      'own finalize is HELD right there — before `_enforceStorageQuota`, the exact window the reviewer '
      'exploited: the clip is visible in DashcamService.clips but A\'s real settlement has not happened. '
      'Session B\'s own stopSession()/persistence pass then runs FIRST. Expected: B consults the clip\'s PRODUCER '
      'provenance and ignores it — B\'s Hive record never contains A\'s path, B never even attempts a write for '
      'it, never claims it — and only afterwards, once A\'s finalize concludes, does A\'s late watcher persist A\'s '
      'own clip',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        final nativeStopGate = Completer<void>();
        final publishedGate = Completer<void>();
        final published = Completer<void>();
        final writes = <String>[];
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            for (final path in claimedPaths) {
              writes.add('$sessionId|$path');
            }
            await writeCall();
          };
          localService.afterClipPublishedHookForTest = (clip) async {
            if (!published.isCompleted) published.complete();
            await publishedGate.future;
          };

          // A's native STOP is gated; A's stopSession() returns bounded (its
          // presentation deadline) — A's own immediate pass finds no clip yet.
          fakePlatform.pendingStopVideoRecording = nativeStopGate;
          await localController.stopSession().timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('X25: A\'s stopSession() must return bounded even though its native STOP is gated'),
          );
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'test setup: A\'s native STOP was issued (gated)');
          expect(localService.clips, isEmpty, reason: 'test setup: A\'s clip does not exist yet');

          // B is born NOW — its baseline (captured synchronously) cannot
          // possibly contain A's clip.
          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(equals(sessionA.id)));

          // A's clip is produced and published; A's own finalize is held
          // immediately after publication.
          nativeStopGate.complete();
          await published.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('X25: A\'s clip was never published'));
          expect(localService.clips, hasLength(1), reason: 'the clip is visible');
          final pathA = localService.clips.single.file.path;
          expect(localService.clips.single.producerToken, sessionA.id, reason: 'provenance is already A\'s at the instant of visibility');
          expect(localService.hasPendingNativeStop, isTrue, reason: 'A\'s own finalize has NOT concluded — real settlement has not happened');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id), isNull, reason: 'A has not persisted anything yet');

          // B's own persistence pass runs FIRST — with A's clip visible.
          await localController.stopSession().timeout(const Duration(seconds: 10), onTimeout: () => fail('X25: B\'s stopSession() never returned'));
          await pumpEventQueue(times: 50);
          expect(writes, isEmpty, reason: 'B must not even attempt a write for a clip it did not produce');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id), isNull, reason: 'B\'s record never receives A\'s clip');
          expect(localController.ownerOfPathForTest(pathA), isNull, reason: 'B did not claim A\'s path');

          // Only now does A's finalize conclude; A's late watcher persists it.
          publishedGate.complete();
          final indexedA = await waitForIndexedCount(sessionA.id, 1);
          expect(indexedA.map((r) => r.filePath), [pathA], reason: 'A persists ITS OWN clip');
          await pumpEventQueue(times: 50);
          final rawB = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id) as List?;
          expect(rawB ?? const <Object>[], isEmpty, reason: 'B\'s Hive record still never contains A\'s path');
          expect(writes, ['${sessionA.id}|$pathA'], reason: 'exactly one write in the whole scenario — A\'s, for A\'s clip');
        } finally {
          localController.persistClipIndexHookForTest = null;
          localService.afterClipPublishedHookForTest = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!nativeStopGate.isCompleted) nativeStopGate.complete();
          if (!publishedGate.isCompleted) publishedGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X26 (§37, provenance + storage failure) — A\'s clip is born already carrying A\'s producer token; A\'s own '
      'Hive write FAILS; the token stays A (a failed write never releases provenance) at every observation; '
      'session B, started before A\'s clip existed, then persists. Expected: B never receives A\'s clip; A may '
      'legitimately stay un-indexed for an explicit, reported storage error',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        final stopGateA = Completer<void>();
        StreamSubscription<DashcamServiceError>? typedSubX26;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            if (sessionId == sessionA.id) throw StateError('forced Hive write failure for A (X26)');
            await writeCall();
          };

          fakePlatform.pendingStopVideoRecording = stopGateA;
          final stopFutureA = localController.stopSession();
          for (var i = 0; i < 300 && fakePlatform.calls.where((c) => c == 'stopVideoRecording').isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): B started as soon as A's
          // native STOP was entered, assuming the recorder had already closed A;
          // with a slower recorder finalization startSession() is REFUSED ("still
          // being ended") before the scenario exists (found by delaying only the
          // recorder's finalization, T-Rm 05_hardened/family_matrix). B starts
          // once A is over as a driving session (canStartSession), A's native
          // STOP still held — "session B, started before A's clip existed".
          await waitForCondition(() => localController.canStartSession, 'A closed by the recorder, its native STOP still held');
          expect(stopGateA.isCompleted, isFalse, reason: 'test setup check: A\'s clip does not exist yet');
          final sessionB = localController.startSession();
          final typedErrors = <DashcamServiceError>[];
          typedSubX26 = localService.originatedErrors.listen(typedErrors.add);

          stopGateA.complete();
          await stopFutureA;
          await waitForStatus(DashcamStatus.recording, on: localController);
          // R4.4-R2.1.1-F1 — ANTES: B's START waited for A's STOP, index pass included, so A's failure was reported
          // before B recorded. MOTIVO: that wait is gone on purpose (RES-1: the index never holds the next session's
          // camera); with a slower index nothing was reported yet here (independent review, F1). DEPOIS: X26 awaits
          // A's passes — A's only — before the count below, and still before B stops.
          await localController.clipIndexFollowUpsSettledForTest(sessionId: sessionA.id);

          expect(typedErrors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult), hasLength(1), reason: 'A\'s failure is reported exactly once');
          expect(localService.clips, hasLength(1));
          final clipA = localService.clips.single;
          expect(clipA.producerToken, sessionA.id, reason: 'the clip carries A\'s token — born with it');
          expect(localController.ownerOfPathForTest(clipA.file.path), sessionA.id);

          await localController.stopSession();
          await typedSubX26.cancel();
          // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): B's stopSession() returns at
          // its 50 ms presentation deadline; B's clip is processed after it (its
          // promotion is real file I/O since R4.4-R1), so under load it was not
          // there yet when read (reproduced by delaying only the rename, T-Rm
          // 02_directed/screen_rename). Read once it has settled.
          await settledClipsOf(localService, sessionB.id, atLeast: 1);
          expect(localService.clips, hasLength(2));
          expect(clipA.producerToken, sessionA.id, reason: 'A\'s failed write never released provenance');
          final clipB = localService.clips.firstWhere((c) => !identical(c, clipA));
          expect(clipB.producerToken, sessionB.id);

          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id), isNull, reason: 'A stays un-indexed — an explicit, reported storage failure');
          final indexedB = await waitForIndexedCount(sessionB.id, 1);
          expect(indexedB.map((r) => r.filePath), [clipB.file.path], reason: 'B\'s record contains ONLY B\'s own clip');
        } finally {
          await typedSubX26?.cancel();
          localController.persistClipIndexHookForTest = null;
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGateA.isCompleted) stopGateA.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X28 (§42, P1-2 + provenance) — the X23-dispose scenario with producer tokens: a retained START for '
      'Recording #2, stopSession() returns bounded, the controller is disposed, then #2 materializes and its '
      'intent stops it. Expected: BOTH physical clips carry session A\'s producer token (the late Recording\'s '
      'clip inherits the token of the Recording that produced it, not "whichever session is current"), and A\'s '
      'Hive record is complete',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          final snapshotBeforeStop = await arrangeRetainedSecondStart(localService, localController, startGate, sessionA.id);
          await localController.stopSession().timeout(const Duration(seconds: 5));
          localController.dispose();

          startGate.complete();
          final indexedA = await waitForIndexedCount(sessionA.id, 2);
          expect(indexedA, hasLength(2), reason: 'Hive A is complete');
          expect(localService.clips, hasLength(2));
          expect(localService.clips.every((clip) => clip.producerToken == sessionA.id), isTrue, reason: 'both clips — including the late one — carry A\'s producer token');
          expect(localService.clips.map((clip) => clip.recordingId).toSet(), hasLength(2));
          expect(localService.clips.last.recordingId, isNot(equals(snapshotBeforeStop)));
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X29 (§43, announcement deadline + B + failure) — A\'s stop intent outlives its presentation deadline '
      '(queued behind a retained START); stopSession() returns; session B is born (ordering permits it now). '
      'The START finishes, A\'s stop intent materializes and stops Recording #2 — A\'s clip is BORN carrying A\'s '
      'token — and A\'s Hive writes FAIL. B then records and persists. Expected: A\'s handle was correct (the '
      'intent resolved to Recording #2), A\'s provenance token stays A through the failures, and B\'s Hive record '
      'contains ONLY B\'s own clip',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        final typedErrors = <DashcamServiceError>[];
        StreamSubscription<DashcamServiceError>? typedSub;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          typedSub = localService.originatedErrors.listen(typedErrors.add);
          localController.persistClipIndexHookForTest = (sessionId, claimedPaths, writeCall) async {
            if (sessionId == sessionA.id) throw StateError('forced Hive write failure for A (X29)');
            await writeCall();
          };
          final snapshotBeforeStop = await arrangeRetainedSecondStart(localService, localController, startGate, sessionA.id);
          await localController.stopSession().timeout(const Duration(seconds: 5));

          // B begins — its own camera acquisition queues BEHIND A's intent.
          final sessionB = localController.startSession();

          startGate.complete();
          // A's obligations conclude: the immediate pass (clip #1) and the late
          // pass (clip #2) each fail exactly once.
          for (var i = 0; i < 300 && typedErrors.where((e) => e.message.contains(sessionA.id)).length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(typedErrors.where((e) => e.message.contains(sessionA.id)), hasLength(2), reason: 'one failure per A obligation/path — exactly once each');
          final clipsOfA = localService.clips.where((clip) => clip.producerToken == sessionA.id).toList();
          expect(clipsOfA, hasLength(2), reason: 'both of A\'s clips carry A\'s token');
          final explicit = localService.stopIntentsForTest.where((i) => i.purpose == 'explicitStop').toList();
          expect(explicit, hasLength(1));
          expect(explicit.single.resolvedRecordingId, isNot(equals(snapshotBeforeStop)), reason: 'A\'s handle was for Recording #2, the late one');

          await waitForStatus(DashcamStatus.recording, on: localController);
          await localController.stopSession();
          final indexedB = await waitForIndexedCount(sessionB.id, 1);
          final clipB = localService.clips.firstWhere((clip) => clip.producerToken == sessionB.id);
          expect(indexedB.map((r) => r.filePath), [clipB.file.path], reason: 'B contains ONLY its own clip');
          for (final clip in clipsOfA) {
            expect(indexedB.map((r) => r.filePath), isNot(contains(clip.file.path)), reason: 'B never receives A\'s clips');
            expect(clip.producerToken, sessionA.id, reason: 'A\'s provenance survived A\'s storage failures');
          }
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionA.id), isNull, reason: 'A stays un-indexed after explicit, reported storage failures');
        } finally {
          await typedSub?.cancel();
          localController.persistClipIndexHookForTest = null;
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X30 (§33/§34, recovery and camera switch keep the SAME producer token) — the app is backgrounded and '
      'resumed mid-session (real WidgetsBinding dispatch), so the session\'s camera is REPLACED: a fresh '
      'controller (a new lifecycle generation, a new Recording id) records the rest of the SAME logical '
      'session — the very path a mid-session camera switch takes (initialize() + startLoopRecording()). '
      'Expected: every clip of both the pre-recovery and post-recovery Recordings carries the session\'s ONE '
      'producer token, and the session\'s Hive record is complete',
      () async {
        await preferences.setEnabled(true);
        final session = controller.startSession();
        await waitForStatus(DashcamStatus.recording);
        final controllerG1 = service.previewController;
        final recordingIdG1 = service.activeRecordingId;

        // ignore: invalid_use_of_visible_for_testing_member
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // ignore: invalid_use_of_visible_for_testing_member
        WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        for (var i = 0; i < 300; i++) {
          if (!identical(service.previewController, controllerG1) &&
              controller.status == DashcamStatus.recording &&
              fakePlatform.calls.where((c) => c == 'startVideoCapturing').length >= 2) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(identical(service.previewController, controllerG1), isFalse, reason: 'test setup: recovery replaced the camera (a new generation\'s controller)');
        expect(service.activeRecordingId, isNot(equals(recordingIdG1)), reason: 'test setup: a new Recording id');

        await controller.stopSession();

        expect(service.clips, hasLength(2), reason: 'the pre-recovery Recording\'s clip + the post-recovery Recording\'s clip');
        expect(
          service.clips.every((clip) => clip.producerToken == session.id),
          isTrue,
          reason: 'recovery / camera switch inside one logical session keeps the SAME producer token — a lifecycle generation is not a provenance',
        );
        expect(service.clips.map((clip) => clip.recordingId).toSet(), hasLength(2));
        final indexed = await waitForIndexedCount(session.id, 2);
        expect(indexed.map((r) => r.filePath).toSet(), service.clips.map((c) => c.file.path).toSet(), reason: 'the session\'s Hive record is complete');
      },
    );

    // ------------------------------------------------------------------
    // Fase 16.2-R4.3-R2.6 — session stop request identity (P1-A)
    // ------------------------------------------------------------------

    Future<void> waitUntil(bool Function() condition, String label, {int maxIterations = 300}) async {
      for (var i = 0; i < maxIterations; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('waitUntil: "$label" never became true after ${maxIterations * 10}ms');
    }

    /// Holds A's `_stopCamera` at its own immediate-persistence gate — a causal,
    /// real point at which A's stop is genuinely still in flight (its
    /// `_stopCameraFuture`/public stop Future both pending) while A's recorder
    /// (an independent, Hive-only path) is free to finish, so a new session B
    /// may legitimately start.
    ({Completer<void> hold, Completer<void> entered}) armFirstStopGate(DashcamSessionController localController) {
      final hold = Completer<void>();
      final entered = Completer<void>();
      var calls = 0;
      localController.beforeImmediatePersistenceHookForTest = () async {
        if (++calls == 1) {
          entered.complete();
          await hold.future;
        }
      };
      return (hold: hold, entered: entered);
    }

    test(
      'X31 (§13-§15, MANDATORY GATE, independent-review P1-A exact reproduction — "stopSession(B) é absorvido '
      'por A") — session A\'s stop is genuinely in flight (held at a real causal point) while A\'s recorder has '
      'already finished, so session B legitimately starts; B\'s camera acquisition is registered but blocked '
      'behind A\'s PHYSICAL teardown. The caller then PUBLICLY calls stopSession() for B. Expected: B\'s stop is '
      'its OWN request (different identity and target than A\'s, not A\'s Future), it invalidates B\'s '
      'acquisition IMMEDIATELY (before A is released), and once A is released B NEVER reaches recording — zero '
      'native camera work for B, zero attempt left to resurrect it',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        Future<void>? stopA;
        Future<void>? stopB;
        final gate = armFirstStopGate(localController);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          stopA = localController.stopSession();
          final requestIdA = localController.inFlightStopRequestIdForTest;
          expect(localController.inFlightStopRequestSessionIdForTest, sessionA.id);
          await gate.entered.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('X31: A\'s stop never reached its causal gate'));
          await waitUntil(() => !recorder.isRecording, 'A\'s recorder finished (so B may start)');

          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(equals(sessionA.id)), reason: 'test setup: B is a genuinely new logical session');
          expect(localController.activeCameraAttemptSessionIdForTest, sessionB.id, reason: 'test setup: B has a registered acquisition attempt, blocked by A\'s physical barrier');
          final createsBeforeStopB = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length;

          stopB = localController.stopSession();
          final requestIdB = localController.inFlightStopRequestIdForTest;
          expect(requestIdB, isNot(equals(requestIdA)), reason: 'B\'s stop is its OWN request — different identity');
          expect(localController.inFlightStopRequestSessionIdForTest, sessionB.id, reason: 'B\'s request targets B, not A');
          expect(identical(stopA, stopB), isFalse, reason: 'stopSession(B) must not be A\'s Future');
          expect(
            localController.activeCameraAttemptSessionIdForTest,
            isNull,
            reason: 'B\'s acquisition is invalidated IMMEDIATELY — while A is still held, not after A finishes',
          );

          gate.hold.complete();
          await Future.wait<void>([stopA, stopB]).timeout(const Duration(seconds: 10), onTimeout: () => fail('X31: the stop Futures never completed'));
          await pumpEventQueue(times: 100);

          expect(localController.status, DashcamStatus.idle, reason: 'B was stopped — it must not be recording (nor initializing/error)');
          expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: 'no attempt is left that could reactivate B');
          expect(recorder.isRecording, isFalse);
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(createsBeforeStopB), reason: 'B never touched the camera');
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1), reason: 'only A ever started a Recording');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'native STOP for B = 0 (B never acquired a Recording); only A\'s');
        } finally {
          localController.beforeImmediatePersistenceHookForTest = null;
          if (!gate.hold.isCompleted) gate.hold.complete();
          if (stopA != null) await stopA.catchError((_) {});
          if (stopB != null) await stopB.catchError((_) {});
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X32 (§16, same-session dedup preserved) — stopSession() called twice for the SAME session is ONE shared '
      'operation (identical Future, same request identity, exactly one native STOP), and a third call made after '
      'the recorder already finished — when there is no active session left, only the still-finishing teardown — '
      'still joins that same in-flight request',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        Future<void>? first;
        final gate = armFirstStopGate(localController);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          first = localController.stopSession();
          final second = localController.stopSession();
          expect(identical(first, second), isTrue, reason: 'same logical session, same request — one shared operation');
          expect(localController.inFlightStopRequestSessionIdForTest, sessionA.id);
          final requestId = localController.inFlightStopRequestIdForTest;

          await gate.entered.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('X32: the stop never reached its causal gate'));
          await waitUntil(() => !recorder.isRecording, 'the recorder finished — no active session remains');
          final third = localController.stopSession();
          expect(identical(first, third), isTrue, reason: 'no session left to stop — waiting for the in-flight teardown is exactly the same request');
          expect(localController.inFlightStopRequestIdForTest, requestId);

          gate.hold.complete();
          await first.timeout(const Duration(seconds: 10));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'no duplicate physical operation');
          expect(localController.inFlightStopRequestIdForTest, isNull, reason: 'the request slot is released once it concludes');
        } finally {
          localController.beforeImmediatePersistenceHookForTest = null;
          if (!gate.hold.isCompleted) gate.hold.complete();
          if (first != null) await first.catchError((_) {});
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X33 (§17, A → B stop → C) — A\'s teardown is retained; B is born; B is stopped; C is requested; A is then '
      'released. Expected: B never records; C progresses ONLY after A\'s physical teardown (its camera acquisition '
      'follows A\'s controller dispose) and is never invalidated by B\'s stop request; C then records and, when '
      'stopped, indexes only its own clip',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        Future<void>? stopA;
        Future<void>? stopB;
        Future<void>? stopC;
        final gate = armFirstStopGate(localController);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          stopA = localController.stopSession();
          await gate.entered.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('X33: A never reached its causal gate'));
          await waitUntil(() => !recorder.isRecording, 'A\'s recorder finished');

          final sessionB = localController.startSession();
          stopB = localController.stopSession();
          expect(localController.inFlightStopRequestSessionIdForTest, sessionB.id);
          await waitUntil(() => !recorder.isRecording, 'B\'s recorder finished');

          final sessionC = localController.startSession();
          expect(localController.activeCameraAttemptSessionIdForTest, sessionC.id, reason: 'C has its own acquisition intent — B\'s stop request did not invalidate it');
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'C is still blocked behind A\'s (and B\'s) physical barrier — only A\'s camera exists while A is retained');

          gate.hold.complete();
          // `status` still shows A's stale `recording` until A's own stop
          // concludes — so wait on causal evidence that C's acquisition ran and
          // concluded, then assert the status.
          await waitUntil(
            () => fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length == 2 && localController.activeCameraAttemptSessionIdForTest == null,
            'C\'s acquisition ran and concluded',
          );
          await waitForStatus(DashcamStatus.recording, on: localController);
          await Future.wait<void>([stopA, stopB]).timeout(const Duration(seconds: 10));

          final calls = fakePlatform.calls;
          expect(calls.where((c) => c == 'createCameraWithSettings'), hasLength(2), reason: 'A and C only — B never acquired a camera');
          expect(
            calls.lastIndexOf('createCameraWithSettings'),
            greaterThan(calls.indexOf('dispose')),
            reason: 'C\'s camera acquisition follows A\'s controller dispose — A\'s physical obligations were respected',
          );
          expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: 'C\'s attempt concluded normally');

          stopC = localController.stopSession();
          await stopC.timeout(const Duration(seconds: 10));
          final indexedC = await waitForIndexedCount(sessionC.id, 1);
          final clipC = localService.clips.where((clip) => clip.producerToken == sessionC.id).toList();
          expect(clipC, hasLength(1));
          expect(indexedC.map((r) => r.filePath), [clipC.single.file.path], reason: 'C indexes only its own clip');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id), isNull, reason: 'B never recorded — nothing to index');
          expect(localService.clips.where((clip) => clip.producerToken == sessionB.id), isEmpty);
          expect(localService.clips.where((clip) => clip.producerToken == sessionA.id), hasLength(1));
        } finally {
          localController.beforeImmediatePersistenceHookForTest = null;
          if (!gate.hold.isCompleted) gate.hold.complete();
          for (final pending in [stopA, stopB, stopC]) {
            if (pending != null) await pending.catchError((_) {});
          }
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X34 (§18, B already recording) — A\'s public stop is still in flight (its recorder stop is genuinely '
      'gated, while A\'s camera teardown already finished), so B starts and REACHES recording. stopSession() '
      'for B must be its own request: it really stops B (native STOP, B\'s clip indexed under B) and its Future '
      'concludes on B\'s own contract — without waiting for A\'s unrelated, still-open request',
      () async {
        final gatedRecorder = _GatedStopRecorder(snapshotController.stream);
        final localService = buildShortStopService();
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: gatedRecorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final gateA = Completer<void>();
        Future<void>? stopA;
        Future<void>? stopB;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          gatedRecorder.nextStopGate = gateA;
          stopA = localController.stopSession();
          final requestIdA = localController.inFlightStopRequestIdForTest;
          expect(localController.inFlightStopRequestSessionIdForTest, sessionA.id);
          await waitUntil(() => localService.previewController == null && !gatedRecorder.isRecording, 'A\'s camera teardown and recorder both finished');
          expect(localController.inFlightStopRequestIdForTest, requestIdA, reason: 'A\'s request is STILL in flight — held by the recorder-side gate');

          final sessionB = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.inFlightStopRequestIdForTest, requestIdA, reason: 'test setup: B is genuinely recording while A\'s request is still open');
          final stopsBefore = fakePlatform.calls.where((c) => c == 'stopVideoRecording').length;

          stopB = localController.stopSession();
          expect(localController.inFlightStopRequestSessionIdForTest, sessionB.id);
          expect(localController.inFlightStopRequestIdForTest, isNot(equals(requestIdA)), reason: 'B\'s stop is its own request, not A\'s');
          expect(identical(stopA, stopB), isFalse);

          await stopB.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('X34: stopSession(B) must conclude on B\'s own contract — it was absorbed by A\'s still-open request'),
          );
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(stopsBefore + 1), reason: 'B\'s own physical STOP was issued');
          expect(localController.status, DashcamStatus.idle);
          // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): stopSession(B) concludes on
          // B's own contract — its 50 ms presentation — and B's clip is processed
          // after it (real file I/O since R4.4-R1); under load it was read before
          // it existed (reproduced by delaying only the rename). Read once settled.
          final clipB = await settledClipsOf(localService, sessionB.id, atLeast: 1);
          expect(clipB, hasLength(1), reason: 'B\'s Recording was really stopped and produced its clip');
          final indexedB = await waitForIndexedCount(sessionB.id, 1);
          expect(indexedB.map((r) => r.filePath), [clipB.single.file.path]);

          gateA.complete();
          await stopA.timeout(const Duration(seconds: 10));
        } finally {
          gatedRecorder.nextStopGate = null;
          if (!gateA.isCompleted) gateA.complete();
          if (stopA != null) await stopA.catchError((_) {});
          if (stopB != null) await stopB.catchError((_) {});
          await drainLocal(localController, localService);
        }
      },
    );

    // ------------------------------------------------------------------
    // Fase 16.2-R4.3-R2.6 — transitive stop discovery at session level (P1-B)
    // and the combination with session stop request identity (P1-A)
    // ------------------------------------------------------------------

    test(
      'X35-session (§33, "todos clips A indexados", independent-review P1-B 4/4) — session A\'s Recording #1 '
      'already produced its clip; a START for Recording #2 is retained. An explicit stop (2) and a targeted '
      'cleanup of the stale Recording #1 (3) are issued on the service, then the SESSION\'s own stopSession() '
      'issues the final explicit stop (4). Intent 3 resolves null; R2.5 let 4 observe only 3 and lose the real '
      'stop 2 produced, so Recording #2\'s clip was never indexed (Hive A: 1 of 2). Expected: intent 4 discovers '
      'the physical stop transitively, its late-persistence watcher is installed, and A\'s Hive record holds BOTH '
      'clips with exactly one physical STOP for Recording #2',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        Future<void>? stopA;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          final id1 = await arrangeRetainedSecondStart(localService, localController, startGate, sessionA.id);
          final controller1 = localService.previewController;

          final e2 = localService.beginStopLoopRecording();
          final t3 = localService.beginStopLoopRecording(expectedRecordingId: id1, expectedController: controller1);
          stopA = localController.stopSession();
          await stopA.timeout(const Duration(seconds: 5), onTimeout: () => fail('X35-session: stopSession() must return bounded'));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'only Recording #1\'s stop so far — #2\'s is queued behind the retained START');

          startGate.complete();
          final indexedA = await waitForIndexedCount(sessionA.id, 2);
          expect(indexedA, hasLength(2), reason: 'P1-B: Recording #2\'s clip is indexed — the session\'s stop discovered the physical stop through the chain');
          expect(indexedA.map((r) => r.filePath).toSet(), localService.clips.map((c) => c.file.path).toSet());
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'zero duplicate native STOP');
          expect(localService.clips.every((clip) => clip.producerToken == sessionA.id), isTrue);

          expect(await t3.handle.timeout(const Duration(seconds: 3)), isNull, reason: 'the stale cleanup resolved null');
          final explicit = localService.stopIntentsForTest.where((i) => i.purpose == 'explicitStop').toList();
          expect(explicit, hasLength(2), reason: 'intent 2 (service) and the session\'s own stop');
          final sessionIntent = explicit.firstWhere((i) => i.id != e2.intentId);
          expect(sessionIntent.resolvedRecordingId, isNotNull);
          expect(sessionIntent.producerIntentId, e2.intentId, reason: 'the session\'s intent ADOPTED the physical stop intent 2 issued');
          expect(sessionIntent.resolvedPhysicalStopId, explicit.firstWhere((i) => i.id == e2.intentId).resolvedPhysicalStopId);
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          if (stopA != null) await stopA.catchError((_) {});
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X40 (§38, MANDATORY — session stop request × transitive stop discovery) — A\'s stop is in flight (held) '
      'with a chain of service stop intents pending behind a retained START (its own explicit stop, a targeted '
      'cleanup of the stale Recording #1, then A\'s release); session B is born and PUBLICLY stopped. Expected: '
      'B\'s request is its own and is never lost; A\'s physical obligations stay retained until released; the '
      'intent chain does not hide the physical stop from B\'s later intents; B NEVER resurrects as recording; '
      'A\'s clips are all indexed under A and none under B',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        Future<void>? stopA;
        Future<void>? stopB;
        final gate = armFirstStopGate(localController);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          final id1 = await arrangeRetainedSecondStart(localService, localController, startGate, sessionA.id);
          final controller1 = localService.previewController;

          stopA = localController.stopSession();
          final requestIdA = localController.inFlightStopRequestIdForTest;
          await gate.entered.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('X40: A never reached its causal gate'));
          final stale = localService.beginStopLoopRecording(expectedRecordingId: id1, expectedController: controller1);
          await waitUntil(() => !recorder.isRecording, 'A\'s recorder finished');

          final sessionB = localController.startSession();
          stopB = localController.stopSession();
          final requestIdB = localController.inFlightStopRequestIdForTest;
          expect(requestIdB, isNot(equals(requestIdA)), reason: 'B\'s request is its own');
          expect(localController.inFlightStopRequestSessionIdForTest, sessionB.id);
          expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: 'B\'s acquisition is invalidated immediately');

          gate.hold.complete();
          await Future.wait<void>([stopA, stopB]).timeout(const Duration(seconds: 10), onTimeout: () => fail('X40: the stop Futures never completed'));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'A\'s Recording #2 is still queued behind the retained START — physical A remains retained');

          startGate.complete();
          final indexedA = await waitForIndexedCount(sessionA.id, 2);
          await pumpEventQueue(times: 100);

          expect(indexedA, hasLength(2), reason: 'A\'s both clips are indexed under A');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id), isNull, reason: 'nothing of A leaks into B');
          expect(localController.status, DashcamStatus.idle, reason: 'B never resurrects as recording');
          expect(recorder.isRecording, isFalse);
          expect(localController.activeCameraAttemptSessionIdForTest, isNull);
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'B never touched the camera');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'exactly one STOP for Recording #1 and one for #2 — no B STOP, no duplicate');
          expect(await stale.handle.timeout(const Duration(seconds: 3)), isNull, reason: 'the stale cleanup resolved null');

          final explicit = localService.stopIntentsForTest.where((i) => i.purpose == 'explicitStop').toList();
          expect(explicit, hasLength(2), reason: 'A\'s own stop and B\'s (which took the chain [release, cleanup, A\'s stop] as ancestry)');
          expect(explicit.every((i) => i.resolvedRecordingId != null), isTrue, reason: 'the intermediate intents did not hide the physical stop from B\'s intent');
          expect(explicit.map((i) => i.resolvedPhysicalStopId).toSet(), hasLength(1), reason: 'both refer to the ONE physical stop A\'s intent issued');
          expect(localService.maxStopIntentAncestryForTest, greaterThanOrEqualTo(3));
          expect(localService.liveStopIntentCountForTest, 0);
          expect(localService.stopIntentAncestryEntriesForTest, 0);
        } finally {
          localController.beforeImmediatePersistenceHookForTest = null;
          fakePlatform.pendingStartVideoCapturing = null;
          if (!gate.hold.isCompleted) gate.hold.complete();
          if (!startGate.isCompleted) startGate.complete();
          if (stopA != null) await stopA.catchError((_) {});
          if (stopB != null) await stopB.catchError((_) {});
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'Barreira física falha (Fase 16.2-R4.3-R2.6-EVIDENCE-CLOSURE §3) — A\'s own RAW native STOP is '
      'genuinely held PAST its own presentation deadline (buildShortStopService\'s 50ms '
      'stopVideoRecordingTimeout — A\'s own stopSession() returns bounded while the physical obligation '
      'is still retained, R2.1-X2\'s own established shape) and THEN fails terminally (a real native '
      'rejection, not a timeout) while session B has already been started and PUBLICLY stopped during '
      'that same held window (X31\'s own established shape). Expected: B never resurrects as recording '
      '(zero native camera work attributable to B); the failed native STOP is never retried (exactly one '
      '`stopVideoRecording()` call total, for A\'s own Recording — B contributes none); neither '
      'stopSession() Future hangs or lets the failure escape as an unhandled/unawaited error '
      '(`_stopCamera` itself never propagates one — this class\'s own established contract); and process '
      'ownership is NOT left fail-closed by a STOP failure alone (only a teardown/dispose failure is — '
      'see DashcamService\'s own doc): a genuinely NEW session C, started only after A and B have both '
      'concluded, must still reach recording normally, on its own fresh camera acquisition — proving C '
      'never crosses A\'s failed physical obligation nor inherits a stuck process owner.',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        Future<void>? stopA;
        Future<void>? stopB;
        final stopGateA = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGateA;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController, label: 'barrier-failure: A initial acquisition');

          stopA = localController.stopSession();
          await waitUntil(() => fakePlatform.calls.where((c) => c == 'stopVideoRecording').isNotEmpty, 'A\'s raw native STOP genuinely issued');
          // A's own public stopSession() must return bounded by its 50ms
          // presentation deadline even though the raw native STOP below is
          // still genuinely retained — awaiting it here is itself the proof.
          await stopA.timeout(
            const Duration(seconds: 3),
            onTimeout: () => fail('barrier-failure: A\'s own stopSession() must return bounded by its presentation deadline even while the raw STOP is held'),
          );
          await waitUntil(() => !recorder.isRecording, 'A\'s recorder finished (so B may start)');

          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(equals(sessionA.id)));
          expect(
            localController.activeCameraAttemptSessionIdForTest,
            sessionB.id,
            reason: 'test setup: B has a registered acquisition, blocked behind A\'s still-retained physical barrier',
          );
          final createsBeforeStopB = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length;

          stopB = localController.stopSession();
          expect(
            localController.activeCameraAttemptSessionIdForTest,
            isNull,
            reason: 'B\'s acquisition is invalidated IMMEDIATELY — before A\'s physical obligation even resolves, let alone fails',
          );

          // NOW fail A's raw native STOP terminally — after both A's own
          // presentation and B's own public stop request have already,
          // genuinely happened while it was held (never a bare timeout: a
          // real native rejection).
          stopGateA.completeError(CameraException('finalize_failed', 'forced physical STOP failure (evidence-closure §3)'));

          await Future.wait<void>([stopB]).timeout(const Duration(seconds: 10), onTimeout: () => fail('barrier-failure: B\'s own stop Future never completed'));
          await pumpEventQueue(times: 100);

          expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: 'no attempt left that could resurrect B');
          expect(recorder.isRecording, isFalse);
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(createsBeforeStopB), reason: 'B never touched the camera');
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1), reason: 'only A ever started a Recording');
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'the failed native STOP for A is never retried — B contributes zero, and nothing repeats A\'s own',
          );

          // Process ownership must not be left fail-closed by a STOP failure
          // alone (only a teardown/dispose failure is — see DashcamService's
          // own doc): a genuinely fresh session C must still reach recording.
          final sessionC = localController.startSession();
          expect(sessionC.id, isNot(equals(sessionA.id)));
          expect(sessionC.id, isNot(equals(sessionB.id)));
          await waitForStatus(DashcamStatus.recording, on: localController, label: 'barrier-failure: C reaches recording despite A\'s failed physical STOP');
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(createsBeforeStopB + 1),
            reason: 'C acquired its own, fresh camera — never inherited A\'s failed obligation nor a stuck process owner',
          );

          await localController.stopSession();
        } finally {
          if (!stopGateA.isCompleted) stopGateA.complete();
          fakePlatform.pendingStopVideoRecording = null;
          if (stopA != null) await stopA.catchError((_) {});
          if (stopB != null) await stopB.catchError((_) {});
          await drainLocal(localController, localService);
        }
      },
    );

    // Fase 16.2-R4.3-R2.6.1 (§5, pre-audit TG-2): the shared arrangement helper
    // must support a native STOP well past the presentation deadline. 120ms is
    // the value the pre-audit reproduced the fragility with (X35-session and X40
    // failed at setup with `Actual: []`); 250ms leaves a margin above it.
    for (final stopDelayMs in const [120, 250]) {
      test(
        'R2.6.1-H1 (§5, harness — "arrangeRetainedSecondStart frágil") — the retained-START arrangement holds with a '
        'native STOP of ${stopDelayMs}ms, far past the 50ms presentation deadline: the setup waits on the CAUSAL state '
        '(physical STOP settled, clip published) instead of assuming stopLoopRecording() returned with the clip ready. '
        'Expected: the arrangement\'s own postconditions hold and the X23-shaped flow then completes — both of A\'s '
        'clips indexed under A, exactly two physical STOPs',
        () async {
          final localService = buildShortStopService();
          localService.trackStopIntentsForTest = true;
          final localController = buildLocalController(localService);
          final startGate = Completer<void>();
          fakePlatform.stopVideoRecordingDelay = Duration(milliseconds: stopDelayMs);
          Future<void>? stopA;
          try {
            await preferences.setEnabled(true);
            final sessionA = localController.startSession();
            await arrangeRetainedSecondStart(localService, localController, startGate, sessionA.id);
            expect(localService.hasPendingNativeStop, isFalse, reason: 'no physical STOP is pending once the arrangement returns');
            expect(localService.clips, hasLength(1));

            stopA = localController.stopSession();
            await stopA.timeout(const Duration(seconds: 5), onTimeout: () => fail('R2.6.1-H1: stopSession() must return bounded'));
            startGate.complete();
            final indexedA = await waitForIndexedCount(sessionA.id, 2);
            expect(indexedA, hasLength(2), reason: 'both of A\'s clips are indexed under A');
            expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'one physical STOP per Recording — no duplicate');
          } finally {
            fakePlatform.stopVideoRecordingDelay = null;
            fakePlatform.pendingStartVideoCapturing = null;
            if (!startGate.isCompleted) startGate.complete();
            if (stopA != null) await stopA.catchError((_) {});
            await drainLocal(localController, localService);
          }
        },
      );
    }
  });

  // ==========================================================================
  // Fase 16.2-R4.3-R2.6.1 — session admission (START during the recorder's own
  // stop) + re-entrant STOP safety. Independent pre-audit P2-1 / P2-2 (both
  // pre-existing, identical in R2.5). Every test here that needs the recorder
  // "in the middle of ending A" uses the REAL [DrivingSessionRecorder], held
  // inside its real stopSession() by gating its snapshot subscription's
  // cancel() ([_CancelGatedStream]) — no recorder subclass, no fake, no sleep
  // as proof.
  // ==========================================================================
  group('Fase 16.2-R4.3-R2.6.1 — session admission + re-entrant stop safety', () {
    DashcamService buildShortStopService() => buildLocalService(stopVideoRecordingTimeout: const Duration(milliseconds: 50));

    Future<void> waitUntil(bool Function() condition, String label, {int maxIterations = 300}) async {
      for (var i = 0; i < maxIterations; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('waitUntil: "$label" never became true after ${maxIterations * 10}ms (calls: ${fakePlatform.calls.join(',')})');
    }

    int nativeCalls(String call) => fakePlatform.calls.where((c) => c == call).length;

    Future<List<DashcamClipRecord>> waitForIndexedCount(String sessionId, int expected) async {
      List<DashcamClipRecord> indexed = const [];
      for (var i = 0; i < 300; i++) {
        final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List?;
        indexed = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
        if (indexed.length >= expected) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return indexed;
    }

    /// A controller over a REAL recorder whose stopSession() can be held inside
    /// its real "ending" window — see [_CancelGatedStream].
    ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) buildGatedRecorderController(DashcamService localService) {
      final gate = _CancelGatedStream(snapshotController.stream);
      final gatedRecorder = DrivingSessionRecorder(gate);
      final localController = DashcamSessionController(
        dashcamService: localService,
        dashcamPreferences: preferences,
        sessionRecorder: gatedRecorder,
        snapshotStream: snapshotController.stream,
        eventStream: eventController.stream,
      );
      return (recorder: gatedRecorder, gate: gate, controller: localController);
    }

    test(
      'X41 (§2, MANDATORY GATE, pre-audit P2-1 exact reproduction — "START durante o STOP do recorder de A") — the REAL '
      'recorder is still ending A (held inside stopSession()) while A\'s camera side already finished: status is idle, '
      'which is exactly when the dashcam tile offers "Iniciar sessão". Pre-fix, startSession() returned A itself, re-armed '
      'the camera for it, and the next stopSession() was absorbed by A\'s own request — a live Recording with no session, '
      'and the following session\'s clips attributed to A. Expected: the START is REJECTED (StateError) with NO effect '
      'whatsoever — no recorder call, no camera acquisition, no attempt, recordingSessionId still null, A\'s request and '
      'session untouched — a second stopSession() legitimately joins A\'s own request, the controller announces the '
      'moment a start becomes admissible again, and a genuinely NEW session B then records and is stopped with every '
      'clip attributed to its own producer',
      () async {
        final localService = buildShortStopService();
        final rig = buildGatedRecorderController(localService);
        final localController = rig.controller;
        final endingGate = Completer<void>();
        final canStartSeen = <bool>[];
        Future<void>? stopA;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          rig.gate.nextCancelGate = endingGate;
          stopA = localController.stopSession();
          final requestIdA = localController.inFlightStopRequestIdForTest;
          await waitUntil(() => rig.gate.cancelEnteredCount >= 1, 'the REAL recorder entered its stopSession() (held inside subscription.cancel())');
          await waitUntil(() => localService.previewController == null && localController.status == DashcamStatus.idle, 'A\'s camera side finished');

          // ---- setup facts: this IS the tile-offers-Start window -------------
          expect(identical(rig.recorder.activeSession, sessionA), isTrue, reason: 'setup: the recorder still holds A — it clears it only after its flush/save');
          expect(rig.recorder.isRecording, isTrue);
          expect(localController.status, DashcamStatus.idle, reason: 'setup: the tile offers "Iniciar sessão" for status idle');
          expect(localController.recordingSessionIdForTest, isNull, reason: 'setup: A\'s camera side already released its session');
          expect(localController.canStartSession, isFalse, reason: 'A is ENDING — it must not be admissible as a new session');
          final createsBefore = nativeCalls('createCameraWithSettings');
          final startsBefore = nativeCalls('startVideoCapturing');
          final stopsBefore = nativeCalls('stopVideoRecording');
          final attemptsBefore = localController.cameraAttemptCreationCountForTest;
          final watchersBefore = localController.lateInitializeWatcherInstallCountForTest;
          final setupsBefore = localController.initialSetupInstallCountForTest;
          localController.addListener(() => canStartSeen.add(localController.canStartSession));

          void expectNoEffect(String when, {bool requestStillInFlight = true}) {
            expect(localController.recordingSessionIdForTest, isNull, reason: '$when: recordingSessionId stays null — A was not re-registered');
            expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: '$when: no camera acquisition intent exists');
            expect(localController.cameraAttemptCreationCountForTest, attemptsBefore, reason: '$when: no attempt was ever created');
            expect(localController.lateInitializeWatcherInstallCountForTest, watchersBefore, reason: '$when: no watcher that could act later');
            expect(localController.initialSetupInstallCountForTest, setupsBefore, reason: '$when: no telemetry setup');
            expect(localController.status, DashcamStatus.idle, reason: '$when: status is untouched');
            expect(nativeCalls('createCameraWithSettings'), createsBefore, reason: '$when: zero camera acquisition');
            expect(nativeCalls('startVideoCapturing'), startsBefore, reason: '$when: zero native START');
            expect(nativeCalls('stopVideoRecording'), stopsBefore, reason: '$when: zero extra native STOP');
            if (requestStillInFlight) {
              expect(localController.inFlightStopRequestIdForTest, requestIdA, reason: '$when: A\'s stop request is the same one, untouched');
              expect(localController.inFlightStopRequestSessionIdForTest, sessionA.id);
              expect(identical(rig.recorder.activeSession, sessionA), isTrue, reason: '$when: A is still the recorder\'s (ending) session — not replaced, not reactivated');
            }
          }

          // ---- the rejected START (what the tile's button would do) -----------
          expect(() => localController.startSession(), throwsStateError, reason: 'START while A is ending is REJECTED, never aliased to A');
          expectNoEffect('right after the rejected START (same synchronous slice)');
          await pumpEventQueue(times: 100);
          expectNoEffect('after the event queue drained — nothing can still be in flight for it');

          // ---- a later stopSession() targets A itself: joining is correct -----
          final joined = localController.stopSession();
          expect(identical(joined, stopA), isTrue, reason: 'A is still the ending session — joining ITS request is not an absorption');
          expect(localController.inFlightStopRequestIdForTest, requestIdA);

          // ---- A really ends; the controller announces re-admission ----------
          endingGate.complete();
          await stopA.timeout(const Duration(seconds: 10), onTimeout: () => fail('X41: A\'s stop never concluded'));
          expect(rig.recorder.isRecording, isFalse);
          expect(localController.canStartSession, isTrue);
          expect(canStartSeen, isNotEmpty, reason: 'the controller notified when the ending window closed — a disabled start control can re-enable itself');
          expect(canStartSeen.every((v) => v), isTrue, reason: 'every notification observed after the rejection reports canStartSession == true only once A really ended');
          expect(nativeCalls('startVideoCapturing'), startsBefore, reason: 'no orphan Recording: still only A\'s');
          expect(nativeCalls('stopVideoRecording'), stopsBefore, reason: 'and A\'s own Recording was stopped exactly once');
          expect(localService.previewController, isNull, reason: 'the camera is released — nothing is left holding it');
          expectNoEffect('after A ended', requestStillInFlight: false);

          // ---- and now a genuinely NEW session is admitted and attributed correctly
          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(equals(sessionA.id)), reason: 'a NEW session, not A brought back');
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.recordingSessionIdForTest, sessionB.id);
          expect(nativeCalls('createCameraWithSettings'), createsBefore + 1, reason: 'B acquired its OWN camera');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          // A's clip settled long before B acquired its camera (FIFO); B's own
          // STOP returned only at its 50ms presentation deadline — R2.6.3-T1.
          final clipsA = localService.clips.where((c) => c.producerToken == sessionA.id).toList();
          final clipsB = await settledClipsOf(localService, sessionB.id, atLeast: 1);
          expect(clipsA, hasLength(1));
          expect(clipsB, hasLength(1), reason: 'B\'s own recording produced ITS clip — not attributed to A');
          expect((await waitForIndexedCount(sessionA.id, 1)).map((r) => r.filePath), [clipsA.single.file.path]);
          expect((await waitForIndexedCount(sessionB.id, 1)).map((r) => r.filePath), [clipsB.single.file.path], reason: 'B\'s Hive record holds B\'s clip');
          expect(nativeCalls('startVideoCapturing'), nativeCalls('stopVideoRecording'), reason: 'every started Recording was stopped');
        } finally {
          if (!endingGate.isCompleted) endingGate.complete();
          if (stopA != null) await stopA.catchError((_) {});
          try {
            await localController.stopSession();
          } catch (_) {}
          await drainLocal(localController, localService);
          rig.recorder.dispose();
        }
      },
    );

    testWidgets(
      'X41-ui (§2, UI contract) — the dashcam tile\'s "Iniciar sessão" (shown for status idle) is DISABLED while the '
      'REAL recorder is still ending A, so the rejection path is not reachable from a tap; it re-enables the moment '
      'the controller announces re-admission (the tile listens to the controller, not to the recorder), and tapping it '
      'then starts a genuinely NEW session',
      (tester) async {
        // Everything that owns real async work (service, recorder, controller) is built INSIDE runAsync:
        // objects created in the FakeAsync zone would park their continuations there and never run.
        late DashcamService localService;
        late ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) rig;
        late DashcamSessionController localController;
        final endingGate = Completer<void>();
        Future<void>? stopA;
        String? sessionAId;
        try {
          await tester.runAsync(() async {
            localService = buildShortStopService();
            rig = buildGatedRecorderController(localService);
            localController = rig.controller;
            await preferences.setEnabled(true);
            sessionAId = localController.startSession().id;
            await waitForStatus(DashcamStatus.recording, on: localController);
            rig.gate.nextCancelGate = endingGate;
            stopA = localController.stopSession();
            await waitUntil(
              () => rig.gate.cancelEnteredCount >= 1 && localService.previewController == null && localController.status == DashcamStatus.idle,
              'A\'s camera side finished while the REAL recorder is still ending A',
            );
          });
          expect(localController.canStartSession, isFalse, reason: 'setup: A is ending');

          await tester.pumpWidget(MaterialApp(home: Scaffold(body: DashcamPreviewView(controller: localController))));
          expect(find.text('Iniciar sessão'), findsOneWidget, reason: 'status idle: the tile offers Start');
          FilledButton startButton() => tester.widget<FilledButton>(find.bySubtype<FilledButton>());
          expect(startButton().onPressed, isNull, reason: 'A is ending: the Start control is disabled — a tap cannot reach a rejected startSession()');

          await tester.runAsync(() async {
            endingGate.complete();
            await stopA!.timeout(const Duration(seconds: 10), onTimeout: () => fail('X41-ui: A\'s stop never concluded'));
          });
          await tester.pump();
          expect(startButton().onPressed, isNotNull, reason: 'the controller announced re-admission — the tile re-enabled itself');

          // The button's own onPressed IS the tap handler; it is invoked inside runAsync (not via
          // tester.tap) because a gesture handler runs in the FakeAsync zone, where the real async
          // camera/Hive work a started session needs would never make progress.
          final onPressed = startButton().onPressed!;
          await tester.runAsync(() async => onPressed());
          // Dispose the tile right away: this test is about the control, not the live preview.
          await tester.pumpWidget(const SizedBox());
          expect(localController.recordingSessionIdForTest, isNotNull, reason: 'the tap started a session');
          expect(localController.recordingSessionIdForTest, isNot(equals(sessionAId)), reason: 'a NEW session, not A');
          await tester.runAsync(() async {
            await waitForStatus(DashcamStatus.recording, on: localController);
            await localController.stopSession().timeout(const Duration(seconds: 10));
          });
        } finally {
          await tester.runAsync(() async {
            if (!endingGate.isCompleted) endingGate.complete();
            if (stopA != null) await stopA!.catchError((_) {});
            try {
              await localController.stopSession();
            } catch (_) {}
            await drainLocal(localController, localService);
            rig.recorder.dispose();
          });
        }
      },
    );

    test(
      'X42 (§3, MANDATORY GATE, pre-audit P2-2 exact reproduction — "STOP reentrante durante a publicação de B") — a '
      'RECORDER listener calls stopSession() synchronously while startSession() is still publishing B '
      '(DrivingSessionRecorder.startSession() notifies before it returns). Pre-fix, B was already the recorder\'s active '
      'session but not yet the controller\'s recordingSessionId: the re-entrant STOP captured target B yet acted on a stale '
      'id, stopped nothing on the camera side, and B then reached recording. Expected: B is fully identifiable in the '
      'controller DURING the notification (recordingSessionId == B, the stop request targets B), the re-entrant STOP '
      'cancels it, and B never touches the camera — zero native calls, no attempt ever created, no telemetry writer, '
      'no watcher — and NOTHING later (an app pause/resume included) can bring it back',
      () async {
        final localRecorder = DrivingSessionRecorder(snapshotController.stream);
        final localService = buildShortStopService();
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: localRecorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        Future<void>? reentrantStop;
        String? activeAtReentry;
        String? recordingSessionIdAtReentry;
        int? requestIdAtReentry;
        String? requestTargetAtReentry;
        var listenerCalls = 0;
        localRecorder.addListener(() {
          listenerCalls++;
          if (localRecorder.isRecording && reentrantStop == null) {
            activeAtReentry = localRecorder.activeSession!.id;
            recordingSessionIdAtReentry = localController.recordingSessionIdForTest;
            reentrantStop = localController.stopSession();
            requestIdAtReentry = localController.inFlightStopRequestIdForTest;
            requestTargetAtReentry = localController.inFlightStopRequestSessionIdForTest;
          }
        });
        try {
          await preferences.setEnabled(true);
          final sessionB = localController.startSession();

          // ---- during the notification ------------------------------------
          expect(listenerCalls, greaterThanOrEqualTo(1));
          expect(activeAtReentry, sessionB.id, reason: 'B was already the recorder\'s active session when the listener ran');
          expect(recordingSessionIdAtReentry, sessionB.id, reason: 'B was ALREADY identifiable in the controller during the recorder notification — the STOP\'s target exists');
          expect(requestIdAtReentry, isNotNull);
          expect(requestTargetAtReentry, sessionB.id, reason: 'the re-entrant request targets B');

          void expectStoppedAtBirth(String when) {
            expect(localController.recordingSessionIdForTest, isNull, reason: '$when: B was cancelled — the re-entrant STOP invalidated it');
            expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: '$when: no acquisition intent');
            expect(localController.cameraAttemptCreationCountForTest, 0, reason: '$when: no attempt was even created for a session stopped at birth');
            expect(localController.lateInitializeWatcherInstallCountForTest, 0, reason: '$when: no late watcher');
            expect(localController.initialSetupInstallCountForTest, 0, reason: '$when: no telemetry setup');
            expect(localController.status, isNot(DashcamStatus.recording), reason: '$when: never recording');
            expect(localController.status, isNot(DashcamStatus.initializing));
            expect(fakePlatform.calls, isEmpty, reason: '$when: ZERO native camera calls for B');
            expect(localService.previewController, isNull);
            expect(localService.isRecording, isFalse, reason: '$when: no recording loop');
            expect(localService.pendingInitializeSettlement, isNull);
          }

          // ---- right after startSession() returned (same slice) -----------
          expectStoppedAtBirth('right after startSession() returned');

          await reentrantStop!.timeout(const Duration(seconds: 5), onTimeout: () => fail('X42: the re-entrant stop never concluded'));
          await pumpEventQueue(times: 100);
          expectStoppedAtBirth('after the re-entrant stop concluded and the queue drained');
          expect(localRecorder.isRecording, isFalse, reason: 'the recorder side of B ended too — no orphan session');
          expect(await (await DashcamTelemetryWriter.fileForSession(sessionB.id)).exists(), isFalse, reason: 'no telemetry file was ever opened for B');

          // ---- nothing can bring B back: a real pause/resume cycle ---------
          // ignore: invalid_use_of_visible_for_testing_member
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          // ignore: invalid_use_of_visible_for_testing_member
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await pumpEventQueue(times: 100);
          expectStoppedAtBirth('after an app pause/resume cycle — no lifecycle callback resurrects a stopped session');

          // ---- the controller is not wedged: a fresh session works ---------
          await waitUntil(() => localController.canStartSession && !localRecorder.isRecording, 'the controller may admit a new session');
          final sessionC = localController.startSession();
          expect(sessionC.id, isNot(equals(sessionB.id)));
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.recordingSessionIdForTest, sessionC.id);
          await localController.stopSession().timeout(const Duration(seconds: 10));
          // R2.6.3-T1: C's STOP returned at its 50ms presentation deadline.
          expect(await settledClipsOf(localService, sessionC.id, atLeast: 1), hasLength(1));
          expect(localService.clips.where((c) => c.producerToken == sessionB.id), isEmpty, reason: 'B never recorded — it owns no clip');
        } finally {
          if (reentrantStop != null) await reentrantStop!.catchError((_) {});
          await drainLocal(localController, localService);
          localRecorder.dispose();
        }
      },
    );

    test(
      'X42-controller (§3, characterization of the OTHER synchronous publication point) — a CONTROLLER listener calls '
      'stopSession() from inside the `initializing` notification that _startCamera issues before its first native '
      'call. Expected: the request targets the session, its attempt is already registered and is invalidated by the '
      'ordinary stop path, and not one native call is ever emitted (the pre-emission checkpoint in '
      'DashcamService.initialize() sees the invalidated attempt) — the same guarantee X42 gives for the recorder '
      'notification, without relying on the absence of such listeners',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        Future<void>? reentrantStop;
        int? requestIdAtReentry;
        String? recordingSessionIdAtReentry;
        localController.addListener(() {
          if (localController.status == DashcamStatus.initializing && reentrantStop == null) {
            recordingSessionIdAtReentry = localController.recordingSessionIdForTest;
            reentrantStop = localController.stopSession();
            requestIdAtReentry = localController.inFlightStopRequestIdForTest;
          }
        });
        try {
          await preferences.setEnabled(true);
          final sessionB = localController.startSession();
          expect(reentrantStop, isNotNull, reason: 'test setup: the listener fired at the initializing notification');
          expect(recordingSessionIdAtReentry, sessionB.id, reason: 'B was already registered at that notification');
          expect(requestIdAtReentry, isNotNull);

          await reentrantStop!.timeout(const Duration(seconds: 5), onTimeout: () => fail('X42-controller: the re-entrant stop never concluded'));
          await pumpEventQueue(times: 100);
          expect(fakePlatform.calls, isEmpty, reason: 'ZERO native calls — the invalidated attempt was honoured before any emission');
          expect(localController.status, DashcamStatus.idle);
          expect(localController.recordingSessionIdForTest, isNull);
          expect(localController.activeCameraAttemptSessionIdForTest, isNull);
          expect(localController.initialSetupInstallCountForTest, 0);
          expect(localService.previewController, isNull);
          expect(recorder.isRecording, isFalse);
        } finally {
          if (reentrantStop != null) await reentrantStop!.catchError((_) {});
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X43 (§4, normal flow) — A → STOP → START B → STOP B, every step awaited, real recorder, no gates. Expected: each '
      'session gets its OWN camera acquisition, its own distinct stop request, and exactly its own clip indexed under its '
      'own id; nothing is left running, registered or in flight afterwards',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.recordingSessionIdForTest, sessionA.id);
          final stopA = localController.stopSession();
          final requestIdA = localController.inFlightStopRequestIdForTest;
          await stopA.timeout(const Duration(seconds: 10));
          expect(localController.canStartSession, isTrue, reason: 'A ended completely — a new session is admissible');
          expect(recorder.isRecording, isFalse);
          expect(localController.recordingSessionIdForTest, isNull);
          expect(localController.status, DashcamStatus.idle);

          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(equals(sessionA.id)), reason: 'B is a genuinely new logical session');
          expect(localController.recordingSessionIdForTest, sessionB.id);
          await waitForStatus(DashcamStatus.recording, on: localController);
          final stopB = localController.stopSession();
          expect(localController.inFlightStopRequestIdForTest, isNot(equals(requestIdA)), reason: 'B\'s stop is its own request');
          expect(localController.inFlightStopRequestSessionIdForTest, sessionB.id);
          await stopB.timeout(const Duration(seconds: 10));

          expect(nativeCalls('createCameraWithSettings'), 2, reason: 'each session acquired its own camera');
          expect(nativeCalls('startVideoCapturing'), 2);
          expect(nativeCalls('stopVideoRecording'), 2);
          expect(nativeCalls('dispose'), 2, reason: 'each camera was released');
          final clipsA = localService.clips.where((c) => c.producerToken == sessionA.id).toList();
          final clipsB = localService.clips.where((c) => c.producerToken == sessionB.id).toList();
          expect(clipsA, hasLength(1));
          expect(clipsB, hasLength(1));
          expect((await waitForIndexedCount(sessionA.id, 1)).map((r) => r.filePath), [clipsA.single.file.path]);
          expect((await waitForIndexedCount(sessionB.id, 1)).map((r) => r.filePath), [clipsB.single.file.path]);
          expect(localController.inFlightStopRequestIdForTest, isNull);
          expect(localController.activeCameraAttemptSessionIdForTest, isNull);
          expect(localController.recordingSessionIdForTest, isNull);
          expect(localController.status, DashcamStatus.idle);
          expect(recorder.isRecording, isFalse);
          expect(localController.canStartSession, isTrue);
          expect(localService.previewController, isNull);
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X44 (§4, rapid START/STOP during a RETAINED physical teardown) — A\'s raw native STOP is genuinely held past its '
      'presentation deadline (A\'s public stop already returned; the physical obligation is retained). Four sessions are '
      'then started and stopped back-to-back; in every cycle a START issued in the SAME slice as the stop is REJECTED '
      '(the session is ending), never aliased. Expected: no rapid session ever acquires the camera (ONE create, ONE START, '
      'ONE STOP, all A\'s, while A\'s STOP is held), every cycle is its own request, and once A\'s STOP is released only '
      'A\'s clip exists — indexed under A — and a fresh session Z then records and is attributed correctly',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final rawStopA = Completer<void>();
        final pendingStops = <Future<void>>[];
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          fakePlatform.pendingStopVideoRecording = rawStopA;
          final stopA = localController.stopSession();
          await waitUntil(() => nativeCalls('stopVideoRecording') == 1, 'A\'s raw native STOP was issued (and is held)');
          await stopA.timeout(const Duration(seconds: 5), onTimeout: () => fail('X44: A\'s public stop must return bounded by its presentation deadline'));
          expect(localService.hasPendingNativeStop, isTrue, reason: 'setup: A\'s physical obligation is RETAINED');
          await waitUntil(() => !recorder.isRecording, 'A\'s recorder finished');

          final ids = <String>{sessionA.id};
          final requestIds = <int?>{};
          for (var cycle = 1; cycle <= 4; cycle++) {
            await waitUntil(() => localController.canStartSession && !recorder.isRecording, 'cycle $cycle: the previous session fully ended on the recorder side');
            final session = localController.startSession();
            expect(ids.add(session.id), isTrue, reason: 'cycle $cycle: a distinct new session');
            final stop = localController.stopSession();
            pendingStops.add(stop);
            expect(requestIds.add(localController.inFlightStopRequestIdForTest), isTrue, reason: 'cycle $cycle: its own request identity');
            expect(localController.inFlightStopRequestSessionIdForTest, session.id);
            expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: 'cycle $cycle: invalidated in the same slice');
            expect(localController.recordingSessionIdForTest, isNull);
            expect(() => localController.startSession(), throwsStateError, reason: 'cycle $cycle: START in the same slice as the stop is rejected (the session is ending)');
            expect(localController.recordingSessionIdForTest, isNull, reason: 'cycle $cycle: the rejected START re-registered nothing');
            expect(localController.activeCameraAttemptSessionIdForTest, isNull);
          }
          await waitUntil(() => !recorder.isRecording, 'the last rapid session ended on the recorder side');

          expect(nativeCalls('createCameraWithSettings'), 1, reason: 'no rapid session touched the camera while A\'s STOP is held — only A\'s');
          expect(nativeCalls('startVideoCapturing'), 1);
          expect(nativeCalls('stopVideoRecording'), 1, reason: 'A\'s one raw STOP; nothing repeats it, no rapid session adds one');

          rawStopA.complete();
          await Future.wait<void>(pendingStops).timeout(const Duration(seconds: 10), onTimeout: () => fail('X44: a rapid session\'s stop never concluded'));
          fakePlatform.pendingStopVideoRecording = null;
          final indexedA = await waitForIndexedCount(sessionA.id, 1);
          await pumpEventQueue(times: 100);
          expect(indexedA, hasLength(1), reason: 'A\'s clip, produced once its held STOP was released, is indexed under A');
          expect(localService.clips.where((c) => c.producerToken != sessionA.id), isEmpty, reason: 'no rapid session produced a clip');
          for (final id in ids.where((id) => id != sessionA.id)) {
            expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(id), isNull, reason: 'nothing of A leaked into rapid session $id');
          }
          expect(localController.activeCameraAttemptSessionIdForTest, isNull);
          expect(localController.status, DashcamStatus.idle);
          expect(nativeCalls('createCameraWithSettings'), 1, reason: 'still only A\'s camera — nothing resurrected after the release');

          // A fresh session after the storm is a normal one.
          final sessionZ = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(nativeCalls('createCameraWithSettings'), 2);
          await localController.stopSession().timeout(const Duration(seconds: 10));
          // R2.6.3-T1: Z's STOP returned at its 50ms presentation deadline.
          final clipsZ = await settledClipsOf(localService, sessionZ.id, atLeast: 1);
          expect(clipsZ, hasLength(1));
          expect((await waitForIndexedCount(sessionZ.id, 1)).map((r) => r.filePath), [clipsZ.single.file.path]);
          expect(localService.liveStopIntentCountForTest, 0);
          expect(localService.stopIntentAncestryEntriesForTest, 0);
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!rawStopA.isCompleted) rawStopA.complete();
          for (final pending in pendingStops) {
            await pending.catchError((_) {});
          }
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X45 (§2, marker identity) — the "ending" marker belongs to ONE session: A\'s public stop is still open (its '
      'recorder future is gated AFTER the recorder already cleared A — the X34 shape) when B starts, records, and is '
      'itself stopped, its REAL recorder held inside stopSession(). Then A\'s OLD recorder future finally completes. '
      'Expected: A finishing late does not re-admit while B is still ending — canStartSession stays false and a START '
      'is still rejected — and only B\'s own end re-opens admission',
      () async {
        final cancelGate = _CancelGatedStream(snapshotController.stream);
        final gatedRecorder = _GatedStopRecorder(cancelGate);
        final localService = buildShortStopService();
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: gatedRecorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        final lateGateA = Completer<void>();
        final endingGateB = Completer<void>();
        Future<void>? stopA;
        Future<void>? stopB;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);

          gatedRecorder.nextStopGate = lateGateA;
          stopA = localController.stopSession();
          await waitUntil(() => localService.previewController == null && !gatedRecorder.isRecording, 'A\'s camera teardown and recorder both finished');
          expect(localController.canStartSession, isTrue, reason: 'the recorder already cleared A — a new session is admissible although A\'s public Future is still open');

          final sessionB = localController.startSession();
          expect(sessionB.id, isNot(equals(sessionA.id)));
          await waitForStatus(DashcamStatus.recording, on: localController);

          cancelGate.nextCancelGate = endingGateB;
          stopB = localController.stopSession();
          await waitUntil(() => cancelGate.cancelEnteredCount >= 2, 'B\'s REAL recorder entered its stopSession() (A\'s was the first cancel)');
          expect(gatedRecorder.activeSession?.id, sessionB.id, reason: 'setup: B is the recorder\'s session and is ending');
          expect(localController.canStartSession, isFalse, reason: 'B is ENDING');

          // A's OLD recorder future completes now — while B is still ending.
          lateGateA.complete();
          await stopA.timeout(const Duration(seconds: 10), onTimeout: () => fail('X45: A\'s stop never concluded'));
          await pumpEventQueue(times: 50);
          expect(localController.canStartSession, isFalse, reason: 'an OLDER stop finishing late must not clear the marker of the session that is still ending');
          expect(() => localController.startSession(), throwsStateError, reason: 'B is still ending: START stays rejected');

          endingGateB.complete();
          await stopB.timeout(const Duration(seconds: 10), onTimeout: () => fail('X45: B\'s stop never concluded'));
          expect(localController.canStartSession, isTrue, reason: 'B\'s own end re-opens admission');
        } finally {
          gatedRecorder.nextStopGate = null;
          if (!lateGateA.isCompleted) lateGateA.complete();
          if (!endingGateB.isCompleted) endingGateB.complete();
          for (final pending in [stopA, stopB]) {
            if (pending != null) await pending.catchError((_) {});
          }
          await drainLocal(localController, localService);
          gatedRecorder.dispose();
        }
      },
    );

    test(
      'X46 (§2, "preservar o contrato de UI existente quando válido") — the alias that IS valid is preserved: the '
      'dashcam is enabled while a driving session is already ALIVE (recorder-only until now), the tile therefore '
      'shows status idle and offers "Iniciar sessão", and startSession() returns that SAME session and arms the '
      'camera for it — no rejection, no second session, no second camera. Rejection applies only to a session that '
      'is ENDING (X41). Expected: same object, one camera acquisition for it, idempotent on a repeat, its clip '
      'indexed under it, and a later stop ends it normally',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          final sessionA = localController.startSession();
          expect(localController.status, DashcamStatus.disabled, reason: 'setup: the dashcam feature is off — recorder-only session');
          expect(localController.recordingSessionIdForTest, isNull);
          expect(fakePlatform.calls, isEmpty);

          await preferences.setEnabled(true);
          expect(localController.status, DashcamStatus.idle, reason: 'setup: this is when the tile offers "Iniciar sessão" — A is alive');
          expect(localController.canStartSession, isTrue, reason: 'A is alive, not ending — admissible (as the existing contract)');

          final again = localController.startSession();
          expect(identical(again, sessionA), isTrue, reason: 'the SAME session — the long-standing alias contract, not a new one');
          expect(localController.recordingSessionIdForTest, sessionA.id, reason: 'the camera side is now registered for A');
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(identical(localController.startSession(), sessionA), isTrue, reason: 'idempotent on a repeat');
          await pumpEventQueue(times: 50);
          expect(nativeCalls('createCameraWithSettings'), 1, reason: 'exactly one camera acquisition for A — no second camera');

          await localController.stopSession().timeout(const Duration(seconds: 10));
          final clipsA = localService.clips.where((c) => c.producerToken == sessionA.id).toList();
          expect(clipsA, hasLength(1));
          expect((await waitForIndexedCount(sessionA.id, 1)).map((r) => r.filePath), [clipsA.single.file.path]);
          expect(recorder.isRecording, isFalse);
          expect(localController.canStartSession, isTrue);
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'R2.6.1-B1 BARRIER (§5, pre-audit TG-1 — "a barreira física do controller não é discriminada por nenhum teste") — '
      'A\'s stop is held at a real causal point INSIDE the controller (its immediate-persistence gate), so A\'s '
      'teardown is genuinely in flight; B is born and stopped; C is born. The physical barrier parks B\'s '
      'camera-side stop behind A: B\'s service-side STOP intent must NOT exist yet (checked in the SAME synchronous '
      'slice as stopSession(B) — without the barrier B\'s stop runs straight through and issues it there), and C must '
      'not acquire a camera while A is held. Expected once A is released: B\'s intent is issued only afterwards, C\'s '
      'acquisition strictly follows A\'s camera dispose, and C reaches recording and STAYS there once every earlier '
      'session\'s late continuation has concluded',
      () async {
        final localService = buildShortStopService();
        localService.trackStopIntentsForTest = true;
        final localController = buildLocalController(localService);
        final hold = Completer<void>();
        final entered = Completer<void>();
        var holdCalls = 0;
        localController.beforeImmediatePersistenceHookForTest = () async {
          if (++holdCalls == 1) {
            entered.complete();
            await hold.future;
          }
        };
        int explicitIntents() => localService.stopIntentsForTest.where((i) => i.purpose == 'explicitStop').length;
        Future<void>? stopA;
        Future<void>? stopB;
        Future<void>? stopC;
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          stopA = localController.stopSession();
          await entered.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('BARRIER: A\'s stop never reached its causal gate'));
          await waitUntil(() => !recorder.isRecording, 'A\'s recorder finished (so B may start)');
          expect(explicitIntents(), 1, reason: 'setup: only A\'s own stop intent exists while A is held');

          final sessionB = localController.startSession();
          stopB = localController.stopSession();
          expect(
            explicitIntents(),
            1,
            reason: 'the physical barrier parks B\'s camera-side stop behind A: B\'s STOP intent does not exist yet — '
                'without the barrier it is issued synchronously here',
          );
          expect(localController.activeCameraAttemptSessionIdForTest, isNull, reason: 'B\'s acquisition is invalidated immediately');
          await waitUntil(() => !recorder.isRecording, 'B\'s recorder finished');

          final sessionC = localController.startSession();
          expect(localController.activeCameraAttemptSessionIdForTest, sessionC.id, reason: 'C\'s acquisition is registered, but blocked behind the barrier');
          expect(nativeCalls('createCameraWithSettings'), 1, reason: 'only A\'s camera exists while A\'s teardown is in flight');
          expect(explicitIntents(), 1, reason: 'still parked');

          hold.complete();
          await waitUntil(
            () => nativeCalls('createCameraWithSettings') == 2 && localController.activeCameraAttemptSessionIdForTest == null,
            'C\'s acquisition ran and concluded (after A was released)',
          );
          await waitForStatus(DashcamStatus.recording, on: localController);
          await Future.wait<void>([stopA, stopB]).timeout(const Duration(seconds: 10), onTimeout: () => fail('BARRIER: the earlier stop Futures never completed'));
          await pumpEventQueue(times: 100);

          expect(explicitIntents(), 2, reason: 'B\'s stop intent was issued only AFTER A was released');
          final calls = fakePlatform.calls;
          expect(
            calls.lastIndexOf('createCameraWithSettings'),
            greaterThan(calls.indexOf('dispose')),
            reason: 'C\'s camera acquisition strictly follows A\'s camera dispose — A\'s physical teardown was respected',
          );
          expect(localController.status, DashcamStatus.recording, reason: 'C is not flipped away by an earlier session\'s late continuation');
          expect(localController.recordingSessionIdForTest, sessionC.id);
          expect(localService.previewController, isNotNull, reason: 'C still holds its camera');
          expect(recorder.isRecording, isTrue, reason: 'C\'s driving session is the recorder\'s active one');

          stopC = localController.stopSession();
          await stopC.timeout(const Duration(seconds: 10));
          // R2.6.3-T1: C's STOP returned at its 50ms presentation deadline. The
          // barrier facts above were all asserted BEFORE this wait, at their own
          // causal points — waiting here cannot mask them.
          final clipsC = await settledClipsOf(localService, sessionC.id, atLeast: 1);
          expect(clipsC, hasLength(1));
          expect((await waitForIndexedCount(sessionC.id, 1)).map((r) => r.filePath), [clipsC.single.file.path]);
          expect(localService.clips.where((c) => c.producerToken == sessionB.id), isEmpty, reason: 'B never recorded');
          expect(localService.clips.where((c) => c.producerToken == sessionA.id), hasLength(1));
        } finally {
          localController.beforeImmediatePersistenceHookForTest = null;
          if (!hold.isCompleted) hold.complete();
          for (final pending in [stopA, stopB, stopC]) {
            if (pending != null) await pending.catchError((_) {});
          }
          await drainLocal(localController, localService);
        }
      },
    );
  });

  // ==========================================================================
  // Fase 16.2-R4.3-R2.6.2 — reentrant camera admission + physical teardown
  // barrier (complementary pre-audit C-3b). R2.6.1 registers a new session in
  // the controller BEFORE the recorder notifies its synchronous listeners (so a
  // re-entrant stop can cancel it); a listener calling retryCamera() there
  // therefore created the new session's attempt through the RECOVERY path,
  // which — unlike _startCamera — did not wait for the previous session's
  // still-pending teardown. Every test here uses the REAL recorder, a REAL
  // synchronous recorder listener, and holds A at a real causal point INSIDE
  // its controller teardown (the immediate-persistence gate).
  // ==========================================================================
  group('Fase 16.2-R4.3-R2.6.2 — reentrant camera admission + physical teardown barrier', () {
    DashcamService buildShortStopService() => buildLocalService(stopVideoRecordingTimeout: const Duration(milliseconds: 50));

    Future<void> waitUntil(bool Function() condition, String label, {int maxIterations = 300}) async {
      for (var i = 0; i < maxIterations; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('waitUntil: "$label" never became true after ${maxIterations * 10}ms (calls: ${fakePlatform.calls.join(',')})');
    }

    int nativeCalls(String call) => fakePlatform.calls.where((c) => c == call).length;

    Future<List<DashcamClipRecord>> waitForIndexedCount(String sessionId, int expected) async {
      List<DashcamClipRecord> indexed = const [];
      for (var i = 0; i < 300; i++) {
        final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List?;
        indexed = raw == null ? const [] : List<DashcamClipRecord>.from(raw);
        if (indexed.length >= expected) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return indexed;
    }

    /// Sample-timer ticks ([DashcamSessionController.sampleTickCountForTest])
    /// over a real-time window whose elapsed time is actually measured.
    Future<({int ticks, int elapsedMs})> sampleTicksOver(DashcamSessionController c, int ms, {bool feed = false}) async {
      final before = c.sampleTickCountForTest;
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < ms) {
        if (feed) snapshotController.add(snapshot(speedKmh: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return (ticks: c.sampleTickCountForTest - before, elapsedMs: sw.elapsedMilliseconds);
    }

    /// ONE periodic timer at the controller's 200ms sample interval cannot tick
    /// more than this in [elapsedMs]; a second (leaked) timer roughly doubles it.
    int maxTicksForOneTimer(int elapsedMs) => elapsedMs ~/ 200 + 1;

    /// The C-3b arrangement. A records; [configureAStop] may set how A's native
    /// STOP behaves; A's stop is then held at its immediate-persistence gate —
    /// after A's native STOP (or its presentation deadline), before A's
    /// persistence, writer close, release decision and status publication — so
    /// A's teardown is genuinely pending. The recorder has finished A, so B is
    /// admissible. B is then started while a synchronous RECORDER listener calls
    /// retryCamera() during B's publication: after `onCreated` registered B,
    /// before startSession() returns.
    Future<_ReentrantRetryArrangement> arrangeReentrantRetry({void Function()? configureAStop}) async {
      final localService = buildShortStopService();
      final localController = buildLocalController(localService);
      final arrangement = _ReentrantRetryArrangement(localService, localController);
      final enteredA = Completer<void>();
      var holdCalls = 0;
      localController.beforeImmediatePersistenceHookForTest = () async {
        if (++holdCalls == 1) {
          enteredA.complete();
          await arrangement.releaseA.future;
        }
      };
      await preferences.setEnabled(true);
      arrangement.sessionA = localController.startSession();
      await waitForStatus(DashcamStatus.recording, on: localController);
      arrangement.controllerA = localService.previewController;
      configureAStop?.call();
      arrangement.stopA = localController.stopSession();
      await enteredA.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('A\'s stop never reached its teardown gate'));
      await waitUntil(() => !recorder.isRecording && localController.canStartSession, 'A\'s recorder finished (B is admissible)');

      void listener() {
        if (arrangement.retryCalls == 0 && recorder.isRecording) {
          arrangement.retryCalls++;
          arrangement.registeredAtRetry = localController.recordingSessionIdForTest;
          arrangement.attemptBeforeRetry = localController.activeCameraAttemptSessionIdForTest;
          arrangement.initializeCallsBeforeRetry = nativeCalls('initializeCamera');
          unawaited(localController.retryCamera());
          arrangement.attemptAfterRetry = localController.activeCameraAttemptSessionIdForTest;
          arrangement.statusAfterRetry = localController.status;
          arrangement.initializeCallsAfterRetry = nativeCalls('initializeCamera');
        }
      }

      recorder.addListener(listener);
      try {
        arrangement.sessionB = localController.startSession();
      } finally {
        recorder.removeListener(listener);
      }
      return arrangement;
    }

    Future<void> disposeArrangement(_ReentrantRetryArrangement arrangement) async {
      arrangement.controller.beforeImmediatePersistenceHookForTest = null;
      if (!arrangement.releaseA.isCompleted) arrangement.releaseA.complete();
      for (final pending in [arrangement.stopA, ...arrangement.laterStops]) {
        if (pending != null) await pending.catchError((_) {});
      }
      try {
        await arrangement.controller.stopSession();
      } catch (_) {}
      await drainLocal(arrangement.controller, arrangement.service);
    }

    /// Facts every variant must show while A's teardown is still held: B's
    /// listener really did call retryCamera() with B registered, the retry
    /// really created B's attempt — it was NOT refused — and yet nothing
    /// physical happened for B.
    void expectRetryAdmittedButParked(_ReentrantRetryArrangement s, String when) {
      expect(s.retryCalls, 1, reason: '$when: the synchronous recorder listener ran exactly once during B\'s publication');
      expect(s.registeredAtRetry, s.sessionB!.id, reason: '$when: B was already registered (onCreated) when the listener retried');
      expect(s.attemptBeforeRetry, isNull, reason: '$when: no attempt existed yet — this IS the window R2.6.1 opened');
      expect(s.attemptAfterRetry, s.sessionB!.id, reason: '$when: the retry was admitted and created B\'s attempt (not refused)');
      expect(s.initializeCallsAfterRetry, s.initializeCallsBeforeRetry, reason: '$when: …but emitted NO native initialize inside the notification');
      expect(s.statusAfterRetry, isNot(DashcamStatus.initializing), reason: '$when: B did not start initializing while A is still tearing down');
    }

    test(
      'X47 (§9, MANDATORY GATE, pre-audit C-3b — "RETRY REENTRANTE") — a synchronous RECORDER listener calls '
      'retryCamera() during B\'s publication (B already registered by onCreated) while A\'s teardown is genuinely held '
      'inside the controller. Pre-fix the recovery path emitted B\'s initialize right there, disposed A\'s controller and '
      'reached recording before A finished. Expected: B\'s attempt is admitted and PARKED — zero native work, A\'s '
      'controller untouched, no telemetry setup — for as long as A is held; B acquires its camera only after A\'s whole '
      'teardown completed, through that single attempt, and ends up recording truthfully',
      () async {
        final s = await arrangeReentrantRetry();
        try {
          expectRetryAdmittedButParked(s, 'same slice');
          expect(s.controller.activeCameraAttemptSessionIdForTest, s.sessionB!.id, reason: 'B\'s acquisition is registered (single-flight) behind the barrier');
          expect(s.controller.cameraAttemptCreationCountForTest, 2, reason: 'A\'s attempt + B\'s one recovery attempt — _startCamera(B) joined it');

          int createsWhenAFinished = -1;
          unawaited(s.stopA!.then((_) => createsWhenAFinished = nativeCalls('createCameraWithSettings')));
          await pumpEventQueue(times: 200);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(nativeCalls('createCameraWithSettings'), 1, reason: 'no physical acquisition for B while A\'s teardown is held — only A\'s camera');
          expect(nativeCalls('initializeCamera'), 1);
          expect(nativeCalls('startVideoCapturing'), 1);
          expect(nativeCalls('dispose'), 0, reason: 'A\'s controller was NOT torn down under A\'s own pending teardown');
          expect(identical(s.service.previewController, s.controllerA), isTrue, reason: 'A\'s controller is still the current one');
          expect(s.service.isRecording, isFalse, reason: 'nothing records for B yet');
          expect(s.controller.initialSetupInstallCountForTest, 1, reason: 'only A\'s telemetry setup ever existed');
          expect(s.controller.activeCameraAttemptSessionIdForTest, s.sessionB!.id, reason: 'still parked, not dropped');

          s.releaseA.complete();
          await s.stopA!.timeout(const Duration(seconds: 10), onTimeout: () => fail('X47: A\'s stop never concluded'));
          await waitForStatus(DashcamStatus.recording, on: s.controller);
          await waitUntil(() => s.controller.activeCameraAttemptSessionIdForTest == null, 'B\'s attempt concluded');
          expect(createsWhenAFinished, 1, reason: 'B\'s camera creation strictly FOLLOWS the completion of A\'s whole teardown');
          expect(nativeCalls('createCameraWithSettings'), 2, reason: 'B acquired exactly one camera');
          expect(nativeCalls('startVideoCapturing'), 2);
          expect(s.controller.cameraAttemptCreationCountForTest, 2, reason: 'no second attempt was ever created for B');
          expect(s.controller.initialSetupInstallCountForTest, 2, reason: 'exactly one telemetry setup for B');
          expect(s.controller.recordingSessionIdForTest, s.sessionB!.id);
          expect(s.service.previewController?.value.isRecordingVideo, isTrue);
          expect(s.controller.recordingStartedAt, isNotNull);

          s.laterStops.add(s.controller.stopSession());
          await s.laterStops.last!.timeout(const Duration(seconds: 10));
          final clipsA = await settledClipsOf(s.service, s.sessionA!.id, atLeast: 1);
          final clipsB = await settledClipsOf(s.service, s.sessionB!.id, atLeast: 1);
          expect(clipsA, hasLength(1));
          expect(clipsB, hasLength(1));
          expect((await waitForIndexedCount(s.sessionA!.id, 1)).map((r) => r.filePath), [clipsA.single.file.path]);
          expect((await waitForIndexedCount(s.sessionB!.id, 1)).map((r) => r.filePath), [clipsB.single.file.path]);
          expect(nativeCalls('startVideoCapturing'), nativeCalls('stopVideoRecording'), reason: 'every Recording was stopped');
        } finally {
          await disposeArrangement(s);
        }
      },
    );

    test(
      'X48 (§9, "CLEANUP OBSOLETO") — once A is released, NOTHING of A\'s late cleanup (its persistence, writer close, '
      'release decision, status publication, late settlement) touches B\'s legitimate resources: B keeps recording with '
      'the SAME controller, the process owner stays held, its recording start time and status are not reset, its single '
      'sample timer keeps ticking, and A is not reactivated',
      () async {
        final s = await arrangeReentrantRetry();
        try {
          s.releaseA.complete();
          await s.stopA!.timeout(const Duration(seconds: 10));
          await waitForStatus(DashcamStatus.recording, on: s.controller);
          await waitUntil(() => s.controller.activeCameraAttemptSessionIdForTest == null, 'B\'s attempt concluded');
          final controllerB = s.service.previewController;
          final ownerB = DashcamService.processOwnerCurrentForTest;
          final startedAtB = s.controller.recordingStartedAt;
          final disposesB = nativeCalls('dispose');
          final stopsB = nativeCalls('stopVideoRecording');
          expect(controllerB, isNotNull);
          expect(ownerB, isNotNull);
          expect(startedAtB, isNotNull);

          // Let every late continuation of A run to completion while B records.
          await pumpEventQueue(times: 200);
          final window = await sampleTicksOver(s.controller, 1000, feed: true);

          expect(s.controller.status, DashcamStatus.recording, reason: 'A\'s cleanup did not publish idle over B');
          expect(identical(s.controller.recordingStartedAt, startedAtB), isTrue, reason: 'B\'s recording start time was not reset');
          expect(identical(s.service.previewController, controllerB), isTrue, reason: 'B\'s controller was not released/replaced');
          expect(s.service.previewController?.value.isRecordingVideo, isTrue, reason: 'B is genuinely still recording');
          expect(identical(DashcamService.processOwnerCurrentForTest, ownerB), isTrue, reason: 'the process owner was not released');
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
          expect(nativeCalls('dispose'), disposesB, reason: 'no dispose issued by A\'s late cleanup');
          expect(nativeCalls('stopVideoRecording'), stopsB, reason: 'no STOP issued by A\'s late cleanup');
          expect(window.ticks, greaterThan(0), reason: 'B\'s legitimate sample timer is alive (not cancelled by A)');
          expect(window.ticks, lessThanOrEqualTo(maxTicksForOneTimer(window.elapsedMs)), reason: 'and it is the ONLY one ticking');
          expect(s.controller.recordingSessionIdForTest, s.sessionB!.id, reason: 'B is the controller\'s session');
          expect(recorder.activeSession?.id, s.sessionB!.id, reason: 'A was not reactivated');

          s.laterStops.add(s.controller.stopSession());
          await s.laterStops.last!.timeout(const Duration(seconds: 10));
          expect(await (await DashcamTelemetryWriter.fileForSession(s.sessionB!.id)).exists(), isTrue, reason: 'B\'s own telemetry file was written and closed by B\'s own stop');
          expect(await settledClipsOf(s.service, s.sessionA!.id, atLeast: 1), hasLength(1));
          expect(await settledClipsOf(s.service, s.sessionB!.id, atLeast: 1), hasLength(1));
        } finally {
          await disposeArrangement(s);
        }
      },
    );

    test(
      'X48-late (§9, "CLEANUP OBSOLETO", late settlement) — A\'s raw native STOP is held PAST its presentation deadline '
      '(A\'s public stop already returned) and A\'s LATE clip persistence is itself held until B is recording; B was '
      'started with the re-entrant retry. Expected: B cannot record while A\'s native STOP is retained (the service '
      'FIFO keeps the physical order); once it is released, A\'s late persistence running WHILE B records indexes A\'s '
      'clip under A and leaves B\'s status, controller, owner and timer untouched',
      () async {
        final localService = buildShortStopService();
        final localController = buildLocalController(localService);
        final rawStopA = Completer<void>();
        final lateWriteA = Completer<void>();
        final futures = <Future<void>>[];
        String? aId;
        localController.persistClipIndexHookForTest = (sessionId, claimed, writeCall) async {
          final write = writeCall();
          if (sessionId == aId) await lateWriteA.future;
          await write;
        };
        var retryCalls = 0;
        void listener() {
          if (retryCalls == 0 && recorder.isRecording) {
            retryCalls++;
            unawaited(localController.retryCamera());
          }
        }

        try {
          await preferences.setEnabled(true);
          aId = localController.startSession().id;
          await waitForStatus(DashcamStatus.recording, on: localController);
          fakePlatform.pendingStopVideoRecording = rawStopA;
          futures.add(localController.stopSession());
          await futures.last.timeout(const Duration(seconds: 5), onTimeout: () => fail('A\'s public stop must return bounded'));
          expect(localService.hasPendingNativeStop, isTrue, reason: 'setup: A\'s physical obligation is retained');
          await waitUntil(() => !recorder.isRecording && localController.canStartSession, 'B admissible');

          recorder.addListener(listener);
          final sessionB = localController.startSession();
          recorder.removeListener(listener);
          expect(retryCalls, 1);
          await pumpEventQueue(times: 200);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(nativeCalls('createCameraWithSettings'), 1, reason: 'B cannot acquire while A\'s native STOP is retained');
          expect(localService.isRecording, isFalse);

          fakePlatform.pendingStopVideoRecording = null;
          rawStopA.complete();
          await waitForStatus(DashcamStatus.recording, on: localController);
          await waitUntil(() => localController.activeCameraAttemptSessionIdForTest == null, 'B\'s attempt concluded');
          final controllerB = localService.previewController;
          final startedAtB = localController.recordingStartedAt;
          final ownerB = DashcamService.processOwnerCurrentForTest;

          lateWriteA.complete(); // A's late persistence now runs while B records
          final indexedA = await waitForIndexedCount(aId, 1);
          final window = await sampleTicksOver(localController, 600, feed: true);
          expect(indexedA, hasLength(1), reason: 'A\'s clip, finalized late, is indexed under A');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionB.id), isNull, reason: 'nothing of A was indexed under B');
          expect(localController.status, DashcamStatus.recording);
          expect(identical(localController.recordingStartedAt, startedAtB), isTrue);
          expect(identical(localService.previewController, controllerB), isTrue);
          expect(localService.previewController?.value.isRecordingVideo, isTrue);
          expect(identical(DashcamService.processOwnerCurrentForTest, ownerB), isTrue);
          expect(window.ticks, inInclusiveRange(1, maxTicksForOneTimer(window.elapsedMs)));
          expect(nativeCalls('stopVideoRecording'), 1, reason: 'A\'s one STOP, never retried');

          futures.add(localController.stopSession());
          await futures.last.timeout(const Duration(seconds: 10));
          expect(await settledClipsOf(localService, sessionB.id, atLeast: 1), hasLength(1));
        } finally {
          recorder.removeListener(listener);
          fakePlatform.pendingStopVideoRecording = null;
          if (!rawStopA.isCompleted) rawStopA.complete();
          if (!lateWriteA.isCompleted) lateWriteA.complete();
          localController.persistClipIndexHookForTest = null;
          for (final pending in futures) {
            await pending.catchError((_) {});
          }
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X49 (§9, "STOP DURANTE RETRY") — B is stopped while its re-entrant retry attempt is still parked behind A\'s held '
      'teardown. Expected: the stop invalidates B\'s attempt in the same slice; when A is released, the parked attempt '
      're-validates and gives up — B never acquires a camera, never records, installs no telemetry, owns no clip — and '
      'nothing (not even a pause/resume cycle) brings it back; a later session C works normally',
      () async {
        final s = await arrangeReentrantRetry();
        try {
          expectRetryAdmittedButParked(s, 'same slice');
          s.laterStops.add(s.controller.stopSession());
          expect(s.controller.inFlightStopRequestSessionIdForTest, s.sessionB!.id, reason: 'B\'s own stop request');
          expect(s.controller.activeCameraAttemptSessionIdForTest, isNull, reason: 'B\'s parked attempt is invalidated synchronously');
          expect(s.controller.recordingSessionIdForTest, isNull);

          s.releaseA.complete();
          await s.stopA!.timeout(const Duration(seconds: 10));
          await s.laterStops.last!.timeout(const Duration(seconds: 10), onTimeout: () => fail('X49: B\'s stop never concluded'));
          await pumpEventQueue(times: 200);
          await Future<void>.delayed(const Duration(milliseconds: 200));

          void expectNeverAcquired(String when) {
            expect(nativeCalls('createCameraWithSettings'), 1, reason: '$when: only A\'s camera was ever created');
            expect(nativeCalls('initializeCamera'), 1, reason: '$when: no initialize for B');
            expect(nativeCalls('startVideoCapturing'), 1, reason: '$when: no START for B');
            expect(s.service.isRecording, isFalse);
            expect(s.controller.status, isNot(DashcamStatus.recording));
            expect(s.controller.status, isNot(DashcamStatus.initializing));
            expect(s.controller.activeCameraAttemptSessionIdForTest, isNull);
            expect(s.controller.recordingSessionIdForTest, isNull);
            expect(s.controller.initialSetupInstallCountForTest, 1, reason: '$when: only A\'s telemetry setup ever existed');
            expect(s.service.clips.where((c) => c.producerToken == s.sessionB!.id), isEmpty, reason: '$when: B owns no clip');
          }

          expectNeverAcquired('after A and B concluded');
          expect(s.controller.cameraAttemptCreationCountForTest, 2, reason: 'no fresh attempt was created by the parked attempt giving up');
          expect(s.service.previewController, isNull, reason: 'the camera was released — nobody wants it');
          final idle = await sampleTicksOver(s.controller, 500);
          expect(idle.ticks, 0, reason: 'no sample timer ticks with no session');

          // ignore: invalid_use_of_visible_for_testing_member
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          // ignore: invalid_use_of_visible_for_testing_member
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await pumpEventQueue(times: 100);
          expectNeverAcquired('after a pause/resume cycle');

          await waitUntil(() => s.controller.canStartSession && !recorder.isRecording, 'C admissible');
          final sessionC = s.controller.startSession();
          await waitForStatus(DashcamStatus.recording, on: s.controller);
          s.laterStops.add(s.controller.stopSession());
          await s.laterStops.last!.timeout(const Duration(seconds: 10));
          expect(await settledClipsOf(s.service, sessionC.id, atLeast: 1), hasLength(1));
        } finally {
          await disposeArrangement(s);
        }
      },
    );

    test(
      'X50 (§9, MANDATORY GATE, "TELEMETRIA SEM VAZAMENTO") — the old flow that left a sample timer ticking 5×/s with no '
      'session: re-entrant retry during B\'s publication with A\'s teardown held; after A is released, the dashcam tile '
      'is driven exactly as a user would (its "Iniciar sessão" is tapped only if it offers one: status idle + '
      'canStartSession); B is stopped; then a session C runs and is stopped. Expected: zero sample ticks whenever no '
      'session records (no orphan timer), exactly one timer per session (no duplicated telemetry in C), and one telemetry '
      'setup per session',
      () async {
        final s = await arrangeReentrantRetry();
        try {
          // Keep A held while B's attempt gets every chance to progress — the
          // pre-fix defect only leaves `idle` over a recording B when B reaches
          // recording BEFORE A's cleanup runs (pre-audit §5.3, ordering
          // dependence). Not a proof by sleep: the oracles below are the ticks.
          await pumpEventQueue(times: 200);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          s.releaseA.complete();
          await s.stopA!.timeout(const Duration(seconds: 10));
          await waitUntil(() => s.service.isRecording && s.controller.activeCameraAttemptSessionIdForTest == null, 'B recording');
          await pumpEventQueue(times: 100);
          final tileOfferedStart = s.controller.status == DashcamStatus.idle && s.controller.canStartSession;
          if (tileOfferedStart) {
            // What the pre-fix state made the tile offer — reproduce the user's tap faithfully.
            s.controller.startSession();
            await waitForStatus(DashcamStatus.recording, on: s.controller);
            await pumpEventQueue(times: 100);
          }
          final duringB = await sampleTicksOver(s.controller, 1000, feed: true);

          s.laterStops.add(s.controller.stopSession());
          await s.laterStops.last!.timeout(const Duration(seconds: 10));
          await pumpEventQueue(times: 50);
          final afterB = await sampleTicksOver(s.controller, 1000);

          await waitUntil(() => s.controller.canStartSession && !recorder.isRecording, 'C admissible');
          final sessionC = s.controller.startSession();
          await waitForStatus(DashcamStatus.recording, on: s.controller);
          final duringC = await sampleTicksOver(s.controller, 1000, feed: true);
          s.laterStops.add(s.controller.stopSession());
          await s.laterStops.last!.timeout(const Duration(seconds: 10));
          await pumpEventQueue(times: 50);
          final afterC = await sampleTicksOver(s.controller, 1000);
          final rowsC = (await (await DashcamTelemetryWriter.fileForSession(sessionC.id)).readAsLines()).where((l) => l.trim().isNotEmpty).length;

          expect(afterB.ticks, 0, reason: 'no sample timer keeps ticking once B has stopped — no orphan timer (pre-fix: 5 in 1s)');
          expect(afterC.ticks, 0, reason: 'none after C either — nothing leaked across sessions');
          expect(duringB.ticks, inInclusiveRange(1, maxTicksForOneTimer(duringB.elapsedMs)), reason: 'B ran exactly one sample timer');
          expect(duringC.ticks, inInclusiveRange(1, maxTicksForOneTimer(duringC.elapsedMs)), reason: 'C ran exactly one sample timer (pre-fix: doubled)');
          expect(rowsC, lessThanOrEqualTo(maxTicksForOneTimer(duringC.elapsedMs) + 1), reason: 'C\'s telemetry file holds no duplicated rows (pre-fix: 2x)');
          expect(s.controller.initialSetupInstallCountForTest, 3, reason: 'one telemetry setup per session (A, B, C) — none repeated');
          expect(tileOfferedStart, isFalse, reason: 'B\'s status was truthful (recording): the tile never offered a start over a recording session');
        } finally {
          await disposeArrangement(s);
        }
      },
    );

    // X51 — the same re-entrant flow under every reachable outcome of A's physical obligation.
    for (final variant in _X51Variant.values) {
      test(
        'X51-${variant.name} (§9, "FAILURE/TIMEOUT") — re-entrant retry during B\'s publication while A\'s teardown is '
        'held, with A\'s native obligation: ${variant.description}. Expected: B\'s admission waits for A\'s teardown in every '
        'case, A\'s STOP is never retried natively, physical exclusivity holds (B never records while A\'s native '
        'obligation is retained), and a dispose failure stays fail-closed',
        () async {
          final rawStopA = Completer<void>();
          final s = await arrangeReentrantRetry(
            configureAStop: switch (variant) {
              _X51Variant.stopOk || _X51Variant.disposeFails => null,
              _ => () => fakePlatform.pendingStopVideoRecording = rawStopA,
            },
          );
          try {
            expectRetryAdmittedButParked(s, variant.name);
            await pumpEventQueue(times: 100);
            expect(nativeCalls('createCameraWithSettings'), 1, reason: '${variant.name}: B parked behind A\'s held teardown');
            expect(nativeCalls('stopVideoRecording'), 1, reason: '${variant.name}: A\'s one native STOP');

            switch (variant) {
              case _X51Variant.stopOk:
                s.releaseA.complete();
              case _X51Variant.presentationTimeoutThenSuccess:
                fakePlatform.pendingStopVideoRecording = null;
                rawStopA.complete();
                await waitUntil(() => !s.service.hasPendingNativeStop, 'A\'s late native STOP resolved');
                s.releaseA.complete();
              case _X51Variant.stopFailsLate:
                fakePlatform.pendingStopVideoRecording = null;
                rawStopA.completeError(CameraException('native_stop_failed', 'simulated terminal STOP failure'));
                await waitUntil(() => !s.service.hasPendingNativeStop, 'A\'s native STOP failed terminally');
                s.releaseA.complete();
              case _X51Variant.obligationRetained:
                s.releaseA.complete(); // A's controller teardown finishes; its raw STOP is STILL retained
                await s.stopA!.timeout(const Duration(seconds: 10));
                await pumpEventQueue(times: 200);
                await Future<void>.delayed(const Duration(milliseconds: 300));
                expect(s.service.hasPendingNativeStop, isTrue, reason: 'setup: A\'s physical obligation is still retained');
                expect(nativeCalls('createCameraWithSettings'), 1, reason: 'B cannot acquire while A\'s native STOP is retained');
                expect(s.service.isRecording, isFalse);
                expect(nativeCalls('stopVideoRecording'), 1, reason: 'no retry of A\'s STOP while it is retained');
                fakePlatform.pendingStopVideoRecording = null;
                rawStopA.complete();
              case _X51Variant.disposeFails:
                fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated teardown failure');
                s.releaseA.complete();
            }
            await s.stopA!.timeout(const Duration(seconds: 10));

            if (variant == _X51Variant.disposeFails) {
              await waitForStatus(DashcamStatus.error, on: s.controller);
              expect(DashcamService.processOwnerIsUncertainForTest, isTrue, reason: 'a failed teardown leaves the backend fail-closed');
              expect(nativeCalls('startVideoCapturing'), 1, reason: 'B never started over an uncertain backend');
              expect(nativeCalls('dispose'), 1, reason: 'the failed dispose was not retried');
              expect(s.service.isRecording, isFalse);
              return;
            }

            await waitForStatus(DashcamStatus.recording, on: s.controller);
            await waitUntil(() => s.controller.activeCameraAttemptSessionIdForTest == null, 'B\'s attempt concluded');
            expect(nativeCalls('createCameraWithSettings'), 2, reason: '${variant.name}: B acquired exactly one camera, after A');
            expect(nativeCalls('stopVideoRecording'), 1, reason: '${variant.name}: A\'s STOP was never retried natively');
            expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
            expect(s.controller.recordingSessionIdForTest, s.sessionB!.id);
            expect(s.controller.initialSetupInstallCountForTest, 2);

            s.laterStops.add(s.controller.stopSession());
            await s.laterStops.last!.timeout(const Duration(seconds: 10));
            await pumpEventQueue(times: 50);
            expect(await settledClipsOf(s.service, s.sessionB!.id, atLeast: 1), hasLength(1), reason: 'B owns its own clip');
            expect(
              await settledClipsOf(s.service, s.sessionA!.id),
              hasLength(variant == _X51Variant.stopFailsLate ? 0 : 1),
              reason: 'A\'s clip exists unless A\'s own STOP failed',
            );
            expect((await sampleTicksOver(s.controller, 500)).ticks, 0, reason: 'no sample timer left ticking');
          } finally {
            fakePlatform.pendingStopVideoRecording = null;
            if (!rawStopA.isCompleted) rawStopA.complete();
            if (variant == _X51Variant.disposeFails) {
              fakePlatform.failDisposeWith = null;
              s.controller.beforeImmediatePersistenceHookForTest = null;
              if (!s.releaseA.isCompleted) s.releaseA.complete();
              await s.stopA?.catchError((_) {});
              try {
                await s.controller.stopSession();
              } catch (_) {}
              await s.service.dispose().catchError((_) {});
              for (var i = 0; i < 200 && s.service.previewController != null; i++) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              if (DashcamService.processOwnerIsUncertainForTest) {
                DashcamService.simulateProcessRestartForTest(s.service.processOwnerTokenForTest);
              }
            }
            await disposeArrangement(s);
          }
        },
      );
    }
  });

  // ==========================================================================
  // Fase 16.2-R4.3-R2.6.3 — session alias + telemetry lifecycle idempotency
  // (R2.6.2 report §14.1). startSession() on an already-active session is the
  // long-standing alias contract, but it reset _initialSetupDone even while
  // that session's telemetry producers were installed and running; the next
  // `resumed` then ran the full initial setup again and the first sample timer
  // kept ticking forever (5 ticks/s with no session; doubled telemetry in every
  // later session). Two protections, each with its own discriminating test:
  // the reset is identity-scoped (X52-shade), and _finishInitialStart never
  // installs a second set of producers for the same session (X53b).
  // ==========================================================================
  group('Fase 16.2-R4.3-R2.6.3 — session alias + telemetry lifecycle idempotency', () {
    Future<void> waitUntil(bool Function() condition, String label, {int maxIterations = 400}) async {
      for (var i = 0; i < maxIterations; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('waitUntil: "$label" never became true after ${maxIterations * 10}ms (calls: ${fakePlatform.calls.join(',')})');
    }

    int nativeCalls(String call) => fakePlatform.calls.where((c) => c == call).length;

    /// Sample-timer ticks over a real-time window whose elapsed time is measured.
    Future<({int ticks, int elapsedMs})> sampleTicksOver(DashcamSessionController c, int ms, {bool feed = false}) async {
      final before = c.sampleTickCountForTest;
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < ms) {
        if (feed) snapshotController.add(snapshot(speedKmh: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return (ticks: c.sampleTickCountForTest - before, elapsedMs: sw.elapsedMilliseconds);
    }

    /// ONE periodic timer at the controller's 200ms sample interval cannot tick
    /// more than this in [elapsedMs]; a second (leaked) timer roughly doubles it.
    int maxTicksForOneTimer(int elapsedMs) => elapsedMs ~/ 200 + 1;

    /// Exactly one sample timer runs: it ticks, and no more than one timer could.
    Future<void> expectOneSampleTimer(DashcamSessionController c, String when) async {
      final w = await sampleTicksOver(c, 1000, feed: true);
      expect(w.ticks, inInclusiveRange(1, maxTicksForOneTimer(w.elapsedMs)), reason: '$when: exactly one sample timer is running');
    }

    /// No sample timer runs at all — nothing is left ticking for an ended session.
    Future<void> expectNoSampleTimer(DashcamSessionController c, String when) async {
      final w = await sampleTicksOver(c, 1000);
      expect(w.ticks, 0, reason: '$when: no sample timer is left running (pre-fix: 5 ticks/s)');
    }

    /// A real background → foreground cycle: the camera is lost while paused and
    /// recovered on resume. Waits causally for that recovery to conclude.
    Future<void> backgroundAndResume(DashcamSessionController c, {required int createsAfter}) async {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpEventQueue(times: 20);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await waitUntil(
        () => c.status == DashcamStatus.recording && c.activeCameraAttemptSessionIdForTest == null && nativeCalls('createCameraWithSettings') >= createsAfter,
        'the camera recovered after resume',
      );
    }

    /// A focus loss that is NOT a background (e.g. the notification shade):
    /// inactive → resumed. The preview was never paused, so the resumed
    /// handler's `resumePreview()` returns without any native call
    /// (camera-0.12.0+2 returns early when `!isPreviewPaused`) and its recovery
    /// decision follows within a few microtasks — draining the event queue
    /// lets it run to completion. X52-shade's negative control shows the
    /// pre-fix recovery attempt appearing inside this same drain.
    Future<void> inactiveThenResumed(DashcamSessionController c) async {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue(times: 100);
    }

    test(
      'X52 (§8, MANDATORY GATE) — alias during RECORDING does not reinstall telemetry after a pause/resume: A records; '
      'startSession() returns A (alias); a real background cycle loses the camera and resume recovers it. Pre-fix the '
      'alias had reset _initialSetupDone, so the recovery re-ran the FULL initial setup and the first sample timer kept '
      'running. Expected: the recovery is camera-only — ONE telemetry installation in total, exactly one sample timer '
      'running, and nothing ticking once A stops',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.initialSetupInstallCountForTest, 1);
          expect(identical(localController.startSession(), sessionA), isTrue, reason: 'alias: the SAME session');
          final attemptsAfterAlias = localController.cameraAttemptCreationCountForTest;

          await backgroundAndResume(localController, createsAfter: 2);
          await expectOneSampleTimer(localController, 'while A records after the recovery (pre-fix: two timers)');
          expect(nativeCalls('createCameraWithSettings'), 2, reason: 'the lost camera was recovered once');
          expect(localController.initialSetupInstallCountForTest, 1, reason: 'the recovery reused A\'s telemetry — no second installation');
          expect(localController.cameraAttemptCreationCountForTest, attemptsAfterAlias + 1, reason: 'ONE recovery attempt');

          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
          expect(localService.clips.where((c) => c.producerToken == sessionA.id), hasLength(2), reason: 'both of A\'s Recordings (before/after the loss) are A\'s');
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X52-shade (§5, protection 1 — identity-scoped reset) — alias during RECORDING followed by a mere focus loss '
      '(inactive → resumed, e.g. the notification shade — NOT a background): the camera was never lost, so nothing may '
      'be restarted. Pre-fix the alias left _initialSetupDone false, which made the resumed handler think the session '
      'had never been set up and re-acquire a perfectly healthy camera. Expected: no recovery attempt, no native call '
      'beyond resumePreview, the same single sample timer',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(identical(localController.startSession(), sessionA), isTrue);
          final attempts = localController.cameraAttemptCreationCountForTest;
          final creates = nativeCalls('createCameraWithSettings');
          final stops = nativeCalls('stopVideoRecording');

          await inactiveThenResumed(localController);
          expect(localController.cameraAttemptCreationCountForTest, attempts, reason: 'no recovery attempt for a healthy, recording session');
          expect(nativeCalls('createCameraWithSettings'), creates, reason: 'the healthy camera was not re-acquired');
          expect(nativeCalls('stopVideoRecording'), stops, reason: 'the ongoing Recording was not cut');
          expect(localController.status, DashcamStatus.recording);
          expect(localController.initialSetupInstallCountForTest, 1);
          await expectOneSampleTimer(localController, 'after the focus loss');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X53 (§8) — alias with a LIVE session whose camera side is idle preserves the valid X46 behaviour: the dashcam '
      'is enabled while A (recorder-only so far) is alive; startSession() returns A and arms its camera with A\'s '
      'FIRST telemetry installation; repeating the alias and a background cycle then add NONE',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          final sessionA = localController.startSession();
          expect(localController.status, DashcamStatus.disabled, reason: 'setup: recorder-only session');
          await preferences.setEnabled(true);
          expect(localController.status, DashcamStatus.idle);
          expect(identical(localController.startSession(), sessionA), isTrue, reason: 'X46: the SAME session');
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(localController.initialSetupInstallCountForTest, 1, reason: 'A\'s camera side got its (first) telemetry installation');
          expect(identical(localController.startSession(), sessionA), isTrue, reason: 'idempotent repeat');
          await backgroundAndResume(localController, createsAfter: 2);
          expect(localController.initialSetupInstallCountForTest, 1, reason: 'no reinstallation by the repeat or the recovery');
          await expectOneSampleTimer(localController, 'A recording');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X53b (§6, protection 2 — telemetry setup eligibility ≠ camera acquisition eligibility) — A records; its camera '
      'errors (a real, current-generation lifecycleCamera error) while A\'s telemetry producers keep running; then '
      'startSession() (alias) re-arms the camera through _startCamera → _finishInitialStart. That continuation used to '
      'install a SECOND set of producers over the live ones. Expected: the camera IS re-armed (recording again), but '
      'A\'s existing telemetry is reused — no new installation, one sample timer, nothing ticking after the stop',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          localController.deliverServiceErrorForTest(
            DashcamServiceError(
              'simulated camera error while recording',
              scope: DashcamServiceErrorScope.lifecycleCamera,
              origin: localService.previewController,
              generation: localController.lifecycleGenerationForTest,
            ),
          );
          expect(localController.status, DashcamStatus.error, reason: 'setup: the camera side errored');
          await expectOneSampleTimer(localController, 'setup: A\'s telemetry keeps running through the camera error');

          expect(identical(localController.startSession(), sessionA), isTrue, reason: 'alias');
          await waitUntil(
            () => localController.status == DashcamStatus.recording && localController.activeCameraAttemptSessionIdForTest == null,
            'the camera was re-armed',
          );
          expect(nativeCalls('createCameraWithSettings'), 2, reason: 'camera acquisition eligibility was honoured — the camera IS re-armed');
          expect(localService.previewController?.value.isRecordingVideo, isTrue);
          expect(localController.initialSetupInstallCountForTest, 1, reason: 'telemetry setup eligibility was NOT — A\'s producers were reused');
          await expectOneSampleTimer(localController, 'after the re-arm');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X54 (§8) — alias while A\'s FIRST start is still pending (native START held): the alias joins the pending '
      'attempt; nothing concurrent is created and exactly one telemetry installation follows',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final startGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingStartVideoCapturing = startGate;
          final sessionA = localController.startSession();
          await waitUntil(() => nativeCalls('startVideoCapturing') == 1, 'A\'s native START is in flight');
          for (var i = 0; i < 3; i++) {
            expect(identical(localController.startSession(), sessionA), isTrue);
          }
          expect(localController.cameraAttemptCreationCountForTest, 1, reason: 'the aliases joined the pending attempt');
          fakePlatform.pendingStartVideoCapturing = null;
          startGate.complete();
          await waitUntil(() => localController.status == DashcamStatus.recording && localController.activeCameraAttemptSessionIdForTest == null, 'A recording');
          expect(nativeCalls('createCameraWithSettings'), 1);
          expect(nativeCalls('startVideoCapturing'), 1);
          expect(localController.initialSetupInstallCountForTest, 1);
          await backgroundAndResume(localController, createsAfter: 2);
          expect(localController.initialSetupInstallCountForTest, 1, reason: 'still one installation after a later recovery');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X54-recovery (§7, "alias durante recovery") — A records; the app is backgrounded and, on resume, A\'s '
      'camera-only recovery is held at its native initialize; aliases arrive meanwhile. Expected: they join the '
      'in-flight recovery (no concurrent attempt/installation), the recovery stays camera-only, and a LATER background '
      'cycle is camera-only too — the aliases did not turn the session back into "never set up"',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await pumpEventQueue(times: 20);
          fakePlatform.pendingInitializeCamera = initGate;
          final inits = nativeCalls('initializeCamera');
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await waitUntil(() => nativeCalls('initializeCamera') > inits, 'the recovery\'s native initialize is in flight');
          final attempts = localController.cameraAttemptCreationCountForTest;
          for (var i = 0; i < 3; i++) {
            expect(identical(localController.startSession(), sessionA), isTrue);
          }
          expect(localController.cameraAttemptCreationCountForTest, attempts, reason: 'the aliases joined the in-flight recovery');
          fakePlatform.pendingInitializeCamera = null;
          initGate.complete();
          await waitUntil(() => localController.status == DashcamStatus.recording && localController.activeCameraAttemptSessionIdForTest == null, 'recovered');
          expect(localController.initialSetupInstallCountForTest, 1, reason: 'the recovery reused A\'s telemetry');
          await backgroundAndResume(localController, createsAfter: 3);
          expect(localController.initialSetupInstallCountForTest, 1, reason: 'a later recovery is still camera-only');
          await expectOneSampleTimer(localController, 'A recording');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X55 (§8, MANDATORY GATE) — STOP after alias leaves zero timers: alias during recording, a background cycle, '
      'then A stops. Expected: zero sample ticks from then on (pre-fix: 5 ticks/s forever), and a fresh session does '
      'not see a second timer writing into its telemetry',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(identical(localController.startSession(), sessionA), isTrue);
          await backgroundAndResume(localController, createsAfter: 2);
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await pumpEventQueue(times: 50);
          await expectNoSampleTimer(localController, 'after A stopped');
          expect(localController.status, DashcamStatus.idle);
          expect(localService.previewController, isNull, reason: 'A\'s camera was released');

          await waitUntil(() => localController.canStartSession && !recorder.isRecording, 'B admissible');
          final sessionB = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          final during = await sampleTicksOver(localController, 1000, feed: true);
          await localController.stopSession().timeout(const Duration(seconds: 10));
          final rowsB = (await (await DashcamTelemetryWriter.fileForSession(sessionB.id)).readAsLines()).where((l) => l.trim().isNotEmpty).length;
          expect(during.ticks, inInclusiveRange(1, maxTicksForOneTimer(during.elapsedMs)), reason: 'B runs exactly one timer (pre-fix: two)');
          expect(rowsB, lessThanOrEqualTo(maxTicksForOneTimer(during.elapsedMs) + 1), reason: 'B\'s telemetry has no duplicated rows');
          await expectNoSampleTimer(localController, 'after B stopped');
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X55-late (§7, "STOP antes de callback tardio") — A\'s FIRST native initialize is held past its presentation '
      'deadline (A reports error, a late watcher owns the retained operation); an alias arrives; A is stopped; only '
      'then does the held initialize succeed. Expected: A\'s late callback does not revive anything — no START, no '
      'telemetry installation, no timer — and the late camera is released',
      () async {
        final localService = buildLocalService(initializeCameraTimeout: const Duration(milliseconds: 100));
        final localController = buildLocalController(localService);
        final initGate = Completer<void>();
        try {
          await preferences.setEnabled(true);
          fakePlatform.pendingInitializeCamera = initGate;
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.error, on: localController, label: 'A\'s initialize presentation deadline elapsed');
          expect(localService.pendingInitializeSettlement, isNotNull, reason: 'setup: the raw initialize is retained');
          expect(identical(localController.startSession(), sessionA), isTrue, reason: 'alias while the late operation is pending');
          await localController.stopSession().timeout(const Duration(seconds: 10));

          fakePlatform.pendingInitializeCamera = null;
          initGate.complete();
          await waitUntil(() => localService.pendingInitializeSettlement == null && localService.previewController == null, 'the late camera was released');
          await pumpEventQueue(times: 50);
          expect(nativeCalls('startVideoCapturing'), 0, reason: 'nothing was started for the stopped session');
          expect(localController.initialSetupInstallCountForTest, 0, reason: 'no telemetry was installed by the late callback');
          await expectNoSampleTimer(localController, 'after the late callback');
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGate.isCompleted) initGate.complete();
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X56 (§8) — a new session B does not inherit A\'s timers, samples or setup flag: A runs the old leaking flow '
      '(alias + background cycle + stop); B is then started while the app is in the BACKGROUND (so its first attempt '
      'cannot run and the resume recovery must decide from B\'s OWN setup state). Expected: on resume B gets its own '
      'FULL telemetry installation (an inherited "already set up" would give B a camera but no telemetry at all), '
      'exactly one timer, and A\'s telemetry file is untouched by B',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          expect(identical(localController.startSession(), sessionA), isTrue);
          await backgroundAndResume(localController, createsAfter: 2);
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
          final rowsA = (await (await DashcamTelemetryWriter.fileForSession(sessionA.id)).readAsLines()).length;
          final setupsBeforeB = localController.initialSetupInstallCountForTest;

          await waitUntil(() => localController.canStartSession && !recorder.isRecording, 'B admissible');
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await pumpEventQueue(times: 20);
          final sessionB = localController.startSession();
          await pumpEventQueue(times: 50);
          expect(localController.status, isNot(DashcamStatus.recording), reason: 'setup: B cannot start in the background');
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await waitUntil(() => localController.status == DashcamStatus.recording && localController.activeCameraAttemptSessionIdForTest == null, 'B recording after resume');
          expect(localController.initialSetupInstallCountForTest, setupsBeforeB + 1, reason: 'B got its OWN full telemetry installation');
          await expectOneSampleTimer(localController, 'B recording');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after B stopped');
          expect((await (await DashcamTelemetryWriter.fileForSession(sessionA.id)).readAsLines()).length, rowsA, reason: 'nothing of B was written into A\'s telemetry');
          expect(localService.clips.where((c) => c.producerToken == sessionB.id), hasLength(1));
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );

    test(
      'X57 (§8) — a repeated sequence of aliases, focus losses, background cycles and recoveries stays idempotent: '
      'three rounds of (alias, inactive → resumed, background with an alias while paused, resume, alias). Expected: '
      'ONE telemetry installation for the whole session, one camera recovery per real background and none per focus '
      'loss, one sample timer throughout, zero after the stop, and every clip A\'s',
      () async {
        final localService = buildLocalService();
        final localController = buildLocalController(localService);
        try {
          await preferences.setEnabled(true);
          final sessionA = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          for (var round = 1; round <= 3; round++) {
            expect(identical(localController.startSession(), sessionA), isTrue);
            final createsBeforeShade = nativeCalls('createCameraWithSettings');
            final attemptsBeforeShade = localController.cameraAttemptCreationCountForTest;
            await inactiveThenResumed(localController);
            // The attempt count is the synchronous, deterministic signal: a
            // recovery decision creates its attempt in the same slice.
            expect(localController.cameraAttemptCreationCountForTest, attemptsBeforeShade, reason: 'round $round: a focus loss starts no recovery');
            expect(nativeCalls('createCameraWithSettings'), createsBeforeShade, reason: 'round $round: a focus loss restarts nothing');

            TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
            await pumpEventQueue(times: 20);
            expect(identical(localController.startSession(), sessionA), isTrue, reason: 'round $round: alias while backgrounded');
            TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await waitUntil(
              () =>
                  localController.status == DashcamStatus.recording &&
                  localController.activeCameraAttemptSessionIdForTest == null &&
                  nativeCalls('createCameraWithSettings') == createsBeforeShade + 1,
              'round $round: recovered once',
            );
            expect(identical(localController.startSession(), sessionA), isTrue);
            expect(localController.initialSetupInstallCountForTest, 1, reason: 'round $round: still ONE installation');
          }
          expect(nativeCalls('createCameraWithSettings'), 4, reason: 'initial + one recovery per real background');
          await expectOneSampleTimer(localController, 'after three rounds');
          await localController.stopSession().timeout(const Duration(seconds: 10));
          await expectNoSampleTimer(localController, 'after A stopped');
          expect(localService.clips.where((c) => c.producerToken != sessionA.id), isEmpty);
          expect(localService.clips.where((c) => c.producerToken == sessionA.id), hasLength(4));
        } finally {
          await drainLocal(localController, localService);
        }
      },
    );
  });

  // ==========================================================================
  // Fase 16.2-R4.3-R2.6.4 — recorder persistence failure recovery (independent
  // review, B — partial approval). A Hive failure while the recorder finalized
  // a session used to leave that ENDED session looking alive: the controller
  // re-admitted it, a start handed it back and re-armed the camera for a
  // session that no longer collected telemetry; and a Hive failure at START
  // left an orphan session nobody knew about. Every test here uses the REAL
  // recorder and REAL Hive failures at the real checkpoints (a box closed at
  // the precise moment), and restores every box in `finally`.
  // ==========================================================================
  group('Fase 16.2-R4.3-R2.6.4 — recorder persistence failure recovery', () {
    const samplesBox = HiveBoxNames.drivingSessionSamples;
    const sessionsBox = HiveBoxNames.drivingSessions;

    DashcamService buildShortStopService() => buildLocalService(stopVideoRecordingTimeout: const Duration(milliseconds: 50));

    Future<void> waitUntil(bool Function() condition, String label, {int maxIterations = 300}) async {
      for (var i = 0; i < maxIterations; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('waitUntil: "$label" never became true after ${maxIterations * 10}ms (calls: ${fakePlatform.calls.join(',')})');
    }

    int nativeCalls(String call) => fakePlatform.calls.where((c) => c == call).length;

    /// A controller over a REAL recorder whose stopSession() can be held inside
    /// its real finalization (at the snapshot subscription's cancel()), so a box
    /// can be made unavailable exactly before the persistence checkpoints run.
    ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) rig(DashcamService localService) {
      final gate = _CancelGatedStream(snapshotController.stream);
      final localRecorder = DrivingSessionRecorder(gate);
      final localController = DashcamSessionController(
        dashcamService: localService,
        dashcamPreferences: preferences,
        sessionRecorder: localRecorder,
        snapshotStream: snapshotController.stream,
        eventStream: eventController.stream,
      );
      return (recorder: localRecorder, gate: gate, controller: localController);
    }

    // Snapshots 2s apart (the recorder keeps one sample per second), on a clock
    // that only moves forward within a test.
    var feedClock = DateTime.now();
    Future<void> feedSamples(int n) async {
      for (var i = 0; i < n; i++) {
        feedClock = feedClock.add(const Duration(seconds: 2));
        snapshotController.add(snapshot(timestamp: feedClock, speedKmh: 40.0 + i));
        await pumpEventQueue();
      }
    }

    Future<void> closeSamplesBox() => Hive.lazyBox(samplesBox).close();
    Future<void> closeSessionsBox() => Hive.box<DrivingSession>(sessionsBox).close();
    Future<void> reopenSamplesBox() => Hive.openLazyBox(samplesBox);
    Future<void> reopenSessionsBox() => Hive.openBox<DrivingSession>(sessionsBox);

    /// Harness safety: every box a test closed is open again, whatever happened.
    Future<void> restoreBoxes() async {
      if (!Hive.isBoxOpen(samplesBox)) await reopenSamplesBox();
      if (!Hive.isBoxOpen(sessionsBox)) await reopenSessionsBox();
    }

    /// The samples as stored on disk (a LazyBox reads the value from the file).
    Future<int?> durableSampleCount(String id) async => (await Hive.lazyBox(samplesBox).get(id) as List?)?.length;

    /// The session record as stored on disk: the sessions box is reopened so its
    /// in-memory cache cannot answer instead of the file. Only call it when no
    /// active session is bound to that box.
    Future<DrivingSession?> durableSession(String id) async {
      await closeSessionsBox();
      await reopenSessionsBox();
      return Hive.box<DrivingSession>(sessionsBox).get(id);
    }

    Future<Object?> errorOf(Future<void> f) async {
      try {
        await f.timeout(const Duration(seconds: 10));
        return null;
      } catch (e) {
        return e;
      }
    }

    /// A records 3 samples; A's stop is held inside the recorder's finalization
    /// (after the camera side finished); [breakStorage] then makes a box
    /// unavailable; the finalization resumes and fails. Returns A and the
    /// error its stop reported.
    Future<({DrivingSession a, Object? error})> failFinalizationOfA(
      ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r,
      DashcamService localService,
      Future<void> Function() breakStorage,
    ) async {
      await preferences.setEnabled(true);
      final a = r.controller.startSession();
      await waitForStatus(DashcamStatus.recording, on: r.controller);
      await feedSamples(3);
      expect(a.sampleCount, 3, reason: 'setup: A has three samples');
      // Fase 16.2-R4.3-R2.6.5 (matrix: X59's "record on disk is not finalized
      // yet" failed in 2 of 6 full-suite runs): every accepted sample does
      // `unawaited(session.save())`, and hive serializes the object when that
      // queued write RUNS — under load the last one ran after STOP had set
      // endTime, so endTime reached disk before the finalization. Same on the
      // R2.6.4 tree (probe: scratchpad/fase16_2_r4_3_r2_6_5/08_x59_diagnosis).
      // Waiting for those writes causally makes every scenario here start from a
      // settled record; the race itself is reported as a finding.
      await Hive.box<DrivingSession>(sessionsBox).flush();
      final endingGate = Completer<void>();
      r.gate.nextCancelGate = endingGate;
      final stopA = r.controller.stopSession();
      await waitUntil(
        () => r.gate.cancelEnteredCount >= 1 && localService.previewController == null && r.controller.status == DashcamStatus.idle,
        'A\'s camera side finished; the recorder is held inside its finalization',
      );
      expect(r.recorder.state, DrivingSessionRecorderState.finalizing);
      expect(r.controller.canStartSession, isFalse, reason: 'A is being finalized');
      await breakStorage();
      endingGate.complete();
      return (a: a, error: await errorOf(stopA));
    }

    /// Everything that must hold while A's finalization is pending after a
    /// failure: A kept as ENDED (never alive again), admission closed and said
    /// so, and a START refused before touching anything.
    Future<void> expectFailedAndNotAdmissible(
      ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r,
      DrivingSession a,
      String when,
    ) async {
      expect(r.recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: '$when: the finalization failed and is pending');
      expect(identical(r.recorder.activeSession, a), isTrue, reason: '$when: the SAME session is kept — nothing discarded');
      expect(a.endTime, isNotNull, reason: '$when: A has ended');
      expect(r.recorder.lastFinalizationError, isNotNull, reason: '$when: the error is observable');
      expect(r.controller.canStartSession, isFalse, reason: '$when: no start while A is not durably closed');
      expect(r.controller.sessionFinalizationFailed, isTrue, reason: '$when: the controller says why');
      final calls = List<String>.of(fakePlatform.calls);
      final attempts = r.controller.cameraAttemptCreationCountForTest;
      final setups = r.controller.initialSetupInstallCountForTest;
      expect(() => r.controller.startSession(), throwsA(isA<SessionAdmissionRejected>()), reason: '$when: START is refused, never aliased to A');
      await feedSamples(2);
      expect(a.sampleCount, 3, reason: '$when: an ended session collects nothing');
      await pumpEventQueue(times: 50);
      expect(fakePlatform.calls, calls, reason: '$when: the refused START touched no camera');
      expect(r.controller.cameraAttemptCreationCountForTest, attempts, reason: '$when: no CameraAttempt');
      expect(r.controller.initialSetupInstallCountForTest, setups, reason: '$when: no telemetry setup');
      expect(r.controller.recordingSessionIdForTest, isNull, reason: '$when: the camera side is not re-armed for A');
      expect(r.controller.status, DashcamStatus.idle);
    }

    Future<void> cleanUp(
      ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r,
      DashcamService localService,
    ) async {
      fakePlatform.pendingStopVideoRecording = null;
      await restoreBoxes();
      // Fase 16.2-R4.3-R2.6.5: after the boxes are back, so a stop held by a gate
      // an interrupted test never completed can finish instead of hanging.
      r.gate.releaseAllGates();
      for (var i = 0; i < 3 && r.recorder.hasPendingFinalization; i++) {
        await errorOf(r.recorder.stopSession());
      }
      await errorOf(r.controller.stopSession());
      await drainLocal(r.controller, localService);
      r.recorder.dispose();
    }

    test(
      'X58 (§14, MANDATORY GATE, blocker 1) — STOP fails while writing the SAMPLES (samples box unavailable at that '
      'checkpoint). Pre-fix: the recorder kept A looking alive, the controller re-admitted it, START returned A and '
      're-armed the camera for a session that collected nothing. Expected: the error reaches the caller; A is kept as '
      'ENDED with its finalization pending (same object, endTime set, nothing discarded, no longer collecting); a START '
      'is refused with SessionAdmissionRejected before any camera/telemetry/attempt side effect; the native STOP ran once',
      () async {
        final localService = buildShortStopService();
        final r = rig(localService);
        try {
          final result = await failFinalizationOfA(r, localService, closeSamplesBox);
          expect(result.error, isA<HiveError>(), reason: 'the persistence failure reaches the stopSession() caller');
          await expectFailedAndNotAdmissible(r, result.a, 'after the failure');
          expect(nativeCalls('startVideoCapturing'), 1, reason: 'only A\'s own Recording ever started');
          expect(nativeCalls('stopVideoRecording'), 1, reason: 'A\'s native STOP ran once — persistence is not the camera');
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X59 (§14/§15, blocker 1 variants B + E) — the samples WERE written, then persisting the SESSION record fails '
      '(sessions box closed at that checkpoint); the box is reopened. hive 2.2.3 keeps the in-memory session bound to '
      'the CLOSED box instance — it can neither save() nor be put into the reopened box. Expected: the samples '
      'checkpoint is durable (3 on disk), the record is not finalized on disk, START stays refused, and the retry '
      '(stopSession again) persists the SAME session by its stable id — endTime preserved, samples not duplicated, no '
      'camera involvement',
      () async {
        final localService = buildShortStopService();
        final r = rig(localService);
        try {
          final result = await failFinalizationOfA(r, localService, closeSessionsBox);
          final a = result.a;
          expect(result.error, isA<HiveError>());
          expect(await durableSampleCount(a.id), 3, reason: 'checkpoint 1 (samples) completed before the failure');
          await reopenSessionsBox();
          await expectFailedAndNotAdmissible(r, a, 'after the failure, box reopened');
          expect(identical(a.box, Hive.box<DrivingSession>(sessionsBox)), isFalse, reason: 'setup (E): the in-memory session is still bound to the CLOSED box instance');
          await expectLater(a.save(), throwsA(isA<HiveError>()), reason: 'setup (E): that instance cannot save() any more');
          expect(Hive.box<DrivingSession>(sessionsBox).get(a.id)?.endTime, isNull, reason: 'the record on disk is not finalized yet');
          final firstEnd = a.endTime!;
          final calls = List<String>.of(fakePlatform.calls);

          await r.controller.stopSession().timeout(const Duration(seconds: 10));
          expect(r.recorder.state, DrivingSessionRecorderState.idle);
          expect(r.recorder.activeSession, isNull);
          expect(r.controller.canStartSession, isTrue);
          expect(fakePlatform.calls, calls, reason: 'the retry touched no camera');
          final durable = await durableSession(a.id);
          expect(durable, isNotNull);
          expect(durable!.endTime?.millisecondsSinceEpoch, firstEnd.millisecondsSinceEpoch, reason: 'the endTime established by the first attempt is kept');
          expect(durable.sampleCount, 3);
          expect(await durableSampleCount(a.id), 3, reason: 'no sample written twice');
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X60 (§14, MANDATORY GATE) — retry after the storage recovered ends the SAME session and preserves its data '
      'without duplication: the samples box fails (A\'s three samples are only in memory), snapshots keep arriving '
      '(ignored), the box comes back, stopSession() is called twice concurrently (one attempt). Expected: exactly '
      'A\'s three samples on disk, A\'s record finalized with its ORIGINAL endTime, no subscription reinstalled, no '
      'native call, no CameraAttempt, no telemetry setup; a new session B then starts as a different session',
      () async {
        final localService = buildShortStopService();
        final r = rig(localService);
        try {
          final result = await failFinalizationOfA(r, localService, closeSamplesBox);
          final a = result.a;
          expect(result.error, isA<HiveError>());
          await expectFailedAndNotAdmissible(r, a, 'after the failure');
          final firstEnd = a.endTime!;
          await reopenSamplesBox();
          expect(await durableSampleCount(a.id), isNull, reason: 'setup: nothing of A reached the samples box');
          final calls = List<String>.of(fakePlatform.calls);
          final attempts = r.controller.cameraAttemptCreationCountForTest;
          final setups = r.controller.initialSetupInstallCountForTest;

          final retry1 = r.controller.stopSession();
          final retry2 = r.controller.stopSession();
          expect(identical(retry1, retry2), isTrue, reason: 'a concurrent retry joins the same attempt');
          expect(r.recorder.state, DrivingSessionRecorderState.finalizing);
          await retry1.timeout(const Duration(seconds: 10));
          await feedSamples(2);

          expect(r.recorder.state, DrivingSessionRecorderState.idle);
          expect(fakePlatform.calls, calls, reason: 'no native STOP/START/initialize by the retry');
          expect(r.controller.cameraAttemptCreationCountForTest, attempts);
          expect(r.controller.initialSetupInstallCountForTest, setups);
          expect(await durableSampleCount(a.id), 3, reason: 'exactly A\'s three samples — none duplicated, none added after its end');
          final durable = await durableSession(a.id);
          expect(durable!.endTime?.millisecondsSinceEpoch, firstEnd.millisecondsSinceEpoch, reason: 'the ORIGINAL endTime');
          expect(durable.sampleCount, 3);

          expect(r.controller.canStartSession, isTrue);
          final b = r.controller.startSession();
          expect(b.id, isNot(equals(a.id)), reason: 'a genuinely new session');
          await waitForStatus(DashcamStatus.recording, on: r.controller);
          await r.controller.stopSession().timeout(const Duration(seconds: 10));
          expect(await durableSampleCount(a.id), 3, reason: 'B wrote nothing into A');
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X61 (§9/§14) — the storage STAYS unavailable: three explicit retries all fail. Expected: every retry reports '
      'the error, the finalization stays pending (never re-admitted), no START, no camera, no attempt, nothing retried '
      'automatically between the explicit calls; once the storage is back one more retry finalizes with no sample '
      'duplicated by the failed ones',
      () async {
        final localService = buildShortStopService();
        final r = rig(localService);
        var notifications = 0;
        r.controller.addListener(() => notifications++);
        try {
          final result = await failFinalizationOfA(r, localService, closeSamplesBox);
          final a = result.a;
          for (var retry = 1; retry <= 3; retry++) {
            final error = await errorOf(r.controller.stopSession());
            expect(error, isA<HiveError>(), reason: 'retry $retry: the error is reported again');
            await expectFailedAndNotAdmissible(r, a, 'after retry $retry');
          }
          final settledNotifications = notifications;
          var sawFinalizing = false;
          for (var i = 0; i < 50; i++) {
            if (r.recorder.state == DrivingSessionRecorderState.finalizing) sawFinalizing = true;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(sawFinalizing, isFalse, reason: 'nothing retries on its own');
          expect(notifications, settledNotifications, reason: 'no background activity at all');
          expect(nativeCalls('stopVideoRecording'), 1);
          expect(nativeCalls('startVideoCapturing'), 1);

          await reopenSamplesBox();
          await r.controller.stopSession().timeout(const Duration(seconds: 10));
          expect(r.recorder.state, DrivingSessionRecorderState.idle);
          expect(await durableSampleCount(a.id), 3, reason: 'the failed attempts duplicated nothing');
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X62 (§10/§14, MANDATORY GATE, blocker 2) — START with the sessions box unavailable, i.e. failing BEFORE onCreated. '
      'Pre-fix: the recorder had already made the new session active — unannounced, unsubscribed, unpersisted — and '
      'a later START returned it as an alias whose STOP could never persist it. Expected: the failure reaches the '
      'caller and NOTHING exists — no active session, no announcement, no controller identity, no camera; admission '
      'is untouched; once the box is back a START creates a genuinely new session and it persists normally',
      () async {
        final localService = buildShortStopService();
        final r = rig(localService);
        var recorderNotifications = 0;
        r.recorder.addListener(() => recorderNotifications++);
        try {
          await preferences.setEnabled(true);
          await closeSessionsBox();
          Object? error;
          try {
            r.controller.startSession();
          } catch (e) {
            error = e;
          }
          expect(error, isA<HiveError>(), reason: 'the failure is communicated to the controller\'s caller');
          expect(error, isNot(isA<SessionAdmissionRejected>()), reason: 'a storage failure is not an admission refusal');
          await feedSamples(2);
          expect(r.recorder.activeSession, isNull, reason: 'no orphan session');
          expect(r.recorder.state, DrivingSessionRecorderState.idle);
          expect(recorderNotifications, 0, reason: 'nothing was announced');
          expect(r.controller.recordingSessionIdForTest, isNull);
          expect(r.controller.cameraAttemptCreationCountForTest, 0);
          expect(fakePlatform.calls, isEmpty, reason: 'no camera for a session that does not exist');
          expect(r.controller.canStartSession, isTrue, reason: 'nothing pending to finalize');

          await reopenSessionsBox();
          final s = r.controller.startSession();
          await waitForStatus(DashcamStatus.recording, on: r.controller);
          await feedSamples(2);
          await r.controller.stopSession().timeout(const Duration(seconds: 10));
          final box = Hive.box<DrivingSession>(sessionsBox);
          expect(box.keys, [s.id], reason: 'only the new session exists — the failed start left nothing behind');
          expect((await durableSession(s.id))?.endTime, isNotNull);
          expect(await durableSampleCount(s.id), 2);
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X63 (§10/§14) — START fails AFTER its durable checkpoint: the session record was written, then the '
      'controller\'s own registration (onCreated) throws. Expected (recoverable, identifiable, nothing deleted): the '
      'error reaches the caller; the session is real — active, recording, announced, collecting, durably recorded; the '
      'controller registered NOTHING of it (no half-registration); a STOP ends it cleanly — no assertion, no unhandled '
      'async error — and finalizes its record',
      () async {
        final localService = _ThrowingClipsService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final r = rig(localService);
        var recorderNotifications = 0;
        r.recorder.addListener(() => recorderNotifications++);
        final uncaught = <Object>[];
        try {
          await preferences.setEnabled(true);
          localService.armed = true;
          Object? error;
          try {
            r.controller.startSession();
          } catch (e) {
            error = e;
          }
          expect(error, isA<StateError>(), reason: 'the injected registration failure reaches the caller');
          final b = r.recorder.activeSession;
          expect(b, isNotNull, reason: 'the session is real');
          expect(r.recorder.state, DrivingSessionRecorderState.recording);
          expect(recorderNotifications, 1, reason: 'announced');
          await pumpEventQueue(times: 20);
          expect(Hive.box<DrivingSession>(sessionsBox).containsKey(b!.id), isTrue, reason: 'its durable checkpoint landed');
          await feedSamples(2);
          expect(b.sampleCount, 2, reason: 'it collects');
          expect(r.controller.recordingSessionIdForTest, isNull, reason: 'no half-registration');
          expect(r.controller.activeCameraAttemptSessionIdForTest, isNull);
          expect(fakePlatform.calls, isEmpty);

          final done = Completer<void>();
          Object? stopError;
          runZonedGuarded(() async {
            try {
              await r.controller.stopSession().timeout(const Duration(seconds: 10));
            } catch (e) {
              stopError = e;
            }
            await pumpEventQueue(times: 50);
            done.complete();
          }, (e, st) => uncaught.add(e));
          await done.future.timeout(const Duration(seconds: 15));
          expect(stopError, isNull, reason: 'the STOP is not refused for a missing identity');
          expect(uncaught, isEmpty, reason: 'no unhandled async error (pre-fix: an assertion on the missing context)');
          expect(r.recorder.state, DrivingSessionRecorderState.idle);
          final durable = await durableSession(b.id);
          expect(durable?.endTime, isNotNull, reason: 'finalized');
          expect(durable?.sampleCount, 2);
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X63-alias (§10) — the same failed start, followed by a START (the valid alias of that live session): the '
      'registration now completes and the camera records for it normally, and its STOP persists its clip under it',
      () async {
        final localService = _ThrowingClipsService(
          config: DashcamConfig(
            cameraSelection: CameraSelection.rear,
            storageQuotaMb: 1024,
            audioEnabled: false,
            resolution: VideoResolution.hd720,
            frameRate: 30,
            enabled: true,
          ),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final r = rig(localService);
        try {
          await preferences.setEnabled(true);
          localService.armed = true;
          expect(() => r.controller.startSession(), throwsStateError);
          final b = r.recorder.activeSession!;
          expect(identical(r.controller.startSession(), b), isTrue, reason: 'the valid alias of a live session');
          await waitForStatus(DashcamStatus.recording, on: r.controller);
          expect(r.controller.recordingSessionIdForTest, b.id);
          await r.controller.stopSession().timeout(const Duration(seconds: 10));
          expect(await settledClipsOf(localService, b.id, atLeast: 1), hasLength(1));
          expect((await durableSession(b.id))?.endTime, isNotNull);
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X64 (§6/§14) — a new session B starts only after A has finished its finalization: while A\'s finalization is '
      'in flight a START is refused; after a FAILED finalization it stays refused; only after the successful retry is '
      'B admitted — as a new session',
      () async {
        final localService = buildShortStopService();
        final r = rig(localService);
        try {
          await preferences.setEnabled(true);
          final a = r.controller.startSession();
          await waitForStatus(DashcamStatus.recording, on: r.controller);
          await feedSamples(2);
          final gate1 = Completer<void>();
          r.gate.nextCancelGate = gate1;
          final stopA = r.controller.stopSession();
          await waitUntil(() => r.gate.cancelEnteredCount >= 1, 'A is being finalized');
          expect(() => r.controller.startSession(), throwsA(isA<SessionAdmissionRejected>()), reason: 'finalization in flight');
          await closeSamplesBox();
          gate1.complete();
          expect(await errorOf(stopA), isA<HiveError>());
          expect(() => r.controller.startSession(), throwsA(isA<SessionAdmissionRejected>()), reason: 'finalization failed');
          await reopenSamplesBox();
          await r.controller.stopSession().timeout(const Duration(seconds: 10));
          expect((await durableSession(a.id))?.endTime, isNotNull, reason: 'A is durably closed first');
          final b = r.controller.startSession();
          expect(b.id, isNot(equals(a.id)));
          await waitForStatus(DashcamStatus.recording, on: r.controller);
          expect(r.controller.recordingSessionIdForTest, b.id);
        } finally {
          await cleanUp(r, localService);
        }
      },
    );

    test(
      'X65 (§12/§14) — failure and retry while A\'s PHYSICAL teardown is retained: A\'s native STOP is held past its '
      'presentation deadline and the recorder\'s finalization fails; retries (while the native STOP is still held) and '
      'an app pause/resume follow; then the native STOP settles late. Expected: persistence retries never repeat the '
      'native STOP, never create a CameraAttempt, never re-acquire the camera; A\'s late clip is indexed once, under '
      'A; and the finalization succeeds once the storage is back',
      () async {
        final localService = buildShortStopService();
        final r = rig(localService);
        final rawStop = Completer<void>();
        try {
          await preferences.setEnabled(true);
          final a = r.controller.startSession();
          await waitForStatus(DashcamStatus.recording, on: r.controller);
          await feedSamples(2);
          fakePlatform.pendingStopVideoRecording = rawStop;
          final endingGate = Completer<void>();
          r.gate.nextCancelGate = endingGate;
          final stopA = r.controller.stopSession();
          await waitUntil(() => r.gate.cancelEnteredCount >= 1 && nativeCalls('stopVideoRecording') == 1, 'A\'s native STOP issued and held');
          await closeSamplesBox();
          endingGate.complete();
          expect(await errorOf(stopA), isA<HiveError>());
          expect(localService.hasPendingNativeStop, isTrue, reason: 'setup: A\'s physical obligation is still retained');
          final attempts = r.controller.cameraAttemptCreationCountForTest;

          expect(await errorOf(r.controller.stopSession()), isA<HiveError>(), reason: 'a persistence retry while the native STOP is held');
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await pumpEventQueue(times: 20);
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await pumpEventQueue(times: 50);
          expect(nativeCalls('stopVideoRecording'), 1, reason: 'no native STOP repeated');
          expect(nativeCalls('createCameraWithSettings'), 1, reason: 'no camera re-acquired');
          expect(r.controller.cameraAttemptCreationCountForTest, attempts, reason: 'no CameraAttempt created or reactivated');

          fakePlatform.pendingStopVideoRecording = null;
          rawStop.complete();
          final clipsA = await settledClipsOf(localService, a.id, atLeast: 1);
          expect(clipsA, hasLength(1));
          List<DashcamClipRecord> indexed = const [];
          for (var i = 0; i < 300 && indexed.isEmpty; i++) {
            indexed = List<DashcamClipRecord>.from((Hive.box(HiveBoxNames.dashcamSessionVideos).get(a.id) as List?) ?? const []);
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(indexed.map((c) => c.filePath), [clipsA.single.file.path], reason: 'A\'s late clip indexed once, under A');
          expect(r.controller.activeCameraAttemptSessionIdForTest, isNull);
          expect(r.controller.status, DashcamStatus.idle);
          expect(r.recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'the camera settling does not finalize the recorder');

          await reopenSamplesBox();
          await r.controller.stopSession().timeout(const Duration(seconds: 10));
          expect(r.recorder.state, DrivingSessionRecorderState.idle);
          expect(nativeCalls('stopVideoRecording'), 1);
          expect(await durableSampleCount(a.id), 2);
        } finally {
          if (!rawStop.isCompleted) rawStop.complete();
          await cleanUp(r, localService);
        }
      },
    );

    testWidgets(
      'X66 (§11/§14, UI) — the dashcam tile is told when a start becomes unavailable (finalization in flight, then '
      'failed) and when it is available again; a tap on a "Iniciar sessão" rendered BEFORE the stop is refused '
      'without any unhandled exception and without side effects',
      (tester) async {
        late DashcamService localService;
        late ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r;
        // Created inside runAsync (below): a Completer built in this FakeAsync
        // body completes through the fake zone and would never resume the real
        // recorder waiting on it.
        late Completer<void> endingGate;
        Future<void>? stopA;
        try {
          await tester.runAsync(() async {
            endingGate = Completer<void>();
            localService = buildShortStopService();
            r = rig(localService);
            r.controller.startSession(); // recorder-only: the dashcam is still disabled
            await feedSamples(2);
            await preferences.setEnabled(true); // enabled mid-session: the tile offers the (valid) alias start
          });
          await tester.pumpWidget(MaterialApp(home: Scaffold(body: DashcamPreviewView(controller: r.controller))));
          FilledButton startButton() => tester.widget<FilledButton>(find.bySubtype<FilledButton>());
          expect(startButton().onPressed, isNotNull, reason: 'setup: rendered enabled');

          await tester.runAsync(() async {
            r.gate.nextCancelGate = endingGate;
            stopA = r.controller.stopSession();
            await waitUntil(() => r.gate.cancelEnteredCount >= 1, 'the recorder is finalizing');
          });
          // Not pumped yet: the rendered button is the stale, enabled one.
          final calls = List<String>.of(fakePlatform.calls);
          await tester.tap(find.text('Iniciar sessão'));
          expect(tester.takeException(), isNull, reason: 'the expected refusal is handled, not an unhandled error');
          expect(fakePlatform.calls, calls, reason: 'the refused tap touched nothing');
          expect(r.controller.recordingSessionIdForTest, isNull);

          await tester.pump();
          expect(startButton().onPressed, isNull, reason: 'the controller published the unavailability');
          expect(find.text('Finalizando a sessão anterior…'), findsOneWidget);

          await tester.runAsync(() async {
            await closeSamplesBox();
            endingGate.complete();
            expect(await errorOf(stopA!), isA<HiveError>());
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(startButton().onPressed, isNull, reason: 'still unavailable after the failure');
          expect(find.textContaining('não pôde ser salva'), findsOneWidget, reason: 'the failure is visible');

          await tester.runAsync(() async {
            await reopenSamplesBox();
            await r.controller.stopSession().timeout(const Duration(seconds: 10));
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(startButton().onPressed, isNotNull, reason: 'available again once the finalization succeeded');
          expect(find.text('Nenhuma sessão em andamento'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        } finally {
          await tester.runAsync(() async {
            if (!endingGate.isCompleted) endingGate.complete();
            if (stopA != null) await errorOf(stopA!);
            await cleanUp(r, localService);
          });
        }
      },
    );

    testWidgets(
      'X66-screen (§9/§11, UI) — SessionRecordingScreen: a failed finalization is shown with a clear retry ("Tentar '
      'finalizar novamente"), the failure is not an unhandled async error, and the retry after the storage came back '
      'ends the session',
      (tester) async {
        late DashcamService localService;
        late ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r;
        try {
          await tester.runAsync(() async {
            await Hive.openBox(HiveBoxNames.appSettings);
            localService = buildShortStopService();
            r = rig(localService);
            await preferences.setEnabled(true);
            r.controller.startSession();
            await waitForStatus(DashcamStatus.recording, on: r.controller);
            await feedSamples(2);
          });
          await tester.pumpWidget(
            MaterialApp(home: UnitPreferencesScope(preferences: UnitPreferences(), child: SessionRecordingScreen(recorder: r.recorder, dashcamController: r.controller))),
          );
          FilledButton button() => tester.widget<FilledButton>(find.bySubtype<FilledButton>());
          expect(find.text('Finalizar sessão'), findsOneWidget);

          await tester.runAsync(() async {
            await closeSamplesBox();
            button().onPressed!();
            await waitUntil(() => r.recorder.state == DrivingSessionRecorderState.finalizationFailed, 'the finalization failed');
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.textContaining('Não foi possível salvar a sessão'), findsOneWidget, reason: 'the error is visible');
          expect(find.text('Tentar finalizar novamente'), findsOneWidget, reason: 'with a clear retry');

          // Fase 16.2-R4.4-R1.2 (X66-screen fix): this test used to call the
          // onPressed of the button rendered right after the failure — while the
          // STOP request was, at that frame, still finishing its camera side (50 ms
          // presentation, the clip's promotion). Pre-fix that stale button was
          // enabled and the tap worked only when the request happened to have
          // settled before the callback ran; otherwise it joined the request and
          // was lost (the defect, reproduced by X477). The retry is now executable
          // only once the controller says a stop would retry: the test waits for
          // that, renders it, and takes it once.
          await tester.runAsync(() async {
            await reopenSamplesBox();
            await waitUntil(() => r.controller.canRetrySessionFinalization, 'the retry is executable (the STOP request settled)');
          });
          await tester.pump();
          expect(button().onPressed, isNotNull, reason: 'the retry is offered');
          await tester.runAsync(() async {
            button().onPressed!();
            await waitUntil(() => r.recorder.state == DrivingSessionRecorderState.idle, 'the retry finalized');
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.text('Nenhuma sessão em andamento'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        } finally {
          await tester.runAsync(() async => cleanUp(r, localService));
        }
      },
    );

    // Fase 16.2-R4.4-R1.2 — X66-screen (independent review of R4.4-R1-T-Rm, P2):
    // the recording screen offered "Tentar finalizar novamente" as soon as the
    // recorder's attempt failed, while the session's STOP request (its camera
    // stop, its telemetry close) was still in flight; the tap joined that
    // request, got its old error, and nothing was retried.

    /// Each finalization attempt of [recorder] started so far. An attempt is
    /// announced by exactly one notification, in a microtask right after it
    /// starts — before it can settle, so it still reads `finalizing`; the
    /// attempt's own end notifies with `finalizationFailed`/`idle`. Every
    /// notification read while `finalizing` is therefore one attempt START,
    /// concurrent ones included (an entry-into-`finalizing` count would miss a
    /// second attempt started while the first runs). Valid while nothing else
    /// makes the recorder notify during a finalization — no snapshots are fed
    /// after a STOP in these tests.
    int Function() countFinalizationAttempts(DrivingSessionRecorder recorder) {
      var count = 0;
      recorder.addListener(() {
        if (recorder.state == DrivingSessionRecorderState.finalizing) count++;
      });
      return () => count;
    }

    FilledButton x66Button(WidgetTester tester) => tester.widget<FilledButton>(find.bySubtype<FilledButton>());

    /// S records (dashcam on, 2 samples) with the recording screen mounted —
    /// unless [viaScreen] is false; then A, S's STOP — the screen's "Finalizar
    /// sessão", or a stopSession() call — runs with the samples box closed and
    /// S's native STOP held: the recorder's attempt fails while A is still in
    /// flight (its camera stop). A's presentation deadlines are held
    /// ([HeldDeadlines]: 9500 ms that never elapse on their own), so A ends only
    /// once the test completes [_X66Window.rawStop]. When this returns the
    /// samples box is open again ([reopen]) — a retry could succeed — and A has
    /// been checked to be still in flight.
    Future<_X66Window> x66PreviousStopInFlight(WidgetTester tester, {bool viaScreen = true, Future<void> Function()? reopen}) async {
      late DashcamService localService;
      late ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r;
      late DrivingSession s;
      late Completer<void> rawStop;
      late int Function() attempts;
      Future<void>? stopA;
      final deadline = HeldDeadlines.forDeadline(const Duration(milliseconds: 9500));
      await tester.runAsync(() async {
        // Created inside runAsync: a Completer built in the FakeAsync body
        // completes through the fake zone and would never resume the real code
        // waiting on it.
        rawStop = Completer<void>();
        await Hive.openBox(HiveBoxNames.appSettings);
        localService = buildLocalService(stopVideoRecordingTimeout: const Duration(milliseconds: 9500));
        r = rig(localService);
        attempts = countFinalizationAttempts(r.recorder);
        await preferences.setEnabled(true);
        s = r.controller.startSession();
        await waitForStatus(DashcamStatus.recording, on: r.controller);
        await feedSamples(2);
        // See failFinalizationOfA: the per-sample saves land before the STOP.
        await Hive.box<DrivingSession>(sessionsBox).flush();
      });
      if (viaScreen) {
        await tester.pumpWidget(
          MaterialApp(home: UnitPreferencesScope(preferences: UnitPreferences(), child: SessionRecordingScreen(recorder: r.recorder, dashcamController: r.controller))),
        );
        expect(find.text('Finalizar sessão'), findsOneWidget, reason: 'setup');
      }
      await tester.runAsync(() async {
        fakePlatform.pendingStopVideoRecording = rawStop;
        await closeSamplesBox();
        if (viaScreen) {
          deadline.run(() => x66Button(tester).onPressed!());
        } else {
          stopA = deadline.run(() => r.controller.stopSession());
        }
        await waitUntil(
          () => nativeCalls('stopVideoRecording') == 1 && r.recorder.state == DrivingSessionRecorderState.finalizationFailed,
          'A: S\'s native STOP entered and held; the recorder\'s attempt failed',
        );
        await (reopen ?? reopenSamplesBox)();
        await pumpEventQueue(times: 20);
      });
      expect(r.controller.inFlightStopRequestSessionIdForTest, s.id, reason: 'setup: A is still the in-flight STOP request of S');
      expect(attempts(), 1, reason: 'setup: A made one finalization attempt');
      expect(deadline.pending, greaterThan(0), reason: 'setup: A\'s presentation deadline is held — A cannot end on the clock');
      return _X66Window(service: localService, r: r, s: s, rawStop: rawStop, deadline: deadline, attempts: attempts, stopA: stopA);
    }

    /// A's native STOP returns; waits until A has settled — its request cleared
    /// and no native STOP left in flight.
    Future<void> x66ReleaseA(WidgetTester tester, _X66Window x) async {
      await tester.runAsync(() async {
        x.rawStop.complete();
        await waitUntil(
          () => x.r.controller.inFlightStopRequestIdForTest == null && !x.service.hasPendingNativeStop,
          'A settled: its request cleared and its native STOP finished',
        );
        await pumpEventQueue(times: 20);
      });
      expect(x.deadline.pending, 0, reason: 'A ended because its native STOP returned, not on a deadline');
    }

    /// The single-physical-STOP invariant, for S's one Recording.
    void expectOnePhysicalStop(String when) {
      expect(nativeCalls('stopVideoRecording'), 1, reason: '$when: S\'s Recording was stopped natively once');
      expect(fakePlatform.maxConcurrentStopVideoRecording, 1, reason: '$when: never two native STOPs at once');
      expect(nativeCalls('startVideoCapturing'), 1, reason: '$when: no new Recording');
      expect(nativeCalls('createCameraWithSettings'), 1, reason: '$when: no new camera');
    }

    Future<void> x66CleanUp(WidgetTester tester, _X66Window? x) async {
      if (x == null) return;
      await tester.runAsync(() async {
        // A's Future (when the test holds it) is observed before A can settle.
        final stopA = x.stopA;
        final settledA = stopA == null ? null : errorOf(stopA);
        if (!x.rawStop.isCompleted) x.rawStop.complete();
        // A settles BEFORE the cleanup's own recorder retry (cleanUp): A's old
        // error must not reach a screen that would already see the session ended
        // (a test that failed mid-way left the screen mounted). Bounded, and not
        // a failure here: a test that broke A's settlement has already failed.
        for (var i = 0; i < 300 && x.r.controller.inFlightStopRequestIdForTest != null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        x.deadline.expire();
        if (settledA != null) await settledA;
        await cleanUp(x.r, x.service);
      });
    }

    testWidgets(
      'X477 (X66-screen reproducer, R4.4-R1.2) — whatever the recording screen offers while the previous STOP request '
      'of the session is still in flight, ONE tap on its retry ("Tentar finalizar novamente") ends the session: a tap '
      'the screen accepts starts a new finalization attempt. Pre-fix the screen offered the retry, the tap joined the '
      'previous request (its old error), nothing was retried and the session stayed finalizationFailed until a second tap',
      (tester) async {
        _X66Window? x;
        try {
          final w = x = await x66PreviousStopInFlight(tester);
          await tester.pump();
          expect(find.textContaining('Não foi possível salvar a sessão'), findsOneWidget, reason: 'A\'s failure is visible');
          var taps = 0;
          if (x66Button(tester).onPressed != null) {
            // Offered while A is still in flight: the user takes it.
            await tester.runAsync(() async {
              x66Button(tester).onPressed!();
              await pumpEventQueue(times: 20);
            });
            taps++;
            expect(w.attempts(), 2, reason: 'the retry the screen offered, and the user took, started a new finalization attempt');
          }
          await x66ReleaseA(tester, w);
          await tester.pump();
          if (taps == 0) {
            expect(x66Button(tester).onPressed, isNotNull, reason: 'offered once A has settled');
            await tester.runAsync(() async => x66Button(tester).onPressed!());
            taps++;
          }
          await tester.runAsync(() async {
            await waitUntil(() => w.r.recorder.state == DrivingSessionRecorderState.idle, 'the ONE retry the user took ended the session');
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(taps, 1);
          expect(w.attempts(), 2, reason: 'exactly one new finalization attempt');
          expect(find.text('Nenhuma sessão em andamento'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expectOnePhysicalStop('after the retry');
          await tester.pumpWidget(const SizedBox());
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X478 (R4.4-R1.2) — while the previous STOP request of the session is still in flight the screen shows the '
      'failure and the retry, NOT executable, and what it waits for; the controller publishes the moment the request '
      'clears (no other event needed) and the retry becomes executable; ONE tap starts exactly one new finalization '
      'attempt — shown in progress while its write is held — and ends the session: samples stored once, the end time '
      'A set kept, the Recording stopped natively once',
      (tester) async {
        _X66Window? x;
        final samplesGate = HiveBoxIoGate(samplesBox);
        try {
          final w = x = await x66PreviousStopInFlight(tester, reopen: () => samplesGate.open(() => Hive.openLazyBox(samplesBox)));
          final endA = w.s.endTime!;
          await tester.pump();
          expect(find.textContaining('Não foi possível salvar a sessão'), findsOneWidget, reason: 'A\'s failure is visible');
          expect(find.text('Tentar finalizar novamente'), findsOneWidget, reason: 'the action is still named');
          expect(x66Button(tester).onPressed, isNull, reason: 'not executable while A is in flight: a tap would only join A');
          expect(find.textContaining('A tentativa anterior ainda está terminando'), findsOneWidget, reason: 'the screen says what it waits for');
          expect(w.r.controller.canRetrySessionFinalization, isFalse);
          await tester.tap(find.text('Tentar finalizar novamente'));
          await tester.runAsync(() async => pumpEventQueue(times: 20));
          expect(w.attempts(), 1, reason: 'a tap on the unavailable retry starts nothing (and nothing was accepted)');
          expectOnePhysicalStop('while A is in flight');

          var publishedAvailable = 0;
          void onChange() {
            if (w.r.controller.canRetrySessionFinalization) publishedAvailable++;
          }

          w.r.controller.addListener(onChange);
          await x66ReleaseA(tester, w);
          w.r.controller.removeListener(onChange);
          expect(publishedAvailable, greaterThan(0), reason: 'the controller notified once the retry became available');
          await tester.pump(); // one frame; fake time does not move, so the screen's 1 s tick never fires
          expect(x66Button(tester).onPressed, isNotNull, reason: 'executable once A has settled');
          expect(find.textContaining('A tentativa anterior ainda está terminando'), findsNothing);
          expect(find.textContaining('Não foi possível salvar a sessão'), findsOneWidget, reason: 'the failure stays visible until a retry succeeds');

          samplesGate.hold = true;
          await tester.runAsync(() async {
            x66Button(tester).onPressed!();
            await samplesGate.untilHolding().timeout(const Duration(seconds: 3), onTimeout: () => fail('the retry never reached its samples write'));
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(w.attempts(), 2, reason: 'exactly one new finalization attempt');
          expect(w.r.recorder.state, DrivingSessionRecorderState.finalizing);
          expect(find.text('Finalizando…'), findsOneWidget, reason: 'the retry is shown in progress');
          expect(x66Button(tester).onPressed, isNull);

          await tester.runAsync(() async {
            samplesGate.hold = false;
            samplesGate.releaseAll();
            await waitUntil(() => w.r.recorder.state == DrivingSessionRecorderState.idle, 'the retry ended the session');
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(find.text('Nenhuma sessão em andamento'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(w.attempts(), 2);
          expect(samplesGate.writes, 1, reason: 'the samples were written once, by the retry');
          expectOnePhysicalStop('after the retry');
          await tester.runAsync(() async {
            expect(await durableSampleCount(w.s.id), 2, reason: 'S\'s samples on disk, once');
            final stored = await durableSession(w.s.id);
            expect(stored?.endTime?.millisecondsSinceEpoch, endA.millisecondsSinceEpoch, reason: 'the end time A set is the one stored');
          });
          await tester.pumpWidget(const SizedBox());
        } finally {
          samplesGate.hold = false;
          samplesGate.releaseAll();
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X479 (R4.4-R1.2, single physical STOP) — while A (the previous STOP request of S) is in flight, STOPs of S join '
      'A — the same logical STOP, A\'s own outcome — and start no finalization attempt; a second STOP of the same '
      'Recording straight at the camera layer adopts A\'s native STOP: one native STOP, never two at once. Once A settles '
      'the controller publishes that a retry is available, and a STOP then is a NEW request — its own Future, its own '
      'attempt — that ends S',
      (tester) async {
        _X66Window? x;
        try {
          final w = x = await x66PreviousStopInFlight(tester, viaScreen: false);
          final requestA = w.r.controller.inFlightStopRequestIdForTest;
          expect(w.r.controller.canRetrySessionFinalization, isFalse, reason: 'A is in flight');
          await tester.runAsync(() async {
            final joined = [for (var i = 0; i < 3; i++) w.r.controller.stopSession()];
            for (final j in joined) {
              expect(identical(j, w.stopA), isTrue, reason: 'a STOP of S while A is in flight joins A');
            }
            final direct = w.service.stopLoopRecording();
            await pumpEventQueue(times: 20);
            expectOnePhysicalStop('while A is in flight');
            expect(w.attempts(), 1, reason: 'no finalization attempt while A is in flight');
            expect(w.r.controller.inFlightStopRequestIdForTest, requestA);

            final available = Completer<void>();
            void onChange() {
              if (w.r.controller.canRetrySessionFinalization && !available.isCompleted) available.complete();
            }

            w.r.controller.addListener(onChange);
            w.rawStop.complete();
            expect(await errorOf(w.stopA!), isA<HiveError>(), reason: 'A ends with its own outcome: the persistence failure');
            for (final j in joined) {
              expect(await errorOf(j), isA<HiveError>(), reason: 'the STOPs that joined A share it');
            }
            await direct.timeout(const Duration(seconds: 10));
            await available.future.timeout(const Duration(seconds: 10), onTimeout: () => fail('the controller never published that a retry is available'));
            w.r.controller.removeListener(onChange);

            final b = w.r.controller.stopSession();
            expect(identical(b, w.stopA), isFalse, reason: 'the retry is its own request');
            expect(w.r.controller.inFlightStopRequestIdForTest, isNot(requestA));
            expect(await errorOf(b), isNull, reason: 'the retry succeeded');
          });
          expect(w.r.recorder.state, DrivingSessionRecorderState.idle);
          expect(w.attempts(), 2, reason: 'exactly one new finalization attempt');
          expect(w.deadline.pending, 0);
          expectOnePhysicalStop('after the retry');
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X480 (R4.4-R1.2, multiple taps) — taps on the retry while A is in flight start nothing; once it is executable, '
      'three taps in a row (before the next frame) start exactly ONE finalization attempt — the later taps reach the '
      'attempt the first one started — and the session ends',
      (tester) async {
        _X66Window? x;
        try {
          final w = x = await x66PreviousStopInFlight(tester);
          await tester.pump();
          for (var i = 0; i < 3; i++) {
            await tester.tap(find.text('Tentar finalizar novamente'));
          }
          await tester.runAsync(() async => pumpEventQueue(times: 20));
          expect(w.attempts(), 1, reason: 'nothing started while A is in flight');
          await x66ReleaseA(tester, w);
          await tester.pump();
          await tester.runAsync(() async {
            final onPressed = x66Button(tester).onPressed!;
            onPressed();
            onPressed();
            onPressed();
            await waitUntil(() => w.r.recorder.state == DrivingSessionRecorderState.idle, 'the retry ended the session');
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(w.attempts(), 2, reason: 'three taps, ONE new finalization attempt');
          expect(find.text('Nenhuma sessão em andamento'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expectOnePhysicalStop('after the retry');
          await tester.pumpWidget(const SizedBox());
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X481 (R4.4-R1.2, the retry fails too, UI) — the retry\'s OWN failure (a write error distinct from A\'s) is the '
      'one shown, the retry is offered again, nothing retries on its own; a later retry then ends the session',
      (tester) async {
        _X66Window? x;
        final samplesGate = HiveBoxIoGate(samplesBox);
        const retryFailure = FileSystemException('retry write failed (injected)', 'x481');
        try {
          final w = x = await x66PreviousStopInFlight(tester, reopen: () => samplesGate.open(() => Hive.openLazyBox(samplesBox)));
          final errorA = w.r.recorder.lastFinalizationError;
          expect(errorA, isA<HiveError>(), reason: 'setup: A failed on the closed box');
          await x66ReleaseA(tester, w);
          await tester.pump();
          expect(find.textContaining('$errorA'), findsOneWidget, reason: 'A\'s failure is the one shown');
          samplesGate.failNext(retryFailure);
          await tester.runAsync(() async {
            x66Button(tester).onPressed!();
            await waitUntil(
              () => w.attempts() == 2 && w.r.recorder.state == DrivingSessionRecorderState.finalizationFailed,
              'the retry failed',
            );
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(samplesGate.failures, 1, reason: 'the retry reached the write and failed there');
          expect('${w.r.recorder.lastFinalizationError}', contains('retry write failed (injected)'), reason: 'the retry\'s own error is kept');
          expect(find.textContaining('retry write failed (injected)'), findsOneWidget, reason: 'and shown');
          expect(find.textContaining('$errorA'), findsNothing, reason: 'not A\'s old one');
          expect(x66Button(tester).onPressed, isNotNull, reason: 'the retry is offered again (the failed retry left nothing in flight)');
          expect(tester.takeException(), isNull, reason: 'the failure is not an unhandled error');
          await tester.runAsync(() async => pumpEventQueue(times: 50));
          expect(w.attempts(), 2, reason: 'nothing retries on its own');
          await tester.runAsync(() async {
            x66Button(tester).onPressed!();
            await waitUntil(() => w.r.recorder.state == DrivingSessionRecorderState.idle, 'a later retry ended the session');
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(find.text('Nenhuma sessão em andamento'), findsOneWidget);
          expect(w.attempts(), 3);
          expect(tester.takeException(), isNull);
          expectOnePhysicalStop('after the retries');
          await tester.pumpWidget(const SizedBox());
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X482 (R4.4-R1.2, the retry fails too, controller) — once A has settled, a STOP of S is a NEW request whose Future '
      'reports ITS OWN failure (a write error distinct from A\'s HiveError), never A\'s; nothing retries on its own; the '
      'next STOP ends S',
      (tester) async {
        _X66Window? x;
        final samplesGate = HiveBoxIoGate(samplesBox);
        const retryFailure = FileSystemException('retry write failed (injected)', 'x482');
        try {
          final w = x = await x66PreviousStopInFlight(tester, viaScreen: false, reopen: () => samplesGate.open(() => Hive.openLazyBox(samplesBox)));
          await tester.runAsync(() async {
            w.rawStop.complete();
            expect(await errorOf(w.stopA!), isA<HiveError>(), reason: 'A\'s outcome');
            await waitUntil(() => w.r.controller.canRetrySessionFinalization, 'the retry is available');
            samplesGate.failNext(retryFailure);
            final b = w.r.controller.stopSession();
            expect(identical(b, w.stopA), isFalse, reason: 'the retry is its own request');
            final errorB = await errorOf(b);
            expect(errorB, isNot(isA<HiveError>()), reason: 'never A\'s old error');
            expect('$errorB', contains('retry write failed (injected)'), reason: 'the retry\'s own failure reaches its caller');
            expect(w.r.recorder.state, DrivingSessionRecorderState.finalizationFailed);
            expect(w.r.controller.canRetrySessionFinalization, isTrue, reason: 'the failed retry left nothing in flight');
            await pumpEventQueue(times: 50);
            expect(w.attempts(), 2, reason: 'nothing retries on its own');
            expect(await errorOf(w.r.controller.stopSession()), isNull, reason: 'the next STOP ends S');
          });
          expect(w.r.recorder.state, DrivingSessionRecorderState.idle);
          expect(w.attempts(), 3);
          expectOnePhysicalStop('after the retries');
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X483 (R4.4-R1.2, the attempt in progress succeeds) — while the session\'s finalization attempt is still running '
      '(held inside it) no retry is offered — "Finalizando…", not executable — and when it succeeds the session ends: '
      'one attempt, no retry ever offered, nothing run again',
      (tester) async {
        late DashcamService localService;
        late ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r;
        late Completer<void> endingGate;
        late int Function() attempts;
        final states = <DrivingSessionRecorderState>[];
        try {
          await tester.runAsync(() async {
            endingGate = Completer<void>();
            await Hive.openBox(HiveBoxNames.appSettings);
            localService = buildLocalService();
            r = rig(localService);
            attempts = countFinalizationAttempts(r.recorder);
            r.recorder.addListener(() => states.add(r.recorder.state));
            await preferences.setEnabled(true);
            r.controller.startSession();
            await waitForStatus(DashcamStatus.recording, on: r.controller);
            await feedSamples(2);
            await Hive.box<DrivingSession>(sessionsBox).flush();
          });
          await tester.pumpWidget(
            MaterialApp(home: UnitPreferencesScope(preferences: UnitPreferences(), child: SessionRecordingScreen(recorder: r.recorder, dashcamController: r.controller))),
          );
          await tester.runAsync(() async {
            r.gate.nextCancelGate = endingGate;
            x66Button(tester).onPressed!();
            await waitUntil(
              () => r.gate.cancelEnteredCount >= 1 && r.recorder.state == DrivingSessionRecorderState.finalizing,
              'the attempt is running, held inside it',
            );
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(find.text('Finalizando…'), findsOneWidget);
          expect(x66Button(tester).onPressed, isNull, reason: 'no retry while the attempt runs');
          expect(find.text('Tentar finalizar novamente'), findsNothing);
          expect(r.controller.canRetrySessionFinalization, isFalse);
          await tester.runAsync(() async {
            endingGate.complete();
            await waitUntil(
              () => r.recorder.state == DrivingSessionRecorderState.idle && r.controller.inFlightStopRequestIdForTest == null,
              'the attempt succeeded and the STOP settled',
            );
            await pumpEventQueue(times: 20);
          });
          await tester.pump();
          expect(find.text('Nenhuma sessão em andamento'), findsOneWidget);
          expect(attempts(), 1, reason: 'one attempt');
          expect(states, isNot(contains(DrivingSessionRecorderState.finalizationFailed)), reason: 'no failure, so no retry was ever offered');
          expect(r.controller.canRetrySessionFinalization, isFalse);
          expect(nativeCalls('stopVideoRecording'), 1);
          expect(fakePlatform.maxConcurrentStopVideoRecording, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          await tester.runAsync(() async {
            if (!endingGate.isCompleted) endingGate.complete();
            await cleanUp(r, localService);
          });
        }
      },
    );

    testWidgets(
      'X484 (R4.4-R1.2, the screen goes away while A is in flight) — when A settles nothing calls back into the '
      'unmounted screen, nothing retries on its own, and the session is kept pending for a later retry',
      (tester) async {
        _X66Window? x;
        try {
          final w = x = await x66PreviousStopInFlight(tester);
          await tester.pump();
          expect(x66Button(tester).onPressed, isNull, reason: 'setup: the retry is waiting for A');
          await tester.pumpWidget(const SizedBox());
          await x66ReleaseA(tester, w);
          await tester.pump();
          expect(tester.takeException(), isNull, reason: 'nothing reached the unmounted screen');
          expect(w.attempts(), 1, reason: 'nothing retried on its own');
          expect(w.r.recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'S is kept for a later retry');
          expect(w.r.controller.canRetrySessionFinalization, isTrue);
          expectOnePhysicalStop('after A');
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X485 (R4.4-R1.2, the controller disposed while A is in flight) — A still ends with its own outcome (no '
      'notification attempted on the disposed controller), nothing retries, the session is kept pending',
      (tester) async {
        _X66Window? x;
        try {
          final w = x = await x66PreviousStopInFlight(tester, viaScreen: false);
          await tester.runAsync(() async {
            w.r.controller.dispose();
            w.rawStop.complete();
            expect(await errorOf(w.stopA!), isA<HiveError>(), reason: 'A\'s own outcome — not a failure to notify a disposed controller');
            await pumpEventQueue(times: 50);
          });
          expect(w.attempts(), 1, reason: 'nothing retried by a disposed controller');
          expect(w.r.recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'S is kept (retried or reclaimed later)');
          expect(fakePlatform.maxConcurrentStopVideoRecording, 1);
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    testWidgets(
      'X486 (R4.4-R1.2, A→B) — while A is in flight a START is refused and lifecycle changes acquire nothing; once A '
      'settles the retry ends S, then session B records with its own camera, nothing of A\'s STOP reaches it, and B\'s '
      'own STOP is its own request',
      (tester) async {
        _X66Window? x;
        try {
          final w = x = await x66PreviousStopInFlight(tester, viaScreen: false);
          await tester.runAsync(() async {
            expect(w.r.controller.canStartSession, isFalse);
            List<int> acquisitions() => [for (final call in ['createCameraWithSettings', 'initializeCamera', 'startVideoCapturing', 'stopVideoRecording']) nativeCalls(call)];
            final before = acquisitions();
            expect(() => w.r.controller.startSession(), throwsA(isA<SessionAdmissionRejected>()), reason: 'no START while S is not durably closed');
            // S's camera still exists while its STOP is held: the lifecycle pauses
            // and resumes its preview (that is all), and acquires nothing.
            w.r.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
            await pumpEventQueue();
            w.r.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
            await pumpEventQueue(times: 20);
            expect(acquisitions(), before, reason: 'neither the refused START nor the lifecycle acquired, started or stopped anything');
            expect(w.r.controller.recordingSessionIdForTest, isNull, reason: 'no camera side re-armed for S');
            expect(w.r.controller.canRetrySessionFinalization, isFalse);

            w.rawStop.complete();
            expect(await errorOf(w.stopA!), isA<HiveError>());
            await waitUntil(() => w.r.controller.canRetrySessionFinalization, 'the retry is available once A settled');
            expect(await errorOf(w.r.controller.stopSession()), isNull, reason: 'the retry ended S');
            expect(w.r.recorder.state, DrivingSessionRecorderState.idle);

            final b = w.r.controller.startSession();
            expect(b.id, isNot(w.s.id));
            await waitForStatus(DashcamStatus.recording, on: w.r.controller);
            expect(w.r.controller.recordingSessionIdForTest, b.id);
            expect(nativeCalls('stopVideoRecording'), 1, reason: 'nothing of S\'s STOP reached B\'s Recording');
            expect(nativeCalls('startVideoCapturing'), 2, reason: 'B\'s own Recording');

            final stopB = w.r.controller.stopSession();
            expect(identical(stopB, w.stopA), isFalse, reason: 'B\'s STOP is its own request');
            expect(await errorOf(stopB), isNull);
            expect(w.r.recorder.state, DrivingSessionRecorderState.idle);
            expect(nativeCalls('stopVideoRecording'), 2, reason: 'B\'s Recording stopped by B\'s own STOP');
            expect(fakePlatform.maxConcurrentStopVideoRecording, 1);
          });
          expect(w.attempts(), 3, reason: 'A, the retry of S, B');
        } finally {
          await x66CleanUp(tester, x);
        }
      },
    );

    // Fase 16.2-R4.3-R2.6.6 — session deletion safety (D1), at the controller
    // level; nested here only to reuse this group's harness (rig,
    // failFinalizationOfA, cleanUp). The recorder-level contract is X80–X88
    // (driving_session_recorder_test.dart), the history flow X89–X91
    // (session_history_screen_test.dart).
    group('Fase 16.2-R4.3-R2.6.6 — deletion vs the controller\'s STOP and retry', () {
      test(
        'X92 (D1) — A\'s finalization fails through the controller\'s STOP (samples box unavailable). Pre-fix the '
        'history deletion was accepted and the retry then recreated the deleted session. Expected: the deletion is '
        'refused and removes nothing (record, dashcam index, clip files, telemetry file); admission stays closed; the '
        'retry through the controller finalizes the SAME session (endTime, 3 samples); then START is admitted and the '
        'deletion is accepted, removing A\'s data and only A\'s',
        () async {
          final localService = buildShortStopService();
          final r = rig(localService);
          try {
            final result = await failFinalizationOfA(r, localService, closeSamplesBox);
            final a = result.a;
            expect(result.error, isA<HiveError>(), reason: 'setup');
            await reopenSamplesBox();
            // R4.4-R2.1.1-F1 — ANTES: A's stopSession() (failing here, in the recorder) returned after its STOP's index
            // pass. MOTIVO: that pass is no longer awaited by the STOP (RES-1); with a slower index A's entry was not
            // there yet when this setup read it (independent review, F1). DEPOIS: X92 awaits A's passes before reading.
            await r.controller.clipIndexFollowUpsSettledForTest(sessionId: a.id);
            final videos = Hive.box(HiveBoxNames.dashcamSessionVideos);
            final clipPaths = [for (final clip in (videos.get(a.id) as List? ?? const []).cast<DashcamClipRecord>()) clip.filePath];
            final telemetry = await DashcamTelemetryWriter.fileForSession(a.id);
            expect(clipPaths, isNotEmpty, reason: 'setup: A\'s clip is indexed (its camera side finished)');
            expect(clipPaths.every((p) => File(p).existsSync()), isTrue, reason: 'setup: A\'s clip files exist');
            expect(telemetry.existsSync(), isTrue, reason: 'setup: A\'s telemetry file exists');

            expect(await errorOf(deleteDrivingSession(a.id)), isA<SessionDeletionRejected>(),
                reason: 'pre-fix: accepted — A\'s record and dashcam data removed while its finalization was pending');
            expect(Hive.box<DrivingSession>(sessionsBox).get(a.id), same(a), reason: 'the record is untouched');
            expect(videos.containsKey(a.id), isTrue, reason: 'the dashcam index is untouched');
            expect(clipPaths.every((p) => File(p).existsSync()), isTrue, reason: 'the clip files are untouched');
            expect(telemetry.existsSync(), isTrue, reason: 'the telemetry file is untouched');
            await expectFailedAndNotAdmissible(r, a, 'after the refused deletion');
            final firstEnd = a.endTime!;

            await r.controller.stopSession().timeout(const Duration(seconds: 10));
            expect(r.recorder.state, DrivingSessionRecorderState.idle);
            expect(r.controller.canStartSession, isTrue);
            expect(await durableSampleCount(a.id), 3, reason: 'the same samples, once');
            final durable = await durableSession(a.id);
            expect(durable?.endTime?.millisecondsSinceEpoch, firstEnd.millisecondsSinceEpoch, reason: 'the same session, its original endTime');
            expect(durable?.sampleCount, 3);

            final b = r.controller.startSession();
            expect(b.id, isNot(a.id), reason: 'START is admitted again');
            await waitForStatus(DashcamStatus.recording, on: r.controller);
            await feedSamples(1);
            await r.controller.stopSession().timeout(const Duration(seconds: 10));

            await deleteDrivingSession(a.id);
            expect(await durableSession(a.id), isNull, reason: 'no record left, on disk');
            expect(await durableSampleCount(a.id), isNull, reason: 'no samples left');
            expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(a.id), isFalse, reason: 'no dashcam index left');
            expect(clipPaths.any((p) => File(p).existsSync()), isFalse, reason: 'no clip file left');
            expect(telemetry.existsSync(), isFalse, reason: 'no telemetry file left');
            expect((await durableSession(b.id))?.sampleCount, 1, reason: 'B is untouched');
          } finally {
            await cleanUp(r, localService);
          }
        },
      );
    });

    // Fase 16.2-R4.3-R2.6.7 — a durable deletion vs the dashcam's clip
    // publication; nested here only to reuse this group's harness (rig,
    // cleanUp, durableSession). Reproduced before the fix
    // (scratchpad/fase16_2_r4_3_r2_6_7/01_prefix_repro): a clip of a session
    // deleted while its STOP was still settling was indexed afterwards — by the
    // late pass after a retained native STOP, and by the IMMEDIATE pass after a
    // normal 400 ms one — or, landing while the deletion removed files, was
    // left in no index at all. The persistence-layer protocol (marker,
    // checkpoints, restart, failures) is X100–X107
    // (session_deletion_protocol_test.dart).
    group('Fase 16.2-R4.3-R2.6.7 — deletion vs the dashcam clip publication', () {
      Box<dynamic> videos() => Hive.box(HiveBoxNames.dashcamSessionVideos);
      List<String> indexedPaths(String id) => [
            for (final c in List<DashcamClipRecord>.from((videos().get(id) as List?) ?? const [])) c.filePath,
          ];
      Set<String> everyIndexedPath() => {for (final key in videos().keys) ...indexedPaths('$key')};

      /// Nothing of [id] is left: record (cache, then disk), samples, clip index, telemetry file.
      Future<void> expectNothingOf(String id, File telemetry, String when) async {
        expect(Hive.box<DrivingSession>(sessionsBox).containsKey(id), isFalse, reason: '$when: record');
        expect(await durableSampleCount(id), isNull, reason: '$when: samples');
        expect(videos().containsKey(id), isFalse, reason: '$when: clip index');
        expect(telemetry.existsSync(), isFalse, reason: '$when: telemetry file');
        expect(await durableSession(id), isNull, reason: '$when: record on disk');
      }

      /// A records 2 samples; its STOP returns at the presentation deadline with
      /// the native STOP retained by [rawStop]; the recorder has released A.
      Future<DrivingSession> stopAWithRetainedNativeStop(
        ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r,
        DashcamService s,
        Completer<void> rawStop,
      ) async {
        await preferences.setEnabled(true);
        final a = r.controller.startSession();
        await waitForStatus(DashcamStatus.recording, on: r.controller);
        await feedSamples(2);
        fakePlatform.pendingStopVideoRecording = rawStop;
        await r.controller.stopSession().timeout(const Duration(seconds: 10));
        expect(r.recorder.state, DrivingSessionRecorderState.idle, reason: 'setup: the recorder released A');
        expect(s.hasPendingNativeStop, isTrue, reason: 'setup: A\'s native STOP is retained');
        return a;
      }

      void releaseNativeStop(Completer<void> rawStop) {
        fakePlatform.pendingStopVideoRecording = null;
        if (!rawStop.isCompleted) rawStop.complete();
      }

      test(
        'X93 — A is deleted after its recorder released it while A\'s native STOP is still retained; then the STOP settles. '
        'Pre-fix the late pass indexed A\'s clip under the deleted session (index + file reachable from nothing). Expected: '
        'no index for A, the clip file discarded, the clip still A\'s (producer and claim — never another session\'s), the '
        'physical STOP run exactly once, nothing of A left',
        () async {
          final s = buildShortStopService();
          final r = rig(s);
          final rawStop = Completer<void>();
          try {
            final a = await stopAWithRetainedNativeStop(r, s, rawStop);
            final telemetry = await DashcamTelemetryWriter.fileForSession(a.id);
            await deleteDrivingSession(a.id);
            expect(sessionDeletionCommitted(a.id), isTrue);
            await expectNothingOf(a.id, telemetry, 'after the deletion, A\'s native STOP still retained');
            expect(s.hasPendingNativeStop, isTrue, reason: 'the deletion does not touch the physical STOP obligation');

            releaseNativeStop(rawStop);
            final clip = (await settledClipsOf(s, a.id, atLeast: 1)).single;
            await waitUntil(() => !clip.file.existsSync() || videos().containsKey(a.id), 'A\'s late pass ran');
            await pumpEventQueue(times: 20);
            expect(videos().containsKey(a.id), isFalse, reason: 'pre-fix: the late pass indexed the deleted session');
            expect(clip.file.existsSync(), isFalse, reason: 'pre-fix: the clip file stayed, referenced only by that orphan index');
            expect(everyIndexedPath().contains(clip.file.path), isFalse, reason: 'indexed under no session');
            expect(clip.producerToken, a.id);
            expect(r.controller.ownerOfPathForTest(clip.file.path), a.id, reason: 'still claimed by A: no other session can take it');
            expect(nativeCalls('stopVideoRecording'), 1, reason: 'the physical STOP ran, once');
            expect(s.hasPendingNativeStop, isFalse);
            await expectNothingOf(a.id, telemetry, 'after the late STOP');
          } finally {
            releaseNativeStop(rawStop);
            await cleanUp(r, s);
          }
        },
      );

      test(
        'X94 — a NORMAL native STOP (400 ms, within the production 5 s deadline): A deleted the moment its recorder '
        'releases it — before the controller\'s IMMEDIATE index pass. Pre-fix that pass indexed A after its deletion. '
        'Expected: not indexed, clip file discarded, the deletion complete — at the latest on a retry (on Windows A\'s '
        'telemetry file is still open by its writer until that stop closes it, and the first attempt keeps its marker)',
        () async {
          final s = buildLocalService();
          final r = rig(s);
          try {
            await preferences.setEnabled(true);
            final a = r.controller.startSession();
            await waitForStatus(DashcamStatus.recording, on: r.controller);
            await feedSamples(2);
            final telemetry = await DashcamTelemetryWriter.fileForSession(a.id);
            fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 400);
            final stop = r.controller.stopSession();
            await waitUntil(() => r.recorder.state == DrivingSessionRecorderState.idle, 'the recorder released A');
            expect(s.hasPendingNativeStop, isTrue, reason: 'setup: A\'s STOP has not settled — the immediate pass is still ahead');

            final first = await errorOf(deleteDrivingSession(a.id));
            expect(first == null || first is FileSystemException, isTrue, reason: 'accepted; only the still-open telemetry file may be left for a retry (got $first)');
            expect(sessionDeletionCommitted(a.id), isTrue);
            await stop.timeout(const Duration(seconds: 10));
            fakePlatform.stopVideoRecordingDelay = null;
            final clip = (await settledClipsOf(s, a.id, atLeast: 1)).single;
            await waitUntil(() => !clip.file.existsSync() || videos().containsKey(a.id), 'the immediate pass ran');
            expect(videos().containsKey(a.id), isFalse, reason: 'pre-fix: the IMMEDIATE pass indexed A after its deletion');
            expect(clip.file.existsSync(), isFalse);
            expect(r.controller.ownerOfPathForTest(clip.file.path), a.id);

            await deleteDrivingSession(a.id); // idempotent: completes whatever the first attempt could not
            await expectNothingOf(a.id, telemetry, 'after the stop');
            expect(nativeCalls('stopVideoRecording'), 1);
          } finally {
            fakePlatform.stopVideoRecordingDelay = null;
            await cleanUp(r, s);
          }
        },
      );

      test(
        'X95 — a clip published WHILE the deletion removes A\'s clip files (it already read A\'s index). Pre-fix the late '
        'entry was added to that index, the deletion then removed the whole index, and the late file was left referenced '
        'by NO index. Expected: the late clip is not indexed, its publisher discards it, and the deletion leaves no file of A',
        () async {
          final s = buildShortStopService();
          final r = rig(s);
          final rawStop = Completer<void>();
          final fileGate = Completer<void>();
          final inFileStep = Completer<void>();
          try {
            final a = await stopAWithRetainedNativeStop(r, s, rawStop);
            final telemetry = await DashcamTelemetryWriter.fileForSession(a.id);
            // A's earlier, already indexed segment — what the immediate pass of
            // a segment rotation writes. Put here rather than produced by a
            // real rotation, whose timer could otherwise take the retained STOP
            // (the first version of this test did, once, under load).
            final clipsDir = Directory('${dir.path}/dashcam_clips')..createSync(recursive: true);
            final earlierFile = File('${clipsDir.path}/clip_x95_earlier.mp4')..writeAsBytesSync([1, 2, 3]);
            await videos().put(a.id, [DashcamClipRecord(filePath: earlierFile.path, recordedAt: a.startTime, durationSeconds: 1, sizeBytes: 3)]);
            final earlier = indexedPaths(a.id);

            final deletion = IOOverrides.runWithIOOverrides(
              () => errorOf(deleteDrivingSession(a.id)),
              _DeletionFileHooks((path, op) async {
                if (op == 'exists' && path.endsWith('.mp4') && !inFileStep.isCompleted) {
                  inFileStep.complete();
                  await fileGate.future;
                }
              }),
            );
            await inFileStep.future.timeout(const Duration(seconds: 10));
            expect(sessionDeletionCommitted(a.id), isTrue, reason: 'setup: committed, inside its clip-file step (the index was read)');

            releaseNativeStop(rawStop);
            final late = (await settledClipsOf(s, a.id, atLeast: 1)).single;
            await waitUntil(() => !late.file.existsSync() || indexedPaths(a.id).contains(late.file.path), 'the late pass ran');
            expect(indexedPaths(a.id), earlier, reason: 'pre-fix: the late clip was added to the index the deletion had already read');
            expect(late.file.existsSync(), isFalse, reason: 'discarded by its publisher');

            fileGate.complete();
            expect(await deletion, isNull);
            expect(earlier.any((p) => File(p).existsSync()), isFalse);
            expect(everyIndexedPath().contains(late.file.path), isFalse);
            await expectNothingOf(a.id, telemetry, 'after the deletion');
          } finally {
            if (!fileGate.isCompleted) fileGate.complete();
            releaseNativeStop(rawStop);
            await cleanUp(r, s);
          }
        },
      );

      test(
        'X96 — the deletion check sits IN the index write: a publication already past every earlier point (clips '
        'claimed, its write about to run) when A\'s deletion commits and completes writes nothing when it resumes, and '
        'discards its file. A check made anywhere before that write (while A still existed) would index A',
        () async {
          final s = buildShortStopService();
          final r = rig(s);
          final rawStop = Completer<void>();
          final writeGate = Completer<void>();
          final atWrite = Completer<List<String>>();
          try {
            final a = await stopAWithRetainedNativeStop(r, s, rawStop);
            final telemetry = await DashcamTelemetryWriter.fileForSession(a.id);
            r.controller.persistClipIndexHookForTest = (id, paths, write) async {
              if (id == a.id && !atWrite.isCompleted) {
                atWrite.complete(paths);
                await writeGate.future;
              }
              await write();
            };
            releaseNativeStop(rawStop);
            final claimed = await atWrite.future.timeout(const Duration(seconds: 10));
            expect(claimed, hasLength(1), reason: 'setup: A\'s late clip is claimed, its write not run');
            expect(sessionDeletionCommitted(a.id), isFalse, reason: 'setup: not deleted yet');

            await deleteDrivingSession(a.id);
            await expectNothingOf(a.id, telemetry, 'deleted while the write waited');
            writeGate.complete();
            await waitUntil(() => !File(claimed.single).existsSync() || videos().containsKey(a.id), 'the write ran');
            await pumpEventQueue(times: 20);
            expect(videos().containsKey(a.id), isFalse, reason: 'the write saw the committed deletion');
            expect(File(claimed.single).existsSync(), isFalse);
          } finally {
            r.controller.persistClipIndexHookForTest = null;
            if (!writeGate.isCompleted) writeGate.complete();
            releaseNativeStop(rawStop);
            await cleanUp(r, s);
          }
        },
      );

      test(
        'X97 — A is deleted while its native STOP is retained and B has already started: A\'s late clip is discarded, '
        'never indexed under A nor attributed to B; B records and is indexed normally; deleting B then removes B\'s data only',
        () async {
          final s = buildShortStopService();
          final r = rig(s);
          final rawStop = Completer<void>();
          try {
            final a = await stopAWithRetainedNativeStop(r, s, rawStop);
            final telemetryA = await DashcamTelemetryWriter.fileForSession(a.id);
            expect(r.controller.canStartSession, isTrue);
            final b = r.controller.startSession();
            await pumpEventQueue(times: 20);
            await deleteDrivingSession(a.id);

            releaseNativeStop(rawStop);
            final clipA = (await settledClipsOf(s, a.id, atLeast: 1)).single;
            await waitForStatus(DashcamStatus.recording, on: r.controller);
            await waitUntil(() => !clipA.file.existsSync() || videos().containsKey(a.id), 'A\'s late pass ran');
            await feedSamples(2);
            await r.controller.stopSession().timeout(const Duration(seconds: 10));
            final clipB = (await settledClipsOf(s, b.id, atLeast: 1)).single;
            await waitUntil(() => indexedPaths(b.id).isNotEmpty, 'B\'s clip is indexed');

            expect(videos().containsKey(a.id), isFalse);
            expect(clipA.file.existsSync(), isFalse);
            expect(r.controller.ownerOfPathForTest(clipA.file.path), a.id);
            expect(clipB.producerToken, b.id);
            expect(indexedPaths(b.id), [clipB.file.path], reason: 'B holds its own clip, and only it');
            expect(clipB.file.existsSync(), isTrue);
            await expectNothingOf(a.id, telemetryA, 'A');

            final telemetryB = await DashcamTelemetryWriter.fileForSession(b.id);
            await deleteDrivingSession(b.id);
            expect(clipB.file.existsSync(), isFalse);
            await expectNothingOf(b.id, telemetryB, 'B');
          } finally {
            releaseNativeStop(rawStop);
            await cleanUp(r, s);
          }
        },
      );

      test(
        'X98 — only a COMMITTED deletion stops the publication: a session whose record is merely absent (what a START '
        'whose put failed leaves for a live session) still gets its late clip indexed',
        () async {
          final s = buildShortStopService();
          final r = rig(s);
          final rawStop = Completer<void>();
          try {
            final a = await stopAWithRetainedNativeStop(r, s, rawStop);
            await Hive.box<DrivingSession>(sessionsBox).delete(a.id); // absent — but nobody decided to delete it
            expect(sessionDeletionCommitted(a.id), isFalse);
            releaseNativeStop(rawStop);
            final clip = (await settledClipsOf(s, a.id, atLeast: 1)).single;
            await waitUntil(() => videos().containsKey(a.id), 'the late pass indexed A\'s clip');
            expect(indexedPaths(a.id), [clip.file.path]);
            expect(clip.file.existsSync(), isTrue);

            await deleteDrivingSession(a.id);
            expect(videos().containsKey(a.id), isFalse);
            expect(clip.file.existsSync(), isFalse);
          } finally {
            releaseNativeStop(rawStop);
            await cleanUp(r, s);
          }
        },
      );

      test(
        'X99 — stress: A recorded, stopped (native STOP retained, or slow within its deadline) and deleted at different '
        'moments of its publication — before the STOP settles, at the recorder\'s release, a few turns or ms after — with '
        'a control session C indexed throughout: once A\'s publication settled, A has no index and no clip file; each '
        'Recording was stopped exactly once; nothing of A is left; C is untouched',
        () async {
          const cId = 'X99-control';
          final clipsDir = Directory('${dir.path}/dashcam_clips')..createSync(recursive: true);
          final cFile = File('${clipsDir.path}/clip_x99_control.mp4')..writeAsBytesSync([7, 7, 7]);
          final cTelemetry = await DashcamTelemetryWriter.fileForSession(cId);
          cTelemetry.writeAsStringSync('{}\n');
          final now = DateTime.now();
          await Hive.box<DrivingSession>(sessionsBox).put(cId, DrivingSession(id: cId, startTime: now, endTime: now));
          await videos().put(cId, [DashcamClipRecord(filePath: cFile.path, recordedAt: now)]);

          var rounds = 0;
          for (final (mode, delay) in [
            ('retained', -1),
            ('retained', 0),
            ('retained', 1),
            ('retained', 3),
            ('retained', 10),
            ('retained', 30),
            ('slow', 0),
            ('slow', 5),
            ('slow', 50),
          ]) {
            final label = 'round $mode/$delay';
            final s = mode == 'retained' ? buildShortStopService() : buildLocalService();
            final r = rig(s);
            final rawStop = Completer<void>();
            try {
              final starts = nativeCalls('startVideoCapturing');
              final stops = nativeCalls('stopVideoRecording');
              await preferences.setEnabled(true);
              final a = r.controller.startSession();
              await waitForStatus(DashcamStatus.recording, on: r.controller);
              await feedSamples(2);
              final telemetry = await DashcamTelemetryWriter.fileForSession(a.id);
              Object? first;
              if (mode == 'retained') {
                fakePlatform.pendingStopVideoRecording = rawStop;
                await r.controller.stopSession().timeout(const Duration(seconds: 10));
                if (delay < 0) first = await errorOf(deleteDrivingSession(a.id));
                releaseNativeStop(rawStop);
                if (delay >= 0) {
                  for (var i = 0; i < delay; i++) {
                    await Future<void>.delayed(Duration.zero);
                  }
                  first = await errorOf(deleteDrivingSession(a.id));
                }
              } else {
                fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 300);
                final stop = r.controller.stopSession();
                await waitUntil(() => r.recorder.state == DrivingSessionRecorderState.idle, '$label: released');
                if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
                first = await errorOf(deleteDrivingSession(a.id));
                await stop.timeout(const Duration(seconds: 10));
                fakePlatform.stopVideoRecordingDelay = null;
              }
              expect(first == null || first is FileSystemException, isTrue, reason: '$label: $first');
              expect(sessionDeletionCommitted(a.id), isTrue, reason: label);

              final clips = await settledClipsOf(s, a.id, atLeast: 1);
              await waitUntil(() => clips.every((c) => !c.file.existsSync()) || videos().containsKey(a.id), '$label: A\'s publication settled');
              await pumpEventQueue(times: 20);
              // Checked BEFORE any retry: nothing may have been indexed or kept after the deletion.
              expect(videos().containsKey(a.id), isFalse, reason: '$label: no index for A');
              for (final c in clips) {
                expect(c.file.existsSync(), isFalse, reason: '$label: no clip file of A');
                expect(everyIndexedPath().contains(c.file.path), isFalse, reason: '$label: in no index');
              }
              expect(nativeCalls('startVideoCapturing') - starts, 1, reason: label);
              expect(nativeCalls('stopVideoRecording') - stops, 1, reason: '$label: the Recording was stopped exactly once');

              await deleteDrivingSession(a.id); // completes what the first attempt could not (the open telemetry file on Windows)
              await expectNothingOf(a.id, telemetry, label);
              expect(Hive.box<DrivingSession>(sessionsBox).containsKey(cId), isTrue, reason: '$label: C untouched');
              expect(indexedPaths(cId), [cFile.path], reason: '$label: C untouched');
              expect(cFile.existsSync() && cTelemetry.existsSync(), isTrue, reason: '$label: C untouched');
              rounds++;
            } finally {
              fakePlatform.stopVideoRecordingDelay = null;
              releaseNativeStop(rawStop);
              await cleanUp(r, s);
            }
          }
          expect(rounds, 9);
        },
      );

      // Fase 16.2-R4.3-R2.6.7-T2 — regression hardening. The R2.6.7 pre-audit
      // (scratchpad/fase16_2_r4_3_r2_6_7/pre_audit, §13.2) mutated the order of
      // the deletion's decision in isolated copies: decided BEFORE its marker
      // (W) or only AFTER its clip files (H). The suite caught both only through
      // a flag or a setup precondition (X95, X100, X102, X103); the audit's
      // probes showed the consequences — a surviving session losing its clip
      // (PA-C3), a clip file left in no index (PA-C4). These two tests assert
      // those consequences, with no internal flag before them.
      group('Fase 16.2-R4.3-R2.6.7-T2 — decision order, by its consequences', () {
        test(
          'X113 — (W) a deletion that fails at its marker (the write fails before taking effect) decides nothing: S, '
          'the session it targeted, survives, and S\'s clip — published only later, when S\'s retained native STOP '
          'settles — is indexed under S and its file kept. Meanwhile another session, A, is deleted and loses '
          'everything. A deletion decided before its marker was durable would discard the surviving session\'s clip',
          () async {
            final s = buildShortStopService();
            final r = rig(s);
            final rawStop = Completer<void>();
            final failing = _WriteFailingSessionAdapter();
            try {
              final survivor = await stopAWithRetainedNativeStop(r, s, rawStop);
              final survivorTelemetry = await DashcamTelemetryWriter.fileForSession(survivor.id);
              final survivorSamples = await durableSampleCount(survivor.id);
              expect(survivorSamples, greaterThan(0), reason: 'setup: S\'s samples are stored');
              expect(survivorTelemetry.existsSync(), isTrue, reason: 'setup: S\'s telemetry file exists');

              Hive.registerAdapter<DrivingSession>(failing, override: true);
              failing.armed = true;
              final failed = await errorOf(deleteDrivingSession(survivor.id));
              failing.armed = false;
              Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
              expect(failed, isA<StateError>(), reason: 'setup: S\'s deletion failed at its marker, before the write took effect');

              // A: another finalized session, with a clip, deleted while S's late work is pending.
              const aId = 'X113-A';
              final clipsDir = Directory('${dir.path}/dashcam_clips')..createSync(recursive: true);
              final aClip = File('${clipsDir.path}/clip_x113_a.mp4')..writeAsBytesSync([1, 2, 3]);
              final aTelemetry = await DashcamTelemetryWriter.fileForSession(aId);
              aTelemetry.writeAsStringSync('{}\n');
              final now = DateTime.now();
              await Hive.box<DrivingSession>(sessionsBox).put(aId, DrivingSession(id: aId, startTime: now, endTime: now, sampleCount: 1));
              await Hive.lazyBox(samplesBox).put(aId, [DrivingSessionSample(timestamp: now, speedKmh: 30)]);
              await videos().put(aId, [DashcamClipRecord(filePath: aClip.path, recordedAt: now)]);
              await deleteDrivingSession(aId);
              expect(aClip.existsSync(), isFalse, reason: 'A\'s clip file is deleted with it');
              await expectNothingOf(aId, aTelemetry, 'A');
              expect(s.hasPendingNativeStop, isTrue, reason: 'setup: S\'s native STOP is still retained');

              releaseNativeStop(rawStop);
              final clip = (await settledClipsOf(s, survivor.id, atLeast: 1)).single;
              await waitUntil(() => videos().containsKey(survivor.id) || !clip.file.existsSync(), 'S\'s late pass ran');
              await pumpEventQueue(times: 20);
              expect('indexed under S: ${indexedPaths(survivor.id).contains(clip.file.path)}, file kept: ${clip.file.existsSync()}',
                  'indexed under S: true, file kept: true',
                  reason: 'S survived its failed deletion, so its late clip is S\'s like any other (pre-audit NC-W: refused and '
                      'discarded — the deletion counted as decided although its marker never took effect: S lost its video)');
              expect(indexedPaths(survivor.id), [clip.file.path]);
              expect(clip.producerToken, survivor.id);
              expect(r.controller.ownerOfPathForTest(clip.file.path), survivor.id);
              final durable = await durableSession(survivor.id);
              expect(durable, isNotNull, reason: 'S survives on disk');
              expect(durable!.deletionPending, isFalse, reason: 'its marker never took effect');
              expect(await durableSampleCount(survivor.id), survivorSamples);
              expect(survivorTelemetry.existsSync(), isTrue);
              expect(videos().containsKey(aId) || aClip.existsSync(), isFalse, reason: 'A stays deleted');
              expect(sessionDeletionCommitted(survivor.id), isFalse, reason: 'consistent with the above: nothing was decided');

              await deleteDrivingSession(survivor.id); // still deletable, normally
              expect(clip.file.existsSync(), isFalse);
              await expectNothingOf(survivor.id, survivorTelemetry, 'S after its own deletion');
            } finally {
              failing.armed = false;
              Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
              releaseNativeStop(rawStop);
              await cleanUp(r, s);
            }
          },
        );

        test(
          'X114 — (H) consequence only: a late clip published while the deletion is inside its clip-file step (it '
          'already read A\'s index) ends in NO index and NO file, and never enters the index the deletion read. A '
          'deletion decided only after its clip files would let that write in and then remove the whole index with it: '
          'a clip file referenced by nothing (the B2 orphan of the R2.6.6 pre-audit)',
          () async {
            final s = buildShortStopService();
            final r = rig(s);
            final rawStop = Completer<void>();
            final fileGate = Completer<void>();
            final inFileStep = Completer<String>();
            Future<Object?>? deletion;
            try {
              final a = await stopAWithRetainedNativeStop(r, s, rawStop);
              final telemetry = await DashcamTelemetryWriter.fileForSession(a.id);
              // A's earlier, already indexed segment (put directly, as in X95).
              final clipsDir = Directory('${dir.path}/dashcam_clips')..createSync(recursive: true);
              final earlierFile = File('${clipsDir.path}/clip_x114_earlier.mp4')..writeAsBytesSync([1, 2, 3]);
              await videos().put(a.id, [DashcamClipRecord(filePath: earlierFile.path, recordedAt: a.startTime, durationSeconds: 1, sizeBytes: 3)]);

              deletion = IOOverrides.runWithIOOverrides(
                () => errorOf(deleteDrivingSession(a.id)),
                _DeletionFileHooks((path, op) async {
                  if (op == 'exists' && path == earlierFile.path && !inFileStep.isCompleted) {
                    inFileStep.complete(path);
                    await fileGate.future;
                  }
                }),
              );
              // An observable position, not an internal flag: the deletion is
              // checking a file only its read of A's index could have named.
              expect(await inFileStep.future.timeout(const Duration(seconds: 10)), earlierFile.path, reason: 'setup: held inside the clip-file step');

              releaseNativeStop(rawStop);
              final late = (await settledClipsOf(s, a.id, atLeast: 1)).single;
              await waitUntil(() => !late.file.existsSync() || indexedPaths(a.id).contains(late.file.path), 'the late pass ran');
              final enteredIndexWhileHeld = indexedPaths(a.id).contains(late.file.path);

              fileGate.complete();
              final error = await deletion;
              await pumpEventQueue(times: 20);
              expect('late clip file exists: ${late.file.existsSync()}, in some index: ${everyIndexedPath().contains(late.file.path)}',
                  'late clip file exists: false, in some index: false',
                  reason: 'discarded by its publisher, indexed nowhere — never a file referenced by NO index (pre-audit NC-H + '
                      'PA-C4: that orphan, 2/2)');
              expect(enteredIndexWhileHeld, isFalse, reason: 'it never entered the index the deletion had already read');
              expect(error, isNull);
              expect(earlierFile.existsSync(), isFalse);
              expect(late.producerToken, a.id);
              expect(r.controller.ownerOfPathForTest(late.file.path), a.id, reason: 'still A\'s: never another session\'s');
              await expectNothingOf(a.id, telemetry, 'after the deletion');
            } finally {
              if (!fileGate.isCompleted) fileGate.complete();
              releaseNativeStop(rawStop);
              if (deletion != null) await deletion;
              await cleanUp(r, s);
            }
          },
        );
      });
    });
  });

  // ==========================================================================
  // Fase 16.2-R4.3-R2.6.5 — idempotent sample flush under an AMBIGUOUS Hive
  // write (independent review, P2), at the controller level: the reviewer's own
  // scenario. The recorder-level regressions (X70–X76, X78, X79) live in
  // driving_session_recorder_test.dart.
  // ==========================================================================
  group('Fase 16.2-R4.3-R2.6.5 — ambiguous sample write, controller level', () {
    test(
      'X77 (§10, reviewer\'s scenario) — A records 40, 41, 42; the STOP\'s sample put WRITES them and then fails in '
      'the samples box\'s REAL compaction (the app\'s default strategy; the .hivec file cannot be opened). Pre-fix the '
      'retry appended the same batch again: 40,41,42,40,41,42 with sampleCount 3. Expected: the failure reaches the '
      'caller, A stays pending and no START is admitted; the retry reconciles and stores 40, 41, 42 exactly once, with '
      'no native call and no CameraAttempt',
      () async {
        const samplesBox = HiveBoxNames.drivingSessionSamples;
        // 100 superseded frames written with compaction disabled; reopened with
        // the default strategy (as HiveBoxes.init does), the keystore counts them
        // as deleted while loading, so the recorder's next put really compacts.
        await Hive.lazyBox(samplesBox).close();
        final prep = await Hive.openLazyBox(samplesBox, compactionStrategy: (_, _) => false);
        for (var i = 0; i < 101; i++) {
          await prep.put('unrelated', <DrivingSessionSample>[]);
        }
        await prep.close();
        await Hive.openLazyBox(samplesBox);
        // Compaction writes into `<box>.hivec`; a directory there makes it fail
        // after the frame was written (PathAccessException on Windows).
        final obstacle = Directory('${dir.path}/$samplesBox.hivec')..createSync();

        final localService = buildLocalService(stopVideoRecordingTimeout: const Duration(milliseconds: 50));
        final localRecorder = DrivingSessionRecorder(snapshotController.stream);
        final localController = DashcamSessionController(
          dashcamService: localService,
          dashcamPreferences: preferences,
          sessionRecorder: localRecorder,
          snapshotStream: snapshotController.stream,
          eventStream: eventController.stream,
        );
        Future<List<double?>?> storedSpeeds(String id) async =>
            ((await Hive.lazyBox(samplesBox).get(id)) as List?)?.map((s) => (s as DrivingSessionSample).speedKmh).toList();
        try {
          await preferences.setEnabled(true);
          final a = localController.startSession();
          await waitForStatus(DashcamStatus.recording, on: localController);
          var clock = DateTime.now();
          for (final speed in [40.0, 41.0, 42.0]) {
            clock = clock.add(const Duration(seconds: 2));
            snapshotController.add(snapshot(timestamp: clock, speedKmh: speed));
            await pumpEventQueue();
          }
          expect(a.sampleCount, 3, reason: 'setup');

          Object? error;
          try {
            await localController.stopSession().timeout(const Duration(seconds: 10));
          } catch (e) {
            error = e;
          }
          expect(error, isNotNull, reason: 'the failed put is reported (${error.runtimeType}) — not assumed to be a HiveError');
          expect(await storedSpeeds(a.id), [40, 41, 42], reason: 'setup: the write took effect although put threw');
          expect(localRecorder.state, DrivingSessionRecorderState.finalizationFailed);
          expect(localController.canStartSession, isFalse);
          expect(() => localController.startSession(), throwsA(isA<SessionAdmissionRejected>()));
          // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): stopSession() returns at its
          // 50 ms presentation; the first STOP's physical teardown — the clip's
          // processing (real file I/O since R4.4-R1), then the camera's native
          // dispose — can still be running. The snapshot below was then taken
          // before that dispose, and "the retry touched no camera" failed on the
          // FIRST stop's own late dispose (found under the directed delays, T-Rm
          // 05_hardened/screen_full2). The snapshot is taken once that teardown
          // has settled: camera released, no native STOP in flight.
          await waitForCondition(() => localService.previewController == null && !localService.hasPendingNativeStop, 'the first STOP\'s physical teardown settled');
          final calls = List<String>.of(fakePlatform.calls);
          final attempts = localController.cameraAttemptCreationCountForTest;

          await localController.stopSession().timeout(const Duration(seconds: 10));
          expect(localRecorder.state, DrivingSessionRecorderState.idle);
          expect(await storedSpeeds(a.id), [40, 41, 42], reason: 'pre-fix: 40,41,42,40,41,42');
          expect(a.sampleCount, 3);
          expect(fakePlatform.calls, calls, reason: 'the retry touched no camera');
          expect(localController.cameraAttemptCreationCountForTest, attempts);
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
        } finally {
          if (obstacle.existsSync()) obstacle.deleteSync(recursive: true);
          if (!Hive.isBoxOpen(samplesBox)) await Hive.openLazyBox(samplesBox);
          for (var i = 0; i < 3 && localRecorder.hasPendingFinalization; i++) {
            try {
              await localRecorder.stopSession();
            } catch (_) {}
          }
          try {
            await localController.stopSession().timeout(const Duration(seconds: 10));
          } catch (_) {}
          await drainLocal(localController, localService);
          localRecorder.dispose();
        }
      },
    );
  });
}

/// Fase 16.2-R4.3-R2.6.4 (X63): makes the controller's registration — the
/// recorder's `onCreated` — throw once, through the only external read it
/// performs ([DashcamService.clips]).
class _ThrowingClipsService extends DashcamService {
  _ThrowingClipsService({required super.config, super.segmentDuration, super.stopVideoRecordingTimeout});

  bool armed = false;

  @override
  List<DashcamClip> get clips {
    if (armed) {
      armed = false;
      throw StateError('injected failure inside the controller\'s registration (onCreated)');
    }
    return super.clips;
  }
}

/// Fase 16.2-R4.3-R2.6.2: the C-3b arrangement's moving parts.
class _ReentrantRetryArrangement {
  _ReentrantRetryArrangement(this.service, this.controller);

  final DashcamService service;
  final DashcamSessionController controller;

  /// Completing this releases A's teardown from its immediate-persistence gate.
  final Completer<void> releaseA = Completer<void>();
  final List<Future<void>?> laterStops = [];

  DrivingSession? sessionA;
  DrivingSession? sessionB;
  Object? controllerA;
  Future<void>? stopA;

  // What the synchronous recorder listener observed around its retryCamera().
  int retryCalls = 0;
  String? registeredAtRetry;
  String? attemptBeforeRetry;
  String? attemptAfterRetry;
  DashcamStatus? statusAfterRetry;
  int? initializeCallsBeforeRetry;
  int? initializeCallsAfterRetry;
}

/// Fase 16.2-R4.3-R2.6.2 (X51): how A's physical obligation ends while B's
/// re-entrant retry is parked.
enum _X51Variant {
  stopOk('native STOP succeeds promptly'),
  presentationTimeoutThenSuccess('native STOP retained past its presentation deadline, then succeeds'),
  stopFailsLate('native STOP retained past its presentation deadline, then fails terminally'),
  obligationRetained('native STOP still retained after A\'s controller teardown has finished'),
  disposeFails('native dispose of A\'s controller fails (backend becomes uncertain)');

  const _X51Variant(this.description);
  final String description;
}

/// Fase 16.2-R4.3-R2.6 (X34): a [DrivingSessionRecorder] whose NEXT
/// `stopSession()` call — after doing its real work and clearing
/// [activeSession] — stays pending until a test-controlled gate opens. Models a
/// stop request that is still in flight (its public Future unresolved) while
/// the recorder itself is already free for a new session to start.
class _GatedStopRecorder extends DrivingSessionRecorder {
  _GatedStopRecorder(super.snapshotStream);

  Completer<void>? nextStopGate;

  @override
  Future<void> stopSession() async {
    final gate = nextStopGate;
    nextStopGate = null;
    await super.stopSession();
    if (gate != null) await gate.future;
  }
}

/// Fase 16.2-R4.3-R2.6.1 (X41): wraps a broadcast snapshot stream so that a
/// subscription's `cancel()` can be held open. The REAL
/// [DrivingSessionRecorder.stopSession] awaits `_sub.cancel()` FIRST — before its
/// flush and save, and while [DrivingSessionRecorder.activeSession] is still the
/// session being ended — so holding `cancel()` holds the real recorder inside
/// its real "ending" window. That is the exact state the pre-audit's P2-1 needs
/// (A's camera side finished, the recorder not yet), reached without a recorder
/// subclass whose gate sits OUTSIDE the recorder's own state machine.
class _CancelGatedStream extends Stream<TelemetrySnapshot> {
  _CancelGatedStream(this._inner);

  final Stream<TelemetrySnapshot> _inner;

  /// Consumed by the NEXT `cancel()` call: that call stays pending until it
  /// completes.
  Completer<void>? get nextCancelGate => _nextCancelGate;
  set nextCancelGate(Completer<void>? gate) {
    _nextCancelGate = gate;
    if (gate != null) _issuedGates.add(gate);
  }

  Completer<void>? _nextCancelGate;
  final List<Completer<void>> _issuedGates = [];

  /// Harness safety (Fase 16.2-R4.3-R2.6.5, independent review): a gate is
  /// consumed when `cancel()` is entered, so a test that failed an assertion
  /// before completing it left the recorder's stop held forever — the cleanup
  /// then waited out its timeouts and the held cancel survived the test. This
  /// releases every gate handed to this stream that is still pending.
  void releaseAllGates() {
    for (final gate in _issuedGates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  /// How many `cancel()` calls have been entered — completes-by-observation for
  /// a test that must know the recorder is really inside its stop.
  int cancelEnteredCount = 0;

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<TelemetrySnapshot> listen(
    void Function(TelemetrySnapshot event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _CancelGatedSubscription(_inner.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError), this);
  }
}

class _CancelGatedSubscription implements StreamSubscription<TelemetrySnapshot> {
  _CancelGatedSubscription(this._inner, this._owner);

  final StreamSubscription<TelemetrySnapshot> _inner;
  final _CancelGatedStream _owner;

  @override
  Future<void> cancel() async {
    _owner.cancelEnteredCount++;
    final gate = _owner.nextCancelGate;
    _owner.nextCancelGate = null;
    if (gate != null) await gate.future;
    await _inner.cancel();
  }

  @override
  void onData(void Function(TelemetrySnapshot data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}

/// Fase 16.2-R4.3-R2.6.7 (X95): wraps the clip (.mp4) and telemetry (.jsonl)
/// Files created inside a zone — the deletion's — so a test can hold it at an
/// exact file operation: [onFile] runs before exists() ('exists') and delete()
/// ('delete'). Every other File is the real one.
final class _DeletionFileHooks extends IOOverrides {
  _DeletionFileHooks(this.onFile);
  final Future<void> Function(String path, String op) onFile;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('.mp4') || path.endsWith('.jsonl') ? _HookedDeletionFile(real, onFile) : real;
  }
}

class _HookedDeletionFile implements File {
  _HookedDeletionFile(this._inner, this._onFile);
  final File _inner;
  final Future<void> Function(String path, String op) _onFile;

  @override
  String get path => _inner.path;

  @override
  Future<bool> exists() async {
    await _onFile(_inner.path, 'exists');
    return _inner.exists();
  }

  @override
  bool existsSync() => _inner.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _onFile(_inner.path, 'delete');
    return _inner.delete(recursive: recursive);
  }

  @override
  void deleteSync({bool recursive = false}) => _inner.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_HookedDeletionFile: ${invocation.memberName}');
}

/// Fase 16.2-R4.3-R2.6.7-T2 (X113): a session adapter that, while [armed],
/// fails while serializing — before a byte reaches the file: a write that
/// fails BEFORE it takes effect (the technique of X102). The override is
/// global: a test restores the real adapter in `finally`.
class _WriteFailingSessionAdapter extends DrivingSessionAdapter {
  // TypeAdapter is @immutable: the switch is a final reference to mutable state.
  final _Armed _armed = _Armed();

  bool get armed => _armed.value;
  set armed(bool value) => _armed.value = value;

  @override
  void write(BinaryWriter writer, DrivingSession obj) {
    if (armed) throw StateError('injected failure while serializing a session record');
    super.write(writer, obj);
  }
}

class _Armed {
  bool value = false;
}

/// Fase 16.2-R4.4-R1.2 (X66-screen): the handles of one "previous STOP still in
/// flight" window — see `x66PreviousStopInFlight`.
class _X66Window {
  _X66Window({
    required this.service,
    required this.r,
    required this.s,
    required this.rawStop,
    required this.deadline,
    required this.attempts,
    this.stopA,
  });

  final DashcamService service;
  final ({DrivingSessionRecorder recorder, _CancelGatedStream gate, DashcamSessionController controller}) r;

  /// The session being finalized.
  final DrivingSession s;

  /// Holds S's native STOP (A's camera side) until completed.
  final Completer<void> rawStop;

  /// A's held presentation deadlines.
  final HeldDeadlines deadline;

  /// S's finalization attempts so far (A's is the first).
  final int Function() attempts;

  /// A's Future, when A was requested through the controller (not the screen).
  final Future<void>? stopA;
}