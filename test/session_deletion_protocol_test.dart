import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

// Fase 16.2-R4.3-R2.6.7 — the durable session deletion protocol
// (deleteDrivingSession / completePendingSessionDeletions), at the persistence
// layer: real Hive in a temporary directory, path_provider mocked to it, real
// files. Reproduced before the fix (scratchpad/fase16_2_r4_3_r2_6_7/
// 01_prefix_repro): a deletion interrupted after the record was removed — a
// killed process, a failing box — left index, clip files and telemetry that
// nothing could reach again. Failures are injected at exact points:
//  * a box's compaction-strategy callback runs synchronously right after each
//    of its writes (frame written, the write not returned): the hooks below
//    use it to close ANOTHER box at that instant (Box.close() flips the box to
//    closed before its first await), or to ask for a compaction that fails;
//  * an IOOverrides zone wraps the clip (.mp4) and telemetry (.jsonl) files
//    the deletion creates, to fail or observe their exists()/delete().
// A "restart" closes every box and reopens it from its file. The controller-
// level scenarios (a clip published while or after its session is deleted)
// live in dashcam_session_controller_test.dart (X93–X99).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  bool Function()? onSessionsWrite;
  bool Function()? onSamplesWrite;
  bool Function()? onVideosWrite;
  final pendingCloses = <Future<void>>[];
  final t0 = DateTime(2026, 3, 1, 8);

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  LazyBox samples() => Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
  Box videos() => Hive.box(HiveBoxNames.dashcamSessionVideos);

  Future<void> openBoxes() async {
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions, compactionStrategy: (entries, deleted) => onSessionsWrite?.call() ?? false);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples, compactionStrategy: (entries, deleted) => onSamplesWrite?.call() ?? false);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos, compactionStrategy: (entries, deleted) => onVideosWrite?.call() ?? false);
  }

  /// Closes [box] from inside a hook: the box reads as closed at once, so the
  /// deletion's next operation on it fails.
  void closeNow(BoxBase<dynamic> box) => pendingCloses.add(box.close());

  /// Every box closed and reopened from its file: nothing cached answers.
  Future<void> restart() async {
    await Future.wait(pendingCloses);
    pendingCloses.clear();
    await Hive.close();
    await openBoxes();
  }

  Future<void> reopenIfClosed() async {
    await Future.wait(pendingCloses);
    pendingCloses.clear();
    if (!Hive.isBoxOpen(HiveBoxNames.drivingSessions) ||
        !Hive.isBoxOpen(HiveBoxNames.drivingSessionSamples) ||
        !Hive.isBoxOpen(HiveBoxNames.dashcamSessionVideos)) {
      await restart();
    }
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('session_deletion_protocol_test');
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
    onSessionsWrite = null;
    onSamplesWrite = null;
    onVideosWrite = null;
    Hive.init(dir.path);
    await openBoxes();
  });

  tearDown(() async {
    onSessionsWrite = null;
    onSamplesWrite = null;
    onVideosWrite = null;
    Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
    final obstacle = Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec');
    if (obstacle.existsSync()) obstacle.deleteSync(recursive: true);
    await Future.wait(pendingCloses);
    pendingCloses.clear();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, null);
    dir.deleteSync(recursive: true);
  });

  /// A finalized session: its record, [sampleCount] stored samples, [clipCount]
  /// indexed clip files and a telemetry file — everything a deletion removes.
  Future<_Seeded> seed(String id, {int clipCount = 2}) async {
    const sampleCount = 3;
    await sessions().put(id, DrivingSession(id: id, startTime: t0, endTime: t0.add(const Duration(minutes: 1)), sampleCount: sampleCount));
    await samples().put(id, [for (var i = 0; i < sampleCount; i++) DrivingSessionSample(timestamp: t0.add(Duration(seconds: i)), speedKmh: 40.0 + i)]);
    final clipsDir = Directory('${dir.path}/dashcam_clips')..createSync(recursive: true);
    final clips = [for (var i = 0; i < clipCount; i++) File('${clipsDir.path}/clip_${id}_$i.mp4')..writeAsBytesSync(List<int>.filled(64, i))];
    await videos().put(id, [for (final f in clips) DashcamClipRecord(filePath: f.path, recordedAt: t0, durationSeconds: 6, sizeBytes: 64)]);
    final telemetry = await DashcamTelemetryWriter.fileForSession(id);
    telemetry.writeAsStringSync('{"t":0}\n');
    return (id: id, clips: clips, telemetry: telemetry);
  }

  /// What exists of [s], in the boxes as they are and on the filesystem.
  Future<String> stateOf(_Seeded s) async {
    final record = sessions().get(s.id);
    final stored = await samples().get(s.id) as List?;
    return 'record=${record == null ? 'absent' : record.deletionPending ? 'marked' : 'present'} '
        'samples=${stored?.length} '
        'index=${videos().containsKey(s.id) ? (videos().get(s.id) as List).length : 'absent'} '
        'clipFiles=${s.clips.where((f) => f.existsSync()).length} '
        'telemetry=${s.telemetry.existsSync()}';
  }

  const intact = 'record=present samples=3 index=2 clipFiles=2 telemetry=true';
  const nothingLeft = 'record=absent samples=null index=absent clipFiles=0 telemetry=false';

  group('Fase 16.2-R4.3-R2.6.7 — durable session deletion', () {
    test('X100 — a finalized session is deleted: its record is marked and WRITTEN before anything is removed, the deletion is committed right after, then samples, clip files, index, telemetry and — last — the record go; another session is untouched', () async {
      final a = await seed('X100-A');
      final b = await seed('X100-B');
      final log = <String>[];
      onSessionsWrite = () {
        final record = sessions().get('X100-A');
        log.add(record == null ? 'record removed' : 'record written (marked=${record.deletionPending}, committed=${sessionDeletionCommitted('X100-A')})');
        return false;
      };
      onSamplesWrite = () {
        log.add('samples removed (committed=${sessionDeletionCommitted('X100-A')})');
        return false;
      };
      onVideosWrite = () {
        log.add('index removed');
        return false;
      };

      final error = await _withFileHooks(() => _errorOf(deleteDrivingSession('X100-A')), (path, op) {
        if (op == 'deleted') log.add('${path.endsWith('.jsonl') ? 'telemetry' : 'clip'} file deleted');
      });

      expect(error, isNull);
      expect(log, [
        'record written (marked=true, committed=false)', // the marker's frame is on disk; nothing removed yet
        'samples removed (committed=true)', // committed in the slice the marker's write returned
        'clip file deleted',
        'clip file deleted',
        'index removed',
        'telemetry file deleted',
        'record removed',
      ]);
      expect(sessionDeletionCommitted('X100-A'), isTrue, reason: 'kept for the rest of the process');
      expect(await stateOf(a), nothingLeft);
      expect(await stateOf(b), intact);
      await restart();
      expect(await stateOf(a), nothingLeft, reason: 'on disk too');
      expect(await stateOf(b), intact);
    });

    test('X101 — restart between checkpoints: a deletion interrupted right after the marker, the samples, the clip files, the index, the telemetry or the record leaves exactly that durable state, never an orphan without its marked record; the recovery at the next start completes it (twice is a no-op) and touches no other session', () async {
      final reported = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
      try {
        for (final (cut, expected) in [
          ('marker', 'record=marked samples=3 index=2 clipFiles=2 telemetry=true'),
          ('samples', 'record=marked samples=null index=2 clipFiles=2 telemetry=true'),
          ('clip files', 'record=marked samples=null index=2 clipFiles=0 telemetry=true'),
          ('index', 'record=marked samples=null index=absent clipFiles=0 telemetry=true'),
          ('telemetry', 'record=marked samples=null index=absent clipFiles=0 telemetry=false'),
          ('record', nothingLeft),
        ]) {
          final a = await seed('X101-A-$cut');
          final b = await seed('X101-B-$cut');
          var clipDeletes = 0;
          var armed = true;
          // The step AFTER the cut fails, so the durable state is the cut's.
          if (cut == 'marker') {
            onSessionsWrite = () {
              if (armed) closeNow(samples()); // inside the marker's write
              armed = false;
              return false;
            };
          }
          final error = await _withFileHooks(() => _errorOf(deleteDrivingSession(a.id)), (path, op) {
            final isClip = path.endsWith('.mp4');
            if (cut == 'samples' && isClip && op == 'delete') throw FileSystemException('injected: clip file not deletable', path);
            if (cut == 'clip files' && isClip && op == 'deleted' && ++clipDeletes == 2) closeNow(videos());
            if (cut == 'index' && !isClip && op == 'delete') throw FileSystemException('injected: telemetry file not deletable', path);
            if (cut == 'telemetry' && !isClip && op == 'deleted') closeNow(sessions());
          });
          onSessionsWrite = null;
          expect(error == null, cut == 'record', reason: 'cut after $cut: setup — the next step failed');

          await restart(); // a new process: only the disk answers
          expect(await stateOf(a), expected, reason: 'cut after $cut: the durable state');
          expect(await stateOf(b), intact, reason: 'cut after $cut: B untouched');

          await completePendingSessionDeletions();
          expect(await stateOf(a), nothingLeft, reason: 'cut after $cut: completed at the start');
          expect(await stateOf(b), intact, reason: 'cut after $cut: B untouched by the recovery');
          await completePendingSessionDeletions();
          await restart();
          expect(await stateOf(a), nothingLeft, reason: 'cut after $cut: completed on disk; a second recovery changes nothing');
          expect(await stateOf(b), intact);
        }
        expect(reported, isEmpty, reason: 'every recovery succeeded');
      } finally {
        FlutterError.onError = originalOnError;
      }
    });

    test('X102 — the marker\'s write fails before taking effect: the deletion stops there (nothing removed, nothing committed); the in-memory record is not presumed rolled back; on disk the session is intact and a restart leaves it alone; a new deletion then completes', () async {
      final a = await seed('X102-A');
      final failing = _WriteFailingSessionAdapter();
      Hive.registerAdapter<DrivingSession>(failing, override: true);
      failing.armed = true;
      final error = await _errorOf(deleteDrivingSession('X102-A'));
      failing.armed = false;

      expect(error, isA<StateError>().having((e) => e.message, 'message', contains('injected')));
      expect(sessionDeletionCommitted('X102-A'), isFalse, reason: 'a clip of A published now would still be indexed');
      expect(await stateOf(a), 'record=marked samples=3 index=2 clipFiles=2 telemetry=true',
          reason: 'nothing removed; the cached record reads as what may be on disk (a failed write is not presumed rolled back)');

      await restart();
      expect(await stateOf(a), intact, reason: 'the write never took effect: no durable intent');
      await completePendingSessionDeletions();
      expect(await stateOf(a), intact, reason: 'nothing to complete: the session was never durably marked');

      await deleteDrivingSession('X102-A');
      expect(await stateOf(a), nothingLeft);
    });

    test('X103 — the marker\'s write is AMBIGUOUS (its frame is written, then the write throws): the error reaches the caller and nothing is removed after it (no blind continuation), nothing is committed; the marker is on disk, so the next start completes the deletion', () async {
      final a = await seed('X103-A');
      final b = await seed('X103-B');
      // Hive compacts after the frame is written; a directory where the
      // compaction file must go makes that compaction — and the write — throw.
      Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec').createSync();
      var armed = true;
      onSessionsWrite = () {
        final ask = armed;
        armed = false;
        return ask;
      };
      final error = await _errorOf(deleteDrivingSession('X103-A'));
      onSessionsWrite = null;

      expect(error, isA<FileSystemException>(), reason: 'setup: the write threw after its frame');
      expect(sessionDeletionCommitted('X103-A'), isFalse);
      expect(await stateOf(a), 'record=marked samples=3 index=2 clipFiles=2 telemetry=true', reason: 'nothing removed after the error');

      Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec').deleteSync(recursive: true);
      await restart();
      expect(await stateOf(a), 'record=marked samples=3 index=2 clipFiles=2 telemetry=true', reason: 'the marker IS on disk');
      await completePendingSessionDeletions();
      expect(await stateOf(a), nothingLeft);
      expect(await stateOf(b), intact);
    });

    test('X104 — the index removal fails after the clip files were deleted: the record stays marked; the retry finds the indexed files already gone, which is not an error, and completes', () async {
      final a = await seed('X104-A');
      var clipDeletes = 0;
      final error = await _withFileHooks(() => _errorOf(deleteDrivingSession('X104-A')), (path, op) {
        if (path.endsWith('.mp4') && op == 'deleted' && ++clipDeletes == 2) closeNow(videos());
      });
      expect(error, isA<HiveError>(), reason: 'setup: the index box became unavailable');
      await reopenIfClosed();
      expect(await stateOf(a), 'record=marked samples=null index=2 clipFiles=0 telemetry=true');

      await deleteDrivingSession('X104-A');
      expect(await stateOf(a), nothingLeft);
    });

    test('X105 — a clip file that cannot be deleted fails the deletion (the other files are still tried) and keeps both its index and the marker — the recovery does not declare it done either; once deletable, the retry completes, and a file that vanished between the check and the delete is not an error', () async {
      final a = await seed('X105-A');
      final reported = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
      try {
        void lockFirstClip(String path, String op) {
          if (path == a.clips[0].path && op == 'delete') throw FileSystemException('injected: in use', path);
        }

        final error = await _withFileHooks(() => _errorOf(deleteDrivingSession('X105-A')), lockFirstClip);
        expect(error, isA<FileSystemException>());
        expect(await stateOf(a), 'record=marked samples=null index=2 clipFiles=1 telemetry=true',
            reason: 'the other clip was deleted; the index still names the one left, and the telemetry step was not reached');

        await _withFileHooks(completePendingSessionDeletions, lockFirstClip);
        expect(reported, hasLength(1), reason: 'the recovery reports it');
        expect(await stateOf(a), 'record=marked samples=null index=2 clipFiles=1 telemetry=true', reason: 'and does not declare it done');

        // Deletable again — and it disappears (e.g. storage quota) between exists() and delete().
        final retry = await _withFileHooks(() => _errorOf(deleteDrivingSession('X105-A')), (path, op) {
          if (path == a.clips[0].path && op == 'delete') {
            a.clips[0].deleteSync();
            throw PathNotFoundException(path, const OSError('injected: vanished'));
          }
        });
        expect(retry, isNull);
        expect(await stateOf(a), nothingLeft);
      } finally {
        FlutterError.onError = originalOnError;
      }
    });

    test('X106 — idempotent repetition: a concurrent deletion of the same session joins the one running (one marker, one removal); deleting it again once gone, or running the recovery with nothing pending, changes nothing; the startup reclaim leaves a marked record to the recovery', () async {
      final a = await seed('X106-A');
      final b = await seed('X106-B');
      var sessionsWrites = 0;
      onSessionsWrite = () {
        sessionsWrites++;
        return false;
      };
      final gate = Completer<void>();
      final entered = Completer<void>();
      final first = _withFileHooks(() => _errorOf(deleteDrivingSession('X106-A')), (path, op) async {
        if (path.endsWith('.mp4') && op == 'exists' && !entered.isCompleted) {
          entered.complete();
          await gate.future;
        }
      });
      await entered.future.timeout(const Duration(seconds: 10));
      final second = _errorOf(deleteDrivingSession('X106-A'));
      gate.complete();
      expect(await first, isNull);
      expect(await second, isNull);
      expect(sessionsWrites, 2, reason: 'one marker, one record removal: the second call joined');
      expect(await stateOf(a), nothingLeft);

      sessionsWrites = 0;
      expect(await _errorOf(deleteDrivingSession('X106-A')), isNull, reason: 'deleting a deleted session is not an error');
      expect(sessionsWrites, 2, reason: 'a marked stand-in, then its removal: the intent is durable even without a record');
      expect(sessions().containsKey('X106-A'), isFalse);
      expect(await stateOf(b), intact);

      sessionsWrites = 0;
      await completePendingSessionDeletions();
      await completePendingSessionDeletions();
      expect(sessionsWrites, 0, reason: 'nothing pending, nothing written');

      // A marked record left ACTIVE (a session killed while recording whose
      // deletion was then interrupted): the startup reclaim does not close it.
      await sessions().put('X106-C', DrivingSession(id: 'X106-C', startTime: t0, deletionPending: true));
      await DrivingSessionRecorder.reclaimOrphanedSessions();
      expect(sessions().get('X106-C')?.endTime, isNull, reason: 'left to the deletion');
      await completePendingSessionDeletions();
      expect(sessions().containsKey('X106-C'), isFalse);
      expect(await stateOf(b), intact);
    });

    test('X107 — a clip file an index of ANOTHER session also names (two indexes, one file: the clip-name collision of the R2.6.6 pre-audit, G) is never deleted — neither by the deletion nor by the discard of an unindexed clip; it goes with the last session referencing it', () async {
      final a = await seed('X107-A');
      final b = await seed('X107-B');
      final shared = a.clips[0];
      final bRecords = List<DashcamClipRecord>.from(videos().get('X107-B') as List)
        ..add(DashcamClipRecord(filePath: shared.path, recordedAt: t0, durationSeconds: 6, sizeBytes: 64));
      await videos().put('X107-B', bRecords);

      await deleteDrivingSession('X107-A');
      expect(shared.existsSync(), isTrue, reason: 'B\'s index names it');
      expect(a.clips[1].existsSync(), isFalse);
      expect(sessions().containsKey('X107-A') || videos().containsKey('X107-A') || a.telemetry.existsSync(), isFalse);

      final unindexed = File('${dir.path}/dashcam_clips/clip_X107-A_late.mp4')..writeAsBytesSync([1]);
      expect(await discardClipFilesOfDeletedSession('X107-A', [shared.path, unindexed.path]), isEmpty);
      expect(shared.existsSync(), isTrue, reason: 'still B\'s');
      expect(unindexed.existsSync(), isFalse, reason: 'A\'s own unindexed clip is discarded');

      await deleteDrivingSession('X107-B');
      expect(shared.existsSync(), isFalse, reason: 'removed with the last session that referenced it');
      expect(await stateOf(b), nothingLeft);
    });
  });

  // Fase 16.2-R4.3-R2.6.7-T2 — regression hardening. The R2.6.7 pre-audit
  // (scratchpad/fase16_2_r4_3_r2_6_7/pre_audit, §13.2) found three guarantees
  // the code keeps but no test of the suite protected: mutated in isolated
  // copies, NO test failed. L: a retry that trusts the cached marker instead of
  // writing it; N: a recovery that stops at the first deletion that fails; S: a
  // record stored before field 25 existed. Each test below fails on the
  // consequence of its mutation (the durable state, the sessions left
  // unprocessed, the legacy record that cannot be read), not on a flag.
  group('Fase 16.2-R4.3-R2.6.7-T2 — durable deletion regression hardening', () {
    test('X110 — (L) a retry in the SAME process after the marker\'s write failed before taking effect writes the marker AGAIN before removing anything: the cached record already reads as marked, the disk one does not. Interrupted right after its samples step, the disk carries the marker and the next start completes the deletion; an index entry published between the two attempts (legitimate: nothing was committed yet) goes with it', () async {
      final a = await seed('X110-A');
      final b = await seed('X110-B');

      final failing = _WriteFailingSessionAdapter();
      Hive.registerAdapter<DrivingSession>(failing, override: true);
      failing.armed = true;
      final first = await _errorOf(deleteDrivingSession(a.id));
      failing.armed = false;
      Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
      expect(first, isA<StateError>().having((e) => e.message, 'message', contains('injected')), reason: 'setup: the marker\'s write failed before taking effect');
      expect(sessionDeletionCommitted(a.id), isFalse, reason: 'setup: nothing decided');
      expect(sessions().get(a.id)?.deletionPending, isTrue,
          reason: 'setup — what a retry could wrongly trust: the cached record reads as marked while the disk one is not (X102)');

      // Not deleted, so A's publisher may still index a clip — as
      // _persistClaimedClips writes it: get + put.
      final late = File('${dir.path}/dashcam_clips/clip_X110-A_late.mp4')..writeAsBytesSync([9]);
      await videos().put(a.id, [
        ...List<DashcamClipRecord>.from(videos().get(a.id) as List),
        DashcamClipRecord(filePath: late.path, recordedAt: t0),
      ]);

      // The retry (the swipe again), killed right after its samples step: the
      // index box closes inside the samples removal.
      final retryWrites = <String>[];
      onSessionsWrite = () {
        retryWrites.add('record written (marked=${sessions().get(a.id)?.deletionPending}, committed=${sessionDeletionCommitted(a.id)})');
        return false;
      };
      var armed = true;
      onSamplesWrite = () {
        retryWrites.add('samples removed (committed=${sessionDeletionCommitted(a.id)})');
        if (armed) closeNow(videos());
        armed = false;
        return false;
      };
      final retry = await _errorOf(deleteDrivingSession(a.id));
      onSessionsWrite = null;
      onSamplesWrite = null;
      expect(retry, isA<HiveError>(), reason: 'setup: the retry died right after its samples step');

      await restart(); // a new process: only the disk answers
      expect(await stateOf(a), 'record=marked samples=null index=3 clipFiles=2 telemetry=true',
          reason: 'the retry removed A\'s samples, so the disk must carry the marker it wrote first — without it this is an '
              'unmarked session whose samples are gone, which no start completes (pre-audit NC-L: record=present)');
      expect(late.existsSync(), isTrue, reason: 'not reached yet');
      expect(retryWrites, ['record written (marked=true, committed=false)', 'samples removed (committed=true)'],
          reason: 'the retry wrote the marker before removing anything, and decided the deletion only once it was written');
      expect(await stateOf(b), intact);

      await completePendingSessionDeletions();
      expect(await stateOf(a), nothingLeft, reason: 'completed at the start');
      expect(late.existsSync(), isFalse, reason: 'the entry published between the attempts went with the deletion: no orphan');
      expect(await stateOf(b), intact);
      await restart();
      expect(await stateOf(a), nothingLeft, reason: 'on disk');
      expect(await stateOf(b), intact);
    });

    test('X111 — (N) the startup recovery does not stop at the first deletion that fails: with A — enumerated first — blocked by a clip file that cannot be deleted, B and C, marked after it, still complete; A stays marked with what it could not remove and its failure is reported naming it; an unrelated session is untouched; a second run with A still blocked declares nothing done, and once unblocked A completes', () async {
      final a = await seed('X111-A-blocked');
      final b = await seed('X111-B');
      final c = await seed('X111-C');
      final unrelated = await seed('X111-U');
      for (final s in [a, b, c]) {
        await sessions().put(s.id, sessions().get(s.id)!..deletionPending = true);
      }
      await restart(); // the marked records come from the disk, as at a start
      expect([for (final s in sessions().values) if (s.deletionPending) s.id], [a.id, b.id, c.id],
          reason: 'setup: the recovery meets the failing deletion FIRST — one that stopped there would never reach B and C');

      void blockA(String path, String op) {
        if (path == a.clips[0].path && op == 'delete') throw FileSystemException('injected: in use', path);
      }

      final reported = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
      try {
        await _withFileHooks(completePendingSessionDeletions, blockA);
        expect(await stateOf(b), nothingLeft, reason: 'B must be processed although A, before it, failed (pre-audit NC-N: B left marked with all its data)');
        expect(await stateOf(c), nothingLeft, reason: 'C too');
        expect(await stateOf(a), 'record=marked samples=null index=2 clipFiles=1 telemetry=true',
            reason: 'A: the file it could not delete stays indexed, and A stays marked — nothing declared done');
        expect(await stateOf(unrelated), intact);
        expect(reported, hasLength(1), reason: 'A\'s failure is reported, once');
        expect(reported.single.exception, isA<FileSystemException>());
        expect(reported.single.context.toString(), contains(a.id), reason: 'the report names the deletion that failed');

        await restart();
        expect(await stateOf(a), 'record=marked samples=null index=2 clipFiles=1 telemetry=true', reason: 'on disk: A pending for the next start');
        expect(await stateOf(b), nothingLeft);
        expect(await stateOf(c), nothingLeft);
        expect(await stateOf(unrelated), intact);

        await _withFileHooks(completePendingSessionDeletions, blockA);
        expect(await stateOf(a), 'record=marked samples=null index=2 clipFiles=1 telemetry=true', reason: 'still blocked: still pending');
        expect(reported, hasLength(2));

        await completePendingSessionDeletions();
        expect(await stateOf(a), nothingLeft, reason: 'unblocked: completed');
        expect(await stateOf(unrelated), intact);
        expect(reported, hasLength(2));
      } finally {
        FlutterError.onError = originalOnError;
      }
    });

    test('X112 — (S) a DrivingSession box file written by the build BEFORE field 25 existed (its bytes frozen below, produced by that build\'s own adapter) opens with the current adapter: the record reads deletionPending=false with every other field intact and the recovery leaves it alone; written back — now with field 25 — it keeps every field, and field 25 then round-trips on it', () async {
      final fixture = base64.decode(_legacySessionsBoxFile);
      // Provenance, read from the bytes themselves: one frame — length, ascii
      // key, type id (10, stored as 10 + hive's 32 reserved ids), field count.
      final keyLength = fixture[5];
      final fieldCountAt = 7 + keyLength;
      expect(fixture[0] | fixture[1] << 8 | fixture[2] << 16 | fixture[3] << 24, fixture.length, reason: 'fixture: a single frame');
      expect(String.fromCharCodes(fixture.sublist(6, 6 + keyLength)), _legacyId);
      expect(fixture[6 + keyLength], DrivingSessionAdapter().typeId + 32, reason: 'fixture: a DrivingSession');
      expect(fixture[fieldCountAt], 25, reason: 'fixture: 25 fields (0–24), no field 25 — a record of a pre-R2.6.7 build, not of the current adapter');

      await Hive.close();
      final boxFile = File('${dir.path}/${HiveBoxNames.drivingSessions}.hive')..writeAsBytesSync(fixture, flush: true);
      try {
        await openBoxes(); // the current adapter reads the legacy frame here
      } catch (_) {
        // hive 2.2.3 closes a box whose open failed WITHOUT awaiting it (the
        // lock file goes last): let that finish, so the tearDown can remove the
        // directory (seen under NC-S: errno 32 on the deletion, a secondary error).
        final lock = File('${dir.path}/${HiveBoxNames.drivingSessions}.lock');
        for (var i = 0; i < 300 && lock.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        rethrow;
      }

      final legacy = sessions().get(_legacyId);
      expect(legacy, isNotNull);
      expect(legacy!.deletionPending, isFalse, reason: 'a record stored before field 25 existed is not a pending deletion');
      _expectLegacyFields(legacy, 'as read');
      await completePendingSessionDeletions();
      expect(sessions().containsKey(_legacyId), isTrue, reason: 'the start leaves it alone');

      await sessions().put(_legacyId, legacy);
      await restart();
      final bytes = boxFile.readAsBytesSync();
      expect(bytes.sublist(0, fixture.length), fixture, reason: 'append-only: the legacy frame is still the first');
      // Fase 16.2-R4.3-R2.6.11: the current adapter also writes fields 26–29
      // (the session's telemetry outcome); X169 holds the fixture of the build
      // right before them.
      expect(bytes[fixture.length + fieldCountAt], 30, reason: 'written back by the current adapter: fields 0–24, 25 and 26–29');
      final rewritten = sessions().get(_legacyId)!;
      expect(rewritten.deletionPending, isFalse);
      _expectLegacyFields(rewritten, 'written back and reread');

      await sessions().put(_legacyId, rewritten..deletionPending = true);
      await restart();
      expect(sessions().get(_legacyId)!.deletionPending, isTrue, reason: 'field 25 persists on the upgraded record');
      _expectLegacyFields(sessions().get(_legacyId)!, 'marked and reread');
    });
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

typedef _Seeded = ({String id, List<File> clips, File telemetry});

Future<Object?> _errorOf(Future<void> f) async {
  try {
    await f.timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  }
}

/// Runs [body] with every clip (.mp4) and telemetry (.jsonl) File it creates
/// wrapped: [onFile] runs before exists() ('exists') and delete() ('delete'),
/// and after a delete that succeeded ('deleted'); it may await, throw, or close
/// a box. Every other File is the real one.
Future<T> _withFileHooks<T>(Future<T> Function() body, FutureOr<void> Function(String path, String op) onFile) =>
    IOOverrides.runWithIOOverrides(body, _HookedIO(onFile));

final class _HookedIO extends IOOverrides {
  _HookedIO(this.onFile);
  final FutureOr<void> Function(String path, String op) onFile;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('.mp4') || path.endsWith('.jsonl') ? _HookedFile(real, onFile) : real;
  }
}

class _HookedFile implements File {
  _HookedFile(this._inner, this._onFile);
  final File _inner;
  final FutureOr<void> Function(String path, String op) _onFile;

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
    final deleted = await _inner.delete(recursive: recursive);
    await _onFile(_inner.path, 'deleted');
    return deleted;
  }

  @override
  void deleteSync({bool recursive = false}) => _inner.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_HookedFile: ${invocation.memberName}');
}

/// A session adapter that, while [armed], fails while serializing — inside
/// `writeFrames`, before a byte reaches the file: a write that fails BEFORE it
/// takes effect (same technique as the recorder's sample adapter tests).
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

const _legacyId = 'X112-legacy';

/// Fase 16.2-R4.3-R2.6.7-T2 (X112): the whole `driving_sessions.hive` file of a
/// box holding ONE record, [_legacyId], written by the build right before
/// field 25 (`deletionPending`) existed: the R2.6.6 snapshot, whose
/// driving_session.g.dart is HEAD bd1aca0's. Frozen bytes — never re-derived
/// from an adapter of this tree, which would only prove the adapter reads its
/// own output. Generator, its two identical runs and the file (SHA-256
/// 07421c8e…1b63, 444 bytes): scratchpad/fase16_2_r4_3_r2_6_7/harness_t2/05_sources.
/// Its values are the ones [_expectLegacyFields] checks.
const _legacySessionsBoxFile =
    'vAEAAAELWDExMi1sZWdhY3kqGQAECwAAAFgxMTItbGVnYWN5ARIAoLQiiaR5QgECEgDA59aLpHlC'
    'AQMCAAAAAKCE3kAEAgAAAAAAkF1ABQIAAAAAAOBDQAYCAAAAAACEjEAHAgAAAAAAAoRACAIAAAAA'
    'AADYPwkCAAAAAAAA5D8KAgAAAAAA5IVACwIAAAAAAJaKQAwCAAAAAAAAKUANAgAAAAAA9HBADgIA'
    'AAAAAADcPw8CAAAAAAAA6j8QAQAAAAAAJqZAEQKwcmiR7Yw3wBICRUdy+Q9RR8ATAkcDeAsk6DbA'
    'FAI8vVKWIZZFwBUCAAAAAAAABEAWAgAAAAAAaHNAFwIAAAAAAAhkQBgKAgAAAC0NACwBARIAUM6J'
    'iqR5QgECAgAAAAAAAOQ/AwQMAAAAZXZ0LWxlZ2FjeS0xBAEAAAAAAJCKQAUCAAAAAABAN8AGAgAA'
    'AAAAwEbABwIAAAAAACBSQAgCAAAAAABiiEAJAgAAAAAAAOS/CgIAAAAAAADAPwsCZmZmZmZm5D8M'
    'LgItDQAsAwESAABCZYukeUIBAgADAAQABQAGAAcACAAJAAoACwAMLgCMsb7o';

/// Every field 0–24 of the record in [_legacySessionsBoxFile], as its
/// generator wrote them (UTC instants: the bytes do not depend on the time zone).
void _expectLegacyFields(DrivingSession s, String when) {
  expect(
    [
      s.id, s.startTime, s.endTime, s.distanceMeters, s.maxSpeedKmh, s.avgSpeedKmh, s.maxAltitudeMeters,
      s.minAltitudeMeters, s.maxAccelerationG, s.maxDecelerationG, s.initialAltitudeMeters, s.finalAltitudeMeters,
      s.initialHeadingDegrees, s.finalHeadingDegrees, s.maxLateralG, s.maxGForceMagnitude, s.sampleCount,
      s.initialLatitude, s.initialLongitude, s.finalLatitude, s.finalLongitude, s.avgGnssQualityIndex,
      s.altitudeGainMeters, s.altitudeLossMeters, s.events.length,
    ],
    [
      _legacyId, DateTime.utc(2025, 11, 3, 7, 15, 30, 250), DateTime.utc(2025, 11, 3, 8, 2, 45, 500), 31250.5, 118.25, 39.75, 912.5,
      640.25, 0.375, 0.625, 700.5, 850.75,
      12.5, 271.25, 0.4375, 0.8125, 2835,
      -23.5505, -46.6333, -22.9068, -43.1729, 2.5,
      310.5, 160.25, 2,
    ],
    reason: '$when: fields 0–24',
  );
  final full = s.events[0];
  expect(
    [
      full.type, full.timestamp, full.magnitude, full.id, full.durationMs, full.latitude, full.longitude,
      full.speedKmh, full.altitudeMeters, full.longitudinalG, full.lateralG, full.resultantG, full.severity,
    ],
    [
      DrivingSessionEventType.hardBraking, DateTime.utc(2025, 11, 3, 7, 40, 1, 125), 0.625, 'evt-legacy-1', 850, -23.25, -45.5,
      72.5, 780.25, -0.625, 0.125, 0.6375, EventSeverity.high,
    ],
    reason: '$when: field 24, a fully populated event',
  );
  final bare = s.events[1];
  expect(
    [bare.type, bare.timestamp, bare.magnitude, bare.id, bare.durationMs, bare.resultantG, bare.severity],
    [DrivingSessionEventType.gnssLost, DateTime.utc(2025, 11, 3, 7, 55), null, null, null, null, EventSeverity.info],
    reason: '$when: field 24, an event with only its required fields',
  );
}
