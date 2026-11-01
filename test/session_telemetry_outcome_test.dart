import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

// Fase 16.2-R4.3-R2.6.11 — the durable per-session telemetry outcome
// (persistSessionTelemetryOutcome), at the persistence layer: real Hive in a
// temporary directory, path_provider mocked to it, real files, the real
// deletion protocol. Independent review (P2): the terminal result of a
// session's dashcam telemetry file existed only in memory and in a log line.
// Failure-injection points are the ones session_deletion_protocol_test.dart
// uses: a box's compaction-strategy callback runs synchronously right after
// each of its writes took effect (frame written, the write not yet returned),
// and an adapter that throws while serializing fails a write BEFORE it takes
// effect. A "restart" closes every box and reopens it from its file, so only
// the disk answers. The controller-level scenarios (session A failing after
// session B started) live in dashcam_telemetry_outcome_session_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  bool Function()? onSessionsWrite;
  bool Function()? onSamplesWrite;
  bool Function()? onVideosWrite;

  /// Writes of the sessions box that took effect (one per put/delete frame).
  var sessionWrites = 0;
  final pendingCloses = <Future<void>>[];
  final t0 = DateTime(2026, 5, 1, 8);

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  LazyBox samples() => Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
  Box videos() => Hive.box(HiveBoxNames.dashcamSessionVideos);

  Future<void> openBoxes() async {
    await Hive.openBox<DrivingSession>(
      HiveBoxNames.drivingSessions,
      compactionStrategy: (entries, deleted) {
        sessionWrites++;
        return onSessionsWrite?.call() ?? false;
      },
    );
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples, compactionStrategy: (entries, deleted) => onSamplesWrite?.call() ?? false);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos, compactionStrategy: (entries, deleted) => onVideosWrite?.call() ?? false);
  }

  /// Every box closed and reopened from its file: nothing cached answers.
  Future<void> restart() async {
    await Future.wait(pendingCloses);
    pendingCloses.clear();
    await Hive.close();
    await openBoxes();
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('session_telemetry_outcome_test');
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
    sessionWrites = 0;
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

  /// A finalized session with every kind of data a deletion removes: a record
  /// with a populated summary and one event, 3 stored samples, [clipCount]
  /// indexed clip files and a telemetry file.
  Future<_Seeded> seed(String id, {int clipCount = 2}) async {
    const sampleCount = 3;
    await sessions().put(
      id,
      DrivingSession(
        id: id,
        startTime: t0,
        endTime: t0.add(const Duration(minutes: 1)),
        distanceMeters: 812.5,
        maxSpeedKmh: 62.5,
        sampleCount: sampleCount,
        events: [DrivingSessionEvent(type: DrivingSessionEventType.hardBraking, timestamp: t0.add(const Duration(seconds: 20)), magnitude: 0.5)],
      ),
    );
    await samples().put(id, [for (var i = 0; i < sampleCount; i++) DrivingSessionSample(timestamp: t0.add(Duration(seconds: i)), speedKmh: 40.0 + i)]);
    final clipsDir = Directory('${dir.path}/dashcam_clips')..createSync(recursive: true);
    final clips = [for (var i = 0; i < clipCount; i++) File('${clipsDir.path}/clip_${id}_$i.mp4')..writeAsBytesSync(List<int>.filled(64, i))];
    await videos().put(id, [for (final f in clips) DashcamClipRecord(filePath: f.path, recordedAt: t0, durationSeconds: 6, sizeBytes: 64)]);
    final telemetry = await DashcamTelemetryWriter.fileForSession(id);
    telemetry.writeAsStringSync('{"t":0}\n');
    sessionWrites = 0;
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

  /// The telemetry outcome [id]'s record carries, as text.
  String outcomeOf(String id) {
    final s = sessions().get(id);
    if (s == null) return 'absent';
    return '${s.dashcamTelemetryOutcome.name} ${s.dashcamTelemetryAcceptedCount}/${s.dashcamTelemetryPersistedCount}/${s.dashcamTelemetryRefusedCount}';
  }

  Future<SessionTelemetryOutcomeWrite> failed(String id, {int accepted = 19, int persisted = 0, int refused = 0}) =>
      persistSessionTelemetryOutcome(id, outcome: DashcamTelemetryOutcome.failed, accepted: accepted, persisted: persisted, refused: refused);

  group('Fase 16.2-R4.3-R2.6.11 — durable per-session telemetry outcome', () {
    test('X160 — a SUCCESS is recorded on its session and nowhere else: one write, only the four telemetry fields change, the '
        'session\'s samples, clips, index and telemetry file are untouched, another session is untouched, and all of it is '
        'what the disk holds after a restart', () async {
      final a = await seed('X160-A');
      final b = await seed('X160-B');
      final aBefore = _fieldsOf(sessions().get(a.id)!);
      final bBefore = _fieldsOf(sessions().get(b.id)!);
      expect(outcomeOf(a.id), 'unknown null/null/null', reason: 'setup: nothing recorded yet');
      sessionWrites = 0;

      final written = await persistSessionTelemetryOutcome(a.id, outcome: DashcamTelemetryOutcome.success, accepted: 19, persisted: 19, refused: 0);
      expect(written, SessionTelemetryOutcomeWrite.recorded);
      expect(sessionWrites, 1, reason: 'one write of the sessions box');

      for (final when in ['in memory', 'after a restart']) {
        expect(outcomeOf(a.id), 'success 19/19/0', reason: when);
        expect(_legacy(_fieldsOf(sessions().get(a.id)!)), _legacy(aBefore), reason: '$when: fields 0–25 of A are what they were');
        expect(_fieldsOf(sessions().get(b.id)!), bBefore, reason: '$when: B is untouched, field by field');
        expect(outcomeOf(b.id), 'unknown null/null/null', reason: '$when: A\'s outcome is not B\'s');
        expect(await stateOf(a), intact, reason: when);
        expect(await stateOf(b), intact, reason: when);
        if (when == 'in memory') await restart();
      }
    });

    test('X161 — a FAILURE is recorded with what was lost: accepted, persisted and refused counts, as given — a total loss, a '
        'partial one with samples refused after the failure, and a file that never opened — each on its own session, and '
        'each read back from the disk', () async {
      final total = await seed('X161-total');
      final partial = await seed('X161-partial');
      final unopened = await seed('X161-unopened');
      final healthy = await seed('X161-healthy');

      expect(await failed(total.id), SessionTelemetryOutcomeWrite.recorded);
      expect(await failed(partial.id, accepted: 50, persisted: 25, refused: 3), SessionTelemetryOutcomeWrite.recorded);
      expect(await failed(unopened.id, accepted: 0), SessionTelemetryOutcomeWrite.recorded);

      for (final when in ['in memory', 'after a restart']) {
        expect(outcomeOf(total.id), 'failed 19/0/0', reason: when);
        expect(outcomeOf(partial.id), 'failed 50/25/3', reason: when);
        expect(outcomeOf(unopened.id), 'failed 0/0/0', reason: when);
        expect(outcomeOf(healthy.id), 'unknown null/null/null', reason: '$when: a session nobody reported on stays unknown');
        expect(sessions().get(total.id)!.endTime, t0.add(const Duration(minutes: 1)), reason: '$when: still a finished session');
        expect(sessions().get(partial.id)!.deletionPending, isFalse, reason: when);
        if (when == 'in memory') await restart();
      }
    });

    test('X162 — the outcome goes onto the record the box holds NOW, and that record stays the box\'s: an instance someone '
        'else still holds (the History\'s open detail screen, a startup reclaim) is the one updated — never replaced by a '
        'copy — so a later save through it succeeds and the disk ends with BOTH its changes and the outcome; a record '
        're-read from the disk since then is the one updated, and the stale instance left behind is not written', () async {
      // (a) Another holder's instance is the box's instance.
      final a = await seed('X162-A');
      final held = sessions().get(a.id)!;
      expect(await failed(a.id), SessionTelemetryOutcomeWrite.recorded);
      // That holder then changes ITS instance and saves it.
      held
        ..sampleCount = 7
        ..endTime = t0.add(const Duration(minutes: 9))
        ..events.add(DrivingSessionEvent(type: DrivingSessionEventType.gnssLost, timestamp: t0.add(const Duration(minutes: 2))));
      await held.save(); // throws "not in a box" had a copy taken its place
      expect(identical(sessions().get(a.id), held), isTrue, reason: 'the box still holds the very instance the other holder has');
      await restart();
      final onDisk = sessions().get(a.id)!;
      expect(outcomeOf(a.id), 'failed 19/0/0', reason: 'the later save did not erase the outcome');
      expect([onDisk.sampleCount, onDisk.endTime, onDisk.events.length], [7, t0.add(const Duration(minutes: 9)), 2],
          reason: 'and the outcome did not undo those changes');

      // (b) The box was reopened: an instance captured before is stale.
      final b = await seed('X162-B');
      final stale = sessions().get(b.id)!;
      await sessions().put(b.id, stale..sampleCount = 11);
      await restart();
      final current = sessions().get(b.id)!;
      expect(identical(current, stale), isFalse, reason: 'setup: the record was re-read from the disk');
      expect(await failed(b.id, accepted: 4, persisted: 1), SessionTelemetryOutcomeWrite.recorded);
      expect(identical(sessions().get(b.id), current), isTrue);
      expect(stale.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: 'the stale instance is neither read nor written');
      await restart();
      expect(outcomeOf(b.id), 'failed 4/1/0');
      expect(sessions().get(b.id)!.sampleCount, 11);
    });

    test('X163 — a session marked for deletion is left exactly as it is: nothing is written, the marker stays, no outcome '
        'appears, and the startup recovery then completes the deletion; a marker that only the cache carries (its write '
        'failed) is respected too, and the outcome does not make that failed marker durable', () async {
      // (i) Marked on disk by an earlier run; nothing decided in this process.
      final a = await seed('X163-A');
      final other = await seed('X163-other');
      await sessions().put(a.id, sessions().get(a.id)!..deletionPending = true);
      await restart();
      expect(sessionDeletionCommitted(a.id), isFalse, reason: 'setup: the marker is all there is');
      final markedBefore = _fieldsOf(sessions().get(a.id)!);
      sessionWrites = 0;

      final onMarked = await failed(a.id);
      expect(_fieldsOf(sessions().get(a.id)!), markedBefore, reason: 'not one field changed — no outcome on it, and the marker still there');
      expect(sessionWrites, 0, reason: 'nothing written for a session being deleted');
      await restart();
      expect(_fieldsOf(sessions().get(a.id)!), markedBefore, reason: 'on disk');
      expect(await stateOf(a), 'record=marked samples=3 index=2 clipFiles=2 telemetry=true');
      expect(onMarked, SessionTelemetryOutcomeWrite.sessionDeletionPending);

      await completePendingSessionDeletions();
      expect(await stateOf(a), nothingLeft, reason: 'the recovery was not hindered');
      expect(await stateOf(other), intact);
      await restart();
      expect(await stateOf(a), nothingLeft, reason: 'on disk');

      // (ii) The marker's own write failed BEFORE taking effect: the cached
      // record reads as marked, the disk one does not, nothing is committed.
      final c = await seed('X163-C');
      final failing = _WriteFailingSessionAdapter()..failures = 1;
      Hive.registerAdapter<DrivingSession>(failing, override: true);
      final refused = await _errorOf(deleteDrivingSession(c.id));
      Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
      expect(refused, isA<StateError>().having((e) => e.message, 'message', contains('injected')), reason: 'setup');
      expect(sessions().get(c.id)!.deletionPending, isTrue, reason: 'setup: the cache reads as marked');
      expect(sessionDeletionCommitted(c.id), isFalse, reason: 'setup');
      sessionWrites = 0;

      final onCachedMarker = await failed(c.id);
      final writesForC = sessionWrites;
      await restart();
      expect(sessions().get(c.id)!.deletionPending, isFalse, reason: 'the outcome did not write the record, so the failed marker did not become durable through it');
      expect(outcomeOf(c.id), 'unknown null/null/null');
      expect(await stateOf(c), intact);
      expect(writesForC, 0);
      expect(onCachedMarker, SessionTelemetryOutcomeWrite.sessionDeletionPending);
    });

    test('X164 — a session that does not exist is not recreated: an id never stored, and a session deleted before its '
        'outcome arrived, get no record, no stand-in and no file — and still none after a restart', () async {
      final onNeverStored = await failed('X164-never-stored');

      final a = await seed('X164-A');
      final other = await seed('X164-other');
      await deleteDrivingSession(a.id);
      expect(await stateOf(a), nothingLeft, reason: 'setup: deleted');
      sessionWrites = 0;
      final onDeleted = await failed(a.id);
      final successOnDeleted = await persistSessionTelemetryOutcome(a.id, outcome: DashcamTelemetryOutcome.success, accepted: 5, persisted: 5, refused: 0);
      final writesAfterDeletion = sessionWrites;

      for (final when in ['in memory', 'after a restart']) {
        expect(sessions().containsKey('X164-never-stored'), isFalse, reason: when);
        expect(await stateOf(a), nothingLeft, reason: '$when: the deleted session was not recreated, nor any of its data');
        expect(sessions().keys.toList(), [other.id], reason: '$when: no stand-in record of any kind');
        expect(File('${dir.path}/dashcam_telemetry/X164-never-stored.jsonl').existsSync(), isFalse, reason: when);
        expect(await stateOf(other), intact, reason: when);
        if (when == 'in memory') await restart();
      }
      await completePendingSessionDeletions();
      expect(sessions().keys.toList(), [other.id], reason: 'and the recovery finds nothing to do');
      expect(writesAfterDeletion, 0, reason: 'nothing was written for the deleted session');
      expect(
        [onNeverStored, onDeleted, successOnDeleted],
        [SessionTelemetryOutcomeWrite.sessionAbsent, SessionTelemetryOutcomeWrite.sessionAbsent, SessionTelemetryOutcomeWrite.sessionAbsent],
        reason: 'and the caller is told so — for a success as for a failure',
      );
    });

    test('X165 — the real race with deleteDrivingSession: issued in the same instant in either order, and arriving at every '
        'step of a deletion in progress, the outcome never brings the session back, never clears its marker and never stops '
        'the deletion: the session ends removed with all its data; a deletion that could not finish keeps its marker and '
        'gets no outcome, and completes later', () async {
      final keep = await seed('X165-keep');

      // (a) The outcome's write is issued first; the deletion starts behind it.
      final a = await seed('X165-A');
      final outcomeFirst = failed(a.id);
      final deletionAfter = deleteDrivingSession(a.id);
      expect(await outcomeFirst, SessionTelemetryOutcomeWrite.recorded, reason: 'it was a live, unmarked session when the outcome arrived');
      await deletionAfter;
      expect(await stateOf(a), nothingLeft, reason: 'the deletion, behind it, still removed everything');

      // (b) The deletion starts first; the outcome arrives in the same instant.
      final b = await seed('X165-B');
      final deletionFirst = deleteDrivingSession(b.id);
      final outcomeAfter = failed(b.id);
      await deletionFirst;
      expect(await stateOf(b), nothingLeft);
      expect(await outcomeAfter, SessionTelemetryOutcomeWrite.sessionDeletionPending, reason: 'the deletion marked its record in the slice it started');

      // (c) The outcome arrives at each step of a deletion in progress.
      final c = await seed('X165-C');
      final arrivals = <String>[];
      void arrive(String step) => failed(c.id).then((w) => arrivals.add('$step: ${w.name}'));
      var sessionSteps = 0;
      onSessionsWrite = () {
        arrive(++sessionSteps == 1 ? 'marker written' : 'record removed');
        return false;
      };
      onSamplesWrite = () {
        arrive('samples removed');
        return false;
      };
      onVideosWrite = () {
        arrive('index removed');
        return false;
      };
      await _withFileHooks(() => deleteDrivingSession(c.id), (path, op) {
        if (op == 'deleted') arrive(path.endsWith('.jsonl') ? 'telemetry file removed' : 'clip file removed');
      });
      onSessionsWrite = null;
      onSamplesWrite = null;
      onVideosWrite = null;
      await Future<void>.delayed(Duration.zero);
      expect(await stateOf(c), nothingLeft, reason: 'none of the seven arrivals brought anything of the session back');
      expect(arrivals, [
        'marker written: sessionDeletionPending',
        'samples removed: sessionDeletionPending',
        'clip file removed: sessionDeletionPending',
        'clip file removed: sessionDeletionPending',
        'index removed: sessionDeletionPending',
        'telemetry file removed: sessionDeletionPending',
        'record removed: sessionAbsent',
      ], reason: 'refused at every step; once the record is gone, the session is simply absent');

      // (d) A deletion that cannot finish (its telemetry file is in use).
      final d = await seed('X165-D');
      final blocked = await _errorOf(_withFileHooks(() => deleteDrivingSession(d.id), (path, op) {
        if (path.endsWith('.jsonl') && op == 'delete') throw FileSystemException('injected: in use', path);
      }));
      expect(blocked, isA<FileSystemException>(), reason: 'setup: the deletion stopped at the telemetry file');
      expect(await stateOf(d), 'record=marked samples=null index=absent clipFiles=0 telemetry=true', reason: 'setup');
      sessionWrites = 0;
      final onBlocked = await failed(d.id);
      expect(outcomeOf(d.id), 'unknown null/null/null', reason: 'no outcome on a session whose deletion is pending');
      expect(sessions().get(d.id)!.deletionPending, isTrue, reason: 'the marker was not cleared');
      expect(sessionWrites, 0);
      expect(onBlocked, SessionTelemetryOutcomeWrite.sessionDeletionPending);

      await restart();
      expect(await stateOf(a), nothingLeft, reason: 'on disk');
      expect(await stateOf(b), nothingLeft, reason: 'on disk');
      expect(await stateOf(c), nothingLeft, reason: 'on disk');
      expect(await stateOf(d), 'record=marked samples=null index=absent clipFiles=0 telemetry=true', reason: 'on disk: still pending');
      expect(outcomeOf(d.id), 'unknown null/null/null', reason: 'on disk');
      await completePendingSessionDeletions();
      expect(await stateOf(d), nothingLeft, reason: 'the startup recovery completes it');
      expect(await stateOf(keep), intact, reason: 'a session that was not part of any of it');
      expect(sessions().keys.toList(), [keep.id]);
    });

    test('X166 — a write that TOOK EFFECT and still failed (hive writes the frame, then its compaction throws) is not '
        'presumed rolled back and not repeated blindly: the record is read again and the same state written once more, the '
        'call succeeds, and the session carries the outcome exactly once — the counts are the ones given, not doubled. When '
        'nothing can be written any more, the first error is thrown and the disk still holds the outcome that took effect', () async {
      // (i) The compaction's own file cannot be created; the box stays usable.
      final a = await seed('X166-A');
      final aBefore = _fieldsOf(sessions().get(a.id)!);
      Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec').createSync();
      var effects = 0;
      onSessionsWrite = () {
        effects++; // runs only after the frame is written and committed
        return true; // …and asks for the compaction that fails
      };
      final written = await failed(a.id);
      onSessionsWrite = null;
      expect(written, SessionTelemetryOutcomeWrite.recorded, reason: 'reconciled: the caller is told it is recorded');
      expect(effects, 2, reason: 'the first write took effect and its put threw; the reconciliation wrote the same state once more');
      for (final when in ['in memory', 'after a restart']) {
        expect(outcomeOf(a.id), 'failed 19/0/0', reason: '$when: once — the given counts, not 38');
        expect(_legacy(_fieldsOf(sessions().get(a.id)!)), _legacy(aBefore), reason: when);
        if (when == 'in memory') {
          Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec').deleteSync();
          await restart();
        }
      }
      expect(await failed(a.id), SessionTelemetryOutcomeWrite.alreadyRecorded, reason: 'and a repeat finds it');

      // (ii) The box closes right after the frame is written: the write took
      // effect, its put throws, and nothing can be written afterwards.
      final b = await seed('X166-B');
      onSessionsWrite = () {
        pendingCloses.add(sessions().close());
        return true;
      };
      final error = await _errorOf(failed(b.id, accepted: 28));
      onSessionsWrite = null;
      expect(error, isA<HiveError>().having((e) => e.message, 'message', contains('already been closed')),
          reason: 'the FIRST error, not the reconciliation\'s own ("Box not found")');
      await restart();
      expect(outcomeOf(b.id), 'failed 28/0/0', reason: 'the write had taken effect: recorded once, although the call failed');
      expect(await stateOf(b), intact);
    });

    test('X167 — a write that failed BEFORE taking effect is not swallowed: the cached record already reads as carrying the '
        'outcome, the disk does not — the reconciliation writes it, and it is on disk after a restart. When that write '
        'fails too, the first error reaches the caller and the disk has no outcome (never a silent "recorded"); a later '
        'attempt records it', () async {
      // (i) One failure, then the disk works.
      final a = await seed('X167-A');
      final failing = _WriteFailingSessionAdapter()..failures = 1;
      Hive.registerAdapter<DrivingSession>(failing, override: true);
      final written = await failed(a.id);
      await restart();
      expect(outcomeOf(a.id), 'failed 19/0/0', reason: 'on disk — a swallowed failure would leave only the cache saying so');
      expect(written, SessionTelemetryOutcomeWrite.recorded);
      expect(failing.attempts, 2, reason: 'the first write failed while serializing; the reconciliation wrote again');
      expect(sessionWrites, 1, reason: 'exactly one write took effect');

      // (ii) Both writes fail.
      final b = await seed('X167-B');
      failing
        ..attempts = 0
        ..failures = 2;
      final error = await _errorOf(failed(b.id, accepted: 28));
      expect(failing.attempts, 2);
      expect(error, isA<StateError>().having((e) => e.message, 'message', contains('injected failure #1')), reason: 'the first error');
      expect(sessionWrites, 0, reason: 'nothing took effect');
      expect(outcomeOf(b.id), 'failed 28/0/0', reason: 'the cached record carries what may or may not be on disk (not presumed rolled back)');
      Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
      await restart();
      expect(outcomeOf(b.id), 'unknown null/null/null', reason: 'on disk: not recorded — which is why the call failed instead of reporting success');
      expect(await stateOf(b), intact);
      expect(await failed(b.id, accepted: 28), SessionTelemetryOutcomeWrite.recorded, reason: 'nothing is left stuck: it can be recorded');
      await restart();
      expect(outcomeOf(b.id), 'failed 28/0/0');
    });

    test('X168 — recording is idempotent: the same terminal outcome again — after it completed, in the same instant, or '
        'after a restart — writes nothing and changes nothing; a DIFFERENT outcome for a session that already has one is '
        'refused and the first is kept: no counter doubled, no failure turned into a success', () async {
      final a = await seed('X168-A');
      final first = await failed(a.id);
      final repeated = await failed(a.id);
      expect(outcomeOf(a.id), 'failed 19/0/0', reason: 'not 38/0/0');
      expect(sessionWrites, 1, reason: 'the repeat wrote nothing');
      expect([first, repeated], [SessionTelemetryOutcomeWrite.recorded, SessionTelemetryOutcomeWrite.alreadyRecorded]);

      final asSuccess = await persistSessionTelemetryOutcome(a.id, outcome: DashcamTelemetryOutcome.success, accepted: 19, persisted: 19, refused: 0);
      expect(outcomeOf(a.id), 'failed 19/0/0', reason: 'a failure is never overwritten by a success');
      final otherCounts = await failed(a.id, accepted: 38);
      expect(outcomeOf(a.id), 'failed 19/0/0', reason: 'nor by other counts');
      expect(sessionWrites, 1);
      expect([asSuccess, otherCounts], [SessionTelemetryOutcomeWrite.conflict, SessionTelemetryOutcomeWrite.conflict]);

      // Two terminal callbacks in the same instant: the second finds the first.
      final b = await seed('X168-B');
      final both = await Future.wait([
        persistSessionTelemetryOutcome(b.id, outcome: DashcamTelemetryOutcome.success, accepted: 30, persisted: 30, refused: 0),
        persistSessionTelemetryOutcome(b.id, outcome: DashcamTelemetryOutcome.success, accepted: 30, persisted: 30, refused: 0),
      ]);
      expect(both, [SessionTelemetryOutcomeWrite.recorded, SessionTelemetryOutcomeWrite.alreadyRecorded]);
      expect(sessionWrites, 1);

      await restart();
      sessionWrites = 0;
      expect(await failed(a.id), SessionTelemetryOutcomeWrite.alreadyRecorded, reason: 'the disk already says so');
      expect(await failed(b.id), SessionTelemetryOutcomeWrite.conflict, reason: 'a success on disk is not replaced by a later failure report either');
      expect(sessionWrites, 0);
      expect([outcomeOf(a.id), outcomeOf(b.id)], ['failed 19/0/0', 'success 30/30/0']);
    });

    test('X169 — a DrivingSession box file written by the build BEFORE fields 26–29 existed (its bytes frozen below, produced '
        'by that build\'s own adapter) opens with the current adapter: both records read with an UNKNOWN telemetry outcome '
        '— not a failure, not a success — and every earlier field intact, the deletion marker included; written back, the '
        'record keeps every field; an outcome then round-trips on it; and the legacy record marked for deletion is still '
        'completed by the recovery', () async {
      final fixture = base64.decode(_legacySessionsBoxFile);
      // Provenance, read from the bytes themselves: two frames, each a
      // DrivingSession (type id 10, stored as 10 + hive's 32 reserved ids)
      // with 26 fields (0–25).
      int frameLength(int at) => fixture[at] | fixture[at + 1] << 8 | fixture[at + 2] << 16 | fixture[at + 3] << 24;
      final second = frameLength(0);
      expect(second + frameLength(second), fixture.length, reason: 'fixture: exactly two frames');
      for (final (at, key) in [(0, _legacyId), (second, _legacyMarkedId)]) {
        final keyLength = fixture[at + 5];
        expect(String.fromCharCodes(fixture.sublist(at + 6, at + 6 + keyLength)), key);
        expect(fixture[at + 6 + keyLength], DrivingSessionAdapter().typeId + 32, reason: 'fixture: a DrivingSession');
        expect(fixture[at + 7 + keyLength], 26, reason: 'fixture: 26 fields (0–25), none of 26–29 — a record of a pre-R2.6.11 build, not of the current adapter');
      }
      final fieldCountAt = 7 + fixture[5];

      await Hive.close();
      final boxFile = File('${dir.path}/${HiveBoxNames.drivingSessions}.hive')..writeAsBytesSync(fixture, flush: true);
      try {
        await openBoxes(); // the current adapter reads the legacy frames here
      } catch (_) {
        // hive 2.2.3 closes a box whose open failed WITHOUT awaiting it: let
        // that finish so the tearDown can remove the directory (see X112).
        final lock = File('${dir.path}/${HiveBoxNames.drivingSessions}.lock');
        for (var i = 0; i < 300 && lock.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        rethrow;
      }

      void expectUnknown(DrivingSession s, String when) {
        expect(s.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: '$when: a record stored before the fields existed has no outcome');
        expect(
          [s.dashcamTelemetryOutcomeCode, s.dashcamTelemetryAcceptedCount, s.dashcamTelemetryPersistedCount, s.dashcamTelemetryRefusedCount],
          [null, null, null, null],
          reason: when,
        );
        expect(dashcamTelemetryOutcomeSummary(s), isNull, reason: '$when: nothing to show — neither a failure nor a success');
      }

      final legacy = sessions().get(_legacyId)!;
      final marked = sessions().get(_legacyMarkedId)!;
      expectUnknown(legacy, 'as read');
      expectUnknown(marked, 'as read (marked)');
      _expectLegacyFields(legacy, 'as read');
      expect(
        [marked.startTime, marked.endTime, marked.distanceMeters, marked.maxSpeedKmh, marked.sampleCount, marked.events, marked.deletionPending],
        [DateTime.utc(2026, 9, 13, 9), DateTime.utc(2026, 9, 13, 9, 12, 30, 250), 5120.5, 62.25, 750, isEmpty, isTrue],
        reason: 'as read: the legacy deletion marker (field 25) is still a deletion marker',
      );

      // Written back by the current adapter.
      await sessions().put(_legacyId, legacy);
      await restart();
      final bytes = boxFile.readAsBytesSync();
      expect(bytes.sublist(0, fixture.length), fixture, reason: 'append-only: the legacy frames are still the first two');
      expect(bytes[fixture.length + fieldCountAt], 30, reason: 'written back by the current adapter: fields 0–25 plus 26–29');
      final rewritten = sessions().get(_legacyId)!;
      expectUnknown(rewritten, 'written back and reread');
      _expectLegacyFields(rewritten, 'written back and reread');

      // An outcome on the upgraded record, and none on the marked one.
      expect(await failed(_legacyId, accepted: 40, persisted: 25, refused: 2), SessionTelemetryOutcomeWrite.recorded);
      final onLegacyMarked = await failed(_legacyMarkedId);
      await restart();
      expect(outcomeOf(_legacyId), 'failed 40/25/2', reason: 'fields 26–29 persist on the upgraded record');
      _expectLegacyFields(sessions().get(_legacyId)!, 'with an outcome, reread');
      expectUnknown(sessions().get(_legacyMarkedId)!, 'marked, reread');
      expect(sessions().get(_legacyMarkedId)!.deletionPending, isTrue);
      expect(onLegacyMarked, SessionTelemetryOutcomeWrite.sessionDeletionPending);

      await completePendingSessionDeletions();
      expect(sessions().keys.toList(), [_legacyId], reason: 'the legacy pending deletion is completed; the other record is left alone');
    });

    test('X180 — a session its recorder still controls is written by that recorder only. While its finalization is in '
        'flight the outcome waits: nothing is written and the record is not read as carrying it; it is then written AFTER '
        'the recorder\'s own last write. When the finalization FAILED the outcome is handed to the recorder — nothing is '
        'written, the record on disk is still the unfinalized one (it is not finalized ahead of its samples) — and the '
        'retry stores the finalized record with the outcome, also when the recorder\'s instance is stale (the sessions box '
        'was closed and reopened)', () async {
      final snapshots = StreamController<TelemetrySnapshot>.broadcast();
      Completer<void>? cancelGate;
      // A snapshot source whose cancel() waits for [cancelGate] when one is
      // set: that holds a stopSession() inside its finalization before
      // anything is written (the technique of session_history_screen_test.dart).
      final recorder = DrivingSessionRecorder(
        Stream<TelemetrySnapshot>.multi((c) {
          final sub = snapshots.stream.listen(c.add);
          c.onCancel = () async {
            await sub.cancel();
            final gate = cancelGate;
            if (gate != null) await gate.future;
          };
        }),
      );
      var clock = DateTime(2026, 5, 2, 9);
      Future<DrivingSession> record3() async {
        final s = recorder.startSession();
        for (var i = 0; i < 3; i++) {
          clock = clock.add(const Duration(seconds: 2));
          snapshots.add(TelemetrySnapshot(timestamp: clock, speedKmh: 40.0 + i, gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable));
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(s.sampleCount, 3, reason: 'setup');
        await sessions().flush(); // the per-sample record writes have landed
        return s;
      }

      try {
        // (a) Finalization in flight.
        final a = await record3();
        cancelGate = Completer<void>();
        final stopA = recorder.stopSession();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(recorder.state, DrivingSessionRecorderState.finalizing, reason: 'setup: held inside the finalization, nothing written');
        final writesOfA = <String>[];
        onSessionsWrite = () {
          writesOfA.add('endTime=${sessions().get(a.id)?.endTime != null} outcome=${sessions().get(a.id)?.dashcamTelemetryOutcome.name}');
          return false;
        };
        SessionTelemetryOutcomeWrite? written;
        final outcomeA = failed(a.id).then((w) => written = w);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(writesOfA, isEmpty, reason: 'without this rule the outcome\'s own write stored the record — end time set — ahead of the recorder\'s samples');
        expect(a.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: 'and nothing is set on the record under the recorder\'s hands');
        expect(written, isNull, reason: 'the outcome waits for the recorder');
        cancelGate.complete();
        cancelGate = null;
        await stopA;
        await outcomeA;
        onSessionsWrite = null;
        expect(written, SessionTelemetryOutcomeWrite.recorded);
        expect(writesOfA, ['endTime=true outcome=unknown', 'endTime=true outcome=failed'],
            reason: 'the recorder\'s own last write first, the outcome\'s after it');

        // (b) Finalization failed: the samples box is unavailable.
        final b = await record3();
        await samples().close();
        expect(await _errorOf(recorder.stopSession()), isA<HiveError>(), reason: 'setup');
        expect(recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup');
        sessionWrites = 0;
        expect(await failed(b.id, accepted: 28), SessionTelemetryOutcomeWrite.handedToRecorder);
        expect(sessionWrites, 0, reason: 'not written: the record is the recorder\'s until it finalizes');
        expect(b.dashcamTelemetryOutcome, DashcamTelemetryOutcome.failed, reason: 'the recorder\'s own instance carries it for the retry');
        expect(await failed(b.id, accepted: 28), SessionTelemetryOutcomeWrite.alreadyRecorded, reason: 'idempotent there too');
        await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples, compactionStrategy: (entries, deleted) => onSamplesWrite?.call() ?? false);
        await recorder.stopSession(); // the retry

        // (c) Finalization failed with the sessions box itself closed, then
        // reopened: the recorder's instance is stale.
        final c = await record3();
        await sessions().close();
        expect(await _errorOf(recorder.stopSession()), isA<HiveError>(), reason: 'setup');
        await openBoxes();
        final onDisk = sessions().get(c.id)!;
        expect(identical(onDisk, c), isFalse, reason: 'setup: the reopened box holds the record as its file has it');
        expect(onDisk.endTime, isNull, reason: 'setup: not finalized on disk');
        sessionWrites = 0;
        expect(await failed(c.id, accepted: 4, persisted: 1), SessionTelemetryOutcomeWrite.handedToRecorder);
        expect(sessionWrites, 0);
        expect([onDisk.endTime, onDisk.dashcamTelemetryOutcome], [null, DashcamTelemetryOutcome.unknown],
            reason: 'the unfinalized record on disk is left as it is — never finalized by the outcome');
        await recorder.stopSession(); // the retry: stores a copy of the recorder's instance
        expect(recorder.state, DrivingSessionRecorderState.idle);

        await restart();
        for (final (id, outcome) in [(a.id, 'failed 19/0/0'), (b.id, 'failed 28/0/0'), (c.id, 'failed 4/1/0')]) {
          expect(outcomeOf(id), outcome, reason: 'on disk');
          expect([sessions().get(id)!.endTime != null, sessions().get(id)!.sampleCount, ((await samples().get(id)) as List).length], [true, 3, 3],
              reason: 'on disk: $id finalized by its recorder, samples and all');
        }
      } finally {
        onSessionsWrite = null;
        final gate = cancelGate;
        if (gate != null && !gate.isCompleted) gate.complete();
        if (!Hive.isBoxOpen(HiveBoxNames.drivingSessionSamples) || !Hive.isBoxOpen(HiveBoxNames.drivingSessions)) {
          await Hive.close();
          await openBoxes();
        }
        for (var i = 0; i < 3 && recorder.hasPendingFinalization; i++) {
          await _errorOf(recorder.stopSession());
        }
        recorder.dispose();
        await snapshots.close();
      }
    });
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

typedef _Seeded = ({String id, List<File> clips, File telemetry});

Future<Object?> _errorOf(Future<Object?> f) async {
  try {
    await f.timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  }
}

/// Every call the generated adapter makes on a writer, in order.
class _FieldCapture implements BinaryWriter {
  final entries = <Object?>[];

  @override
  void writeByte(int value) => entries.add(value);

  @override
  void write<T>(T value, {bool writeTypeId = true}) =>
      entries.add(value is List ? [for (final e in value) e is DrivingSessionEvent ? '${e.type.name}@${e.timestamp.toIso8601String()}' : e] : value);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('$invocation');
}

/// What the adapter persists for [s]: field index → value.
Map<int, Object?> _fieldsOf(DrivingSession s) {
  final capture = _FieldCapture();
  DrivingSessionAdapter().write(capture, s);
  final e = capture.entries;
  return {for (var i = 1; i + 1 < e.length; i += 2) e[i]! as int: e[i + 1]};
}

/// Fields 0–25: everything a session persisted before R2.6.11.
Map<int, Object?> _legacy(Map<int, Object?> fields) => {
  for (final entry in fields.entries)
    if (entry.key <= 25) entry.key: entry.value,
};

/// Runs [body] with every clip (.mp4) and telemetry (.jsonl) File it creates
/// wrapped: [onFile] runs before delete() ('delete') and after a delete that
/// succeeded ('deleted'); it may throw. Every other File is the real one.
Future<T> _withFileHooks<T>(Future<T> Function() body, void Function(String path, String op) onFile) =>
    IOOverrides.runWithIOOverrides(body, _HookedIO(onFile));

final class _HookedIO extends IOOverrides {
  _HookedIO(this.onFile);
  final void Function(String path, String op) onFile;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('.mp4') || path.endsWith('.jsonl') ? _HookedFile(real, onFile) : real;
  }
}

class _HookedFile implements File {
  _HookedFile(this._inner, this._onFile);
  final File _inner;
  final void Function(String path, String op) _onFile;

  @override
  String get path => _inner.path;

  @override
  Future<bool> exists() => _inner.exists();

  @override
  bool existsSync() => _inner.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    _onFile(_inner.path, 'delete');
    final deleted = await _inner.delete(recursive: recursive);
    _onFile(_inner.path, 'deleted');
    return deleted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_HookedFile: ${invocation.memberName}');
}

/// A session adapter that fails its next [failures] serializations — inside
/// `writeFrames`, before a byte reaches the file: a write that fails BEFORE it
/// takes effect (the technique of session_deletion_protocol_test.dart).
class _WriteFailingSessionAdapter extends DrivingSessionAdapter {
  // TypeAdapter is @immutable: the counters live in a final holder.
  final _Counters _counters = _Counters();

  int get failures => _counters.failures;
  set failures(int value) => _counters.failures = value;

  /// Serializations attempted since the last reset.
  int get attempts => _counters.attempts;
  set attempts(int value) => _counters.attempts = value;

  @override
  void write(BinaryWriter writer, DrivingSession obj) {
    _counters.attempts++;
    if (_counters.failures > 0) {
      _counters.failures--;
      throw StateError('injected failure #${_counters.attempts} while serializing a session record');
    }
    super.write(writer, obj);
  }
}

class _Counters {
  int failures = 0;
  int attempts = 0;
}

const _legacyId = 'R2611-legacy';
const _legacyMarkedId = 'R2611-legacy-marked';

/// Fase 16.2-R4.3-R2.6.11 (X169): the whole `driving_sessions.hive` file of a
/// box holding TWO records — [_legacyId], a fully populated finished session,
/// and [_legacyMarkedId], a session marked for deletion — written by the build
/// right before fields 26–29 existed (R2.6.10 + T4 + T5: the tree this round
/// started from, whose driving_session.g.dart is SHA-256 ef30c704…87d5). Frozen
/// bytes — never re-derived from an adapter of this tree, which would only
/// prove the adapter reads its own output. Generator, its two identical runs
/// and the file (SHA-256 06f0297a…1c19, 617 bytes):
/// scratchpad/fase16_2_r4_3_r2_6_11/02_legacy_fixture. The values are the ones
/// [_expectLegacyFields] and X169 check.
const _legacySessionsBoxFile =
    'wAEAAAEMUjI2MTEtbGVnYWN5KhoABAwAAABSMjYxMS1sZWdhY3kBEgDQZvteCXpCAQISAGDGbWEJ'
    'ekIBAwIAAAAA0MPbQAQCAAAAAAAgWkAFAgAAAAAAoERABgIAAAAAAFSLQAcCAAAAAAD2hUAIAgAA'
    'AAAAANQ/CQIAAAAAAADiPwoCAAAAAADEh0ALAgAAAAAAYolADAIAAAAAAOBVQA0CAAAAAAA4aEAO'
    'AgAAAAAAANo/DwIAAAAAAADnPxABAAAAAAAKpEARAqs+V1uxjzfAEgJ56SYxCFRHwBMCAd4CCYov'
    'N8AUAqUsQxzrckfAFQIAAAAAAAAKQBYCAAAAAACwbkAXAgAAAAAAOGhAGAoCAAAALQ0ALAUBEgBA'
    'GtxfCXpCAQICAAAAAAAA3D8DBAsAAABldnQtcjI2MTEtMQQBAAAAAADAkkAFAmZmZmZmZjfABgIA'
    'AAAAAGBHwAcCAAAAAABATUAIAgAAAAAAsohACQIAAAAAAADAvwoCAAAAAAAA3D8LAh+F61G4Ht0/'
    'DC4BLQ0ALAQBEgAAynVgCXpCAQIAAwAEAAUABgAHAAgACQAKAAsADC4AGQMA/E0O96kAAAABE1Iy'
    'NjExLWxlZ2FjeS1tYXJrZWQqGgAEEwAAAFIyNjExLWxlZ2FjeS1tYXJrZWQBEgAA6OqfCXpCAQIS'
    'AKASoqAJekIBAwIAAAAAgAC0QAQCAAAAAAAgT0AFAAYABwAIAAkACgALAAwADQAOAA8AEAEAAAAA'
    'AHCHQBEAEgATABQAFQAWAgAAAAAAAAAAFwIAAAAAAAAAABgKAAAAABkDAXzCYXg=';

/// Every field 0–25 of [_legacyId] in [_legacySessionsBoxFile], as its
/// generator wrote them (UTC instants: the bytes do not depend on the time zone).
void _expectLegacyFields(DrivingSession s, String when) {
  expect(
    [
      s.id, s.startTime, s.endTime, s.distanceMeters, s.maxSpeedKmh, s.avgSpeedKmh, s.maxAltitudeMeters,
      s.minAltitudeMeters, s.maxAccelerationG, s.maxDecelerationG, s.initialAltitudeMeters, s.finalAltitudeMeters,
      s.initialHeadingDegrees, s.finalHeadingDegrees, s.maxLateralG, s.maxGForceMagnitude, s.sampleCount,
      s.initialLatitude, s.initialLongitude, s.finalLatitude, s.finalLongitude, s.avgGnssQualityIndex,
      s.altitudeGainMeters, s.altitudeLossMeters, s.events.length, s.deletionPending,
    ],
    [
      _legacyId, DateTime.utc(2026, 9, 12, 14, 5, 10, 125), DateTime.utc(2026, 9, 12, 14, 47, 55, 750), 28431.25, 104.5, 41.25, 874.5,
      702.75, 0.3125, 0.5625, 760.5, 812.25,
      87.5, 193.75, 0.40625, 0.71875, 2565,
      -23.5613, -46.6565, -23.1857, -46.8978, 3.25,
      245.5, 193.75, 2, false,
    ],
    reason: '$when: fields 0–25',
  );
  final full = s.events[0];
  expect(
    [
      full.type, full.timestamp, full.magnitude, full.id, full.durationMs, full.latitude, full.longitude,
      full.speedKmh, full.altitudeMeters, full.longitudinalG, full.lateralG, full.resultantG, full.severity,
    ],
    [
      DrivingSessionEventType.hardCorneringLeft, DateTime.utc(2026, 9, 12, 14, 20, 30, 500), 0.4375, 'evt-r2611-1', 1200, -23.4, -46.75,
      58.5, 790.25, -0.125, 0.4375, 0.455, EventSeverity.warning,
    ],
    reason: '$when: field 24, a fully populated event',
  );
  final bare = s.events[1];
  expect(
    [bare.type, bare.timestamp, bare.magnitude, bare.id, bare.durationMs, bare.resultantG, bare.severity],
    [DrivingSessionEventType.gnssRecovered, DateTime.utc(2026, 9, 12, 14, 31), null, null, null, null, EventSeverity.info],
    reason: '$when: field 24, an event with only its required fields',
  );
}
