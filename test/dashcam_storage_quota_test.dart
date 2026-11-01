import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_descriptor.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/services/dashcam_clip_files.dart';
import 'package:synapse_auto/services/dashcam_clip_index.dart';
import 'package:synapse_auto/services/dashcam_storage_probe.dart';
import 'package:synapse_auto/services/dashcam_storage_quota.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_storage_probe.dart';

// Fase 16.2-R4.4-R2 — the physical storage quota and the free-space guard at
// the persistence layer: real Hive in a temporary directory, path_provider
// mocked to it, real files under `dashcam_clips/` (the R4.4-R1 index tests'
// harness). No camera, no controller: the controller-level contracts are in
// dashcam_storage_session_test.dart.
//
// Sizes are small on purpose: a clip of 100 bytes plays a segment; the volume
// is the fake probe's (`FakeStorageProbe`), computed from what is left in the
// directory where a test needs evictions to free space. A "restart" closes
// every box and reopens it from its file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory clipsDir;
  late Directory cacheDir;
  late String ns;
  var rid = 0;
  var videosWrites = 0;
  final t0 = DateTime(2026, 10, 28, 9);

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  Box videos() => Hive.box(HiveBoxNames.dashcamSessionVideos);

  Future<void> openBoxes() async {
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    await Hive.openBox(
      HiveBoxNames.dashcamSessionVideos,
      compactionStrategy: (entries, deleted) {
        videosWrites++;
        return false;
      },
    );
  }

  Future<void> restart() async {
    await Hive.close();
    await openBoxes();
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dashcam_storage_quota_test');
    clipsDir = Directory('${dir.path}/$dashcamClipsDirectoryName')..createSync();
    cacheDir = Directory('${dir.path}/cache')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => dir.path,
        'getTemporaryDirectory' => cacheDir.path,
        _ => null,
      };
    });
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
      Hive.registerAdapter(VideoResolutionAdapter());
      Hive.registerAdapter(DashcamClipRecordAdapter());
    }
    ns = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padRight(32, 'd');
    rid = 0;
    videosWrites = 0;
    resetDashcamStorageForTest();
    DashcamClipStorageCounters.resetForTest();
    quotaPassDecidedHookForTest = null;
    afterEvictedFileDeletedHookForTest = null;
    Hive.init(dir.path);
    await openBoxes();
  });

  tearDown(() async {
    quotaPassDecidedHookForTest = null;
    afterEvictedFileDeletedHookForTest = null;
    // Every queued pass and index write of this test settles here.
    await runInClipIndexQueue(() async {});
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, null);
    dir.deleteSync(recursive: true);
  });

  DashcamClipDescriptor clip(String sessionId, {int? recordingId, DateTime? at, bool protected = false, String? namespace, VideoResolution resolution = VideoResolution.fhd1080}) {
    final id = recordingId ?? ++rid;
    return DashcamClipDescriptor.tryCreate(
      sessionId: sessionId,
      recordedAt: at ?? t0.add(Duration(minutes: id)),
      namespace: namespace ?? ns,
      recordingId: id,
      durationSeconds: 180,
      isProtected: protected,
      resolution: resolution,
      audioEnabled: false,
    )!;
  }

  String pathOf(DashcamClipDescriptor d) => '${clipsDir.path}/${d.basename}';

  String publish(DashcamClipDescriptor d, {int size = 100}) {
    File(pathOf(d)).writeAsBytesSync(List<int>.filled(size, 1));
    return pathOf(d);
  }

  Future<void> session(String id, {bool marked = false}) =>
      sessions().put(id, DrivingSession(id: id, startTime: t0, endTime: t0.add(const Duration(minutes: 30)), deletionPending: marked));

  Future<String> indexedClip(String sessionId, {int size = 100, bool protected = false, String? namespace, VideoResolution resolution = VideoResolution.fhd1080}) async {
    final path = publish(clip(sessionId, protected: protected, namespace: namespace, resolution: resolution), size: size);
    expect(await ensureClipIndexed(path, origin: ClipIndexOrigin.producedInThisProcess), ClipIndexOutcome.indexed, reason: 'setup: indexed');
    return path;
  }

  List<DashcamClipRecord> indexed(String id) => List<DashcamClipRecord>.from(videos().get(id) as List? ?? const []);
  List<String> indexedNames(String id) => [for (final r in indexed(id)) dashcamClipBasename(r.filePath)];
  bool onDisk(String path) => File(path).existsSync();
  int bytesInClipsDir() => [for (final f in clipsDir.listSync().whereType<File>()) f.lengthSync()].fold(0, (a, b) => a + b);

  final unsupported = FakeStorageProbe(supported: false);

  Future<DashcamQuotaPassResult> pass({
    int quota = 0,
    String? trigger,
    Set<String> memory = const {},
    Set<String> immune = const {},
    DashcamStorageProbe? probe,
    DashcamClipFileOps ops = const DashcamClipFileOps(),
    VideoResolution resolution = VideoResolution.fhd1080,
    Set<String> Function()? memoryNow,
  }) => runDashcamQuotaPass(
    trigger: DashcamQuotaTrigger.publication,
    quotaBytes: () => quota,
    resolution: () => resolution,
    probe: probe ?? unsupported,
    triggerClipPath: trigger,
    protectedInMemory: memoryNow ?? () => memory,
    immunePaths: () => immune,
    fileOps: ops,
  );

  group('Fase 16.2-R4.4-R2 — physical authority (§16)', () {
    test('X487 — what is on disk counts, at its real size: an entry whose file is gone adds nothing, an entry that claims a size is not believed, '
        'and clips of an EARLIER process (another namespace, in no memory) count and are evicted oldest first', () async {
      await session('s1');
      final older = await indexedClip('s1', namespace: 'a' * 32);
      final gone = await indexedClip('s1', namespace: 'a' * 32);
      File(gone).deleteSync(); // a stale entry: its file is gone
      final mid = await indexedClip('s1');
      final newer = await indexedClip('s1');
      // The entry of `mid` claims 10 GB; the file has 100 bytes.
      final entries = indexed('s1');
      final i = entries.indexWhere((e) => e.filePath == mid);
      final e = entries[i];
      entries[i] = DashcamClipRecord(filePath: e.filePath, recordedAt: e.recordedAt, durationSeconds: e.durationSeconds, sizeBytes: 10 << 30, resolution: e.resolution);
      await videos().put('s1', entries);

      final result = await pass(quota: 250);
      final snapshot = result.snapshot!;
      expect(result.aborted, isFalse);
      expect(result.evictedPaths, [older], reason: 'managed = 300 bytes on disk (not 10 GB, not 400): only the oldest goes to reach 250');
      expect(snapshot.managedBytes, 200);
      expect(snapshot.effectiveQuotaBytes, 250);
      expect(onDisk(mid) && onDisk(newer), isTrue);
      expect(indexedNames('s1'), [dashcamClipBasename(gone), dashcamClipBasename(mid), dashcamClipBasename(newer)], reason: 'only the evicted entry left; a dangling one is the startup\'s');
    });

    test('X488 — a canonical clip of a live session that is not indexed (yet) counts physically, is never evicted, and once the startup '
        'reconciliation has indexed it, it is decided normally', () async {
      await session('s2');
      final unindexed = publish(clip('s2'));
      final second = await indexedClip('s2');
      final third = await indexedClip('s2');

      var result = await pass(quota: 0);
      expect(result.snapshot!.bytesOf(DashcamStorageClass.unindexed), 100);
      expect(result.snapshot!.managedBytes, 200, reason: '300 on disk, the unindexed clip included, > Q_eff = 2 × 100: one clip had to go');
      expect(result.evictedPaths, [second], reason: 'the oldest is unindexed: the next one is evicted instead');
      expect(onDisk(unindexed), isTrue);

      await restart();
      final reconciliation = await reconcileCanonicalClipsAtStartup();
      expect(reconciliation.of(ClipIndexOutcome.indexed), 1);
      publish(clip('s2'));
      result = await pass(quota: 0);
      expect(result.evictedPaths, [unindexed], reason: 'indexed now: the oldest, and evicted first');
      expect(onDisk(third), isTrue);
    });

    test('X489 — every pass reads the disk again: a file added after the previous pass is counted (and evicted in order) by the next, '
        'one removed meanwhile is no longer counted', () async {
      await session('s3');
      final a = await indexedClip('s3');
      final b = await indexedClip('s3');
      var result = await pass(quota: 0);
      expect(result.snapshot!.managedBytes, 200);
      expect(result.evictedPaths, isEmpty);

      final c = await indexedClip('s3', size: 50);
      result = await pass(quota: 0);
      expect(result.snapshot!.managedBytes, 150, reason: '250 > Q_eff = 2 × 100: a goes, 150 left');
      expect(result.evictedPaths, [a]);

      File(b).deleteSync();
      result = await pass(quota: 0);
      expect(result.snapshot!.managedBytes, 50, reason: 'b is gone from the disk: not counted, whatever the index says');
      expect(result.evictedPaths, isEmpty);
      expect(onDisk(c), isTrue);
    });
  });

  group('Fase 16.2-R4.4-R2 — what never leaves (§17–§19)', () {
    test('X490 — the newest canonical clip survives a quota smaller than itself, even alone; a quota below two segments keeps two; '
        'the third pushes out the oldest', () async {
      await session('s4');
      final first = await indexedClip('s4', size: 300);
      var result = await pass(quota: 100);
      expect(result.evictedPaths, isEmpty, reason: 'alone and larger than the quota: kept (the quota is a retention target)');
      expect(result.snapshot!.effectiveQuotaBytes, 600);
      expect(onDisk(first), isTrue);

      final second = await indexedClip('s4', size: 300);
      result = await pass(quota: 100, trigger: second);
      expect(result.evictedPaths, isEmpty, reason: 'Q_eff = max(100, 2 × 300): both kept');

      final third = await indexedClip('s4', size: 300);
      result = await pass(quota: 100, trigger: third);
      expect(result.evictedPaths, [first]);
      expect(onDisk(second) && onDisk(third), isTrue);
      expect(result.snapshot!.managedBytes, 600);
    });

    test('X491 — immunity holds whatever the quota: the newest by compareOrder, the trigger, and the caller\'s immune path are never evicted — '
        'the pass saturates instead, visibly', () async {
      await session('s5');
      final a = await indexedClip('s5');
      final b = await indexedClip('s5');
      final c = await indexedClip('s5');
      final result = await pass(quota: 0, trigger: a, immune: {b});
      expect(result.evictedPaths, isEmpty, reason: 'a: trigger, b: immune path, c: newest');
      expect(result.snapshot!.countOf(DashcamStorageClass.immune), 3);
      expect(result.snapshot!.health, DashcamStorageHealth.quotaSaturated);
      expect(onDisk(a) && onDisk(b) && onDisk(c), isTrue);
    });

    test('X492 — protected clips count in the managed bytes and are never candidates — protected by their NAME, by their ENTRY, or only IN MEMORY '
        '(an index write still pending, R4.4-R1.1); protection never goes back to false', () async {
      await session('s6');
      final byName = await indexedClip('s6', protected: true);
      final byEntry = await indexedClip('s6');
      expect(await ensureClipIndexed(byEntry, origin: ClipIndexOrigin.producedInThisProcess, protectedNow: true), ClipIndexOutcome.protectionRaised);
      final inMemory = await indexedClip('s6');
      final plain = await indexedClip('s6');
      final newest = await indexedClip('s6');

      final result = await pass(quota: 0, memory: {inMemory});
      expect(result.evictedPaths, [plain], reason: 'the only unprotected, non-immune clip');
      expect(result.snapshot!.protectedBytes, 300);
      expect(result.snapshot!.bytesOf(DashcamStorageClass.protected), 300);
      expect(result.snapshot!.managedBytes, 400, reason: 'protected bytes count');
      expect(result.snapshot!.health, DashcamStorageHealth.protectedSaturated, reason: '300 protected > Q_eff 200 − 2 × 100');
      for (final path in [byName, byEntry, inMemory, newest]) {
        expect(onDisk(path), isTrue);
      }
      expect(indexed('s6').firstWhere((e) => e.filePath == byEntry).isProtected, isTrue, reason: 'never back to false');
    });

    test('X493 — an orphan (no record), a partial, a clip of a session being deleted, an identity conflict, legacy clip_<ms> and other names: '
        'none is a candidate, none is indexed by the pass; only canonical clips and partials are managed', () async {
      await session('s7');
      await session('s7m', marked: true);
      final orphan = publish(clip('nobody'));
      final partial = '${pathOf(clip('s7'))}${DashcamClipDescriptor.partialSuffix}';
      File(partial).writeAsBytesSync(List.filled(100, 2));
      final marked = publish(clip('s7m'));
      final conflictA = publish(clip('s7', recordingId: 900, at: t0.subtract(const Duration(hours: 8))));
      final conflictB = publish(clip('s7', recordingId: 900, at: t0.subtract(const Duration(hours: 9)))); // same clip id, two names
      File('${clipsDir.path}/clip_1700000000000.mp4').writeAsBytesSync(List.filled(500, 3));
      File('${clipsDir.path}/notes.txt').writeAsBytesSync(List.filled(7, 4));
      final newest = await indexedClip('s7');

      final result = await pass(quota: 0);
      final s = result.snapshot!;
      expect(result.evictedPaths, isEmpty);
      expect(s.countOf(DashcamStorageClass.orphan), 1);
      expect(s.countOf(DashcamStorageClass.partial), 1);
      expect(s.countOf(DashcamStorageClass.deletionPending), 1);
      expect(s.countOf(DashcamStorageClass.conflict), 2);
      expect(s.managedBytes, 600, reason: 'canonical + partial only');
      expect(s.legacyClipCount, 1);
      expect(s.legacyClipBytes, 500);
      expect(s.otherCount, 1);
      for (final path in [orphan, partial, marked, conflictA, conflictB, newest, '${clipsDir.path}/clip_1700000000000.mp4']) {
        expect(onDisk(path), isTrue);
      }
      expect(videos().containsKey('nobody'), isFalse, reason: 'the orphan was not attributed to anyone');
      expect(indexedNames('s7'), [dashcamClipBasename(newest)]);
    });
  });

  group('Fase 16.2-R4.4-R2 — eviction: file first, entry after (§7, §20)', () {
    test('X494 — an evicted clip: the file is gone, then its entry; the key goes when it empties; indexing it again finds nothing; '
        'the next start indexes nothing', () async {
      await session('s8');
      await session('s8b');
      final a = await indexedClip('s8');
      final b = await indexedClip('s8b');
      final c = await indexedClip('s8b');
      final result = await pass(quota: 0);
      expect(result.evictedPaths, [a]);
      expect(onDisk(a), isFalse);
      expect(videos().containsKey('s8'), isFalse, reason: 'its only entry: the key goes (the History tests containsKey)');
      expect(await ensureClipIndexed(a, origin: ClipIndexOrigin.producedInThisProcess), ClipIndexOutcome.notPresent);
      await restart();
      expect((await reconcileCanonicalClipsAtStartup()).of(ClipIndexOutcome.indexed), 0);
      expect(videos().containsKey('s8'), isFalse);
      expect(indexedNames('s8b'), [dashcamClipBasename(b), dashcamClipBasename(c)]);
    });

    test('X495 — a process death between the file and the entry leaves an entry without a file: the next start does NOT index anything again '
        '(no resurrection) and removes that entry; a second start writes nothing', () async {
      await session('s9');
      final a = await indexedClip('s9');
      final b = await indexedClip('s9');
      final c = await indexedClip('s9');
      afterEvictedFileDeletedHookForTest = (path) async => throw StateError('process killed (simulated) after the file of $path');
      final result = await pass(quota: 0);
      expect(result.aborted, isTrue, reason: 'the death interrupts the pass');
      afterEvictedFileDeletedHookForTest = null;
      expect(onDisk(a), isFalse, reason: 'the file went first');
      expect(indexedNames('s9'), contains(dashcamClipBasename(a)), reason: 'the entry never got removed');

      await restart();
      final reconciliation = await reconcileCanonicalClipsAtStartup();
      expect(reconciliation.of(ClipIndexOutcome.indexed), 0, reason: 'nothing to reindex: the evicted clip has no file');
      final writesBefore = videosWrites;
      await measureDashcamStorageAtStartup(probe: unsupported);
      expect(indexedNames('s9'), [dashcamClipBasename(b), dashcamClipBasename(c)], reason: 'the dangling v1 entry is removed');
      expect(DashcamStorageCounters.danglingEntriesRemoved, 1);
      expect(videosWrites, writesBefore + 1);

      await restart();
      final writesSecond = videosWrites;
      await reconcileCanonicalClipsAtStartup();
      await measureDashcamStorageAtStartup(probe: unsupported);
      expect(videosWrites, writesSecond, reason: 'idempotent: a second start writes nothing');
      expect(indexedNames('s9'), [dashcamClipBasename(b), dashcamClipBasename(c)]);
    });

    test('X496 — a file that cannot be deleted: its entry stays (the index does not lie), the pass stops, the failure is counted, and the next '
        'pass tries again', () async {
      await session('s10');
      final a = await indexedClip('s10');
      final b = await indexedClip('s10');
      await indexedClip('s10');
      await indexedClip('s10');
      final failing = _FailingDeleteOps({a});
      var result = await pass(quota: 0, ops: failing);
      expect(result.evictedPaths, isEmpty, reason: 'a failed: nothing after it was tried');
      expect(onDisk(a) && onDisk(b), isTrue);
      expect(indexedNames('s10'), contains(dashcamClipBasename(a)));
      expect(DashcamStorageCounters.evictionFileFailures, 1);

      result = await pass(quota: 0);
      expect(result.evictedPaths, [a, b]);
      expect(indexedNames('s10'), isNot(contains(dashcamClipBasename(a))));
    });

    test('X497 — an entry that cannot be removed after its file is gone: counted, the pass stops; the next start removes the entry', () async {
      await session('s11');
      final a = await indexedClip('s11');
      await indexedClip('s11');
      await indexedClip('s11');
      await indexedClip('s11');
      afterEvictedFileDeletedHookForTest = (path) async {
        // The box is closed under the eviction's feet: its put fails.
        await Hive.box(HiveBoxNames.dashcamSessionVideos).close();
      };
      final result = await pass(quota: 0);
      afterEvictedFileDeletedHookForTest = null;
      expect(result.evictedPaths, [a], reason: 'the file is gone: evicted, and the pass stopped there');
      expect(DashcamStorageCounters.evictionEntryFailures, 1);
      await restart();
      expect(indexedNames('s11'), contains(dashcamClipBasename(a)));
      await measureDashcamStorageAtStartup(probe: unsupported);
      expect(indexedNames('s11'), isNot(contains(dashcamClipBasename(a))));
    });
  });

  group('Fase 16.2-R4.4-R2 — serialization against indexing, protection and deletion (§8)', () {
    test('X498 — a protection that arrives while a pass is running is honoured up to the instant the deletion is issued: the victim is decided '
        'again, in the slice that issues its unlink', () async {
      await session('s12');
      final a = await indexedClip('s12');
      final b = await indexedClip('s12');
      await indexedClip('s12');
      final memory = <String>{};
      final decided = Completer<void>();
      final release = Completer<void>();
      quotaPassDecidedHookForTest = () async {
        decided.complete();
        await release.future;
      };
      final running = pass(quota: 0, memoryNow: () => memory);
      await decided.future;
      memory.add(a); // e.g. the RAM flag of R4.4-R1.1, set while the pass was held
      release.complete();
      final result = await running;
      expect(result.evictedPaths, [b], reason: 'a was decided again and kept; the next candidate went instead');
      expect(onDisk(a), isTrue);
    });

    test('X499 — an indexing or protection queued while a pass holds the index FIFO runs after it — never inside it — and a clip the pass '
        'evicted is not indexed again', () async {
      await session('s13');
      final a = await indexedClip('s13');
      await indexedClip('s13');
      await indexedClip('s13');
      final release = Completer<void>();
      final decided = Completer<void>();
      quotaPassDecidedHookForTest = () async {
        decided.complete();
        await release.future;
      };
      final running = pass(quota: 0);
      await decided.future;
      var protectionDone = false;
      final protection = ensureClipIndexed(a, origin: ClipIndexOrigin.producedInThisProcess, protectedNow: true).then((outcome) {
        protectionDone = true;
        return outcome;
      });
      await pumpEventQueue(times: 20);
      expect(protectionDone, isFalse, reason: 'queued behind the pass');
      release.complete();
      expect((await running).evictedPaths, [a]);
      expect(await protection, ClipIndexOutcome.notPresent, reason: 'after the pass: nothing to protect, nothing resurrected');
      expect(indexedNames('s13'), isNot(contains(dashcamClipBasename(a))));
    });

    test('X500 — eviction × session deletion: a deletion committed before the eviction decides keeps the clip for the deletion; one committed '
        'between the file and the entry is not undone — no key is recreated, nothing is written for the deleted session', () async {
      // Order 1: deletion first.
      await session('s14');
      final a = await indexedClip('s14');
      await indexedClip('s14');
      await indexedClip('s14');
      final decided = Completer<void>();
      final release = Completer<void>();
      quotaPassDecidedHookForTest = () async {
        decided.complete();
        await release.future;
      };
      final running = pass(quota: 0);
      await decided.future;
      await deleteDrivingSession('s14');
      release.complete();
      expect((await running).evictedPaths, isEmpty, reason: 'the deletion owns its files');
      expect(onDisk(a), isFalse, reason: 'removed once — by the deletion');
      expect(videos().containsKey('s14'), isFalse);
      quotaPassDecidedHookForTest = null;

      // Order 2: the deletion commits between the eviction's file and entry.
      await session('s15');
      final c = await indexedClip('s15');
      await indexedClip('s15');
      await indexedClip('s15');
      final fileGone = Completer<void>();
      final resume = Completer<void>();
      afterEvictedFileDeletedHookForTest = (path) async {
        fileGone.complete();
        await resume.future;
      };
      final second = pass(quota: 0);
      await fileGone.future;
      final deletion = deleteDrivingSession('s15');
      await pumpEventQueue(times: 50);
      resume.complete();
      expect((await second).evictedPaths, [c]);
      await deletion;
      afterEvictedFileDeletedHookForTest = null;
      expect(videos().containsKey('s15'), isFalse, reason: 'never recreated');
      expect(sessions().containsKey('s15'), isFalse);
    });
  });

  group('Fase 16.2-R4.4-R2 — the free-space guard (§10, §22)', () {
    // total 1000 → L = min(50, 500 MiB) = 50 → TRIM = 75; S = 100 → floor 175.
    const total = 1000;

    test('X501 — the floor is Android\'s trim threshold (1.5 × min(5 %, 500 MiB)) + one segment (+ one more after a copied promotion)', () {
      expect(dashcamStorageTrimBytes(total), 75);
      expect(dashcamStorageFloorBytes(totalBytes: total, segmentBytes: 100, copyReserve: false), 175);
      expect(dashcamStorageFloorBytes(totalBytes: total, segmentBytes: 100, copyReserve: true), 275);
      const gib = 1024 * 1024 * 1024;
      expect(dashcamStorageTrimBytes(110 * gib), 750 * 1024 * 1024, reason: 'the SM-A326B volume: capped at 500 MiB × 1.5');
    });

    Future<DashcamStartStorageDecision> start(FakeStorageProbe probe, {int quota = 1 << 30, Set<String> memory = const {}}) => evaluateDashcamStartStorage(
      quotaBytes: () => quota,
      resolution: () => VideoResolution.fhd1080,
      probe: probe,
      protectedInMemory: () => memory,
    );

    test('X502 — above the floor and exactly at it: allowed; one byte below with nothing evictable: refused, with a message that is not '
        '"camera unavailable"', () async {
      await session('s16');
      await indexedClip('s16');
      final probe = FakeStorageProbe(totalBytes: total, availableBytes: 500);
      expect((await start(probe)).allowed, isTrue);
      probe.availableBytes = 175;
      final atFloor = await start(probe);
      expect(atFloor.allowed, isTrue, reason: 'the boundary is allowed');
      expect(atFloor.floorBytes, 175);
      probe.availableBytes = 174;
      final below = await start(probe);
      expect(below.allowed, isFalse, reason: 'the only clip is the newest: nothing can be freed');
      expect(below.refusal, contains('Armazenamento insuficiente'));
      expect(below.refusal, isNot(contains('indispon')));
      expect(DashcamStorageCounters.startRefusals, 1);
    });

    test('X503 — a failing native read is never "enough space": the decision is unknown (allowed, fail-open), the snapshot says unknown, '
        'and the failure is counted', () async {
      await session('s17');
      await indexedClip('s17');
      final probe = FakeStorageProbe(totalBytes: total)..volumeFailure = PlatformException(code: 'statfs_failed');
      final decision = await start(probe);
      expect(decision.allowed, isTrue);
      expect(decision.availableBytes, isNull, reason: 'no number was invented');
      expect(DashcamStorageCounters.probeFailures, 1);
      final result = await pass(quota: 1 << 30, probe: probe);
      expect(result.snapshot!.probeFailed, isTrue);
      expect(result.snapshot!.availableBytes, isNull);
      expect(result.snapshot!.health, DashcamStorageHealth.unknown);
    });

    test('X504 — below the floor with evictable clips: a pass under pressure evicts oldest first — below the quota if it must, never the newest, '
        'a protected or an orphan clip — and the START is allowed once the volume, read again, is at the floor', () async {
      await session('s18');
      final orphan = publish(clip('nobody2'));
      final a = await indexedClip('s18');
      final protected = await indexedClip('s18', protected: true);
      final b = await indexedClip('s18');
      final c = await indexedClip('s18');
      final newest = await indexedClip('s18');
      // The volume: 1000 bytes, 400 of them not clips — 0 free with these 600 bytes of clips.
      final probe = FakeStorageProbe(totalBytes: total)..availableNow = () => total - 400 - bytesInClipsDir();
      final decision = await start(probe);
      expect(decision.allowed, isTrue);
      expect(decision.pass!.evictedPaths, [a, b], reason: 'oldest evictable first, until the projected space reaches the floor');
      expect(decision.pass!.snapshot!.pressureEvictedCount, 2);
      expect(decision.availableBytes, 200);
      for (final path in [orphan, protected, c, newest]) {
        expect(onDisk(path), isTrue);
      }
    });

    test('X505 — protected clips keep the space from being freed: refused, the message says how much they hold; with no candidate at all: refused', () async {
      await session('s19');
      await indexedClip('s19', protected: true);
      await indexedClip('s19', protected: true);
      await indexedClip('s19');
      final probe = FakeStorageProbe(totalBytes: total)..availableNow = () => total - 900 - bytesInClipsDir() + 300;
      final refused = await start(probe);
      expect(refused.allowed, isFalse);
      expect(refused.pass!.evictedPaths, isEmpty);
      expect(refused.refusal, contains('protegidos'));
      expect(refused.pass!.snapshot!.health, DashcamStorageHealth.lowDisk, reason: '100 free: above the trim threshold (75), below the floor (175)');
    });

    test('X506 — the volume is read afresh at every START: the same disk, freed meanwhile by someone else, turns a refusal into an allowance', () async {
      await session('s20');
      await indexedClip('s20');
      final probe = FakeStorageProbe(totalBytes: total, availableBytes: 100);
      expect((await start(probe)).allowed, isFalse);
      probe.availableBytes = 900;
      expect((await start(probe)).allowed, isTrue);
      expect(probe.volumeCalls, greaterThanOrEqualTo(3));
    });
  });

  group('Fase 16.2-R4.4-R2 — P3-HW-1 cache-group repair (§13, §14)', () {
    test('X507 — a publication pass repairs the group of the clip just published, only it; a failed repair keeps the clip, evicts nothing more '
        'and is counted', () async {
      await session('s21');
      final a = await indexedClip('s21');
      final b = await indexedClip('s21');
      final probe = FakeStorageProbe();
      await pass(quota: 1 << 30, trigger: b, probe: probe);
      expect(probe.groupRepairCalls, [
        [b],
      ]);
      probe.repairFailure = PlatformException(code: 'chown_failed');
      final result = await pass(quota: 1 << 30, trigger: b, probe: probe);
      expect(result.evictedPaths, isEmpty);
      expect(onDisk(a) && onDisk(b), isTrue, reason: 'durability first: never deleted for a bookkeeping failure');
      expect(DashcamStorageCounters.groupRepairFailures, 1);
      probe.repairFailure = null;
      probe.repairFailedCount = 1;
      await pass(quota: 1 << 30, trigger: b, probe: probe);
      expect(onDisk(b), isTrue);
      expect(DashcamStorageCounters.groupRepairFailures, 2);
    });

    test('X508 — the startup repairs every canonical clip and partial (never a legacy or other file), deletes nothing although the quota is '
        'exceeded, and keeps a clip whose repair failed', () async {
      await session('s22');
      final a = await indexedClip('s22', size: 5000);
      final b = await indexedClip('s22', size: 5000);
      final partial = '${pathOf(clip('s22'))}${DashcamClipDescriptor.partialSuffix}';
      File(partial).writeAsBytesSync(List.filled(10, 1));
      File('${clipsDir.path}/clip_1700000000001.mp4').writeAsBytesSync(List.filled(10, 1));
      final probe = FakeStorageProbe()..repairFailedCount = 1;
      final snapshot = await measureDashcamStorageAtStartup(probe: probe);
      expect(probe.groupRepairCalls.single.toSet(), {a, b, partial});
      expect(snapshot!.managedBytes, 10010);
      expect(snapshot.evictedCount, 0);
      expect(onDisk(a) && onDisk(b) && onDisk(partial), isTrue);
      expect(DashcamStorageCounters.groupRepairFailures, 1);
    });
  });

  group('Fase 16.2-R4.4-R2 — the startup measures, never evicts (§11.1)', () {
    test('X509 — the plugin\'s cache/REC files are measured read-only (count, bytes, empty ones) — never deleted, adopted or counted in the quota; '
        'legacy entries without a file and the entries of a session being deleted are left alone', () async {
      await session('s23');
      await session('s23m', marked: true);
      File('${cacheDir.path}/REC111.mp4').writeAsBytesSync(List.filled(700, 1));
      File('${cacheDir.path}/REC222.mp4').writeAsBytesSync(const []);
      File('${cacheDir.path}/other.tmp').writeAsBytesSync(List.filled(3, 1));
      final legacyGone = DashcamClipRecord(filePath: '${clipsDir.path}/clip_1600000000000.mp4', recordedAt: t0, sizeBytes: 9);
      await videos().put('s23', [legacyGone]);
      final markedGone = clip('s23m');
      await videos().put('s23m', [
        DashcamClipRecord(filePath: pathOf(markedGone), recordedAt: markedGone.recordedAt, durationSeconds: 180, sizeBytes: 9, resolution: VideoResolution.fhd1080),
      ]);
      final snapshot = await measureDashcamStorageAtStartup(probe: unsupported);
      expect(snapshot!.recCount, 2);
      expect(snapshot.recBytes, 700);
      expect(snapshot.recEmptyCount, 1);
      expect(snapshot.managedBytes, 0);
      expect(File('${cacheDir.path}/REC111.mp4').existsSync() && File('${cacheDir.path}/REC222.mp4').existsSync(), isTrue);
      expect(indexed('s23'), hasLength(1), reason: 'legacy: R4.4-R3');
      expect(indexed('s23m'), hasLength(1), reason: 'the deletion owns it');
    });
  });

  group('Fase 16.2-R4.4-R2 — the native bridge seam (§21)', () {
    const channel = MethodChannel(MethodChannelDashcamStorageProbe.channelName);
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    test('X510 — the production probe is not supported off Android (answered synchronously); over the channel it decodes the volume and the '
        'repair counts, and a malformed or failed reply is an error, never a number', () async {
      expect(const MethodChannelDashcamStorageProbe().isSupported, Platform.isAndroid);
      final calls = <MethodCall>[];
      Object? Function(MethodCall call) reply = (call) => switch (call.method) {
        'volumeStats' => {'availableBytes': 123, 'totalBytes': 456},
        'normalizeClipGroups' => {'normalized': 1, 'alreadyAppGroup': 2, 'otherGroup': 0, 'skipped': 1, 'failed': 0},
        _ => null,
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply(call);
      });
      const probe = MethodChannelDashcamStorageProbe.forTest();
      final volume = await probe.volumeStats('/docs');
      expect((volume.availableBytes, volume.totalBytes), (123, 456));
      final repair = await probe.normalizeClipGroups(['/docs/dashcam_clips/x.mp4']);
      expect((repair.normalized, repair.alreadyAppGroup, repair.skipped), (1, 2, 1));
      expect([for (final c in calls) c.method], ['volumeStats', 'normalizeClipGroups']);
      expect(calls[0].arguments, {'path': '/docs'});
      expect(calls[1].arguments, {
        'paths': ['/docs/dashcam_clips/x.mp4'],
      });
      expect(await probe.normalizeClipGroups(const []), isA<DashcamGroupRepair>(), reason: 'nothing to send');
      expect(calls, hasLength(2));

      reply = (call) => {'availableBytes': 'x', 'totalBytes': 1};
      await expectLater(probe.volumeStats('/docs'), throwsFormatException);
      reply = (call) => throw PlatformException(code: 'statfs_failed');
      await expectLater(probe.volumeStats('/docs'), throwsA(isA<PlatformException>()));
    });
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

class _FailingDeleteOps extends DashcamClipFileOps {
  const _FailingDeleteOps(this.failing);

  final Set<String> failing;

  @override
  Future<void> delete(String path) async {
    if (failing.contains(path)) throw FileSystemException('forced delete failure', path);
    return super.delete(path);
  }
}
