// Fase 16.2-R4.4-R1 — durable clip identity and per-segment indexing, through
// the real DashcamService + DashcamSessionController (a driving session with
// the dashcam on, the fake camera writing real files): each segment is renamed
// to its canonical name and indexed as soon as it is published — the session's
// STOP is no longer the only checkpoint of its clips (D1) — and none of it ever
// waits inside a camera operation.
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

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 10)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail('never happened within ${within.inMilliseconds} ms: $what (status=${controller.status.name}, clips=${service.clips.length}, calls=${fakePlatform.calls.join(',')})');
  }

  void build({Duration segment = const Duration(minutes: 10), VideoResolution resolution = VideoResolution.hd720, bool audio = false, int quotaMb = 1024}) {
    service = DashcamService(
      config: DashcamConfig(
        cameraSelection: CameraSelection.rear,
        storageQuotaMb: quotaMb,
        audioEnabled: audio,
        resolution: resolution,
        frameRate: 30,
        enabled: true,
      ),
      segmentDuration: segment,
    );
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  }

  Future<DrivingSession> startRecordingSession() async {
    await preferences.setEnabled(true);
    final session = controller.startSession();
    await waitUntil(() => controller.status == DashcamStatus.recording, 'the session reaching recording');
    return session;
  }

  List<DashcamClipRecord> indexedOf(String sessionId) => List<DashcamClipRecord>.from(Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List? ?? const []);

  List<String> namesOf(Iterable<String> paths) => [for (final p in paths) dashcamClipBasename(p)];

  /// What the index box FILE holds for [sessionId], read from a copy opened as
  /// another box — the live box and its cache untouched (the technique of
  /// test/support/hive_file_snapshot.dart): what a process killed right now
  /// would leave behind.
  Future<List<DashcamClipRecord>> indexOnDisk(String sessionId) async {
    final copyDir = Directory.systemTemp.createTempSync('clip_index_on_disk');
    try {
      File('${dir.path}/${HiveBoxNames.dashcamSessionVideos}.hive').copySync('${copyDir.path}/videos_snapshot.hive');
      final box = await Hive.openBox('videos_snapshot', path: copyDir.path);
      try {
        return List<DashcamClipRecord>.from(box.get(sessionId) as List? ?? const []);
      } finally {
        await box.close();
      }
    } finally {
      copyDir.deleteSync(recursive: true);
    }
  }

  /// The fake camera's own recording files ("cache/REC*.mp4" in production)
  /// still where the plugin left them.
  List<String> recordingsLeftBehind() => [
    for (final f in dir.listSync()) if (f is File && dashcamClipBasename(f.path).startsWith('fake_clip_')) dashcamClipBasename(f.path),
  ];

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_clip_durability_session_test');
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
    try {
      controller.dispose();
    } catch (_) {}
    await waitUntil(
      () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null && !DashcamService.processOwnerIsUncertainForTest,
      'the service being released in tearDown',
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
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  group('Fase 16.2-R4.4-R1 — per-segment durability (D1)', () {
    test('X460 — every rotated segment is renamed to its canonical name (its recording file gone, no twin) and INDEXED BEFORE the session stops; the STOP adds its own clip; each clip once, under its own session, with its own clip id', () async {
      build(segment: const Duration(milliseconds: 300));
      final session = await startRecordingSession();
      await waitUntil(() => service.clips.length >= 2, 'two rotated segments published');
      await waitUntil(() => indexedOf(session.id).length >= 2, 'the rotated segments indexed while the session still records');
      expect(recorder.state, DrivingSessionRecorderState.recording, reason: 'the session has not stopped');
      final duringSession = namesOf(indexedOf(session.id).map((r) => r.filePath));
      expect(duringSession.toSet(), hasLength(duringSession.length), reason: 'no duplicate');

      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop && indexedOf(session.id).length == service.clips.length, 'the STOP\'s own clip indexed');
      final records = indexedOf(session.id);
      final names = namesOf(records.map((r) => r.filePath));
      expect(names.toSet(), hasLength(records.length), reason: 'each clip exactly once');
      expect(names.toSet(), namesOf(service.clips.map((c) => c.file.path)).toSet());
      expect(names, containsAll(duringSession));
      final descriptors = [for (final n in names) DashcamClipDescriptor.parse(n)!];
      expect(descriptors.map((d) => d.sessionId).toSet(), {session.id});
      expect(descriptors.map((d) => d.clipId).toSet(), hasLength(records.length));
      expect(descriptors.map((d) => d.namespace).toSet(), {service.clipNamespaceForTest});
      for (final r in records) {
        expect(File(r.filePath).existsSync(), isTrue);
        expect(r.sizeBytes, 1024);
      }
      expect(recordingsLeftBehind(), isEmpty, reason: 'renamed, never copied: no recording left in the camera\'s directory');
    });

    test('X461 — the STOP is no longer the only checkpoint: with the session STILL recording, the index FILE on disk (what a process killed right now leaves) already holds every segment published so far', () async {
      build(segment: const Duration(milliseconds: 300));
      final session = await startRecordingSession();
      await waitUntil(() => indexedOf(session.id).length >= 2, 'two segments indexed');
      // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): Hive shows a put in memory as
      // soon as it is issued, before its frame is written; the file copied
      // right after could miss the last frame still in flight (found under the
      // directed delays, T-Rm 05_hardened/screen_full2). The index FIFO's turn
      // ends when a write SETTLES: a call for a name that is never a clip takes
      // its turn after every write queued so far — then the file holds them.
      expect(await ensureClipIndexed('${dir.path}/not_a_clip.mp4', origin: ClipIndexOrigin.producedInThisProcess), ClipIndexOutcome.invalidName);
      final onDisk = await indexOnDisk(session.id);
      expect(onDisk.length, greaterThanOrEqualTo(2));
      expect(recorder.state, DrivingSessionRecorderState.recording);
      for (final r in onDisk) {
        expect(DashcamClipDescriptor.parse(dashcamClipBasename(r.filePath))?.sessionId, session.id);
      }
      await controller.stopSession();
    });

    test('X462 — a protection reaches the index (it used to stay in memory) and never goes back: the protected segment\'s entry reads protected after the STOP\'s passes, and on disk', () async {
      build(segment: const Duration(milliseconds: 300));
      final session = await startRecordingSession();
      await waitUntil(() => indexedOf(session.id).isNotEmpty, 'a segment indexed');
      // The most recent published clip — read in the same slice as the call,
      // which marks it before its first await (a rotation may follow).
      final target = service.clips.last;
      final protecting = controller.protectCurrentClip();
      expect(target.isProtected, isTrue, reason: 'setup: the retroactive protection in memory');
      await protecting;
      final targetName = dashcamClipBasename(target.file.path);
      expect(DashcamClipDescriptor.parse(targetName)!.isProtected, isFalse, reason: 'setup: published unprotected');
      DashcamClipRecord entryOf(List<DashcamClipRecord> records) => records.firstWhere((r) => dashcamClipBasename(r.filePath) == targetName);
      expect(entryOf(indexedOf(session.id)).isProtected, isTrue);

      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop && indexedOf(session.id).length == service.clips.length, 'the session stopped and indexed');
      expect(entryOf(indexedOf(session.id)).isProtected, isTrue, reason: 'the STOP\'s passes did not lower it');
      expect(entryOf(await indexOnDisk(session.id)).isProtected, isTrue);
    });

    test('X463 — resolution and audio recorded for a clip are the ones its camera controller was BUILT with — not the preferences, not a configuration changed after the camera was initialized', () async {
      build(resolution: VideoResolution.fhd1080, audio: true);
      expect(preferences.resolution, isNot(VideoResolution.fhd1080), reason: 'setup: the preferences differ');
      final session = await startRecordingSession();
      service.updateConfig(
        DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: 1024, audioEnabled: false, resolution: VideoResolution.sd480, frameRate: 30, enabled: true),
      );
      await controller.stopSession();
      await waitUntil(() => indexedOf(session.id).isNotEmpty, 'the clip indexed');
      final record = indexedOf(session.id).single;
      expect(record.resolution, VideoResolution.fhd1080);
      expect(record.audioEnabled, isTrue);
      final d = DashcamClipDescriptor.parse(dashcamClipBasename(record.filePath))!;
      expect([d.resolution, d.audioEnabled], [VideoResolution.fhd1080, true]);
    });

    test('X464 — unknown provenance (a Recording started without a session token): the clip is MOVED under a legacy name the v1 parser never accepts, and indexed nowhere', () async {
      build();
      await service.initialize();
      await service.startLoopRecording();
      await service.stopLoopRecording();
      await waitUntil(() => service.clips.isNotEmpty && !service.hasPendingNativeStop, 'the clip published');
      final name = dashcamClipBasename(service.clips.single.file.path);
      expect(name, matches(RegExp(r'^clip_[0-9]+\.mp4$')));
      expect(DashcamClipDescriptor.parse(name), isNull);
      await pumpEventQueue(times: 50);
      expect(Hive.box(HiveBoxNames.dashcamSessionVideos).isEmpty, isTrue);
      expect(recordingsLeftBehind(), isEmpty);
    });

    test('X465 — the index never delays the camera: with every index write held, segments keep rotating and being published; once released, each is indexed exactly once', () async {
      build(segment: const Duration(milliseconds: 300));
      final release = Completer<void>();
      var held = 0;
      controller.persistClipIndexHookForTest = (sessionId, paths, write) async {
        held++;
        await release.future;
        await write();
      };
      final session = await startRecordingSession();
      final startsAtBegin = count('startVideoCapturing');
      await waitUntil(() => service.clips.length >= 3, 'three segments published while the index is held', within: const Duration(seconds: 15));
      expect(count('startVideoCapturing') - startsAtBegin, greaterThanOrEqualTo(2), reason: 'the rotation restarted the recording each time');
      expect(indexedOf(session.id), isEmpty, reason: 'nothing written while held');
      expect(held, 1, reason: 'the first write holds the index FIFO; the others wait their turn');
      release.complete();
      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop && indexedOf(session.id).length == service.clips.length, 'every clip indexed');
      final names = namesOf(indexedOf(session.id).map((r) => r.filePath));
      expect(names.toSet(), hasLength(names.length));
    });

    test('X466 — a cross-filesystem rename at the service: the clip is published through the .partial copy, indexed, and the recording deleted — no partial left', () async {
      build();
      service.promotionFileOpsForTest = _CrossDeviceSourceOps();
      final session = await startRecordingSession();
      await controller.stopSession();
      await waitUntil(() => indexedOf(session.id).isNotEmpty, 'the clip indexed');
      final record = indexedOf(session.id).single;
      expect(File(record.filePath).lengthSync(), 1024);
      expect(recordingsLeftBehind(), isEmpty);
      expect(Directory('${dir.path}/$dashcamClipsDirectoryName').listSync().where((e) => e.path.endsWith(DashcamClipDescriptor.partialSuffix)), isEmpty);
    });

    test('X467 — the canonical name already taken at the service: nothing is overwritten and nothing is published — the failure leaves the finalize like a copy failure did (a recordingResult error), the recording stays where it was, nothing is indexed', () async {
      build();
      service.promotionFileOpsForTest = _OccupiedFinalOps();
      final errors = <DashcamServiceError>[];
      final sub = service.originatedErrors.listen(errors.add);
      addTearDown(sub.cancel);
      final session = await startRecordingSession();
      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop, 'the stop settled');
      await pumpEventQueue(times: 50);
      expect(service.clips, isEmpty);
      expect(recordingsLeftBehind(), hasLength(1), reason: 'the recording is preserved');
      expect(indexedOf(session.id), isEmpty);
      expect(errors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult && e.message.contains('DashcamClipCollision')), isNotEmpty);
    });

    // Fase 16.2-R4.4-R2 — ADAPTED (a 6th test, outside the D0's list of five:
    // it is R4.4-R1's own record of D3-Q, the defect this round closes — brief
    // §9 "eliminar novo clip → promoção → imediatamente deletado").
    // BEFORE: with a 0 MB quota the clip was evicted at birth — never
    //   announced, never indexed (D3 open).
    // WHY superseded: the quota never evicts the newest clip, and its effective
    //   value is at least two segments (D0 §9).
    // AFTER: the same 0 MB quota — the clip is announced, indexed once, and its
    //   file is still there after the pass it triggered.
    // NEGATIVE CONTROL: newest evictable (M3), or the in-FIFO quota back (M9)
    //   → evicted at birth again → this test fails.
    test('X468 — a clip the quota evicts as it is published is not announced and not indexed (D3 stays open: the index never names a file the quota already took)', () async {
      build(quotaMb: 0);
      final session = await startRecordingSession();
      await controller.stopSession();
      await waitUntil(() => !service.hasPendingNativeStop, 'the stop settled');
      await pumpEventQueue(times: 50);
      await runInClipIndexQueue(() async {});
      await runInClipIndexQueue(() async {});
      expect(service.clips, hasLength(1), reason: 'the newest clip survives a quota smaller than itself');
      expect(File(service.clips.single.file.path).existsSync(), isTrue);
      expect(indexedOf(session.id).map((r) => r.filePath), [service.clips.single.file.path], reason: 'indexed exactly once');
    });
  });

  // Fase 16.2-R4.4-R1.1 — IR-P2-01 (independent review of R4.4-R1, verdict C):
  // a protection marked in memory whose index write fails is still the clip's
  // until a write carrying it takes effect. It used to travel only as the
  // argument of the protection's own write: the STOP's passes retried the
  // clip without it, and a healthy STOP left the entry unprotected for good.
  //
  // Rotation ticks are delivered by hand (segmentTimerArmedHookForTest; the
  // segment period stays 10 minutes): every clip is one the test asked for. A
  // failure is a genuine Hive failure BEFORE the write takes effect — a record
  // that fails while being serialized, so Hive rolls the put back from memory
  // (X436's technique, and the review's probe). Every assertion follows an
  // awaited step; nothing waits for a fixed time.
  group('Fase 16.2-R4.4-R1.1 — a protection survives a transient index failure (IR-P2-01)', () {
    final timerTicks = <void Function()>[];
    late _FlakyClipRecordAdapter adapter;
    late List<DashcamServiceError> errors;

    setUp(() {
      timerTicks.clear();
      adapter = _FlakyClipRecordAdapter();
      Hive.registerAdapter<DashcamClipRecord>(adapter, override: true);
    });

    tearDown(() {
      Hive.registerAdapter<DashcamClipRecord>(DashcamClipRecordAdapter(), override: true);
    });

    Future<DrivingSession> startWithTicksByHand() async {
      build();
      service.segmentTimerArmedHookForTest = timerTicks.add;
      errors = <DashcamServiceError>[];
      final sub = service.originatedErrors.listen(errors.add);
      addTearDown(sub.cancel);
      final session = await startRecordingSession();
      expect(timerTicks, isNotEmpty, reason: 'setup: the run armed its segment timer');
      return session;
    }

    /// The index failures reported so far: `recordingResult`, once per clip
    /// (frozen X26/X28).
    List<DashcamServiceError> indexFailures() => [
      for (final e in errors)
        if (e.scope == DashcamServiceErrorScope.recordingResult && e.message.startsWith('Falha ao indexar')) e,
    ];

    /// Every index write queued so far has settled: a name that is never a
    /// clip takes its turn in the index FIFO after them (no I/O, no write).
    Future<void> indexWritesSettled() async {
      expect(await ensureClipIndexed('${dir.path}/not_a_clip.mp4', origin: ClipIndexOrigin.producedInThisProcess), ClipIndexOutcome.invalidName);
    }

    /// One rotation: the segment it ends, once published and once the
    /// controller's own index write for it (queued as it was announced, before
    /// this listener resumes) has settled.
    Future<DashcamClip> rotate() async {
      final published = service.publishedClips.first;
      timerTicks.last();
      final clip = await published.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('the rotation never published its segment'));
      await indexWritesSettled();
      return clip;
    }

    /// [clip]'s entry in [records]: its protection, or `null` when absent.
    bool? protectedIn(List<DashcamClipRecord> records, DashcamClip clip) {
      final entries = [for (final r in records) if (dashcamClipBasename(r.filePath) == dashcamClipBasename(clip.file.path)) r];
      expect(entries.length, lessThanOrEqualTo(1), reason: 'one entry per clip, never two');
      return entries.isEmpty ? null : entries.single.isProtected;
    }

    bool publishedProtected(DashcamClip clip) => DashcamClipDescriptor.parse(dashcamClipBasename(clip.file.path))!.isProtected;

    test('X470 — IR-P2-01: a clip published and indexed UNprotected is protected; that write fails before taking effect (rolled back, reported); the later healthy STOP still writes it — protected in memory and on disk, one entry, one report', () async {
      final session = await startWithTicksByHand();
      final target = await rotate();
      expect(publishedProtected(target), isFalse, reason: 'setup: published unprotected — its name keeps p=0');
      expect(protectedIn(indexedOf(session.id), target), isFalse, reason: 'setup: indexed unprotected');

      var protectionWrites = 0;
      adapter.failWhen = (r) => r.filePath == target.file.path && r.isProtected && ++protectionWrites == 1;
      expect(service.clips.last, same(target), reason: 'setup: the clip a protection marks now');
      await controller.protectCurrentClip();
      expect(protectionWrites, 1, reason: 'setup: its index write was attempted, and failed');
      expect(target.isProtected, isTrue, reason: 'still marked in memory after its write failed');
      expect(protectedIn(indexedOf(session.id), target), isFalse, reason: 'setup: the failed write was rolled back');
      expect(indexFailures(), hasLength(1), reason: 'the failure is reported');

      await controller.stopSession();
      // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
      // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
      // pass is awaited here, where this test reads what it wrote.
      await controller.clipIndexFollowUpsSettledForTest();
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'the STOP retried the clip WITH the protection still marked in memory');
      expect(protectedIn(await indexOnDisk(session.id), target), isTrue, reason: 'and it is on disk');
      expect(indexFailures(), hasLength(1), reason: 'reported once, not once per attempt (frozen X26/X28)');
    });

    test('X471 — two failures, then a success: the protection\'s write fails, the STOP\'s immediate retry carries it and fails too — a failed retry consumes nothing — and the STOP\'s late retry writes it; one report', () async {
      final session = await startWithTicksByHand();
      final target = await rotate();
      var protectionWrites = 0;
      final thirdAttempt = Completer<void>();
      adapter.failWhen = (r) {
        if (r.filePath != target.file.path || !r.isProtected) return false;
        protectionWrites++;
        if (protectionWrites == 3 && !thirdAttempt.isCompleted) thirdAttempt.complete();
        return protectionWrites <= 2;
      };
      await controller.protectCurrentClip();
      expect(protectionWrites, 1, reason: 'setup: the protection\'s write failed');

      await controller.stopSession();
      // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
      // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
      // pass is awaited here, where this test reads what it wrote.
      await controller.clipIndexFollowUpsSettledForTest();
      // stopSession() awaits its immediate pass: by now that pass has retried
      // the clip WITH its protection (attempt 2, failed by the adapter).
      // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): this used to read "exactly 2
      // attempts, still unprotected" here — but stopSession() also waits for
      // the recorder, and with a slower recorder finalization the late pass had
      // already written attempt 3 (found by delaying only the recorder's
      // finalization, T-Rm 05_hardened/recorder_latent). What is observable at
      // this point is only that the immediate pass retried with the protection.
      expect(protectionWrites, greaterThanOrEqualTo(2), reason: 'the STOP\'s immediate pass retried the clip WITH its protection — and failed again');
      expect(target.isProtected, isTrue, reason: 'still marked in memory');

      // The late pass is installed only once the immediate one is over.
      await thirdAttempt.future.timeout(const Duration(seconds: 10), onTimeout: () => throw TestFailure('the STOP\'s late pass never retried the protection'));
      await indexWritesSettled();
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'the late pass carried it');
      expect(protectedIn(await indexOnDisk(session.id), target), isTrue);
      expect(indexFailures(), hasLength(1), reason: 'two failed attempts, one report');
    });

    test('X472 — a protection already durable is never lowered by a later failure: a write of the same session fails and is rolled back — to the PROTECTED entry — and the STOP and the disk keep it protected', () async {
      final session = await startWithTicksByHand();
      final target = await rotate();
      await controller.protectCurrentClip();
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'setup: the protection reached the index');
      expect(protectedIn(await indexOnDisk(session.id), target), isTrue, reason: 'setup: and the disk');

      // The next write that carries the protected entry fails once, before
      // taking effect: the next segment's own index write.
      var failuresLeft = 1;
      adapter.failWhen = (r) => r.filePath == target.file.path && failuresLeft-- > 0;
      final next = await rotate();
      expect(failuresLeft, lessThan(1), reason: 'setup: the write carrying the protected entry failed');
      expect(protectedIn(indexedOf(session.id), next), isNull, reason: 'setup: the next segment is not indexed');
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'the rollback restored the protected entry');
      expect(indexFailures(), hasLength(1));

      await controller.stopSession();
      // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
      // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
      // pass is awaited here, where this test reads what it wrote.
      await controller.clipIndexFollowUpsSettledForTest();
      expect(protectedIn(indexedOf(session.id), target), isTrue);
      expect(protectedIn(indexedOf(session.id), next), isNotNull, reason: 'the STOP retried the failed segment');
      expect(protectedIn(await indexOnDisk(session.id), target), isTrue);
      expect(indexFailures(), hasLength(1));
    });

    test('X473 — the entry is ABSENT (the segment\'s own write and the protection\'s both failed) and the name says p=0: the STOP\'s first successful write INSERTS the clip protected — a name published unprotected never decides against the protection marked since', () async {
      final session = await startWithTicksByHand();
      var failing = true;
      adapter.failWhen = (_) => failing;
      final target = await rotate();
      expect(protectedIn(indexedOf(session.id), target), isNull, reason: 'setup: the segment\'s own index write failed');
      expect(publishedProtected(target), isFalse);
      await controller.protectCurrentClip();
      expect(protectedIn(indexedOf(session.id), target), isNull, reason: 'setup: the protection\'s write failed too');
      expect(target.isProtected, isTrue, reason: 'still marked in memory after its write failed');
      expect(indexFailures(), hasLength(1), reason: 'one clip, one report');
      failing = false;

      await controller.stopSession();
      // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
      // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
      // pass is awaited here, where this test reads what it wrote.
      await controller.clipIndexFollowUpsSettledForTest();
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'inserted protected');
      expect(protectedIn(await indexOnDisk(session.id), target), isTrue);
      expect(indexFailures(), hasLength(1));
    });

    test('X474 — after the protection recovered by the STOP: ensureClipIndexed again, of either origin and asking no protection, writes nothing and lowers nothing; the index box reopened from its file and the startup reconciliation (the name still says p=0) find it protected, once', () async {
      final session = await startWithTicksByHand();
      final target = await rotate();
      var protectionWrites = 0;
      adapter.failWhen = (r) => r.filePath == target.file.path && r.isProtected && ++protectionWrites == 1;
      await controller.protectCurrentClip();
      expect(protectedIn(indexedOf(session.id), target), isFalse, reason: 'setup: the protection\'s write failed');
      await controller.stopSession();
      // R4.4-R2.1.1 (RES-1) — ANTES: stopSession() returned after its STOP's index pass. MOTIVO: by owner decision
      // that pass is no longer awaited by the STOP (the canonical file is the durability frontier). DEPOIS: the
      // pass is awaited here, where this test reads what it wrote.
      await controller.clipIndexFollowUpsSettledForTest();
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'setup: the STOP carried it');

      for (var i = 0; i < 3; i++) {
        expect(await ensureClipIndexed(target.file.path, origin: ClipIndexOrigin.producedInThisProcess), ClipIndexOutcome.alreadyIndexed);
        expect(await ensureClipIndexed(target.file.path, origin: ClipIndexOrigin.recovered), ClipIndexOutcome.alreadyIndexed);
      }
      expect(protectedIn(indexedOf(session.id), target), isTrue);
      expect(indexFailures(), hasLength(1), reason: 'nothing more to report');

      await Hive.box(HiveBoxNames.dashcamSessionVideos).close();
      await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'read back from the file');
      await reconcileCanonicalClipsAtStartup();
      expect(publishedProtected(target), isFalse);
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'a name saying p=0 never lowers the entry');
      final names = namesOf(indexedOf(session.id).map((r) => r.filePath));
      expect(names.toSet(), hasLength(names.length), reason: 'no duplicate');
    });

    test('X475 — an AMBIGUOUS protection write (its frame written, then the write reported failed): the protection is durable already — reported once; the STOP\'s retries find it and write nothing more for it; the index box reopened and the reconciliation find it protected', () async {
      final session = await startWithTicksByHand();
      final target = await rotate();
      var targetWrites = 0;
      controller.persistClipIndexHookForTest = (sessionId, paths, write) async {
        await write();
        if (paths.single == target.file.path && ++targetWrites == 1) throw StateError('injected failure after the frame was written');
      };
      await controller.protectCurrentClip();
      expect(targetWrites, 1, reason: 'setup: the protection\'s write took effect, then failed');
      expect(indexFailures(), hasLength(1));
      expect(protectedIn(indexedOf(session.id), target), isTrue, reason: 'the effect is there although the write "failed"');
      expect(protectedIn(await indexOnDisk(session.id), target), isTrue);

      await controller.stopSession();
      expect(targetWrites, 1, reason: 'the STOP found it protected: nothing more written for it');
      expect(protectedIn(indexedOf(session.id), target), isTrue);
      expect(indexFailures(), hasLength(1));

      await Hive.box(HiveBoxNames.dashcamSessionVideos).close();
      await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
      await reconcileCanonicalClipsAtStartup();
      expect(protectedIn(indexedOf(session.id), target), isTrue);
    });
  });
}

/// The source's rename crosses a filesystem boundary (EXDEV / ERROR_NOT_SAME_DEVICE).
class _CrossDeviceSourceOps extends DashcamClipFileOps {
  @override
  Future<void> rename(String from, String to) {
    if (!from.endsWith(DashcamClipDescriptor.partialSuffix)) {
      throw FileSystemException('Cannot rename file', from, OSError('Invalid cross-device link', Platform.isWindows ? 17 : 18));
    }
    return super.rename(from, to);
  }
}

/// Something already sits under every canonical name.
class _OccupiedFinalOps extends DashcamClipFileOps {
  @override
  Future<bool> isOccupied(String path) async => true;
}

/// A clip record that fails while being serialized, for the records
/// [failWhen] picks: the put fails BEFORE taking effect and Hive rolls it back
/// from memory (X436's technique).
class _FlakyClipRecordAdapter extends DashcamClipRecordAdapter {
  // Adapters are @immutable: the rule lives in a holder.
  final _FailureRule _rule = _FailureRule();

  set failWhen(bool Function(DashcamClipRecord record) rule) => _rule.failWhen = rule;

  @override
  void write(BinaryWriter writer, DashcamClipRecord obj) {
    if (_rule.failWhen(obj)) throw StateError('injected transient failure while serializing a clip record');
    super.write(writer, obj);
  }
}

class _FailureRule {
  bool Function(DashcamClipRecord record) failWhen = (_) => false;
}
