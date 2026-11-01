import 'dart:async';
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
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/hive_box_io_gate.dart';
import 'support/hive_file_snapshot.dart';

// Fase 16.2-R4.3-R2.6.13 — X195–X207 and X211: what a write of a session's
// record stores, and in which order. Independent review of R2.6.12 (P2,
// reproduced with the reviewer's own probe —
// scratchpad/fase16_2_r4_3_independent_review_r2612):
// hive 2.2.3 serializes a record when its queued write RUNS, and the instance
// it serializes is the one the recorder keeps changing. A per-sample save
// requested BEFORE a STOP ran after it and stored the end time the STOP had
// just set — the record finished on disk declaring 4 samples with none stored.
// The samples write then failed (or the process died right there, with no I/O
// error anywhere), and the startup recovery, which reclaims ACTIVE records,
// never repaired it.
//
// The rule under test: an end time enters what a write of the record stores
// only at the finalization's terminal checkpoint — after every accepted sample
// is stored. Whatever was requested earlier, and whenever it runs, stores a
// session that is still active (or, once that checkpoint was reached, the same
// final state); a record that reads as finished on disk declares exactly the
// samples stored for it.
//
// The real DrivingSessionRecorder over real Hive in a temporary directory, the
// real deleteDrivingSession / persistSessionTelemetryOutcome /
// recoverDrivingSessionsAtStartup. The two box files are opened through
// support/hive_box_io_gate.dart: a write can be HELD after its frame was
// serialized and before a byte reaches the file — which leaves the writes
// requested meanwhile waiting in hive's own queue, requested and not
// serialized — or FAILED before it takes effect. A write that took effect and
// then threw is hive's own compaction failing to create its file, requested
// from the compaction-strategy callback. Assertions are on what the FILES hold
// (support/hive_file_snapshot.dart): the sessions box answers `get` from its
// cache, the recorder's own instance, so it cannot say what is durable.
//
// What is NOT promised, and X211 pins: a queued write stores the record as it
// is when it runs, not as it was when it was requested — a later sample count,
// on a session still active. A copy per write would take the recorder's own
// instance out of the box (X80, X81, X89–X91, X115: frozen).
//
// The model's side of the rule (an unconfirmed end time, the stored format) is
// in driving_session_end_time_test.dart (X208–X210).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late List<Directory> sideDirs;
  late StreamController<TelemetrySnapshot> snapshots;
  late List<DrivingSessionRecorder> recorders;
  late HiveBoxIoGate sessionsFile;
  late HiveBoxIoGate samplesFile;

  /// Compaction-strategy callbacks: each runs right after a write of its box
  /// took effect; returning true asks for a compaction.
  bool Function()? onSessionsWrite;
  bool Function()? onSamplesWrite;
  var clock = DateTime.utc(2026, 6, 1, 8);
  var speed = 0;

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  LazyBox samples() => Hive.lazyBox(HiveBoxNames.drivingSessionSamples);

  Future<void> openBoxes() async {
    await sessionsFile.open(
      () => Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions, compactionStrategy: (entries, deleted) => onSessionsWrite?.call() ?? false),
    );
    await samplesFile.open(
      () => Hive.openLazyBox(HiveBoxNames.drivingSessionSamples, compactionStrategy: (entries, deleted) => onSamplesWrite?.call() ?? false),
    );
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
  }

  /// Every box closed and reopened from its file: nothing cached answers.
  Future<void> restart() async {
    sessionsFile.releaseAll();
    samplesFile.releaseAll();
    await Hive.close();
    await openBoxes();
  }

  /// The next start of the app, as far as sessions go: the boxes as their
  /// files have them, then the startup recovery; and closed and reopened once
  /// more, so that what the recovery did is read from the files too.
  Future<void> nextStart() async {
    await restart();
    await recoverDrivingSessionsAtStartup();
    await restart();
  }

  /// A copy of the two session files as they are RIGHT NOW — what the next
  /// process finds if this one dies at this instant. Only taken while nothing
  /// is landing (a gate holds, or everything settled).
  Directory filesNow() {
    final copy = Directory.systemTemp.createTempSync('session_checkpoint_ordering_files');
    sideDirs.add(copy);
    for (final name in [HiveBoxNames.drivingSessions, HiveBoxNames.drivingSessionSamples]) {
      final file = File('${dir.path}/$name.hive');
      if (file.existsSync()) file.copySync('${copy.path}/$name.hive');
    }
    return copy;
  }

  /// The next start of the app over [files] instead of what this process went
  /// on to write: the process died at the instant [files] was taken.
  Future<void> nextStartAfterDyingAt(Directory files) async {
    sessionsFile.releaseAll();
    samplesFile.releaseAll();
    await Hive.close();
    for (final name in [HiveBoxNames.drivingSessions, HiveBoxNames.drivingSessionSamples]) {
      final current = File('${dir.path}/$name.hive');
      if (current.existsSync()) current.deleteSync();
      final then = File('${files.path}/$name.hive');
      if (then.existsSync()) then.copySync(current.path);
    }
    await openBoxes();
    await recoverDrivingSessionsAtStartup();
    await restart();
  }

  Future<void> until(bool Function() condition, String label, {Duration timeout = const Duration(seconds: 5)}) async {
    final sw = Stopwatch()..start();
    var turns = 0;
    while (!condition()) {
      if (sw.elapsed > timeout) fail('timed out waiting for: $label');
      // A few turns of the event loop first: most conditions here are a
      // microtask or one file operation away.
      await Future<void>.delayed(turns++ < 20 ? Duration.zero : const Duration(milliseconds: 2));
    }
  }

  DrivingSessionRecorder newRecorder() {
    final recorder = DrivingSessionRecorder(snapshots.stream);
    recorders.add(recorder);
    return recorder;
  }

  /// One sample, delivered SYNCHRONOUSLY: when this returns the recorder has
  /// counted it and REQUESTED its record save — nothing has been serialized
  /// yet. Sample #i of a test carries speed i.
  void sample() {
    clock = clock.add(const Duration(seconds: 2));
    speed++;
    snapshots.add(TelemetrySnapshot(timestamp: clock, speedKmh: speed.toDouble()));
  }

  /// [n] more samples on [recorder]'s session, every write they cause landed
  /// before this returns — each incremental flush (every tenth sample) before
  /// the next sample, so exactly the last `count % 10` stay pending.
  Future<void> landedSamples(DrivingSessionRecorder recorder, int n) async {
    for (var i = 0; i < n; i++) {
      sample();
      if (recorder.activeSession!.sampleCount % 10 == 0) {
        await until(() => recorder.pendingSampleCountForTest == 0, 'the incremental flush at sample ${recorder.activeSession!.sampleCount} has landed');
      }
    }
    await sessions().flush();
  }

  /// The reviewer's scenario up to the STOP: a session with [landed] samples
  /// whose writes are all in the files; one more whose record save is HELD
  /// inside the sessions file write, its frame already serialized; and one
  /// more whose record save is therefore only QUEUED — requested, and not
  /// serialized before the held one is released. [landed] + 2 samples accepted.
  Future<DrivingSession> sessionWithQueuedSave(DrivingSessionRecorder recorder, {required int landed}) async {
    final session = recorder.startSession();
    await landedSamples(recorder, landed);
    sessionsFile.hold = true;
    sample();
    await sessionsFile.untilHolding();
    sample();
    return session;
  }

  /// What the FILES hold about session [id], as text.
  Future<String> onDisk(String id) async {
    final r = await sessionRecordOnDisk(dir, id);
    final stored = await sessionSamplesOnDisk(dir, id);
    if (r == null) return 'no record, stored=${stored?.length}';
    final outcome = r.dashcamTelemetryOutcome == DashcamTelemetryOutcome.unknown
        ? 'unknown'
        : '${r.dashcamTelemetryOutcome.name} ${r.dashcamTelemetryAcceptedCount}/${r.dashcamTelemetryPersistedCount}/${r.dashcamTelemetryRefusedCount}';
    return '${r.deletionPending ? 'MARKED ' : ''}${r.endTime == null ? 'ACTIVE' : 'ENDED'} declared=${r.sampleCount} stored=${stored?.length ?? 0} telemetry=$outcome';
  }

  /// The end time the FILE holds for [id], in milliseconds (what hive stores).
  Future<int?> endOnDisk(String id) async => (await sessionRecordOnDisk(dir, id))?.endTime?.millisecondsSinceEpoch;

  /// The speeds of the samples the FILES hold for [id], in order.
  Future<List<int?>> storedSpeeds(String id) async => [for (final s in await sessionSamplesOnDisk(dir, id) ?? const <DrivingSessionSample>[]) s.speedKmh?.toInt()];

  List<int> range(int from, int to) => [for (var i = from; i <= to; i++) i];

  const samplesFailure = FileSystemException('injected: the samples write fails before any byte is written');

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('session_checkpoint_ordering_test');
    sideDirs = [];
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
    sessionsFile = HiveBoxIoGate(HiveBoxNames.drivingSessions);
    samplesFile = HiveBoxIoGate(HiveBoxNames.drivingSessionSamples);
    Hive.init(dir.path);
    await openBoxes();
    // Synchronous delivery: a sample and a STOP can share one slice.
    snapshots = StreamController<TelemetrySnapshot>.broadcast(sync: true);
    recorders = [];
    speed = 0;
  });

  tearDown(() async {
    onSessionsWrite = null;
    onSamplesWrite = null;
    sessionsFile.releaseAll();
    samplesFile.releaseAll();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final recorder in recorders) {
      try {
        recorder.dispose();
      } catch (_) {
        // Already disposed by its test.
      }
    }
    await snapshots.close();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, null);
    dir.deleteSync(recursive: true);
    for (final side in sideDirs) {
      if (side.existsSync()) side.deleteSync(recursive: true);
    }
  });

  group('Fase 16.2-R4.3-R2.6.13 — a record write requested before the STOP never stores the session as finished', () {
    for (final landed in [2, 10]) {
      final prefix = landed == 10 ? 10 : 0;
      final accepted = landed + 2;

      test('X195 [$prefix samples already stored] — the reviewer\'s scenario: a per-sample save is still QUEUED when the STOP ends the '
          'session; the finalization\'s samples write fails once; then the queued save runs. It stores a session that is STILL '
          'ACTIVE — in memory the session has ended for every reader — so the next start reclaims it and the record ends '
          'declaring exactly the samples that are stored', () async {
        final recorder = newRecorder();
        final a = await sessionWithQueuedSave(recorder, landed: landed);
        expect(a.sampleCount, accepted, reason: 'setup');
        expect(await onDisk(a.id), 'ACTIVE declared=$landed stored=$prefix telemetry=unknown', reason: 'setup: neither the held save nor the queued one is in the file');

        samplesFile.failNext(samplesFailure);
        final stopError = await _errorOf(recorder.stopSession());

        expect(stopError, same(samplesFailure), reason: 'setup: the finalization failed at its samples checkpoint, with that one injected error');
        expect(recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup');
        expect(a.endTime, isNotNull, reason: 'setup: the STOP ended the session, in memory');
        expect(sessionsFile.isHolding, isTrue, reason: 'setup: the sessions file is still busy — the queued save has not been serialized yet');
        expect(await onDisk(a.id), 'ACTIVE declared=$landed stored=$prefix telemetry=unknown', reason: 'setup: nothing reached the files meanwhile');

        sessionsFile.releaseAll();
        await sessions().flush();

        expect(await onDisk(a.id), 'ACTIVE declared=$accepted stored=$prefix telemetry=unknown',
            reason: 'pre-fix: "ENDED declared=$accepted stored=$prefix" — the save requested BEFORE the STOP was serialized after it and stored the '
                'end time; the finalization itself never wrote the record');
        expect(await durablyFinalizedViolations(dir, names: {a.id: 'A'}), isEmpty);
        expect(sessionsFile.failures, 0, reason: 'one I/O error in all: the samples write');
        expect(samplesFile.failures, 1);
        // What every reader of the process sees did not change.
        expect(sessions().get(a.id), same(a), reason: 'the box still holds the recorder\'s own instance');
        expect(a.isInBox, isTrue);
        expect(sessions().get(a.id)!.isActive, isFalse, reason: 'which reads as ended: what the history lists');
        expect(recorder.startSession, throwsA(isA<SessionAdmissionRejected>()), reason: 'and the session still awaits its finalization');
        expect(recorder.pendingSampleCountForTest, accepted - prefix, reason: 'nothing was dropped');

        // The app is restarted instead of retrying.
        recorder.dispose();
        await nextStart();

        expect(await onDisk(a.id), 'ENDED declared=$prefix stored=$prefix telemetry=unknown',
            reason: 'pre-fix: unchanged — the recovery reclaims ACTIVE records and this one read as finished, declaring $accepted samples with $prefix stored');
        expect(await storedSpeeds(a.id), range(1, prefix));
        final recovered = sessions().get(a.id)!;
        final lastStored = (await sessionSamplesOnDisk(dir, a.id))?.lastOrNull?.timestamp;
        expect(recovered.endTime, lastStored ?? recovered.startTime, reason: 'the end time is the recovery\'s — the last stored sample, or the start');
        expect(await durablyFinalizedViolations(dir), isEmpty);

        final next = newRecorder();
        final b = next.startSession();
        sample();
        await next.stopSession();
        expect(await onDisk(b.id), 'ENDED declared=1 stored=1 telemetry=unknown', reason: 'a new session starts and finishes normally');
        expect(await onDisk(a.id), 'ENDED declared=$prefix stored=$prefix telemetry=unknown');
      });

      test('X196 [$prefix samples already stored] — the same scenario, and the STOP is RETRIED in the same process: the retry stores the '
          'missing samples, each once, and only then the record — with the end time of the FIRST attempt; a new session is then '
          'admitted. Restart (X195) and retry both end with a finished record that declares what is stored', () async {
        final recorder = newRecorder();
        final a = await sessionWithQueuedSave(recorder, landed: landed);
        samplesFile.failNext(samplesFailure);
        expect(await _errorOf(recorder.stopSession()), same(samplesFailure), reason: 'setup');
        final firstEnd = a.endTime!;
        sessionsFile.releaseAll();
        await sessions().flush();
        expect(await onDisk(a.id), 'ACTIVE declared=$accepted stored=$prefix telemetry=unknown', reason: 'pre-fix: already "ENDED" here, before any retry');

        await recorder.stopSession();

        expect(recorder.state, DrivingSessionRecorderState.idle);
        expect(await onDisk(a.id), 'ENDED declared=$accepted stored=$accepted telemetry=unknown');
        expect(await storedSpeeds(a.id), range(1, accepted), reason: 'every sample once, in order');
        expect(await endOnDisk(a.id), firstEnd.millisecondsSinceEpoch, reason: 'the end time of the first attempt');
        expect(await durablyFinalizedViolations(dir), isEmpty);

        final b = recorder.startSession();
        expect(b.id, isNot(a.id));
        sample();
        await recorder.stopSession();
        expect(await onDisk(b.id), 'ENDED declared=1 stored=1 telemetry=unknown');

        await nextStart();
        expect(await onDisk(a.id), 'ENDED declared=$accepted stored=$accepted telemetry=unknown', reason: 'and the recovery has nothing to do');
        expect(await endOnDisk(a.id), firstEnd.millisecondsSinceEpoch);
      });
    }

    test('X197 — NO I/O error at all: the finalization\'s samples write is merely IN FLIGHT while the sessions queue drains. The '
        'record in the file stays ACTIVE until the samples are stored — a process that dies at that instant leaves a session '
        'the next start reclaims, not a finished one without samples — and then the STOP completes with everything stored', () async {
      final recorder = newRecorder();
      final a = await sessionWithQueuedSave(recorder, landed: 2);

      samplesFile.hold = true;
      var stopped = false;
      final stop = recorder.stopSession().then((_) => stopped = true);
      await samplesFile.untilHolding();
      sessionsFile.releaseAll();
      await sessions().flush();

      expect(await onDisk(a.id), 'ACTIVE declared=4 stored=0 telemetry=unknown',
          reason: 'pre-fix: "ENDED declared=4 stored=0", with the STOP still pending and no error anywhere');
      expect(stopped, isFalse, reason: 'setup: the STOP is waiting for its samples');
      expect(recorder.state, DrivingSessionRecorderState.finalizing);
      expect(samplesFile.failures + sessionsFile.failures, 0, reason: 'setup: no I/O error');
      final atThatInstant = filesNow();

      samplesFile.releaseAll();
      await stop;

      expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=unknown');
      expect(await storedSpeeds(a.id), [1, 2, 3, 4]);
      expect(await durablyFinalizedViolations(dir), isEmpty);
      expect(recorder.state, DrivingSessionRecorderState.idle);

      // The same run, had the process died while the samples write was in flight.
      recorder.dispose();
      await nextStartAfterDyingAt(atThatInstant);
      expect(await onDisk(a.id), 'ENDED declared=0 stored=0 telemetry=unknown',
          reason: 'pre-fix: "ENDED declared=4 stored=0", left as it was — a finished session whose 4 samples exist nowhere');
      expect(sessions().get(a.id)!.endTime, sessions().get(a.id)!.startTime, reason: 'closed by the recovery, from what is stored');
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });

    test('X198 — an EVENT\'s save queued before the STOP (no second sample is needed): it stores the event on a session that is '
        'still active', () async {
      final recorder = newRecorder();
      final a = recorder.startSession();
      await landedSamples(recorder, 2);
      sessionsFile.hold = true;
      sample();
      await sessionsFile.untilHolding();
      recorder.recordDetectedEvent(
        DetectedEvent(
          type: DetectedEventType.hardBraking,
          timestamp: clock,
          severity: EventSeverity.warning,
          snapshot: TelemetrySnapshot(timestamp: clock, speedKmh: 40),
          value: 0.5,
        ),
      );
      expect(a.events, hasLength(1), reason: 'setup: the event was accepted; its save is queued behind the held one');

      samplesFile.failNext(samplesFailure);
      expect(await _errorOf(recorder.stopSession()), same(samplesFailure), reason: 'setup');
      sessionsFile.releaseAll();
      await sessions().flush();

      final disk = (await sessionRecordOnDisk(dir, a.id))!;
      expect([disk.endTime, disk.sampleCount, disk.events.length], [null, 3, 1],
          reason: 'pre-fix: the event\'s save stored the end time — finished on disk with 3 samples declared, none stored');
      expect(await durablyFinalizedViolations(dir), isEmpty);

      recorder.dispose();
      await nextStart();
      expect(await onDisk(a.id), 'ENDED declared=0 stored=0 telemetry=unknown');
      expect(sessions().get(a.id)!.events, hasLength(1), reason: 'the event stays with the session the recovery closed');
    });

    test('X199 — the START\'s own put is the write still queued (the sessions file is busy with another record): started, one '
        'sample, stopped, and the samples write fails. The start\'s put and the sample\'s save both run after the STOP — and '
        'store an active session', () async {
      final recorder = newRecorder();
      sessionsFile.hold = true;
      final other = sessions().put('another-session', DrivingSession(id: 'another-session', startTime: clock, endTime: clock));
      await sessionsFile.untilHolding();

      final a = recorder.startSession();
      sample();
      samplesFile.failNext(samplesFailure);
      expect(await _errorOf(recorder.stopSession()), same(samplesFailure), reason: 'setup');
      expect(await sessionRecordOnDisk(dir, a.id), isNull, reason: 'setup: nothing of the session has reached the file — not even its first record');

      sessionsFile.releaseAll();
      await other;
      await sessions().flush();

      expect(await onDisk(a.id), 'ACTIVE declared=1 stored=0 telemetry=unknown',
          reason: 'pre-fix: "ENDED declared=1 stored=0" — the very first write of the record already stored the end time');
      expect(await durablyFinalizedViolations(dir), isEmpty);

      recorder.dispose();
      await nextStart();
      expect(await onDisk(a.id), 'ENDED declared=0 stored=0 telemetry=unknown');
      expect(await onDisk('another-session'), 'ENDED declared=0 stored=0 telemetry=unknown', reason: 'the other record is untouched');
    });

    test('X200 — ORDER of the record\'s writes, stepped one at a time. W1 (a save requested before the STOP) is held inside the '
        'file: the finalization\'s own write cannot complete before it, however long it waits. W1 lands with what the record '
        'was when it was serialized. The save queued behind it runs after the samples were stored and the end confirmed: it '
        'stores that same final state — never an older one on top of a newer one — and the terminal write lands last', () async {
      final recorder = newRecorder();
      final a = await sessionWithQueuedSave(recorder, landed: 2);
      expect(sessionsFile.landed, 3, reason: 'setup: the start\'s put and two saves are in the file');
      expect(sessionsFile.writes, 4, reason: 'setup: W1 — the save of sample 3 — is at the file; the save of sample 4 waits behind it');

      var stopped = false;
      final stop = recorder.stopSession().then((_) => stopped = true);
      await until(() => recorder.pendingSampleCountForTest == 0, 'the samples checkpoint landed');
      // Every chance for the terminal write to overtake W1.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(stopped, isFalse, reason: 'the terminal write is behind W1 in the box\'s queue');
      expect(sessionsFile.writes, 4, reason: 'nothing was even serialized past W1');
      expect(await onDisk(a.id), 'ACTIVE declared=2 stored=4 telemetry=unknown', reason: 'the file holds neither yet');

      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      expect(await onDisk(a.id), 'ACTIVE declared=3 stored=4 telemetry=unknown', reason: 'W1: serialized before the STOP — sample 3, no end time');
      expect(stopped, isFalse);

      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=unknown',
          reason: 'the save requested before the STOP ran after the terminal checkpoint was reached: the final state, with its samples already stored');
      expect(await durablyFinalizedViolations(dir), isEmpty);
      expect(stopped, isFalse, reason: 'the STOP still waits for its own write, the last one');

      sessionsFile.releaseAll();
      await stop;
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=unknown');
      expect(sessionsFile.writes, 6, reason: 'start, four samples, the terminal write: nothing else');

      // Nothing of the session lands later and undoes it.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sessionsFile.writes, 6);
      expect(sessionsFile.landed, 6);
      expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=unknown');
      expect(await storedSpeeds(a.id), [1, 2, 3, 4]);
    });

    test('X211 — what a queued save stores WHILE RECORDING, pinned: the record as it is when the save runs. The save requested at '
        'sample 4 runs after sample 5 was accepted and stores 5 — hive serializes the one instance the box holds, the '
        'recorder\'s — on a session that is still ACTIVE, where the count may be ahead of the stored samples anyway. What it can '
        'never store is the end: the record is finished only by the terminal checkpoint, with every sample stored', () async {
      final recorder = newRecorder();
      final a = await sessionWithQueuedSave(recorder, landed: 2);
      expect(a.sampleCount, 4, reason: 'setup: the save requested at sample 4 waits behind the held one');
      sample();
      expect(a.sampleCount, 5, reason: 'setup: and so does the one requested at sample 5');

      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'the held save: serialized when it reached the file, at sample 3');
      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      expect(await onDisk(a.id), 'ACTIVE declared=5 stored=0 telemetry=unknown',
          reason: 'the save requested at sample 4 stores the count as it is NOW; a per-write copy would unbind the recorder\'s instance from the box (X80, X81)');
      expect(sessions().get(a.id), same(a), reason: 'which stays the one the box holds');

      samplesFile.failNext(samplesFailure);
      expect(await _errorOf(recorder.stopSession()), same(samplesFailure), reason: 'setup: the session ends while the save requested at sample 5 is still at the file');
      sessionsFile.releaseAll();
      await sessions().flush();
      expect(await onDisk(a.id), 'ACTIVE declared=5 stored=0 telemetry=unknown', reason: 'and the end time is in none of them');

      await recorder.stopSession();
      expect(await onDisk(a.id), 'ENDED declared=5 stored=5 telemetry=unknown');
      expect(await storedSpeeds(a.id), [1, 2, 3, 4, 5]);
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });

    for (final n in [0, 1, 3, 10, 13, 25]) {
      final storedBefore = n == 0 ? 0 : ((n - 1) ~/ 10) * 10;

      test('X201 [$n samples] — the terminal record and the stored samples: the last record write before the STOP shares its slice '
          '(${n == 0 ? 'the start\'s own put' : 'the save of the last sample'}: requested, not serialized), and the finalization\'s samples write is held. While it is, '
          'the record in the file is ACTIVE — ahead of its samples, as it may be while recording; once it lands, the record is '
          'finished and declares exactly $n samples, $n stored', () async {
        final recorder = newRecorder();
        final a = recorder.startSession();
        if (n > 1) {
          await landedSamples(recorder, n - 1);
          expect(await onDisk(a.id), 'ACTIVE declared=${n - 1} stored=$storedBefore telemetry=unknown', reason: 'setup: recording — no equality between the two is required');
        }

        samplesFile.hold = true;
        if (n > 0) sample();
        var stopped = false;
        final stop = recorder.stopSession().then((_) => stopped = true);
        await samplesFile.untilHolding();
        await sessions().flush();

        expect(await onDisk(a.id), 'ACTIVE declared=$n stored=$storedBefore telemetry=unknown',
            reason: 'pre-fix: "ENDED declared=$n stored=$storedBefore" — finished in the file before its samples');
        expect(stopped, isFalse);

        samplesFile.releaseAll();
        await stop;

        expect(await onDisk(a.id), 'ENDED declared=$n stored=$n telemetry=unknown');
        expect(await storedSpeeds(a.id), range(1, n), reason: 'every sample once, in order');
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });
    }

    test('X202 — the samples write TOOK EFFECT and then threw (hive\'s compaction could not create its file), with a record save '
        'still queued: the attempt failed, so nothing says the session finished — the queued save stores it active — and the '
        'retry reconciles what is already stored instead of writing it again: every sample once, the first end time', () async {
      final recorder = newRecorder();
      final a = await sessionWithQueuedSave(recorder, landed: 2);
      // hive only compacts a box that has a dead entry: an unrelated key,
      // written twice.
      await samples().put('unrelated', const <DrivingSessionSample>[]);
      await samples().put('unrelated', const <DrivingSessionSample>[]);
      final obstacle = Directory('${dir.path}/${HiveBoxNames.drivingSessionSamples}.hivec')..createSync();
      onSamplesWrite = () => true;

      final stopError = await _errorOf(recorder.stopSession());

      onSamplesWrite = null;
      obstacle.deleteSync(recursive: true);
      expect(stopError, isA<FileSystemException>(), reason: 'setup: the compaction after the samples write failed');
      expect(await storedSpeeds(a.id), [1, 2, 3, 4], reason: 'setup: the write itself took effect');
      expect(recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup');
      final firstEnd = a.endTime!;

      sessionsFile.releaseAll();
      await sessions().flush();
      expect(await onDisk(a.id), 'ACTIVE declared=4 stored=4 telemetry=unknown',
          reason: 'the attempt never reached its terminal checkpoint, and no earlier write stands in for it (pre-fix: "ENDED", written by the queued save)');

      await recorder.stopSession();

      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=unknown');
      expect(await storedSpeeds(a.id), [1, 2, 3, 4], reason: 'reconciled by position: what the failed write had stored is not appended again');
      expect(await endOnDisk(a.id), firstEnd.millisecondsSinceEpoch);
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });

    for (final then in ['retry', 'restart']) {
      test('X203 [$then] — the TERMINAL record write took effect and then threw: the file already holds the finished record — '
          'written only after its samples — while the recorder reports the failure and keeps the session. The $then leaves '
          'that same record: same end time, same count, every sample once', () async {
        final recorder = newRecorder();
        final a = recorder.startSession();
        await landedSamples(recorder, 3);
        final obstacle = Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec')..createSync();
        onSessionsWrite = () => true;

        final stopError = await _errorOf(recorder.stopSession());

        onSessionsWrite = null;
        obstacle.deleteSync(recursive: true);
        expect(stopError, isA<FileSystemException>(), reason: 'setup: the compaction after the terminal write failed');
        expect(recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup: the attempt failed');
        expect(await onDisk(a.id), 'ENDED declared=3 stored=3 telemetry=unknown', reason: 'the write took effect — and it was requested only with the samples stored');
        final firstEnd = a.endTime!;
        expect(recorder.startSession, throwsA(isA<SessionAdmissionRejected>()));

        if (then == 'retry') {
          await recorder.stopSession();
          expect(recorder.state, DrivingSessionRecorderState.idle);
        } else {
          recorder.dispose();
          await nextStart();
        }

        expect(await onDisk(a.id), 'ENDED declared=3 stored=3 telemetry=unknown');
        expect(await storedSpeeds(a.id), [1, 2, 3]);
        expect(await endOnDisk(a.id), firstEnd.millisecondsSinceEpoch, reason: 'neither a retry nor the recovery changes a record that was already finished');
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });

      test('X204 [$then] — the TERMINAL record write fails before taking effect, with 10 samples checkpointed earlier and 3 stored '
          'by the finalization: the file keeps an active record over 13 stored samples. The $then finishes it — 13 declared, '
          '13 stored, none twice', () async {
        final recorder = newRecorder();
        final a = recorder.startSession();
        await landedSamples(recorder, 13);
        expect(await onDisk(a.id), 'ACTIVE declared=13 stored=10 telemetry=unknown', reason: 'setup');
        const recordFailure = FileSystemException('injected: the terminal record write fails before any byte is written');
        sessionsFile.failNext(recordFailure);

        expect(await _errorOf(recorder.stopSession()), same(recordFailure), reason: 'setup: the samples were stored, the record write failed');

        expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);
        expect(await onDisk(a.id), 'ACTIVE declared=13 stored=13 telemetry=unknown', reason: 'the terminal write did not happen');
        final firstEnd = a.endTime!;

        if (then == 'retry') {
          await recorder.stopSession();
          expect(recorder.state, DrivingSessionRecorderState.idle);
          expect(await endOnDisk(a.id), firstEnd.millisecondsSinceEpoch, reason: 'the end time of the first attempt');
        } else {
          recorder.dispose();
          await nextStart();
          final lastStored = (await sessionSamplesOnDisk(dir, a.id))!.last.timestamp;
          expect(sessions().get(a.id)!.endTime, lastStored, reason: 'closed by the recovery: the last stored sample');
        }

        expect(await onDisk(a.id), 'ENDED declared=13 stored=13 telemetry=unknown');
        expect(await storedSpeeds(a.id), range(1, 13), reason: 'the samples the failed attempt had stored are not written again');
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });

      test('X205 [$then] — a field of ANOTHER authority while an old record write is pending: the finalization failed, a save '
          'requested before the STOP is still queued, and the session\'s telemetry outcome is handed to the recorder. The queued '
          'save stores the record as it is when it runs — the outcome is in it, the end time is not — and the $then keeps the '
          'outcome: no write of the record carries an older copy of it', () async {
        final recorder = newRecorder();
        final a = await sessionWithQueuedSave(recorder, landed: 2);
        samplesFile.failNext(samplesFailure);
        expect(await _errorOf(recorder.stopSession()), same(samplesFailure), reason: 'setup');

        final handed = await persistSessionTelemetryOutcome(a.id, outcome: DashcamTelemetryOutcome.failed, accepted: 19, persisted: 5, refused: 2);

        expect(handed, SessionTelemetryOutcomeWrite.handedToRecorder, reason: 'setup: its recorder still controls the session');
        expect(await onDisk(a.id), 'ACTIVE declared=2 stored=0 telemetry=unknown', reason: 'setup: the outcome wrote nothing, and the sessions file is still busy');

        sessionsFile.releaseAll();
        await sessions().flush();
        expect(await onDisk(a.id), 'ACTIVE declared=4 stored=0 telemetry=failed 19/5/2',
            reason: 'pre-fix: "ENDED declared=4 stored=0 telemetry=failed 19/5/2"');

        if (then == 'retry') {
          await recorder.stopSession();
          expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=failed 19/5/2', reason: 'the terminal checkpoint did not erase it');
        } else {
          recorder.dispose();
          await nextStart();
          expect(await onDisk(a.id), 'ENDED declared=0 stored=0 telemetry=failed 19/5/2', reason: 'nor did the recovery');
        }
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });
    }

    test('X206 — a DELETION while old record writes are pending. (a) Recording, two saves on their way, the recorder is disposed '
        'and the session deleted; the deletion stops at its telemetry file. The save that runs after the marker was set stores '
        'the record MARKED — it cannot write the marker back — and the next start completes the deletion. (b) Abandoned after '
        'a failed finalization, deleted: the marked record is written as it reads, ended; once removed the session never '
        'comes back', () async {
      // (a)
      final recorderA = newRecorder();
      final a = await sessionWithQueuedSave(recorderA, landed: 2);
      recorderA.dispose();
      expect(DrivingSessionRecorder.controllingState(a.id), isNull, reason: 'setup: a disposed recorder controls nothing — its two record writes are still on their way');
      (await DashcamTelemetryWriter.fileForSession(a.id))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"t":0}\n');

      final deletion = _errorOf(IOOverrides.runWithIOOverrides(() => deleteDrivingSession(a.id), _UndeletableTelemetry()));
      expect(sessions().get(a.id)!.deletionPending, isTrue, reason: 'setup: the deletion marked the record, in memory; its own write waits behind the recorder\'s two');

      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'the held save: serialized before the deletion began');
      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      expect(await onDisk(a.id), 'MARKED ACTIVE declared=4 stored=0 telemetry=unknown',
          reason: 'the recorder\'s older save ran after the marker was set and stores the record as it is — marked');
      sessionsFile.releaseAll();

      expect(await deletion, isA<FileSystemException>(), reason: 'setup: the deletion stopped at the telemetry file');
      expect(await onDisk(a.id), 'MARKED ACTIVE declared=4 stored=0 telemetry=unknown', reason: 'the marker stays, whatever was written around it');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(await onDisk(a.id), 'MARKED ACTIVE declared=4 stored=0 telemetry=unknown', reason: 'and nothing of the recorder lands afterwards');

      // (b)
      final recorderB = newRecorder();
      final b = await sessionWithQueuedSave(recorderB, landed: 2);
      samplesFile.failNext(samplesFailure);
      expect(await _errorOf(recorderB.stopSession()), same(samplesFailure), reason: 'setup');
      expect(await _errorOf(deleteDrivingSession(b.id)), isA<SessionDeletionRejected>(), reason: 'setup: not deletable while its recorder controls it (R2.6.6)');
      recorderB.dispose();

      final deletionB = deleteDrivingSession(b.id);
      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      sessionsFile.releaseNext();
      await sessionsFile.untilHolding();
      expect(await onDisk(b.id), 'MARKED ENDED declared=4 stored=0 telemetry=unknown',
          reason: 'a record being deleted is written as it reads — the end time of the failed finalization included (R2.6.12)');
      sessionsFile.releaseAll();
      await deletionB;
      expect(await onDisk(b.id), 'no record, stored=null');

      await nextStart();

      expect(await onDisk(a.id), 'no record, stored=null', reason: 'the next start completed the interrupted deletion — it did not reclaim the marked record');
      expect((await DashcamTelemetryWriter.fileForSession(a.id)).existsSync(), isFalse);
      expect(await onDisk(b.id), 'no record, stored=null', reason: 'and a session that was removed is not recreated');
      expect(sessions().keys, isEmpty);
    });

    for (final then in ['fails', 'lands']) {
      test('X207 [the samples write then $then] — the recorder is DISPOSED while its finalization is in flight (the app\'s root torn '
          'down mid-STOP), a record save still queued. The queued save stores an active session. ${then == 'fails' ? 'The attempt then fails: nothing can retry it in this process, and the next start reclaims the session' : 'The attempt then completes: it was in flight at the dispose and keeps its semantics — samples, then the record'}', () async {
        final recorder = newRecorder();
        final a = await sessionWithQueuedSave(recorder, landed: 2);
        samplesFile.hold = true;
        if (then == 'fails') samplesFile.failNext(samplesFailure);
        final stop = _errorOf(recorder.stopSession());
        await samplesFile.untilHolding();

        recorder.dispose();
        sessionsFile.releaseAll();
        await sessions().flush();

        expect(await onDisk(a.id), 'ACTIVE declared=4 stored=0 telemetry=unknown', reason: 'pre-fix: "ENDED declared=4 stored=0"');
        expect(DrivingSessionRecorder.controllingState(a.id), DrivingSessionRecorderState.finalizing, reason: 'the attempt in flight still writes the session (R2.6.6)');

        samplesFile.releaseAll();
        final stopError = await stop;

        if (then == 'fails') {
          expect(stopError, same(samplesFailure));
          expect(await onDisk(a.id), 'ACTIVE declared=4 stored=0 telemetry=unknown');
          expect(await _errorOf(recorder.stopSession()), isA<StateError>(), reason: 'no retry after dispose (R2.6.7)');
          expect(await onDisk(a.id), 'ACTIVE declared=4 stored=0 telemetry=unknown', reason: 'and the refusal wrote nothing');
          await nextStart();
          expect(await onDisk(a.id), 'ENDED declared=0 stored=0 telemetry=unknown');
        } else {
          expect(stopError, isNull);
          expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=unknown');
          expect(await storedSpeeds(a.id), [1, 2, 3, 4]);
          await nextStart();
          expect(await onDisk(a.id), 'ENDED declared=4 stored=4 telemetry=unknown');
        }
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });
    }
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

Future<Object?> _errorOf(Future<Object?> f) async {
  try {
    await f.timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  }
}

/// A telemetry file (`.jsonl`) that cannot be deleted — in use by its writer.
final class _UndeletableTelemetry extends IOOverrides {
  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('.jsonl') ? _UndeletableFile(real) : real;
  }
}

class _UndeletableFile implements File {
  _UndeletableFile(this._inner);
  final File _inner;

  @override
  String get path => _inner.path;

  @override
  Future<bool> exists() => _inner.exists();

  @override
  bool existsSync() => _inner.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => throw FileSystemException('injected: in use', _inner.path);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_UndeletableFile: ${invocation.memberName}');
}
