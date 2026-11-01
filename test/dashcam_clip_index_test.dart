import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
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
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

// Fase 16.2-R4.4-R1 — the clip index's one writer (`ensureClipIndexed`), the
// startup reconciliation and the session deletion's selection of canonical
// files, at the persistence layer: real Hive in a temporary directory,
// path_provider mocked to it, real files under `dashcam_clips/`.
//
// A "restart" closes every box and reopens it from its file — a new process as
// far as the disk is concerned: nothing cached answers. Process-wide state
// survives it (the committed deletions, the per-clip reports, the index FIFO):
// every test uses its own session ids and its own clip namespace, so nothing
// leaks between tests. Real cross-process kills (dart:io exit) are in the
// round's report (scratchpad/fase16_2_r4_4_r1_implementation/04_kill).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory clipsDir;
  late String ns;
  var rid = 0;
  var videosWrites = 0;
  var sessionsWrites = 0;
  bool Function()? onSessionsWrite;
  final t0 = DateTime(2026, 10, 24, 9);

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  Box videos() => Hive.box(HiveBoxNames.dashcamSessionVideos);

  Future<void> openBoxes() async {
    await Hive.openBox<DrivingSession>(
      HiveBoxNames.drivingSessions,
      compactionStrategy: (entries, deleted) {
        sessionsWrites++;
        return onSessionsWrite?.call() ?? false;
      },
    );
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    await Hive.openBox(
      HiveBoxNames.dashcamSessionVideos,
      compactionStrategy: (entries, deleted) {
        videosWrites++;
        return false;
      },
    );
  }

  /// Every box closed and reopened from its file.
  Future<void> restart() async {
    await Hive.close();
    await openBoxes();
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dashcam_clip_index_test');
    clipsDir = Directory('${dir.path}/$dashcamClipsDirectoryName')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
      Hive.registerAdapter(VideoResolutionAdapter());
      Hive.registerAdapter(DashcamClipRecordAdapter());
    }
    ns = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padRight(32, 'c');
    rid = 0;
    videosWrites = 0;
    sessionsWrites = 0;
    onSessionsWrite = null;
    afterReconciledClipHookForTest = null;
    Hive.init(dir.path);
    await openBoxes();
  });

  tearDown(() async {
    afterReconciledClipHookForTest = null;
    onSessionsWrite = null;
    Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
    Hive.registerAdapter<DashcamClipRecord>(DashcamClipRecordAdapter(), override: true);
    final obstacle = Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec');
    if (obstacle.existsSync()) obstacle.deleteSync(recursive: true);
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, null);
    dir.deleteSync(recursive: true);
  });

  DashcamClipDescriptor clip(String sessionId, {int? recordingId, DateTime? at, int duration = 3, bool protected = false, String? namespace}) {
    final id = recordingId ?? ++rid;
    return DashcamClipDescriptor.tryCreate(
      sessionId: sessionId,
      recordedAt: at ?? t0.add(Duration(seconds: id)),
      namespace: namespace ?? ns,
      recordingId: id,
      durationSeconds: duration,
      isProtected: protected,
      resolution: VideoResolution.fhd1080,
      audioEnabled: true,
    )!;
  }

  String pathOf(DashcamClipDescriptor d) => '${clipsDir.path}/${d.basename}';

  /// The canonical file of [d], [size] bytes — a clip published under its name.
  String publish(DashcamClipDescriptor d, {int size = 64}) {
    File(pathOf(d)).writeAsBytesSync(List<int>.filled(size, 1));
    return pathOf(d);
  }

  Future<void> session(String id, {bool marked = false}) =>
      sessions().put(id, DrivingSession(id: id, startTime: t0, endTime: t0.add(const Duration(minutes: 5)), deletionPending: marked));

  List<DashcamClipRecord> indexed(String id) => List<DashcamClipRecord>.from(videos().get(id) as List? ?? const []);
  List<String> indexedNames(String id) => [for (final r in indexed(id)) dashcamClipBasename(r.filePath)];

  Future<ClipIndexOutcome> produced(String path, {bool protectedNow = false, ClipIndexWriteHook? hook, List<String>? reports}) =>
      ensureClipIndexed(path, origin: ClipIndexOrigin.producedInThisProcess, protectedNow: protectedNow, writeHookForTest: hook, report: reports?.add);

  Future<ClipIndexOutcome> recovered(String path, {List<String>? reports}) => ensureClipIndexed(path, origin: ClipIndexOrigin.recovered, report: reports?.add);

  Future<List<FlutterErrorDetails>> capturingFlutterErrors(Future<void> Function() body) async {
    final reported = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    FlutterError.onError = reported.add;
    try {
      await body();
    } finally {
      FlutterError.onError = original;
    }
    return reported;
  }

  group('Fase 16.2-R4.4-R1 — ensureClipIndexed', () {
    test('X433 — normal: the record is f(name, size) — every field from the canonical name, the size from the file — and reads back IDENTICAL after a restart (ms on both sides)', () async {
      const s = 'X433-S';
      await session(s);
      final d = clip(s, protected: true);
      final path = publish(d, size: 777);
      expect(await produced(path), ClipIndexOutcome.indexed);
      DashcamClipRecord only() => indexed(s).single;
      List<Object> fields(DashcamClipRecord r) => [r.filePath, r.recordedAt, r.recordedAt.isUtc, r.durationSeconds, r.sizeBytes, r.isProtected, r.resolution, r.audioEnabled];
      final inMemory = fields(only());
      expect(inMemory, [path, d.recordedAt, false, 3, 777, true, VideoResolution.fhd1080, true]);
      await restart();
      expect(fields(only()), inMemory, reason: 'the record rebuilt from the name is the record Hive gives back');
    });

    test('X434 — already indexed and repeated: N calls leave ONE entry; once present, no write happens at all (the hook is not even called)', () async {
      const s = 'X434-S';
      await session(s);
      final path = publish(clip(s));
      var hookCalls = 0;
      Future<void> hook(String sid, List<String> paths, Future<void> Function() write) async {
        hookCalls++;
        await write();
      }

      expect(await produced(path, hook: hook), ClipIndexOutcome.indexed);
      final writesAfterFirst = videosWrites;
      for (var i = 0; i < 5; i++) {
        expect(await produced(path, hook: hook), ClipIndexOutcome.alreadyIndexed);
        expect(await recovered(path), ClipIndexOutcome.alreadyIndexed);
      }
      expect(indexed(s), hasLength(1));
      expect(hookCalls, 1);
      expect(videosWrites, writesAfterFirst, reason: 'no write for a clip already there');
    });

    test('X435 — retry after a failure: a failed write is pending (reported ONCE per clip, however many attempts fail) and the next attempt indexes it — one entry', () async {
      const s = 'X435-S';
      await session(s);
      final path = publish(clip(s));
      final reports = <String>[];
      Future<void> failing(String sid, List<String> paths, Future<void> Function() write) async => throw StateError('injected index write failure');
      expect(await produced(path, hook: failing, reports: reports), ClipIndexOutcome.indexPending);
      expect(await produced(path, hook: failing, reports: reports), ClipIndexOutcome.indexPending);
      expect(indexed(s), isEmpty);
      expect(reports, hasLength(1));
      expect(reports.single, contains(s));
      expect(await produced(path, reports: reports), ClipIndexOutcome.indexed);
      expect(indexed(s), hasLength(1));
      expect(reports, hasLength(1));
    });

    test('X436 — ambiguous persistence results: a write that fails BEFORE taking effect is rolled back (the retry writes it once); one that wrote its frame and THEN failed is in memory and on disk (the retry writes nothing; a restart and a reconciliation find it once)', () async {
      const s = 'X436-S';
      await session(s);
      final before = publish(clip(s));
      final failingAdapter = _WriteFailingClipRecordAdapter();
      Hive.registerAdapter<DashcamClipRecord>(failingAdapter, override: true);
      failingAdapter.armed = true;
      expect(await produced(before), ClipIndexOutcome.indexPending);
      failingAdapter.armed = false;
      expect(indexed(s), isEmpty, reason: 'rolled back from memory');
      expect(await produced(before), ClipIndexOutcome.indexed);
      expect(indexed(s), hasLength(1));

      final after = publish(clip(s));
      Future<void> writesThenFails(String sid, List<String> paths, Future<void> Function() write) async {
        await write();
        throw StateError('injected failure after the frame was written');
      }

      expect(await produced(after, hook: writesThenFails), ClipIndexOutcome.indexPending);
      expect(indexed(s), hasLength(2), reason: 'the effect is there although the write "failed"');
      expect(await produced(after), ClipIndexOutcome.alreadyIndexed, reason: 'never a second entry');
      await restart();
      expect(indexedNames(s), [dashcamClipBasename(before), dashcamClipBasename(after)]);
      final result = await reconcileCanonicalClipsAtStartup();
      expect(result.of(ClipIndexOutcome.alreadyIndexed), 2);
      expect(indexed(s), hasLength(2));
    });

    test('X437 — identity: the same name under another directory is the same clip (no rewrite, path drift is P3); the same clip id under ANOTHER name — in this session or in another — is a conflict: nothing written, nothing re-attributed, reported once', () async {
      const s = 'X437-S';
      const other = 'X437-T';
      await session(s);
      await session(other);
      final d = clip(s);
      final path = publish(d);
      await videos().put(s, [
        DashcamClipRecord(filePath: '/storage/moved/${d.basename}', recordedAt: d.recordedAt, durationSeconds: 3, sizeBytes: 64, resolution: VideoResolution.fhd1080, audioEnabled: true),
      ]);
      expect(await produced(path), ClipIndexOutcome.alreadyIndexed);
      expect(indexed(s).single.filePath, '/storage/moved/${d.basename}', reason: 'not rewritten');

      // Same clip id, another name (another duration) in the same session.
      final twin = clip(s, recordingId: d.recordingId, duration: 9, at: d.recordedAt);
      expect(twin.clipId, d.clipId);
      final twinPath = publish(twin);
      final reports = <String>[];
      expect(await produced(twinPath, reports: reports), ClipIndexOutcome.identityConflict);
      expect(await recovered(twinPath, reports: reports), ClipIndexOutcome.identityConflict);
      expect(indexed(s), hasLength(1));
      expect(reports, hasLength(1));

      // Same clip id named for ANOTHER session, while the first is indexed under s.
      final foreign = clip(other, recordingId: d.recordingId, at: d.recordedAt);
      expect(foreign.clipId, d.clipId);
      expect(await produced(publish(foreign)), ClipIndexOutcome.identityConflict);
      expect(videos().containsKey(other), isFalse, reason: 'evidence is never re-attributed');
      expect(File(twinPath).existsSync() && File(pathOf(foreign)).existsSync() && File(path).existsSync(), isTrue, reason: 'every file preserved');
    });

    test('X438 — protection is MONOTONIC: false → true is written (and survives a restart); true never goes back to false — not from a name published unprotected, not from a recovery, not from another produced call', () async {
      const s = 'X438-S';
      await session(s);
      final path = publish(clip(s));
      expect(await produced(path), ClipIndexOutcome.indexed);
      expect(indexed(s).single.isProtected, isFalse);
      expect(await produced(path, protectedNow: true), ClipIndexOutcome.protectionRaised);
      expect(indexed(s).single.isProtected, isTrue);
      expect(await produced(path, protectedNow: true), ClipIndexOutcome.alreadyIndexed);
      expect(await produced(path), ClipIndexOutcome.alreadyIndexed);
      expect(await recovered(path), ClipIndexOutcome.alreadyIndexed);
      expect(indexed(s).single.isProtected, isTrue);
      await restart();
      expect(indexed(s).single.isProtected, isTrue);
      await reconcileCanonicalClipsAtStartup();
      expect(indexed(s).single.isProtected, isTrue, reason: 'the name still says p=0 — the entry stays protected');

      // Published protected: indexed protected, and a later call cannot lower it.
      final protectedPath = publish(clip(s, protected: true));
      expect(await recovered(protectedPath), ClipIndexOutcome.indexed);
      expect(indexed(s).last.isProtected, isTrue);
      expect(indexed(s), hasLength(2));
    });

    test('X439 — concurrency: two callers (and ten, of both origins) for ONE clip leave one entry; two clips of one session indexed concurrently, out of order, are both there in clip order; a legacy entry keeps its place', () async {
      const s = 'X439-S';
      await session(s);
      final path = publish(clip(s));
      final pair = await Future.wait([produced(path), produced(path)]);
      expect(pair.toSet(), {ClipIndexOutcome.indexed, ClipIndexOutcome.alreadyIndexed});
      final crowd = await Future.wait([for (var i = 0; i < 10; i++) i.isEven ? produced(path) : recovered(path)]);
      expect(crowd, everyElement(ClipIndexOutcome.alreadyIndexed));
      expect(indexed(s), hasLength(1));

      const u = 'X439-U';
      await session(u);
      final legacy = DashcamClipRecord(filePath: '${clipsDir.path}/clip_123.mp4', recordedAt: t0.add(const Duration(seconds: 15)));
      await videos().put(u, [legacy]);
      final late = clip(u, recordingId: 30, at: t0.add(const Duration(seconds: 30)));
      final early = clip(u, recordingId: 10, at: t0.add(const Duration(seconds: 10)));
      final same = clip(u, recordingId: 9, at: t0.add(const Duration(seconds: 30)));
      await Future.wait([produced(publish(late)), produced(publish(early)), recovered(publish(same))]);
      expect(indexedNames(u), [early.basename, 'clip_123.mp4', same.basename, late.basename],
          reason: 'by time, then recording id; the legacy entry stays where it was');
    });

    test('X440 — the FIFO turn ends when a write SETTLES, not when its caller resumes: a hook holding AFTER its write delays only its own caller (R2.2-X7); a hook holding BEFORE its write holds the queue, and a deletion committed meanwhile is seen by the write when it runs (X96): refused, the file discarded', () async {
      const a = 'X440-A';
      const b = 'X440-B';
      await session(a);
      await session(b);
      final written = Completer<void>();
      final release = Completer<void>();
      final first = produced(publish(clip(a)), hook: (sid, paths, write) async {
        await write();
        written.complete();
        await release.future;
      });
      await written.future;
      expect(await produced(publish(clip(b))), ClipIndexOutcome.indexed, reason: 'B is not held behind A\'s caller');
      release.complete();
      expect(await first, ClipIndexOutcome.indexed);

      const c = 'X440-C';
      await session(c);
      final entered = Completer<void>();
      final hold = Completer<void>();
      final heldPath = publish(clip(c));
      final held = produced(heldPath, hook: (sid, paths, write) async {
        entered.complete();
        await hold.future;
        await write();
      });
      await entered.future;
      var queuedDone = false;
      final queued = produced(publish(clip(b)))..then((_) => queuedDone = true);
      await deleteDrivingSession(c);
      await pumpEventQueue();
      expect(queuedDone, isFalse, reason: 'the write in its hook has not run: the queue waits for it');
      hold.complete();
      expect(await held, ClipIndexOutcome.deletionRefused);
      expect(videos().containsKey(c), isFalse);
      expect(File(heldPath).existsSync(), isFalse);
      expect(await queued, ClipIndexOutcome.indexed);
    });

    test('X441 — not a clip to index: a non-canonical name, a missing file, a 0-byte file, a directory under a canonical name — nothing written, nothing deleted', () async {
      const s = 'X441-S';
      await session(s);
      final legacy = File('${clipsDir.path}/clip_1791348535280.mp4')..writeAsBytesSync([1]);
      expect(await produced(legacy.path), ClipIndexOutcome.invalidName);
      expect(await produced(pathOf(clip(s))), ClipIndexOutcome.notPresent);
      final empty = clip(s);
      File(pathOf(empty)).writeAsBytesSync(const []);
      expect(await produced(pathOf(empty)), ClipIndexOutcome.emptyPreserved);
      final asDirectory = clip(s);
      Directory(pathOf(asDirectory)).createSync();
      expect(await recovered(pathOf(asDirectory)), ClipIndexOutcome.notPresent);
      expect(videos().containsKey(s), isFalse);
      expect(legacy.existsSync() && File(pathOf(empty)).existsSync() && Directory(pathOf(asDirectory)).existsSync(), isTrue);
    });

    test('X442 — the index never writes a session record: whatever ensureClipIndexed and the reconciliation do, the sessions box is not written and its file is byte-identical (R2.6.11–R2.6.13)', () async {
      const s = 'X442-S';
      const marked = 'X442-M';
      await session(s);
      await session(marked, marked: true);
      final file = File('${dir.path}/${HiveBoxNames.drivingSessions}.hive');
      final bytes = file.readAsBytesSync();
      final writes = sessionsWrites;
      final path = publish(clip(s));
      await produced(path);
      await produced(path, protectedNow: true);
      await recovered(publish(clip(s)));
      await recovered(publish(clip(marked)));
      await recovered(publish(clip('X442-absent')));
      await reconcileCanonicalClipsAtStartup();
      expect(sessionsWrites, writes);
      expect(file.readAsBytesSync(), bytes);
      expect(sessions().containsKey('X442-absent'), isFalse, reason: 'no session is created for an orphan');
    });
  });

  group('Fase 16.2-R4.4-R1 — deletion guards', () {
    test('X443 — runtime, COMMITTED deletion: a clip produced afterwards is refused and its file discarded; found at startup with the record gone it is an orphan, preserved', () async {
      const s = 'X443-S';
      await session(s);
      await deleteDrivingSession(s);
      expect(sessionDeletionCommitted(s), isTrue);
      final late = publish(clip(s));
      expect(await produced(late), ClipIndexOutcome.deletionRefused);
      expect(File(late).existsSync(), isFalse);
      expect(videos().containsKey(s), isFalse);
      final later = publish(clip(s));
      expect(await recovered(later), ClipIndexOutcome.orphanPreserved);
      expect(File(later).existsSync(), isTrue);
      expect(sessions().containsKey(s), isFalse);
    });

    test('X444 — runtime, record ABSENT but nothing committed (a START whose put failed): the clip is indexed (frozen X98); at startup the same state is an orphan — not indexed, not deleted, no record created', () async {
      const s = 'X444-S';
      final path = publish(clip(s));
      expect(await recovered(path), ClipIndexOutcome.orphanPreserved);
      expect(videos().containsKey(s), isFalse);
      expect(File(path).existsSync(), isTrue);
      expect(sessions().containsKey(s), isFalse);
      expect(await produced(path), ClipIndexOutcome.indexed);
      expect(indexed(s), hasLength(1));
    });

    test('X445 — a deletion whose marker write FAILED decides nothing at runtime (frozen X113): the cached record reads as marked, but nothing is committed — a produced clip is indexed and kept; a recovered one is held back (marked, as far as this process can tell); after a restart the disk has no marker and the reconciliation indexes it', () async {
      const s = 'X445-S';
      await session(s);
      final failing = _WriteFailingSessionAdapter();
      Hive.registerAdapter<DrivingSession>(failing, override: true);
      failing.armed = true;
      Object? error;
      try {
        await deleteDrivingSession(s);
      } catch (e) {
        error = e;
      }
      failing.armed = false;
      Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
      expect(error, isA<StateError>(), reason: 'setup: the marker\'s write failed before taking effect');
      expect(sessions().get(s)!.deletionPending, isTrue, reason: 'setup: the cached record is not presumed rolled back');
      expect(sessionDeletionCommitted(s), isFalse);

      final producedPath = publish(clip(s));
      expect(await produced(producedPath), ClipIndexOutcome.indexed);
      expect(File(producedPath).existsSync(), isTrue);
      final recoveredPath = publish(clip(s));
      expect(await recovered(recoveredPath), ClipIndexOutcome.deletionBlocked);
      expect(File(recoveredPath).existsSync(), isTrue);

      await restart();
      expect(sessions().get(s)!.deletionPending, isFalse, reason: 'the marker never reached the disk');
      await recoverDrivingSessionsAtStartup();
      final result = await reconcileCanonicalClipsAtStartup();
      expect(result.of(ClipIndexOutcome.indexed), 1);
      expect(indexedNames(s), [dashcamClipBasename(producedPath), dashcamClipBasename(recoveredPath)]);
    });
  });

  group('Fase 16.2-R4.4-R1 — startup reconciliation', () {
    test('X446 — the whole directory at once: canonical clips of known sessions are indexed (once, in clip order, each under its own session); already indexed, orphan, marked-for-deletion, duplicated identity, empty, partial, legacy, plugin, other-version, malformed names and directories are left EXACTLY as they are; a second run and a restart write nothing more', () async {
      const s1 = 'X446-S1';
      const s2 = 'X446-S2';
      const marked = 'X446-M';
      const orphan = 'X446-O';
      await session(s1);
      await session(s2);
      await session(marked, marked: true);

      final a = clip(s1);
      final b = clip(s1);
      final already = clip(s1);
      publish(already);
      expect(await produced(pathOf(already)), ClipIndexOutcome.indexed);
      publish(b);
      publish(a);
      final c2 = publish(clip(s2));
      final dupA = clip(s2, recordingId: 500, duration: 3);
      final dupB = clip(s2, recordingId: 500, duration: 4, at: dupA.recordedAt);
      publish(dupA);
      publish(dupB);
      final m = publish(clip(marked));
      final o = publish(clip(orphan));
      final empty = clip(s1);
      File(pathOf(empty)).writeAsBytesSync(const []);
      final partial = File('${pathOf(clip(s1))}${DashcamClipDescriptor.partialSuffix}')..writeAsBytesSync([5, 5]);
      final untouchable = [
        File('${clipsDir.path}/clip_1791348535280.mp4'),
        File('${clipsDir.path}/REC4242.mp4'),
        File('${clipsDir.path}/${clip(s1).basename.replaceFirst('clip_v1_', 'clip_v2_')}'),
        File('${clipsDir.path}/${clip(s1).basename.replaceFirst('clip_v1_58', 'clip_v1_5A')}'),
        File('${clipsDir.path}/notes.txt'),
      ];
      for (final f in untouchable) {
        f.writeAsBytesSync([3]);
      }
      final asDirectory = Directory(pathOf(clip(s1)))..createSync();
      final listingBefore = {for (final e in clipsDir.listSync()) dashcamClipBasename(e.path)};

      late DashcamClipReconciliation result;
      final reported = await capturingFlutterErrors(() async => result = await reconcileCanonicalClipsAtStartup());
      expect(reported, hasLength(1), reason: 'one aggregate report: the duplicated identity');
      expect(indexedNames(s1), [already.basename, b.basename, a.basename].toList()..sort((x, y) => DashcamClipDescriptor.compareOrder(DashcamClipDescriptor.parse(x)!, DashcamClipDescriptor.parse(y)!)));
      expect(indexedNames(s2), [dashcamClipBasename(c2)], reason: 'two names with one identity: neither indexed');
      expect(videos().containsKey(marked) || videos().containsKey(orphan), isFalse);
      expect(sessions().containsKey(orphan), isFalse, reason: 'no session created for an orphan');
      expect({for (final e in clipsDir.listSync()) dashcamClipBasename(e.path)}, listingBefore, reason: 'nothing renamed, copied or deleted');
      expect(File(m).existsSync() && File(o).existsSync() && partial.existsSync() && asDirectory.existsSync(), isTrue);
      expect(result.of(ClipIndexOutcome.indexed), 3, reason: 'a, b and the other session\'s clip');
      expect(result.of(ClipIndexOutcome.alreadyIndexed), 1);
      expect(result.of(ClipIndexOutcome.orphanPreserved), 1);
      expect(result.of(ClipIndexOutcome.deletionBlocked), 1);
      expect(result.of(ClipIndexOutcome.emptyPreserved), 1);
      expect(result.duplicateIdentities, 2);
      expect(result.partials, 1);
      expect(result.invalid, untouchable.length + 1, reason: 'the five names and the directory');

      final writes = videosWrites;
      late DashcamClipReconciliation again;
      await capturingFlutterErrors(() async => again = await reconcileCanonicalClipsAtStartup());
      expect(again.of(ClipIndexOutcome.indexed), 0);
      expect(videosWrites, writes, reason: 'the second run writes nothing');
      await restart();
      late DashcamClipReconciliation afterRestart;
      await capturingFlutterErrors(() async => afterRestart = await reconcileCanonicalClipsAtStartup());
      expect(afterRestart.of(ClipIndexOutcome.indexed), 0);
      expect(indexed(s1), hasLength(3));
      expect(indexed(s2), hasLength(1));
    });

    test('X447 — nothing to reconcile or nothing to decide with: no directory → nothing; the boxes not open → aborted and reported, nothing written; a directory that cannot be listed → aborted and reported', () async {
      clipsDir.deleteSync(recursive: true);
      final none = await reconcileCanonicalClipsAtStartup();
      expect(none.seen, 0);
      expect(none.aborted, isFalse);

      clipsDir.createSync();
      const s = 'X447-S';
      await session(s);
      final path = publish(clip(s));
      await Hive.close();
      late DashcamClipReconciliation closed;
      final reported = await capturingFlutterErrors(() async => closed = await reconcileCanonicalClipsAtStartup());
      expect(closed.aborted, isTrue);
      expect(reported, hasLength(1));
      await openBoxes();
      expect(videos().containsKey(s), isFalse, reason: 'nothing decided without the boxes');

      late DashcamClipReconciliation unlistable;
      final reportedList = await capturingFlutterErrors(
        () => IOOverrides.runWithIOOverrides(() async => unlistable = await reconcileCanonicalClipsAtStartup(), _UnlistableClipsDirectory(clipsDir.path)),
      );
      expect(unlistable.aborted, isTrue);
      expect(reportedList, hasLength(1));
      expect(videos().containsKey(s), isFalse);
      expect((await reconcileCanonicalClipsAtStartup()).of(ClipIndexOutcome.indexed), 1, reason: 'once listable, the next start indexes it');
      expect(File(path).existsSync(), isTrue);
    });

    test('X448 — the ensure of the normal flow and the startup reconciliation, run concurrently on the same clip, leave ONE entry', () async {
      const s = 'X448-S';
      await session(s);
      final path = publish(clip(s));
      final results = await Future.wait<Object>([produced(path), reconcileCanonicalClipsAtStartup(), produced(path)]);
      expect(indexed(s), hasLength(1));
      expect((results[1] as DashcamClipReconciliation).seen, 1);
    });
  });

  group('Fase 16.2-R4.4-R1 — process death (simulated: the disk state each cut leaves, then a restart)', () {
    test('X449 — P0/P1 (before the canonical rename): the only artifact is the plugin\'s REC file in the cache, which R1 never reads — the next start indexes nothing and leaves it where it is (D2)', () async {
      const s = 'X449-S';
      await sessions().put(s, DrivingSession(id: s, startTime: t0));
      final cache = Directory('${dir.path}/cache')..createSync();
      final rec = File('${cache.path}/REC88123456.mp4')..writeAsBytesSync(List<int>.filled(1024, 7));
      await restart();
      await recoverDrivingSessionsAtStartup();
      final result = await reconcileCanonicalClipsAtStartup();
      expect(result.seen, 0);
      expect(videos().containsKey(s), isFalse);
      expect(rec.existsSync(), isTrue);
      expect(rec.lengthSync(), 1024);
      expect(sessions().get(s)!.isActive, isFalse, reason: 'the session itself is reclaimed as before');
    });

    test('X450 — P2 (after the rename, before the index): the next start indexes the clip exactly once; every later start writes nothing', () async {
      const s = 'X450-S';
      await session(s);
      publish(clip(s));
      await restart();
      await recoverDrivingSessionsAtStartup();
      expect((await reconcileCanonicalClipsAtStartup()).of(ClipIndexOutcome.indexed), 1);
      expect(indexed(s), hasLength(1));
      for (var i = 0; i < 2; i++) {
        await restart();
        final writes = videosWrites;
        await recoverDrivingSessionsAtStartup();
        await reconcileCanonicalClipsAtStartup();
        expect(videosWrites, writes);
        expect(indexed(s), hasLength(1));
      }
    });

    test('X451 — P3 (during the index write): the frame not written, written only in part (Hive drops a torn last frame on open), or written whole — every case converges to ONE entry at the next start', () async {
      const s = 'X451-S';
      await session(s);
      final file = File('${dir.path}/${HiveBoxNames.dashcamSessionVideos}.hive');

      // Not written: the write failed before taking effect.
      final notWritten = publish(clip(s));
      final failingAdapter = _WriteFailingClipRecordAdapter();
      Hive.registerAdapter<DashcamClipRecord>(failingAdapter, override: true);
      failingAdapter.armed = true;
      expect(await produced(notWritten), ClipIndexOutcome.indexPending);
      failingAdapter.armed = false;
      Hive.registerAdapter<DashcamClipRecord>(DashcamClipRecordAdapter(), override: true);
      await restart();
      expect(videos().containsKey(s), isFalse);
      await reconcileCanonicalClipsAtStartup();
      expect(indexedNames(s), [dashcamClipBasename(notWritten)]);

      // Torn: the last frame cut short.
      final torn = publish(clip(s));
      expect(await produced(torn), ClipIndexOutcome.indexed);
      await Hive.close();
      final bytes = file.readAsBytesSync();
      file.writeAsBytesSync(bytes.sublist(0, bytes.length - 5));
      await openBoxes();
      expect(indexedNames(s), [dashcamClipBasename(notWritten)], reason: 'the torn frame was discarded on open');
      await reconcileCanonicalClipsAtStartup();
      expect(indexedNames(s), [dashcamClipBasename(notWritten), dashcamClipBasename(torn)]);

      // Whole: written, the process gone before the write returned.
      final whole = publish(clip(s));
      expect(await produced(whole), ClipIndexOutcome.indexed);
      await restart();
      final result = await reconcileCanonicalClipsAtStartup();
      expect(result.of(ClipIndexOutcome.indexed), 0);
      expect(indexed(s), hasLength(3));
    });

    test('X452 — P4 (after the index): restarts and reconciliations never duplicate', () async {
      const s = 'X452-S';
      await session(s);
      for (var i = 0; i < 3; i++) {
        expect(await produced(publish(clip(s))), ClipIndexOutcome.indexed);
      }
      for (var i = 0; i < 3; i++) {
        await restart();
        await reconcileCanonicalClipsAtStartup();
        expect(indexed(s), hasLength(3));
      }
    });

    test('X453 — P5 (during the startup reconciliation): killed after its first clip, the next start completes the rest — each clip once', () async {
      const s = 'X453-S';
      await session(s);
      final paths = [for (var i = 0; i < 3; i++) publish(clip(s))];
      afterReconciledClipHookForTest = (path, outcome) async => throw StateError('the process dies here');
      final reported = await capturingFlutterErrors(() async {
        final first = await reconcileCanonicalClipsAtStartup();
        expect(first.aborted, isTrue);
      });
      expect(reported, hasLength(1));
      afterReconciledClipHookForTest = null;
      expect(indexed(s), hasLength(1), reason: 'the death left one clip indexed');
      await restart();
      await reconcileCanonicalClipsAtStartup();
      expect(indexedNames(s), [for (final p in paths) dashcamClipBasename(p)]);
      await restart();
      final writes = videosWrites;
      await reconcileCanonicalClipsAtStartup();
      expect(videosWrites, writes);
    });
  });

  group('Fase 16.2-R4.4-R1 — the session deletion and canonical files', () {
    test('X454 — the deletion removes the session\'s indexed AND unindexed canonical clips and its partials; another session\'s files, a name that only looks like the session\'s, legacy and invalid names, and a canonical file another session\'s index names are left alone', () async {
      const s = 'X454-S';
      const t = 'X454-T';
      await session(s);
      await session(t);
      final indexedOfS = publish(clip(s));
      expect(await produced(indexedOfS), ClipIndexOutcome.indexed);
      final unindexedOfS = publish(clip(s));
      final partialOfS = File('${pathOf(clip(s))}${DashcamClipDescriptor.partialSuffix}')..writeAsBytesSync([1]);
      final legacyOfS = File('${clipsDir.path}/clip_x454_legacy.mp4')..writeAsBytesSync([1]);
      await videos().put(s, [...indexed(s), DashcamClipRecord(filePath: legacyOfS.path, recordedAt: t0)]);
      final referencedByT = publish(clip(s));
      await videos().put(t, [DashcamClipRecord(filePath: referencedByT, recordedAt: t0)]);
      final ofT = publish(clip(t));
      final lookalike = File('${clipsDir.path}/${clip(s).basename.replaceFirst('clip_v1_58', 'clip_v1_5A')}')..writeAsBytesSync([1]);
      final unindexedLegacy = File('${clipsDir.path}/clip_999.mp4')..writeAsBytesSync([1]);

      await deleteDrivingSession(s);
      expect(File(indexedOfS).existsSync(), isFalse);
      expect(File(unindexedOfS).existsSync(), isFalse, reason: 'a canonical file is the session\'s video even without an index entry');
      expect(partialOfS.existsSync(), isFalse);
      expect(legacyOfS.existsSync(), isFalse, reason: 'indexed for s');
      expect(File(referencedByT).existsSync(), isTrue, reason: 'another session\'s index names it (R2.6.6 G)');
      expect(File(ofT).existsSync() && lookalike.existsSync() && unindexedLegacy.existsSync(), isTrue);
      expect(videos().containsKey(s) || sessions().containsKey(s), isFalse);

      await restart();
      await recoverDrivingSessionsAtStartup();
      final result = await reconcileCanonicalClipsAtStartup();
      expect(videos().containsKey(s), isFalse, reason: 'nothing resurrects the deleted session');
      expect(indexedNames(t), containsAll([dashcamClipBasename(ofT)]));
      expect(result.of(ClipIndexOutcome.orphanPreserved), 1, reason: 'the canonical file of s another index names: kept, never indexed for s');
    });

    test('X455 — the marker\'s write is AMBIGUOUS (on disk, then the write threw): nothing is removed in this process; the next start completes the deletion — the unindexed canonical file included — before the reconciliation, which then finds nothing of the session', () async {
      const s = 'X455-S';
      await session(s);
      final unindexed = publish(clip(s));
      Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec').createSync();
      var armed = true;
      onSessionsWrite = () {
        final ask = armed;
        armed = false;
        return ask;
      };
      Object? error;
      try {
        await deleteDrivingSession(s);
      } catch (e) {
        error = e;
      }
      onSessionsWrite = null;
      expect(error, isA<FileSystemException>(), reason: 'setup: the write threw after its frame');
      expect(File(unindexed).existsSync(), isTrue, reason: 'nothing removed after the error');
      Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec').deleteSync(recursive: true);

      await restart();
      expect(sessions().get(s)!.deletionPending, isTrue, reason: 'the marker is on disk');
      await recoverDrivingSessionsAtStartup();
      expect(File(unindexed).existsSync(), isFalse);
      expect(sessions().containsKey(s), isFalse);
      final result = await reconcileCanonicalClipsAtStartup();
      expect(result.seen, 0);
      expect(videos().containsKey(s), isFalse);
    });

    test('X456 — a marked session whose deletion fails again at startup stays marked: the reconciliation refuses its canonical file (blocked, preserved, not indexed); once the deletion completes, nothing of it is left or indexed', () async {
      const s = 'X456-S';
      await session(s, marked: true);
      final canonical = publish(clip(s));
      await restart();
      final reported = await capturingFlutterErrors(
        () => IOOverrides.runWithIOOverrides(recoverDrivingSessionsAtStartup, _FailingDeleteOf(canonical)),
      );
      expect(reported, hasLength(1), reason: 'the failed deletion is reported');
      expect(sessions().get(s)!.deletionPending, isTrue);
      final result = await reconcileCanonicalClipsAtStartup();
      expect(result.of(ClipIndexOutcome.deletionBlocked), 1);
      expect(videos().containsKey(s), isFalse);
      expect(File(canonical).existsSync(), isTrue);

      await restart();
      await recoverDrivingSessionsAtStartup();
      expect(File(canonical).existsSync(), isFalse);
      expect(sessions().containsKey(s), isFalse);
      expect((await reconcileCanonicalClipsAtStartup()).seen, 0);
    });

    test('X457 — the deletion and an index write of the same session, in both orders: written before the deletion → removed with it; held before its write while the deletion commits and completes → refused and discarded when it runs. Either way no entry and no file of the session survive', () async {
      const s = 'X457-S';
      await session(s);
      final before = publish(clip(s));
      expect(await produced(before), ClipIndexOutcome.indexed);
      final entered = Completer<void>();
      final hold = Completer<void>();
      final heldPath = publish(clip(s));
      final held = produced(heldPath, hook: (sid, paths, write) async {
        entered.complete();
        await hold.future;
        await write();
      });
      await entered.future;
      await deleteDrivingSession(s);
      expect(File(before).existsSync(), isFalse);
      hold.complete();
      expect(await held, ClipIndexOutcome.deletionRefused);
      expect(File(heldPath).existsSync(), isFalse);
      expect(videos().containsKey(s), isFalse);
      await restart();
      await recoverDrivingSessionsAtStartup();
      expect((await reconcileCanonicalClipsAtStartup()).seen, 0);
    });

    test('X458 — an orphan (canonical file, no record) is preserved by every start; deleting that id explicitly (the marked stand-in of R2.6.7) removes its canonical files', () async {
      const s = 'X458-S';
      final path = publish(clip(s));
      for (var i = 0; i < 2; i++) {
        await restart();
        await recoverDrivingSessionsAtStartup();
        expect((await reconcileCanonicalClipsAtStartup()).of(ClipIndexOutcome.orphanPreserved), 1);
        expect(File(path).existsSync(), isTrue);
        expect(sessions().containsKey(s) || videos().containsKey(s), isFalse);
      }
      await deleteDrivingSession(s);
      expect(File(path).existsSync(), isFalse);
      expect(sessions().containsKey(s), isFalse);
    });

    test('X459 — a clips directory that exists and cannot be listed fails the deletion and KEEPS its marker (a step never swallows its failure); the next attempt completes it, the canonical file included', () async {
      const s = 'X459-S';
      await session(s);
      final canonical = publish(clip(s));
      Object? error;
      try {
        await IOOverrides.runWithIOOverrides(() => deleteDrivingSession(s), _UnlistableClipsDirectory(clipsDir.path));
      } catch (e) {
        error = e;
      }
      expect(error, isA<FileSystemException>());
      expect(File(canonical).existsSync(), isTrue);
      await restart();
      expect(sessions().get(s)!.deletionPending, isTrue, reason: 'the marker is durable');
      await recoverDrivingSessionsAtStartup();
      expect(File(canonical).existsSync(), isFalse);
      expect(sessions().containsKey(s), isFalse);
    });
  });

  // Fase 16.2-R4.4-R1.1 — since IR-P2-01 every in-process retry of a clip
  // marked protected in memory asks for its protection: that must never make
  // the protection a veto on the session's deletion.
  group('Fase 16.2-R4.4-R1.1 — a pending protection is not a veto', () {
    test('X476 — a protection still pending never vetoes a legitimate deletion: the deletion removes a PROTECTED entry and its file like any other; once it is committed, a produced retry carrying the protection is refused and its file discarded; a marked session\'s protected clip is left to its deletion at startup', () async {
      const s = 'X476-S';
      await session(s);
      final protectedClip = publish(clip(s));
      expect(await produced(protectedClip, protectedNow: true), ClipIndexOutcome.indexed);
      expect(indexed(s).single.isProtected, isTrue, reason: 'setup: indexed protected');
      await deleteDrivingSession(s);
      expect(sessionDeletionCommitted(s), isTrue);
      expect(videos().containsKey(s), isFalse, reason: 'the protected entry went with the session');
      expect(File(protectedClip).existsSync(), isFalse, reason: 'and so did its file');

      final late = publish(clip(s));
      expect(await produced(late, protectedNow: true), ClipIndexOutcome.deletionRefused, reason: 'the deletion guard decides before any protection');
      expect(File(late).existsSync(), isFalse, reason: 'discarded (R2.6.7)');
      expect(videos().containsKey(s), isFalse, reason: 'nothing resurrected');
      expect(sessions().containsKey(s), isFalse);

      const m = 'X476-M';
      await session(m, marked: true);
      final marked = publish(clip(m, protected: true));
      expect(await recovered(marked), ClipIndexOutcome.deletionBlocked);
      expect(videos().containsKey(m), isFalse);
      expect(File(marked).existsSync(), isTrue, reason: 'left to the deletion');
    });
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// A clip-record adapter that, while [armed], fails while serializing — before
/// a byte reaches the file: a write that fails BEFORE it takes effect.
class _WriteFailingClipRecordAdapter extends DashcamClipRecordAdapter {
  final _Armed _armed = _Armed();

  bool get armed => _armed.value;
  set armed(bool value) => _armed.value = value;

  @override
  void write(BinaryWriter writer, DashcamClipRecord obj) {
    if (armed) throw StateError('injected failure while serializing a clip record');
    super.write(writer, obj);
  }
}

/// The technique of X102/X113: a session record that fails while serializing.
class _WriteFailingSessionAdapter extends DrivingSessionAdapter {
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

/// The clips directory exists and its listing fails.
final class _UnlistableClipsDirectory extends IOOverrides {
  _UnlistableClipsDirectory(this.clipsPath);
  final String clipsPath;

  @override
  Directory createDirectory(String path) {
    final real = super.createDirectory(path);
    return path.replaceAll(r'\', '/') == clipsPath.replaceAll(r'\', '/') ? _UnlistableDirectory(real) : real;
  }
}

class _UnlistableDirectory implements Directory {
  _UnlistableDirectory(this._real);
  final Directory _real;

  @override
  String get path => _real.path;

  @override
  Future<bool> exists() => _real.exists();

  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      Stream.error(FileSystemException('injected listing failure', _real.path, const OSError('Permission denied', 13)));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_UnlistableDirectory: ${invocation.memberName}');
}

/// Deleting [path] fails (the file stays).
final class _FailingDeleteOf extends IOOverrides {
  _FailingDeleteOf(this.path);
  final String path;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.replaceAll(r'\', '/') == this.path.replaceAll(r'\', '/') ? _UndeletableFile(real) : real;
  }
}

class _UndeletableFile implements File {
  _UndeletableFile(this._real);
  final File _real;

  @override
  String get path => _real.path;

  @override
  Future<bool> exists() => _real.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async =>
      throw FileSystemException('injected delete failure', _real.path, const OSError('Permission denied', 13));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_UndeletableFile: ${invocation.memberName}');
}
