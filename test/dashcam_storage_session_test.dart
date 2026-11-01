import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_descriptor.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_clip_files.dart';
import 'package:synapse_auto/services/dashcam_clip_index.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/dashcam_storage_quota.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_camera_platform.dart';
import 'support/fake_storage_probe.dart';

// Fase 16.2-R4.4-R2 — the physical quota and the START's free-space guard
// through the REAL DashcamSessionController + DashcamService against the fake
// camera platform (test/support), real Hive in a temporary directory, and a
// deterministic storage probe (the native bridge's seam). Each fake segment is
// a 1024-byte file. Nothing here waits for a fixed time to decide anything:
// every wait is for a causal state, bounded, and fails explicitly.
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
  late FakeStorageProbe probe;
  late List<DashcamStatus> statuses;
  Timer? snapshotFeeder;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;
  Directory clipsDir() => Directory('${dir.path}/$dashcamClipsDirectoryName');
  int bytesOfClips() => clipsDir().existsSync() ? [for (final f in clipsDir().listSync().whereType<File>()) f.lengthSync()].fold(0, (a, b) => a + b) : 0;

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 10)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail('never happened within ${within.inMilliseconds} ms: $what (status=${controller.status.name}, clips=${service.clips.length}, calls=${fakePlatform.calls.join(',')})');
  }

  /// Every index write and quota pass queued so far has settled (see the
  /// controller test file's helper of the same name).
  Future<void> storagePassesSettled() async {
    await runInClipIndexQueue(() async {});
    await runInClipIndexQueue(() async {});
  }

  /// Rotation ticks armed by the service, when [build] is asked for them by
  /// hand (Fase 16.2-R4.4-R2.1, X526): the segment period stays 10 minutes, so
  /// every rotation is one the test delivers.
  final timerTicks = <void Function()>[];

  void build({int quotaMb = 1024, Duration stopTimeout = const Duration(seconds: 5), bool ticksByHand = false}) {
    service = DashcamService(
      config: DashcamConfig(
        cameraSelection: CameraSelection.rear,
        storageQuotaMb: quotaMb,
        audioEnabled: false,
        resolution: VideoResolution.hd720,
        frameRate: 30,
        enabled: true,
      ),
      segmentDuration: const Duration(minutes: 10),
      stopVideoRecordingTimeout: stopTimeout,
    );
    timerTicks.clear();
    if (ticksByHand) service.segmentTimerArmedHookForTest = timerTicks.add;
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
      storageProbe: probe,
    );
    statuses = [];
    controller.addListener(() => statuses.add(controller.status));
  }

  void setQuota(int quotaMb) => service.updateConfig(
    DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: quotaMb, audioEnabled: false, resolution: VideoResolution.hd720, frameRate: 30, enabled: true),
  );

  Future<DrivingSession> recordOneSegment() async {
    final session = controller.startSession();
    await waitUntil(() => controller.status == DashcamStatus.recording, 'the session reaching recording');
    await controller.stopSession();
    await waitUntil(() => !service.hasPendingNativeStop, 'the stop settled');
    await storagePassesSettled();
    return session;
  }

  List<DashcamClipRecord> indexedOf(String sessionId) => List<DashcamClipRecord>.from(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List? ?? const []);

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_storage_session_test');
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
    resetDashcamStorageForTest();

    snapshotController = StreamController<TelemetrySnapshot>.broadcast();
    eventController = StreamController<DetectedEvent>.broadcast();
    recorder = DrivingSessionRecorder(snapshotController.stream);
    preferences = DashcamPreferences();
    await preferences.setEnabled(true);
    probe = FakeStorageProbe();
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
    controller.persistClipIndexHookForTest = null;
    quotaPassDecidedHookForTest = null;
    final gate = probe.volumeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    final stopGate = fakePlatform.pendingStopVideoRecording;
    if (stopGate != null && !stopGate.isCompleted) stopGate.complete();
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    if (recorder.state != DrivingSessionRecorderState.idle) {
      try {
        await controller.stopSession();
      } catch (_) {}
    }
    try {
      controller.dispose();
    } catch (_) {}
    await waitUntil(
      () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null && !DashcamService.processOwnerIsUncertainForTest,
      'the service being released in tearDown',
    );
    await storagePassesSettled();
    await snapshotController.close();
    await eventController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    for (var attempt = 0; ; attempt++) {
      try {
        dir.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  group('Fase 16.2-R4.4-R2 — the quota through the controller', () {
    test('X511 — each published clip is indexed, then a pass runs: under a near-zero quota the newest segment and the one before survive, the '
        'oldest file and entry go, the service forgets it and its claim goes with it; the group of every new clip is repaired', () async {
      build(quotaMb: 0);
      final a = await recordOneSegment();
      final pathA = service.clips.single.file.path;
      expect(File(pathA).existsSync(), isTrue, reason: 'alone, larger than the quota: kept (D3-Q closed)');
      final b = await recordOneSegment();
      expect(service.clips, hasLength(2), reason: 'Q_eff = 2 segments');
      final c = await recordOneSegment();

      expect(File(pathA).existsSync(), isFalse, reason: 'the third segment pushed the oldest out');
      expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(a.id), isFalse, reason: 'its only entry went, and the key with it');
      expect(service.clips.map((clip) => clip.file.path), isNot(contains(pathA)), reason: 'forgotten, with its provenance');
      expect(controller.ownerOfPathForTest(pathA), isNull, reason: 'its claim went in the same step');
      expect(indexedOf(b.id), hasLength(1));
      expect(indexedOf(c.id), hasLength(1));
      expect(controller.storageSnapshot!.managedBytes, 2048);
      expect(controller.totalClipBytes, 2048, reason: 'what the disk holds, from the snapshot');
      expect(controller.quotaBytes, 2048, reason: 'the effective quota, raised to two segments');
      expect(probe.groupRepairCalls.map((paths) => paths.single).toList(), [pathA, service.clips[0].file.path, service.clips[1].file.path]);
    });

    test('X512 — a clip protected only in memory (its index write failed, R4.4-R1.1) is never evicted: the next candidate goes instead', () async {
      build(quotaMb: 0);
      await recordOneSegment();
      final pathA = service.clips.single.file.path;
      controller.persistClipIndexHookForTest = (sessionId, paths, writeCall) async => throw StateError('forced index failure (X512)');
      await controller.protectCurrentClip();
      controller.persistClipIndexHookForTest = null;
      expect(service.clips.single.isProtected, isTrue, reason: 'setup: protected in memory');
      expect(indexedOf(Hive.box(HiveBoxNames.dashcamSessionVideos).keys.single as String).single.isProtected, isFalse, reason: 'setup: not in the entry');

      await recordOneSegment();
      final pathB = service.clips.last.file.path;
      await recordOneSegment();
      expect(File(pathA).existsSync(), isTrue, reason: 'protected in memory: never a candidate');
      expect(File(pathB).existsSync(), isFalse, reason: 'B, the oldest unprotected, went instead');
    });

    test('X513 — a quota pass completes while the camera FIFO is held by a native STOP: the quota never waits for — nor lives in — the camera '
        'queue; a change of the quota setting runs one', () async {
      build();
      await recordOneSegment();
      final pathA = service.clips.single.file.path;
      await recordOneSegment();
      await recordOneSegment();
      setQuota(0);
      controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'the fourth session recording');
      fakePlatform.pendingStopVideoRecording = Completer<void>();
      final stopping = controller.stopSession();
      await waitUntil(() => count('stopVideoRecording') == 4, 'the native STOP in flight');
      expect(service.hasPendingNativeStop, isTrue);

      await preferences.setStorageQuotaMb(512);
      await waitUntil(() => !File(pathA).existsSync(), 'the pass evicting the oldest clip while the camera FIFO is held');
      expect(service.hasPendingNativeStop, isTrue, reason: 'the STOP is still held: the pass did not wait for the camera queue');
      expect(controller.storageSnapshot!.trigger, DashcamQuotaTrigger.settingChanged);
      fakePlatform.pendingStopVideoRecording!.complete();
      await stopping;
    });

    test('X520 — a protection that races a quota pass never loses its clip: protectCurrentClip marks the newest clip of this process, which '
        'the pass holds immune while it runs; the protection lands after it, and every later pass keeps the clip', () async {
      build(quotaMb: 0);
      await recordOneSegment();
      final pathA = service.clips.single.file.path;
      await recordOneSegment();
      final decided = Completer<void>();
      final release = Completer<void>();
      quotaPassDecidedHookForTest = () async {
        if (decided.isCompleted) return;
        decided.complete();
        await release.future;
      };
      controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'the third session recording');
      final stopping = controller.stopSession();
      await decided.future.timeout(const Duration(seconds: 10));
      final pathC = service.clips.last.file.path;
      final protection = controller.protectCurrentClip();
      await pumpEventQueue(times: 20);
      expect(service.clips.last.isProtected, isTrue, reason: 'marked in memory while the pass is held');
      release.complete();
      await stopping;
      await protection;
      quotaPassDecidedHookForTest = null;
      await storagePassesSettled();
      expect(File(pathA).existsSync(), isFalse, reason: 'the held pass evicted the oldest');
      expect(File(pathC).existsSync(), isTrue, reason: 'the clip being protected was immune during the pass');
      expect(indexedOf(controller.ownerOfPathForTest(pathC)!).single.isProtected, isTrue, reason: 'the protection landed after the pass');

      await recordOneSegment();
      await recordOneSegment();
      await recordOneSegment();
      expect(File(pathC).existsSync(), isTrue, reason: 'protected: never a candidate, also once it is no longer the newest');
    });
  });

  // Fase 16.2-R4.4-R2.1 — R2-P3-HW-STOP (hardware, ROT1: a STOP's camera was
  // released only after its own publication's quota pass, 5.5 s later): the
  // STOP waits for what makes its clips durable — finalize, canonical
  // publication, the index write — and never for the quota pass that
  // publication schedules afterwards, in the same index FIFO. A pass is held at
  // its decision (quotaPassDecidedHookForTest: classified, nothing evicted yet);
  // the STOP's own persistence is let in only once that pass is running
  // (beforeImmediatePersistenceHookForTest), the order the hardware showed.
  // Every wait is for a causal state, bounded, and fails explicitly.
  group('Fase 16.2-R4.4-R2.1 — the STOP never waits for its quota pass; the newest clip of this process', () {
    late Completer<void> passDecided;
    late Completer<void> releasePass;

    /// Holds the NEXT quota pass at its decision until [releasePass]; the
    /// later ones run free. Released in tearDown whatever happens.
    void holdNextPass({Object? thenThrow}) {
      passDecided = Completer<void>();
      releasePass = Completer<void>();
      final decided = passDecided;
      final release = releasePass;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      quotaPassDecidedHookForTest = () async {
        if (decided.isCompleted) return;
        decided.complete();
        await release.future;
        if (thenThrow != null) throw thenThrow;
      };
    }

    /// [stopSession] started with its own persistence held until its
    /// publication's pass is running, and the clip that STOP published.
    Future<(Future<void>, String)> stopWithItsPassHeld() async {
      controller.beforeImmediatePersistenceHookForTest = () => passDecided.future;
      final stopping = controller.stopSession();
      await passDecided.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('the STOP\'s publication never reached its quota pass'));
      return (stopping, service.clips.last.file.path);
    }

    String nameOf(String path) => dashcamClipBasename(path);

    test('X523 — with its own publication\'s quota pass held, the STOP completes: the clip published and indexed first, the camera '
        'released, stopSession() returned; released, the pass converges — the oldest goes, its trigger stays', () async {
      build(quotaMb: 0);
      await recordOneSegment();
      final pathA = service.clips.single.file.path;
      await recordOneSegment();
      holdNextPass();
      final session = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'the third session recording');
      final disposesBefore = count('dispose');
      final (stopping, pathC) = await stopWithItsPassHeld();
      var stopped = false;
      unawaited(stopping.then((_) => stopped = true));

      expect(indexedOf(session.id).map((r) => nameOf(r.filePath)), [nameOf(pathC)], reason: 'durable before its pass: published and indexed');
      await waitUntil(() => stopped && service.previewController == null, 'the STOP completing — camera released, stopSession() returned — while its quota pass is held');
      await waitUntil(() => controller.status == DashcamStatus.idle, 'the STOP settled as idle');
      expect(releasePass.isCompleted, isFalse, reason: 'the pass is still held');
      expect(File(pathA).existsSync(), isTrue, reason: 'held at its decision: nothing evicted yet');
      expect(count('dispose'), disposesBefore + 1, reason: 'the camera released once, by this STOP');

      releasePass.complete();
      await storagePassesSettled();
      expect(File(pathA).existsSync(), isFalse, reason: 'released, the pass converges: the oldest goes');
      expect(File(pathC).existsSync(), isTrue, reason: 'its trigger stays');
      expect(indexedOf(session.id), hasLength(1));
      expect(controller.storageSnapshot!.trigger, DashcamQuotaTrigger.publication);
      expect(controller.storageSnapshot!.evictedCount, 1);
      expect(controller.storageSnapshot!.managedBytes, 2048);
    });

    test('X524 — STOP A, then START B with A\'s quota pass still held: B acquires the one camera (A\'s released first) and records; nothing '
        'of B lands in A; released while B records, A\'s pass keeps A\'s trigger, converges and never touches B or its camera', () async {
      build(quotaMb: 0);
      await recordOneSegment();
      final pathOldest = service.clips.single.file.path;
      await recordOneSegment();
      holdNextPass();
      final a = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'session A recording');
      final (stoppingA, triggerA) = await stopWithItsPassHeld();
      await stoppingA.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP A never completed while its quota pass was held'));
      expect(service.previewController, isNull, reason: 'A released the camera');

      final createsBefore = count('createCameraWithSettings');
      final b = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'session B recording while A\'s pass is held');
      expect(releasePass.isCompleted, isFalse, reason: 'A\'s pass is still held');
      expect(b.id, isNot(a.id));
      expect(count('createCameraWithSettings'), createsBefore + 1, reason: 'one camera, created once for B');
      expect(fakePlatform.calls.lastIndexOf('dispose'), lessThan(fakePlatform.calls.lastIndexOf('createCameraWithSettings')), reason: 'A\'s camera disposed before B\'s was created');
      expect(indexedOf(a.id).map((r) => nameOf(r.filePath)), [nameOf(triggerA)], reason: 'A holds only its own clip');
      expect(indexedOf(b.id), isEmpty, reason: 'nothing indexed for B yet, nothing of A attributed to B');
      expect(controller.ownerOfPathForTest(triggerA), a.id);

      final callsBeforeRelease = fakePlatform.calls.length;
      releasePass.complete();
      await storagePassesSettled();
      expect(fakePlatform.calls.length, callsBeforeRelease, reason: 'A\'s pass made no camera call');
      expect(controller.status, DashcamStatus.recording, reason: 'B never disturbed');
      expect(File(triggerA).existsSync(), isTrue, reason: 'A\'s trigger kept by A\'s pass, late as it ran');
      expect(File(pathOldest).existsSync(), isFalse, reason: 'A\'s pass converged');

      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop, 'B\'s stop settled');
      await storagePassesSettled();
      expect(indexedOf(b.id), hasLength(1), reason: 'B\'s own clip, under B');
      expect(indexedOf(a.id).map((r) => nameOf(r.filePath)), [nameOf(triggerA)], reason: 'A unchanged');
    });

    test('X525 — a quota pass that fails after its STOP completed: the STOP\'s outcome stands (idle, no error, the camera stays released), '
        'the failure is counted and printed by the pass — never an unhandled error, never a camera error — and the next publication converges', () async {
      build(quotaMb: 0);
      await recordOneSegment();
      final pathA = service.clips.single.file.path;
      await recordOneSegment();
      final cameraErrors = <DashcamServiceError>[];
      final sub = service.originatedErrors.listen(cameraErrors.add);
      addTearDown(sub.cancel);
      holdNextPass(thenThrow: StateError('forced late quota failure (X525)'));
      controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'the third session recording');
      final (stopping, _) = await stopWithItsPassHeld();
      await stopping.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('the STOP never completed while its quota pass was held'));
      await waitUntil(() => controller.status == DashcamStatus.idle && service.previewController == null, 'the STOP settled');
      final creates = count('createCameraWithSettings');
      final disposes = count('dispose');
      expect(DashcamStorageCounters.passesAborted, 0);

      releasePass.complete();
      await storagePassesSettled();
      expect(DashcamStorageCounters.passesAborted, 1, reason: 'the late failure is the pass\'s own, counted (and printed) there');
      expect(File(pathA).existsSync(), isTrue, reason: 'the failed pass deleted nothing');
      expect(controller.status, DashcamStatus.idle, reason: 'a late quota failure never reopens the completed STOP');
      expect(controller.errorMessage, isNull);
      expect(cameraErrors, isEmpty, reason: 'never reported as a camera or recording error');
      expect(count('createCameraWithSettings'), creates, reason: 'no camera reacquired');
      expect(count('dispose'), disposes);

      quotaPassDecidedHookForTest = null;
      await recordOneSegment();
      expect(File(pathA).existsSync(), isFalse, reason: 'the next publication\'s pass converges what the failed one left');
      expect(controller.storageSnapshot!.managedBytes, 2048);
    });

    test('X526 — a pass that runs late keeps ITS trigger: a rotation\'s segment C is published, its index write held while the next rotation '
        'publishes D (now the newest, and this process\'s last); C\'s pass, running after D, still holds C immune — only D\'s pass may take it', () async {
      build(quotaMb: 0, ticksByHand: true);
      await recordOneSegment();
      await controller.protectCurrentClip();
      final pathS1 = service.clips.single.file.path;
      expect(service.clips.single.isProtected, isTrue, reason: 'setup: the first segment protected — never a candidate');
      controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording && timerTicks.isNotEmpty, 'the session recording with its rotation armed');

      final writeHeld = Completer<void>();
      final releaseWrite = Completer<void>();
      addTearDown(() {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      });
      String? heldPath;
      controller.persistClipIndexHookForTest = (sessionId, paths, writeCall) async {
        if (heldPath == null || paths.contains(heldPath)) {
          if (!writeHeld.isCompleted) {
            heldPath = paths.single;
            writeHeld.complete();
            await releaseWrite.future;
          }
        }
        await writeCall();
      };
      Future<String> rotate() async {
        final published = service.publishedClips.first;
        timerTicks.last();
        final clip = await published.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('the rotation never published its segment'));
        return clip.file.path;
      }

      final pathC = await rotate();
      await writeHeld.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('C\'s index write never started'));
      expect(heldPath, pathC, reason: 'setup: C\'s own index write is the one held');
      final pathD = await rotate();
      expect(service.clips.last.file.path, pathD, reason: 'setup: D is this process\'s last clip before C\'s pass is even scheduled');

      holdNextPass();
      releaseWrite.complete();
      await passDecided.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('C\'s pass never ran'));
      // C's pass is held at its decision; let it finish and hold D's.
      final cDecided = passDecided;
      expect(cDecided.isCompleted, isTrue);
      final dDecided = Completer<void>();
      final releaseD = Completer<void>();
      addTearDown(() {
        if (!releaseD.isCompleted) releaseD.complete();
      });
      quotaPassDecidedHookForTest = () async {
        if (dDecided.isCompleted) return;
        dDecided.complete();
        await releaseD.future;
      };
      final evictedBefore = DashcamStorageCounters.evictedClips;
      releasePass.complete();
      await dDecided.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('D\'s pass never ran'));
      expect(File(pathC).existsSync(), isTrue, reason: 'C\'s pass ran after D was published and still held C immune: its trigger');
      expect(DashcamStorageCounters.evictedClips, evictedBefore, reason: 'C\'s pass: S1 protected, C its trigger, D the newest — nothing to take');
      expect(latestDashcamStorageSnapshot!.trigger, DashcamQuotaTrigger.publication);
      expect(latestDashcamStorageSnapshot!.countOf(DashcamStorageClass.immune), 2, reason: 'C\'s pass: C (its trigger) and D (the newest)');

      releaseD.complete();
      await storagePassesSettled();
      expect(File(pathC).existsSync(), isFalse, reason: 'D\'s pass: C is neither its trigger nor the newest any more — it goes');
      expect(File(pathD).existsSync(), isTrue);
      expect(File(pathS1).existsSync(), isTrue, reason: 'protected');
    });

    test('X522 — the newest clip of THIS process is immune by that rule alone: a quota-setting pass (no trigger) over a disk whose newest '
        'canonical is a foreign orphan, with the older clip protected — only the current-process-newest rule keeps this process\'s last clip', () async {
      build();
      await recordOneSegment();
      await controller.protectCurrentClip();
      final pathA = service.clips.single.file.path;
      final b = await recordOneSegment();
      final pathB = service.clips.last.file.path;
      final foreign = DashcamClipDescriptor.tryCreate(
        sessionId: 'x522-foreign-session',
        recordedAt: DateTime.now().add(const Duration(days: 1)),
        namespace: 'f' * 32,
        recordingId: 1,
        durationSeconds: 1,
        isProtected: false,
        resolution: VideoResolution.hd720,
        audioEnabled: false,
      )!;
      final pathF = '${clipsDir().path}/${foreign.basename}';
      File(pathF).writeAsBytesSync(List<int>.filled(1024, 7));
      expect(service.clips.first.isProtected, isTrue, reason: 'setup: A protected');
      expect(service.clips.last.file.path, pathB, reason: 'setup: B is this process\'s last clip');

      setQuota(0);
      await preferences.setStorageQuotaMb(512);
      await storagePassesSettled();
      // Behaviour first: what must hold whatever the pass decided.
      expect(File(pathB).existsSync(), isTrue, reason: 'B survives only as the newest clip of this process');
      expect(indexedOf(b.id), hasLength(1));
      expect(File(pathA).existsSync(), isTrue);
      expect(File(pathF).existsSync(), isTrue, reason: 'an orphan never leaves');
      // Then the pass that decided it: no trigger, the foreign orphan the newest
      // canonical on disk, A protected — B immune by the remaining rule alone,
      // over the effective quota with nothing it may take.
      final snapshot = controller.storageSnapshot!;
      expect(snapshot.trigger, DashcamQuotaTrigger.settingChanged, reason: 'a pass with no trigger clip');
      expect(snapshot.countOf(DashcamStorageClass.orphan), 1, reason: 'the foreign file is an orphan — and the newest canonical on disk');
      expect(snapshot.countOf(DashcamStorageClass.protected), 1, reason: 'A protected');
      expect(snapshot.countOf(DashcamStorageClass.immune), 1, reason: 'B, by the current-process-newest rule');
      expect(snapshot.evictedCount, 0);
      expect(snapshot.managedBytes, greaterThan(snapshot.effectiveQuotaBytes!), reason: 'over the effective quota (3 × 1024 > 2048): something would have gone if anything could');
    });
  });

  // Fase 16.2-R4.4-R2.1.1 — RES-1 (owner decision: the index leaves the STOP's
  // critical path). The canonical file is the durability frontier (R4.4-R1:
  // the name carries the session and the clip's identity, the startup
  // reconciliation rebuilds a missing entry). A quota pass of an EARLIER
  // publication held in the index FIFO keeps the next clip's index write
  // queued behind it: the STOP of that clip's session must still release the
  // camera and return; the write stays owned, serialized, retried and
  // observable — only no longer awaited by the STOP. Every wait is for a causal
  // state, bounded, and fails explicitly.
  group('Fase 16.2-R4.4-R2.1.1 — the STOP never waits for the index (RES-1)', () {
    late Completer<void> passDecided;
    late Completer<void> releasePass;

    void holdNextPass() {
      passDecided = Completer<void>();
      releasePass = Completer<void>();
      final decided = passDecided;
      final release = releasePass;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      quotaPassDecidedHookForTest = () async {
        if (decided.isCompleted) return;
        decided.complete();
        await release.future;
      };
    }

    /// Session A started and stopped; its publication's quota pass is running
    /// and held — the slow EARLIER pass of RES-1. STOP A itself completed
    /// (R4.4-R2.1: a STOP never waits for its own publication's pass).
    Future<DrivingSession> sessionAWithItsPassHeld() async {
      holdNextPass();
      final a = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'session A recording');
      final stopping = controller.stopSession();
      await passDecided.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('A\'s publication never reached its quota pass'));
      await stopping.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP A never completed (R4.4-R2.1)'));
      return a;
    }

    /// Session B started; the caller arms what it needs; then STOP B — whose
    /// canonical clip is published while A's pass holds the index FIFO, so B's
    /// index write is queued behind it. Returns B's clip path and the STOP.
    Future<(String, Future<void>)> stopB() async {
      final published = service.publishedClips.first;
      // The STOP's own follow-up starts once the publication has been seen by
      // the controller (its listener runs before this one): the order the
      // hardware showed, made deterministic.
      controller.beforeImmediatePersistenceHookForTest = () => published.then((_) {});
      final stopping = controller.stopSession();
      final clip = await published.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP B never published its clip'));
      return (clip.file.path, stopping);
    }

    Future<DrivingSession> startB() async {
      final b = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'session B recording');
      return b;
    }

    String nameOf(String path) => dashcamClipBasename(path);
    int indexCalls() => ClipIndexOutcome.values.fold(0, (sum, outcome) => sum + DashcamClipIndexCounters.of(outcome));

    test('X527 — RES-1: an EARLIER publication\'s quota pass held keeps B\'s index write queued behind it; STOP B still releases the camera and '
        'returns — B\'s canonical clip on disk, not yet indexed; released, the pass, B\'s index write and B\'s own pass converge', () async {
      build(quotaMb: 0);
      await recordOneSegment();
      final pathOldest = service.clips.single.file.path;
      await recordOneSegment();
      await sessionAWithItsPassHeld();
      final b = await startB();
      final (pathB, stoppingB) = await stopB();
      var stopped = false;
      unawaited(stoppingB.then((_) => stopped = true));

      await waitUntil(() => stopped && service.previewController == null, 'STOP B completing — camera released, stopSession() returned — with its index write queued behind A\'s held pass');
      await waitUntil(() => controller.status == DashcamStatus.idle, 'STOP B settled as idle');
      expect(File(pathB).existsSync(), isTrue, reason: 'the durability frontier: B\'s canonical clip is on disk');
      expect(indexedOf(b.id), isEmpty, reason: 'its index write is still queued behind A\'s pass');
      expect(releasePass.isCompleted, isFalse, reason: 'A\'s pass is still held');

      releasePass.complete();
      await waitUntil(() => indexedOf(b.id).length == 1, 'B indexed once A\'s pass let go');
      await storagePassesSettled();
      await storagePassesSettled();
      expect(indexedOf(b.id).map((r) => nameOf(r.filePath)), [nameOf(pathB)], reason: 'once, under B');
      expect(File(pathOldest).existsSync(), isFalse, reason: 'A\'s pass converged');
      expect(File(pathB).existsSync(), isTrue, reason: 'B\'s own pass keeps its trigger');
      expect(controller.storageSnapshot!.trigger, DashcamQuotaTrigger.publication);
      expect(controller.storageSnapshot!.managedBytes, 2048);
    });

    test('X528 — STOP B done with its index write still queued behind A\'s held pass: START C acquires the one camera (B\'s released first) '
        'and records; B\'s clip is never C\'s; released, B is indexed under B and the passes converge without touching C or its camera', () async {
      build(quotaMb: 0);
      await recordOneSegment();
      await recordOneSegment();
      await sessionAWithItsPassHeld();
      final b = await startB();
      final (pathB, stoppingB) = await stopB();
      await stoppingB.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP B never completed with its index write pending'));
      expect(indexedOf(b.id), isEmpty, reason: 'setup: B\'s index write still pending');

      final creates = count('createCameraWithSettings');
      final c = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'session C recording while B\'s index write is pending behind A\'s held pass');
      expect(releasePass.isCompleted, isFalse);
      expect(indexedOf(b.id), isEmpty, reason: 'C recorded without waiting for B\'s index');
      expect(count('createCameraWithSettings'), creates + 1, reason: 'one camera, created once for C');
      expect(fakePlatform.calls.lastIndexOf('dispose'), lessThan(fakePlatform.calls.lastIndexOf('createCameraWithSettings')), reason: 'B\'s camera disposed before C\'s was created');
      expect(c.id, isNot(b.id));
      expect(controller.ownerOfPathForTest(pathB), b.id, reason: 'B\'s clip stays B\'s');
      expect(indexedOf(c.id), isEmpty);

      final callsBefore = fakePlatform.calls.length;
      releasePass.complete();
      await waitUntil(() => indexedOf(b.id).length == 1, 'B indexed once A\'s pass let go');
      await storagePassesSettled();
      await storagePassesSettled();
      expect(fakePlatform.calls.length, callsBefore, reason: 'neither the passes nor B\'s index write made a camera call');
      expect(controller.status, DashcamStatus.recording, reason: 'C undisturbed');
      expect(indexedOf(c.id), isEmpty, reason: 'nothing of B under C');
      expect(indexedOf(b.id).map((r) => nameOf(r.filePath)), [nameOf(pathB)]);

      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop, 'C\'s stop settled');
      await storagePassesSettled();
      await storagePassesSettled();
      expect(indexedOf(c.id), hasLength(1), reason: 'C\'s own clip, under C');
      expect(indexedOf(b.id).map((r) => nameOf(r.filePath)), [nameOf(pathB)], reason: 'B unchanged');
    });

    test('X529 — a process that dies right after STOP B returned, B\'s index write still queued behind A\'s held pass: the disk it leaves '
        '(B\'s canonical clip, no entry) is recovered by the startup reconciliation exactly once', () async {
      build(); // 1024 MB: nothing is evicted — the clip files stay as the dead process left them
      await recordOneSegment();
      await sessionAWithItsPassHeld();
      final b = await startB();
      final (pathB, stoppingB) = await stopB();
      await stoppingB.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP B never completed with its index write pending'));
      expect(indexedOf(b.id), isEmpty, reason: 'setup: B\'s index write still pending');

      // The kill, now: the boxes' files as they are at this instant (every
      // frame Hive acknowledged is in them) are what the next start reads.
      final dead = Directory('${dir.path}/dead_process')..createSync();
      final boxes = [HiveBoxNames.dashcamSessionVideos, HiveBoxNames.drivingSessions];
      for (final box in boxes) {
        File('${dir.path}/$box.hive').copySync('${dead.path}/$box.hive');
      }
      // The living copy finishes on its own; the restart below discards it.
      releasePass.complete();
      await waitUntil(() => indexedOf(b.id).length == 1, 'the living process indexing B');
      await storagePassesSettled();
      await storagePassesSettled();

      await Hive.box(HiveBoxNames.dashcamSessionVideos).close();
      await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).close();
      for (final box in boxes) {
        File('${dead.path}/$box.hive').copySync('${dir.path}/$box.hive');
      }
      await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
      await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
      expect(indexedOf(b.id), isEmpty, reason: 'restarted from the dead process\'s disk: no entry for B');
      expect(File(pathB).existsSync(), isTrue, reason: 'its canonical clip is there');
      expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(b.id), isNotNull, reason: 'and its session record');

      final indexedBefore = DashcamClipIndexCounters.of(ClipIndexOutcome.indexed);
      await reconcileCanonicalClipsAtStartup();
      expect(indexedOf(b.id).map((r) => nameOf(r.filePath)), [nameOf(pathB)], reason: 'recovered by the startup reconciliation');
      await reconcileCanonicalClipsAtStartup();
      expect(indexedOf(b.id), hasLength(1), reason: 'exactly once: a second start writes nothing');
      expect(DashcamClipIndexCounters.of(ClipIndexOutcome.indexed) - indexedBefore, 1);
    });

    test('X530 — STOP B done, its index write pending; the user deletes B while that write is held inside its turn (after it saw the file): '
        'the deletion completes, and the write, deciding again, is refused — no entry, no record, no file of B, nothing for a restart to recover', () async {
      build();
      await recordOneSegment();
      await sessionAWithItsPassHeld();
      final b = await startB();
      // The hook goes with the write when it is queued (at B's publication).
      final writeHeld = Completer<void>();
      final releaseWrite = Completer<void>();
      addTearDown(() {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      });
      controller.persistClipIndexHookForTest = (sessionId, paths, writeCall) async {
        if (sessionId == b.id && !writeHeld.isCompleted) {
          writeHeld.complete();
          await releaseWrite.future;
        }
        await writeCall();
      };
      final (pathB, stoppingB) = await stopB();
      await stoppingB.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP B never completed with its index write pending'));
      expect(indexedOf(b.id), isEmpty, reason: 'setup: B\'s index write still pending');
      expect(writeHeld.isCompleted, isFalse, reason: 'setup: still queued behind A\'s pass, not yet at its write');

      final refusedBefore = DashcamClipIndexCounters.of(ClipIndexOutcome.deletionRefused);
      releasePass.complete();
      await writeHeld.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('B\'s pending index write never reached its write'));

      await deleteDrivingSession(b.id);
      expect(File(pathB).existsSync(), isFalse, reason: 'the deletion removed B\'s canonical clip, indexed or not');
      expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).containsKey(b.id), isFalse, reason: 'and its record');

      final passesBefore = DashcamStorageCounters.passes;
      releaseWrite.complete();
      // A refusal ends the FIFO turn as soon as it is decided; the outcome is
      // counted once the discard settled, and B's own pass is queued after it.
      await waitUntil(
        () => DashcamClipIndexCounters.of(ClipIndexOutcome.deletionRefused) - refusedBefore == 1 && DashcamStorageCounters.passes > passesBefore,
        'the late write concluding as refused, and B\'s own pass running',
      );
      await storagePassesSettled();
      await storagePassesSettled();
      expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(b.id), isFalse, reason: 'the late write, deciding again, was refused: no resurrection');
      expect(DashcamClipIndexCounters.of(ClipIndexOutcome.deletionRefused) - refusedBefore, 1, reason: 'refused once — never retried into an entry');
      expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).containsKey(b.id), isFalse);
      expect(File(pathB).existsSync(), isFalse);

      await reconcileCanonicalClipsAtStartup();
      expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(b.id), isFalse, reason: 'nothing for a restart to recover');
    });

    test('X531 — B\'s pending index write fails after STOP B returned (its retry too): STOP B is not failed after the fact — idle, no error, '
        'the camera stays released — the failure is reported once (recordingResult), B\'s clip stays on disk, nobody else\'s, and the '
        'startup reconciliation repairs it under B', () async {
      build();
      await recordOneSegment();
      final a = await sessionAWithItsPassHeld();
      final errors = <DashcamServiceError>[];
      final sub = service.originatedErrors.listen(errors.add);
      addTearDown(sub.cancel);
      List<DashcamServiceError> indexFailures() => [
        for (final e in errors)
          if (e.scope == DashcamServiceErrorScope.recordingResult && e.message.startsWith('Falha ao indexar')) e,
      ];
      final b = await startB();
      controller.persistClipIndexHookForTest = (sessionId, paths, writeCall) async {
        if (sessionId == b.id) throw StateError('forced late index failure (X531)');
        await writeCall();
      };
      final (pathB, stoppingB) = await stopB();
      await stoppingB.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP B never completed with its index write pending'));
      await waitUntil(() => controller.status == DashcamStatus.idle && service.previewController == null, 'STOP B settled');
      final creates = count('createCameraWithSettings');
      final disposes = count('dispose');
      expect(indexFailures(), isEmpty, reason: 'setup: nothing has failed yet — B\'s write is still queued');

      releasePass.complete();
      await waitUntil(() => indexFailures().isNotEmpty, 'B\'s late index failure reported');
      await storagePassesSettled();
      await storagePassesSettled();
      expect(controller.status, DashcamStatus.idle, reason: 'a late index failure never fails the STOP after the fact');
      expect(controller.errorMessage, isNull);
      expect(count('createCameraWithSettings'), creates, reason: 'no camera reacquired');
      expect(count('dispose'), disposes);
      expect(indexFailures(), hasLength(1), reason: 'reported once for the clip, whatever the retries');
      expect(File(pathB).existsSync(), isTrue, reason: 'B\'s canonical clip stays');
      expect(indexedOf(b.id), isEmpty);
      final elsewhere = [
        for (final key in Hive.box(HiveBoxNames.dashcamSessionVideos).keys)
          if (key != b.id && indexedOf(key as String).any((r) => nameOf(r.filePath) == nameOf(pathB))) key,
      ];
      expect(elsewhere, isEmpty, reason: 'no other session received it (A: ${a.id})');

      controller.persistClipIndexHookForTest = null;
      await reconcileCanonicalClipsAtStartup();
      expect(indexedOf(b.id).map((r) => nameOf(r.filePath)), [nameOf(pathB)], reason: 'repaired by the startup reconciliation, under B');
    });

    test('X532 — exactly once after the decoupling: a write already done costs the STOP nothing; one still running is awaited by the STOP\'s '
        'follow-up, never queued again; only a failed one is retried', () async {
      build();
      // Done: the publication's write settled before the STOP's follow-up looks.
      var before = indexCalls();
      await recordOneSegment();
      expect(indexCalls() - before, 1, reason: 'done: one ensureClipIndexed for the clip — the publication\'s');

      // Running: the publication's write held inside its write while the STOP returns.
      final writeHeld = Completer<void>();
      final releaseWrite = Completer<void>();
      addTearDown(() {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      });
      var failNext = false;
      controller.persistClipIndexHookForTest = (sessionId, paths, writeCall) async {
        if (failNext) {
          failNext = false;
          throw StateError('forced index failure (X532)');
        }
        if (!writeHeld.isCompleted) {
          writeHeld.complete();
          await releaseWrite.future;
        }
        await writeCall();
      };
      before = indexCalls();
      final b = await startB();
      final (pathB, stoppingB) = await stopB();
      await writeHeld.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('B\'s publication write never reached its write'));
      await stoppingB.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP B never completed with its write running'));
      releaseWrite.complete();
      await waitUntil(() => indexedOf(b.id).length == 1, 'B indexed');
      await storagePassesSettled();
      await storagePassesSettled();
      expect(indexCalls() - before, 1, reason: 'running: the STOP\'s follow-up awaited that write — no second ensureClipIndexed');
      expect(indexedOf(b.id).map((r) => nameOf(r.filePath)), [nameOf(pathB)]);

      // Failed: the publication's write fails once; the follow-up retries it, once.
      before = indexCalls();
      failNext = true;
      final c = await startB();
      final (pathC, stoppingC) = await stopB();
      await stoppingC.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('STOP C never completed'));
      await waitUntil(() => indexedOf(c.id).length == 1, 'C indexed by the retry');
      await storagePassesSettled();
      await storagePassesSettled();
      expect(indexCalls() - before, 2, reason: 'failed: the publication\'s write, then exactly one retry');
      expect(indexedOf(c.id).map((r) => nameOf(r.filePath)), [nameOf(pathC)]);
    });
  });

  group('Fase 16.2-R4.4-R2 — the START\'s free-space guard (§11)', () {
    // total 100 000 → TRIM = 7 500; S = 1024 once a segment exists.
    const total = 100000;

    test('X514 — below the floor with nothing to evict: the camera is never acquired, the status is an explicit storage error (never REC, never '
        '"camera unavailable"), the session itself goes on and stops normally; space freed + retry → it records', () async {
      build();
      probe
        ..totalBytes = total
        ..availableBytes = 100;
      final session = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.error, 'the refusal');
      expect(controller.errorMessage, contains('Armazenamento insuficiente'));
      expect(controller.errorMessage, isNot(contains('indispon')));
      expect(count('createCameraWithSettings'), 0, reason: 'no camera intent at all');
      expect(count('startVideoCapturing'), 0);
      expect(statuses, isNot(contains(DashcamStatus.recording)), reason: 'never a false REC');
      expect(recorder.state, DrivingSessionRecorderState.recording, reason: 'the recorder session is untouched');
      expect(recorder.activeSession?.id, session.id);
      expect(DashcamStorageCounters.startRefusals, 1);

      probe.availableBytes = 50000;
      await controller.retryCamera();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'the retry recording');
      expect(probe.volumeCalls, greaterThanOrEqualTo(3), reason: 'the retry read the volume again');
      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop, 'the stop settled');
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(service.clips, hasLength(1));
    });

    test('X515 — a volume that cannot be read never blocks: the START proceeds (fail-open), the failure is counted, and no camera error is reported', () async {
      build();
      final errors = <DashcamServiceError>[];
      final sub = service.originatedErrors.listen(errors.add);
      addTearDown(sub.cancel);
      probe.volumeFailure = PlatformException(code: 'statfs_failed');
      controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'recording despite the failed probe');
      expect(DashcamStorageCounters.probeFailures, greaterThanOrEqualTo(1));
      expect(errors, isEmpty);
    });

    test('X516 — below the floor with older segments: the START evicts them under pressure (oldest first, never the newest), the service forgets '
        'them, and the START goes on', () async {
      build();
      await recordOneSegment();
      final pathA = service.clips.single.file.path;
      await recordOneSegment();
      final pathB = service.clips.last.file.path;
      await recordOneSegment();
      final pathC = service.clips.last.file.path;
      // floor = 7 500 + 1 024 = 8 524; 500 bytes short with the three segments.
      final base = 8524 - 500 + bytesOfClips();
      probe
        ..totalBytes = total
        ..availableNow = () => base - bytesOfClips();
      controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'recording after the pressure eviction');
      expect(File(pathA).existsSync(), isFalse, reason: 'one segment freed enough');
      expect(File(pathB).existsSync() && File(pathC).existsSync(), isTrue);
      expect(service.clips.map((clip) => clip.file.path), [pathB, pathC]);
      expect(controller.storageSnapshot!.pressureEvictedCount, 1);
    });

    test('X517 — a stop while the START waits for the volume: nothing is acquired once it answers (no initialize, no release to ask for — N6), '
        'and the session ends normally', () async {
      build();
      probe.volumeGate = Completer<void>();
      controller.startSession();
      await probe.volumeRead.future;
      await controller.stopSession();
      probe.volumeGate!.complete();
      await storagePassesSettled();
      await pumpEventQueue(times: 50);
      expect(count('createCameraWithSettings'), 0);
      expect(count('initializeCamera'), 0);
      expect(count('dispose'), 0, reason: 'nothing to release');
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(controller.status, isNot(DashcamStatus.recording));
      expect(statuses, isNot(contains(DashcamStatus.initializing)), reason: 'the attempt is concluded at the guard\'s own checkpoint: nothing is published for a stopped session');
    });

    test('X518 — backgrounded while the START waits for the volume: abandoned without acquiring anything; the next resume checks the volume '
        'again and records', () async {
      build();
      probe.volumeGate = Completer<void>();
      controller.startSession();
      await probe.volumeRead.future;
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final gate = probe.volumeGate!;
      probe.volumeGate = null;
      gate.complete();
      await pumpEventQueue(times: 50);
      expect(count('createCameraWithSettings'), 0, reason: 'the attempt was abandoned at its checkpoint');
      expect(statuses, isNot(contains(DashcamStatus.initializing)), reason: 'abandoned silently: no "initializing" for an ineligible generation');
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await waitUntil(() => controller.status == DashcamStatus.recording, 'recording after the resume');
      expect(probe.volumeCalls, 2);
    });

    test('X521 — a START admitted while the previous session\'s native STOP is still held in the camera FIFO, on a full disk: refused before any '
        'camera intent — nothing is queued behind that STOP, nothing acquired, nothing to release (N6); once it settles, the previous session\'s '
        'clip is published and indexed as its own', () async {
      build(stopTimeout: const Duration(milliseconds: 100));
      final a = controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.recording, 'A recording');
      fakePlatform.pendingStopVideoRecording = Completer<void>();
      await controller.stopSession();
      expect(service.hasPendingNativeStop, isTrue, reason: 'setup: A\'s native STOP is still held past its presentation deadline');
      probe
        ..totalBytes = total
        ..availableBytes = 100;
      final creates = count('createCameraWithSettings');
      final initializes = count('initializeCamera');
      controller.startSession();
      await waitUntil(() => controller.status == DashcamStatus.error && (controller.errorMessage ?? '').contains('Armazenamento insuficiente'), 'B refused for storage');
      expect(service.hasPendingNativeStop, isTrue, reason: 'the refusal neither waited for nor queued behind A\'s STOP');
      expect(count('createCameraWithSettings'), creates, reason: 'no camera for B');
      expect(count('initializeCamera'), initializes);

      fakePlatform.pendingStopVideoRecording!.complete();
      await waitUntil(() => !service.hasPendingNativeStop, 'A\'s STOP settled');
      await storagePassesSettled();
      expect(indexedOf(a.id), hasLength(1), reason: 'A\'s clip, indexed under A');
      expect(count('createCameraWithSettings'), creates, reason: 'still nothing acquired for B');
    });

    test('X519 — a platform without the native side: the START never reads the volume, nothing is repaired, and the quota still runs over the disk', () async {
      probe = FakeStorageProbe(supported: false);
      build(quotaMb: 0);
      await recordOneSegment();
      await recordOneSegment();
      await recordOneSegment();
      expect(probe.volumeCalls, 0);
      expect(probe.groupRepairCalls, isEmpty);
      expect(service.clips, hasLength(2));
      expect(controller.storageSnapshot!.health, DashcamStorageHealth.unknown);
    });
  });
}
