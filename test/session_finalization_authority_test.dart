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
import 'package:synapse_auto/screens/sessions/session_history_screen.dart' show visibleSessionsSortedByRecency;
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/hive_file_snapshot.dart';

// Fase 16.2-R4.3-R2.6.12 — X182–X189: who may make a session's finalization
// durable. Independent review of R2.6.11 (P2, reproduced — also through the
// app's real root teardown, scratchpad/fase16_2_r4_3_independent_review_r2611):
// a recorder whose finalization had FAILED was disposed, the session's dashcam
// telemetry file closed afterwards, and its outcome — finding no recorder in
// control — wrote the record the sessions box held: the end time of the failed
// finalization included. The record read as finalized on disk with 3 samples
// declared and none stored, and the startup recovery, which reclaims active
// records, never repaired it.
//
// The rule under test: a telemetry outcome changes its own four fields and
// nothing else. The end time, the sample count and the finalization of a
// session belong to its recorder, and nothing else makes them durable — not
// while the recorder finalizes, not after it failed, and not after it was
// disposed.
//
// The real DrivingSessionRecorder over real Hive in a temporary directory, the
// real persistSessionTelemetryOutcome / deleteDrivingSession /
// recoverDrivingSessionsAtStartup. Assertions are on consequences, read from
// the box FILES (support/hive_file_snapshot.dart: the sessions box answers
// `get` from its cache — the recorder's own instance — so it cannot say what is
// durable) and, for a restart, from boxes closed and reopened. Failure
// injection uses the suite's own points: a box that is closed; an adapter that
// throws while serializing (a write that fails BEFORE it takes effect, with
// the box open); and a compaction that cannot create its file, requested from
// the compaction-strategy callback — which runs right after a write took
// effect — so the write is on disk and its put still throws. The controller
// level (the real DashcamSessionController and telemetry writer) is in
// dashcam_finalization_authority_session_test.dart; the app's real root
// teardown in session_host/x194_root_unmount_failed_finalization_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late StreamController<TelemetrySnapshot> snapshots;
  late List<DrivingSessionRecorder> recorders;
  late List<Completer<void>> gates;
  bool Function()? onSessionsWrite;
  bool Function()? onSamplesWrite;

  /// Writes of the sessions box that took effect (one per put/delete frame).
  var sessionWrites = 0;
  var clock = DateTime(2026, 6, 1, 8);

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  LazyBox samples() => Hive.lazyBox(HiveBoxNames.drivingSessionSamples);

  Future<void> openSamples() => Hive.openLazyBox(HiveBoxNames.drivingSessionSamples, compactionStrategy: (entries, deleted) => onSamplesWrite?.call() ?? false);

  Future<void> openBoxes() async {
    await Hive.openBox<DrivingSession>(
      HiveBoxNames.drivingSessions,
      compactionStrategy: (entries, deleted) {
        sessionWrites++;
        return onSessionsWrite?.call() ?? false;
      },
    );
    await openSamples();
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
  }

  /// Every box closed and reopened from its file: nothing cached answers.
  Future<void> restart() async {
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

  /// A recorder whose snapshot subscription's cancel() waits for the returned
  /// gate while one is held: that holds its stopSession() inside the
  /// finalization BEFORE anything is written (the technique of X180).
  ({DrivingSessionRecorder recorder, void Function() hold, void Function() release}) gatedRecorder() {
    Completer<void>? gate;
    final recorder = DrivingSessionRecorder(
      Stream<TelemetrySnapshot>.multi((c) {
        final sub = snapshots.stream.listen(c.add);
        c.onCancel = () async {
          await sub.cancel();
          final held = gate;
          if (held != null) await held.future;
        };
      }),
    );
    recorders.add(recorder);
    return (
      recorder: recorder,
      hold: () {
        final held = Completer<void>();
        gate = held;
        gates.add(held);
      },
      release: () {
        final held = gate;
        gate = null;
        if (held != null && !held.isCompleted) held.complete();
      },
    );
  }

  /// Starts a session on [recorder] and has it accept [n] samples, sample #i
  /// (from 1) carrying speed i — one at a time, as a drive delivers them, each
  /// incremental flush (every tenth sample) landing before the next sample: so
  /// exactly the last `n % 10` samples are still pending. Returns once every
  /// write they caused has landed, the record's own save on each sample
  /// included.
  Future<DrivingSession> record(DrivingSessionRecorder recorder, int n) async {
    final session = recorder.startSession();
    for (var i = 1; i <= n; i++) {
      clock = clock.add(const Duration(seconds: 2));
      snapshots.add(TelemetrySnapshot(timestamp: clock, speedKmh: i.toDouble(), gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable));
      await until(() => session.sampleCount == i, 'sample $i accepted');
      if (i % 10 == 0) await until(() => recorder.pendingSampleCountForTest == 0, 'the incremental flush at sample $i has landed');
    }
    await sessions().flush();
    return session;
  }

  Future<SessionTelemetryOutcomeWrite> succeeded(String id, {int samples = 19}) =>
      persistSessionTelemetryOutcome(id, outcome: DashcamTelemetryOutcome.success, accepted: samples, persisted: samples, refused: 0);

  Future<SessionTelemetryOutcomeWrite> failed(String id, {int accepted = 19, int persisted = 0, int refused = 0}) =>
      persistSessionTelemetryOutcome(id, outcome: DashcamTelemetryOutcome.failed, accepted: accepted, persisted: persisted, refused: refused);

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

  /// The speeds of the samples the FILES hold for [id], in order.
  Future<List<int?>> storedSpeeds(String id) async => [for (final s in await sessionSamplesOnDisk(dir, id) ?? const <DrivingSessionSample>[]) s.speedKmh?.toInt()];

  List<int> range(int from, int to) => [for (var i = from; i <= to; i++) i];

  /// Makes [recorder]'s next finalization fail at its samples checkpoint, in
  /// one of three ways; returns what undoes the injection.
  Future<Future<void> Function()> failSamplesCheckpoint(_SamplesFailure how) async {
    switch (how) {
      case _SamplesFailure.boxClosed:
        await samples().close();
        return openSamples;
      case _SamplesFailure.writeFailsBeforeEffect:
        Hive.registerAdapter<DrivingSessionSample>(_WriteFailingSampleAdapter(), override: true);
        return () async => Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
      case _SamplesFailure.writeTookEffectThenFailed:
        // hive only compacts a box that has a dead entry: an unrelated key,
        // written twice.
        await samples().put('unrelated', const <DrivingSessionSample>[]);
        await samples().put('unrelated', const <DrivingSessionSample>[]);
        final obstacle = Directory('${dir.path}/${HiveBoxNames.drivingSessionSamples}.hivec')..createSync();
        onSamplesWrite = () => true; // ask for the compaction that cannot create its file
        return () async {
          onSamplesWrite = null;
          if (obstacle.existsSync()) obstacle.deleteSync(recursive: true);
        };
    }
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('session_finalization_authority_test');
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
    Hive.init(dir.path);
    await openBoxes();
    snapshots = StreamController<TelemetrySnapshot>.broadcast();
    recorders = [];
    gates = [];
    sessionWrites = 0;
  });

  tearDown(() async {
    onSessionsWrite = null;
    onSamplesWrite = null;
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
    Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
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
  });

  group('Fase 16.2-R4.3-R2.6.12 — a telemetry outcome never finalizes a session in its recorder\'s place', () {
    for (final how in _SamplesFailure.values) {
      test('X182 [${how.name}] — the recorder\'s finalization FAILS, the recorder is disposed, and the session\'s telemetry outcome '
          'arrives afterwards: nothing is written — the file keeps the UNFINALIZED record, no end time, no outcome — and '
          'nothing is set on the abandoned instance; the next start still reclaims the session, and after it the record '
          'declares exactly the samples that are stored; only then does a new session start and finish normally', () async {
        final recorder = newRecorder();
        final a = await record(recorder, 3);
        expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'setup: three samples accepted, below the incremental flush');

        final undo = await failSamplesCheckpoint(how);
        final stopError = await _errorOf(recorder.stopSession());
        await undo();
        expect(stopError, isNotNull, reason: 'setup: the finalization failed at its samples checkpoint');
        expect(recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup');
        expect(a.endTime, isNotNull, reason: 'setup: the STOP set the end time on the recorder\'s instance, in memory');
        // What the failed samples write left: nothing — or, when it took
        // effect before throwing, the three samples themselves.
        final stored = how == _SamplesFailure.writeTookEffectThenFailed ? 3 : 0;
        final unfinalized = 'ACTIVE declared=3 stored=$stored telemetry=unknown';
        expect(await onDisk(a.id), unfinalized, reason: 'setup: the record\'s own finalizing write was never issued');

        recorder.dispose();
        expect(DrivingSessionRecorder.controllingState(a.id), isNull, reason: 'setup: a disposed recorder controls nothing — the state the outcome arrives in');
        sessionWrites = 0;

        final written = await succeeded(a.id); // the telemetry file itself was fine

        expect(await onDisk(a.id), unfinalized, reason: 'pre-fix: "ENDED declared=3 stored=0 telemetry=success 19/19/0" — finalized on disk by the outcome');
        expect(sessionWrites, 0, reason: 'pre-fix: one write — the whole cached record, with the end time of the FAILED finalization');
        expect(a.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: 'and nothing is set on an instance nobody will write again');
        expect(written, SessionTelemetryOutcomeWrite.sessionNotFinalized);
        expect(recorder.startSession, throwsA(isA<SessionAdmissionRejected>()), reason: 'and it released nothing: the session is still one whose finalization is pending');
        expect(await _errorOf(recorder.stopSession()), isA<StateError>(), reason: 'no retry after dispose (R2.6.7): the outcome was not this session\'s last chance');
        expect(await onDisk(a.id), unfinalized);

        // The next start: the session is still one the recovery reconciles.
        await nextStart();
        expect(await onDisk(a.id), 'ENDED declared=$stored stored=$stored telemetry=unknown',
            reason: 'pre-fix: the recovery skipped it (it read as finalized) and it kept declaring 3 samples with none stored');
        final recovered = sessions().get(a.id)!;
        final lastStored = (await sessionSamplesOnDisk(dir, a.id))?.lastOrNull?.timestamp;
        expect(recovered.endTime, lastStored ?? recovered.startTime, reason: 'the end time is the recovery\'s — the last stored sample, or the start — not the failed STOP\'s');
        expect(await storedSpeeds(a.id), range(1, stored), reason: 'what was stored is there exactly once');
        expect(await durablyFinalizedViolations(dir), isEmpty);
        expect(visibleSessionsSortedByRecency(sessions().values).map((s) => s.id), [a.id], reason: 'and it is listed again');

        // A new session, after the convergence.
        final next = newRecorder();
        final b = await record(next, 2);
        await next.stopSession();
        final onB = await succeeded(b.id, samples: 5);
        await restart();
        expect(await onDisk(b.id), 'ENDED declared=2 stored=2 telemetry=success 5/5/0', reason: 'and ITS outcome is recorded: its recorder finalized it');
        expect(onB, SessionTelemetryOutcomeWrite.recorded);
        expect(await onDisk(a.id), 'ENDED declared=$stored stored=$stored telemetry=unknown', reason: 'A is not touched by B');
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });
    }

    test('X183 — the recorder is disposed WHILE its finalization is in flight, the telemetry outcome already waiting for it. '
        'When that finalization then FAILS, the outcome writes nothing: the file keeps the unfinalized record. When it '
        'SUCCEEDS, the attempt in flight at the dispose keeps its semantics: the record is finalized by its recorder and the '
        'outcome is recorded on it, after the recorder\'s own write', () async {
      // (a) Fails after the dispose.
      final g = gatedRecorder();
      final a = await record(g.recorder, 3);
      g.hold();
      final stopA = _errorOf(g.recorder.stopSession());
      await until(() => g.recorder.state == DrivingSessionRecorderState.finalizing, 'A: held inside its finalization');
      sessionWrites = 0;
      SessionTelemetryOutcomeWrite? writtenA;
      final outcomeA = succeeded(a.id).then((w) => writtenA = w);
      await Future<void>.delayed(const Duration(milliseconds: 40)); // an absence, under a held gate
      expect([writtenA, sessionWrites, a.dashcamTelemetryOutcome], [null, 0, DashcamTelemetryOutcome.unknown], reason: 'setup: the outcome waits for the recorder (X180)');

      g.recorder.dispose();
      expect(DrivingSessionRecorder.controllingState(a.id), DrivingSessionRecorderState.finalizing, reason: 'setup: the attempt in flight still writes the session');
      await samples().close(); // its samples checkpoint will fail
      g.release();
      expect(await stopA, isA<HiveError>(), reason: 'setup: the finalization failed, after the dispose');
      await outcomeA;
      await openSamples();
      expect(DrivingSessionRecorder.controllingState(a.id), isNull, reason: 'setup: the failure released the disposed recorder\'s authority — the state the waiting outcome resumes in');

      expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'pre-fix: "ENDED declared=3 stored=0 telemetry=success 19/19/0"');
      expect(sessionWrites, 0, reason: 'pre-fix: the waiting outcome, finding no recorder any more, wrote the cached record');
      expect(a.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown);
      expect(writtenA, SessionTelemetryOutcomeWrite.sessionNotFinalized);

      // (b) Succeeds after the dispose.
      final h = gatedRecorder();
      final b = await record(h.recorder, 3);
      h.hold();
      final stopB = _errorOf(h.recorder.stopSession());
      await until(() => h.recorder.state == DrivingSessionRecorderState.finalizing, 'B: held inside its finalization');
      final writesOfB = <String>[];
      onSessionsWrite = () {
        writesOfB.add('endTime=${sessions().get(b.id)?.endTime != null} outcome=${sessions().get(b.id)?.dashcamTelemetryOutcome.name}');
        return false;
      };
      final outcomeB = failed(b.id);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      h.recorder.dispose();
      h.release();
      expect(await stopB, isNull, reason: 'setup: the attempt in flight at the dispose completed');
      final writtenB = await outcomeB;
      onSessionsWrite = null;

      expect(await onDisk(b.id), 'ENDED declared=3 stored=3 telemetry=failed 19/0/0', reason: 'finalized by its recorder; the outcome was not lost to the dispose');
      expect(writesOfB, ['endTime=true outcome=unknown', 'endTime=true outcome=failed'], reason: 'the recorder\'s own write first, the outcome\'s after it');
      expect(writtenB, SessionTelemetryOutcomeWrite.recorded);

      await nextStart();
      expect([await onDisk(a.id), await onDisk(b.id)], ['ENDED declared=0 stored=0 telemetry=unknown', 'ENDED declared=3 stored=3 telemetry=failed 19/0/0']);
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });

    test('X184 — the dispose lands in the window of the handoff. (a) Between the finalization\'s failure and the waiting '
        'outcome\'s continuation — the recorder disposed from a session-control listener: the outcome, resuming with no '
        'recorder in control, writes nothing. (b) Right AFTER the outcome was handed to the live recorder: the recorder\'s '
        'instance carries it, nobody writes it, and a repeat of the same outcome does not either; the next start reclaims '
        'both sessions and their telemetry outcome is unknown — never read from an instance that was not stored', () async {
      // (a)
      final g = gatedRecorder();
      final a = await record(g.recorder, 3);
      final order = <String>[];
      void disposeOnFailure() {
        if (g.recorder.state != DrivingSessionRecorderState.finalizationFailed || order.contains('disposed')) return;
        order.add('disposed');
        g.recorder.dispose();
      }

      DrivingSessionRecorder.sessionControlChanges.addListener(disposeOnFailure);
      addTearDown(() => DrivingSessionRecorder.sessionControlChanges.removeListener(disposeOnFailure));
      g.hold();
      final stopA = _errorOf(g.recorder.stopSession());
      await until(() => g.recorder.state == DrivingSessionRecorderState.finalizing, 'A: held inside its finalization');
      sessionWrites = 0;
      final outcomeA = succeeded(a.id).then((w) {
        order.add('outcome resumed');
        return w;
      });
      await samples().close();
      g.release();
      expect(await stopA, isA<HiveError>(), reason: 'setup');
      final writtenA = await outcomeA;
      await openSamples();
      DrivingSessionRecorder.sessionControlChanges.removeListener(disposeOnFailure);
      expect(order, ['disposed', 'outcome resumed'], reason: 'setup: the dispose came between the failure and the outcome\'s continuation');

      expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'pre-fix: the outcome resumed with no recorder in control and wrote the cached record — finalized, 3 declared, none stored');
      expect(sessionWrites, 0);
      expect(a.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown);
      expect(writtenA, SessionTelemetryOutcomeWrite.sessionNotFinalized);

      // (b)
      final recorder = newRecorder();
      final b = await record(recorder, 3);
      await samples().close();
      expect(await _errorOf(recorder.stopSession()), isA<HiveError>(), reason: 'setup');
      await openSamples();
      sessionWrites = 0;
      final handed = await failed(b.id, accepted: 28);
      expect(b.dashcamTelemetryOutcome, DashcamTelemetryOutcome.failed, reason: 'setup: handed to the live recorder — its instance carries it, in memory (X180)');
      recorder.dispose();
      final repeated = await failed(b.id, accepted: 28);

      expect(await onDisk(b.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'what only the abandoned instance carries is not on disk');
      expect(sessionWrites, 0, reason: 'the handoff wrote nothing, the dispose wrote nothing, the repeat wrote nothing');
      expect(handed, SessionTelemetryOutcomeWrite.handedToRecorder);
      expect(repeated, SessionTelemetryOutcomeWrite.sessionNotFinalized, reason: 'not "already recorded": the instance carries it, the file does not');

      await nextStart();
      expect([await onDisk(a.id), await onDisk(b.id)], ['ENDED declared=0 stored=0 telemetry=unknown', 'ENDED declared=0 stored=0 telemetry=unknown']);
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });

    test('X185 — the outcome before, during and after the recorder\'s finalization, with the recorder alive: BEFORE (still '
        'recording) it is handed over and stored by the finalization; DURING it waits; AFTER A SUCCESS it is written on the '
        'finalized record; AFTER A FAILURE it is handed over, the file stays unfinalized, and the retry stores both; AFTER A '
        'SUCCESSFUL RETRY it is written. Every one converges to a finalized record with its samples exactly once and its '
        'own outcome — and the outcome\'s own write changes no recorder field', () async {
      final g = gatedRecorder();
      final recorder = g.recorder;

      // BEFORE: the session still records.
      final before = await record(recorder, 3);
      sessionWrites = 0;
      final onRecording = await failed(before.id, accepted: 11);
      expect(await onDisk(before.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'before: nothing is written under the recording recorder\'s hands');
      expect(sessionWrites, 0);
      await recorder.stopSession();
      expect(await onDisk(before.id), 'ENDED declared=3 stored=3 telemetry=failed 11/0/0', reason: 'before: stored by the finalization, with the record it finalized');
      expect(onRecording, SessionTelemetryOutcomeWrite.handedToRecorder);

      // DURING: the finalization is in flight.
      final during = await record(recorder, 3);
      g.hold();
      final stopDuring = recorder.stopSession();
      await until(() => recorder.state == DrivingSessionRecorderState.finalizing, 'during: held inside the finalization');
      sessionWrites = 0;
      SessionTelemetryOutcomeWrite? onFinalizing;
      final waiting = succeeded(during.id, samples: 12).then((w) => onFinalizing = w);
      await Future<void>.delayed(const Duration(milliseconds: 40)); // an absence, under a held gate
      expect([onFinalizing, sessionWrites], [null, 0], reason: 'during: it waits, and writes nothing meanwhile');
      expect(await onDisk(during.id), 'ACTIVE declared=3 stored=0 telemetry=unknown');
      g.release();
      await stopDuring;
      await waiting;
      expect(await onDisk(during.id), 'ENDED declared=3 stored=3 telemetry=success 12/12/0');
      expect(onFinalizing, SessionTelemetryOutcomeWrite.recorded);

      // AFTER A SUCCESS: only the four telemetry fields change on disk.
      final afterSuccess = await record(recorder, 3);
      await recorder.stopSession();
      final finalized = _recorderFields((await sessionRecordOnDisk(dir, afterSuccess.id))!);
      final onFinalized = await succeeded(afterSuccess.id, samples: 13);
      expect(await onDisk(afterSuccess.id), 'ENDED declared=3 stored=3 telemetry=success 13/13/0', reason: 'after a success: written on the record its recorder finalized');
      expect(onFinalized, SessionTelemetryOutcomeWrite.recorded);
      expect(_recorderFields((await sessionRecordOnDisk(dir, afterSuccess.id))!), finalized, reason: 'after a success: end time, sample count, summary — every field the recorder wrote is what it wrote');

      // AFTER A FAILURE, recorder alive; then the retry.
      final afterFailure = await record(recorder, 3);
      await samples().close();
      expect(await _errorOf(recorder.stopSession()), isA<HiveError>(), reason: 'setup');
      await openSamples();
      sessionWrites = 0;
      final onFailed = await failed(afterFailure.id, accepted: 14, persisted: 4, refused: 2);
      expect(sessionWrites, 0, reason: 'after a failure: not written — the record is not finalized ahead of its samples');
      expect(await onDisk(afterFailure.id), 'ACTIVE declared=3 stored=0 telemetry=unknown');
      await recorder.stopSession(); // the retry
      expect(await onDisk(afterFailure.id), 'ENDED declared=3 stored=3 telemetry=failed 14/4/2', reason: 'the retry stores the finalized record together with the outcome');
      expect(onFailed, SessionTelemetryOutcomeWrite.handedToRecorder);

      // AFTER A SUCCESSFUL RETRY.
      final afterRetry = await record(recorder, 3);
      await samples().close();
      expect(await _errorOf(recorder.stopSession()), isA<HiveError>(), reason: 'setup');
      await openSamples();
      await recorder.stopSession(); // the retry, before any outcome
      expect(await onDisk(afterRetry.id), 'ENDED declared=3 stored=3 telemetry=unknown', reason: 'setup');
      final onRetried = await succeeded(afterRetry.id, samples: 15);
      expect(await onDisk(afterRetry.id), 'ENDED declared=3 stored=3 telemetry=success 15/15/0', reason: 'after a successful retry: written on the record the retry finalized');
      expect(onRetried, SessionTelemetryOutcomeWrite.recorded);

      await restart();
      for (final s in [before, during, afterSuccess, afterFailure, afterRetry]) {
        expect(await storedSpeeds(s.id), [1, 2, 3], reason: '${s.id}: its samples, each once, in order — none lost, none doubled');
      }
      expect(await durablyFinalizedViolations(dir), isEmpty);
      expect(sessions().values.where((s) => s.isActive), isEmpty, reason: 'nothing left for a recovery to reclaim');
    });

    test('X186 — declared samples against stored samples, at the only checkpoint where they must agree — a record durably '
        'finalized. A recorder that finalizes 0, 1, 3 or 25 samples (two incremental flushes and a final one) leaves a '
        'finalized record declaring exactly what is stored, with or without a late outcome. One whose finalization fails '
        'before any flush (3 samples, none stored) or after a partial one (13 samples, 10 stored; 25, 20 stored), disposed, '
        'is NOT finalized on disk by the late outcome; the next start finalizes it declaring what is stored — 0, 10, 20 — '
        'each stored sample once and in order', () async {
      // Finalized by the recorder.
      final finalized = <String, int>{};
      for (final n in [0, 1, 3, 25]) {
        final recorder = newRecorder();
        final s = await record(recorder, n);
        if (n == 25) expect(await onDisk(s.id), 'ACTIVE declared=25 stored=20 telemetry=unknown', reason: 'setup: while recording the summary is AHEAD of the stored samples — not a violation');
        await recorder.stopSession();
        expect(await onDisk(s.id), 'ENDED declared=$n stored=$n telemetry=unknown', reason: '$n samples: finalized by its recorder');
        final written = await succeeded(s.id, samples: n + 1);
        expect(await onDisk(s.id), 'ENDED declared=$n stored=$n telemetry=success ${n + 1}/${n + 1}/0', reason: '$n samples: the late outcome is recorded and changes neither count');
        expect(written, SessionTelemetryOutcomeWrite.recorded);
        expect(await storedSpeeds(s.id), range(1, n));
        finalized[s.id] = n;
      }
      expect(await durablyFinalizedViolations(dir), isEmpty);

      // Finalization failed, recorder disposed, late outcome.
      final abandoned = <String, int>{};
      for (final (n, storedBefore) in [(3, 0), (13, 10), (25, 20)]) {
        final recorder = newRecorder();
        final s = await record(recorder, n);
        expect(await onDisk(s.id), 'ACTIVE declared=$n stored=$storedBefore telemetry=unknown', reason: 'setup: $storedBefore stored by the incremental flushes');
        final undo = await failSamplesCheckpoint(_SamplesFailure.writeFailsBeforeEffect);
        expect(await _errorOf(recorder.stopSession()), isA<StateError>(), reason: 'setup: the final samples write failed');
        await undo();
        recorder.dispose();
        sessionWrites = 0;
        final written = await failed(s.id, accepted: n);
        expect(await onDisk(s.id), 'ACTIVE declared=$n stored=$storedBefore telemetry=unknown', reason: '$n samples: pre-fix "ENDED declared=$n stored=$storedBefore" — finalized declaring samples that are not stored');
        expect(sessionWrites, 0, reason: '$n samples: the outcome wrote nothing');
        expect(written, SessionTelemetryOutcomeWrite.sessionNotFinalized);
        abandoned[s.id] = storedBefore;
      }
      expect(await durablyFinalizedViolations(dir), isEmpty, reason: 'nothing unfinalized reads as finalized');

      await nextStart();
      for (final MapEntry(key: id, value: n) in finalized.entries) {
        expect(await onDisk(id), 'ENDED declared=$n stored=$n telemetry=success ${n + 1}/${n + 1}/0', reason: 'after the next start: untouched by the recovery');
      }
      for (final MapEntry(key: id, value: stored) in abandoned.entries) {
        expect(await onDisk(id), 'ENDED declared=$stored stored=$stored telemetry=unknown', reason: 'after the next start: reclaimed, declaring what is stored');
        expect(await storedSpeeds(id), range(1, stored), reason: 'the stored prefix, each sample once and in order');
        final record = sessions().get(id)!;
        final last = (await sessionSamplesOnDisk(dir, id))?.lastOrNull?.timestamp;
        expect(record.endTime, last ?? record.startTime);
      }
      expect(await durablyFinalizedViolations(dir), isEmpty);
      expect(sessions().values.where((s) => s.isActive), isEmpty);
    });

    test('X187 — the outcome writes nothing of what only its recorder\'s memory holds, whatever the field: a session its '
        'recorder was disposed WHILE RECORDING — never stopped, its last summary write having failed, so the instance is '
        'ahead of the file (3 samples against 2) — gets no write from a late outcome: the file keeps declaring 2, with no '
        'outcome, and the next start reclaims it. With the recorder alive in that same state the outcome is handed over, '
        'and nothing is written either', () async {
      Future<({DrivingSessionRecorder recorder, DrivingSession session, List<Object> uncaught})> recordingAheadOfItsFile() async {
        final recorder = newRecorder();
        late DrivingSession s;
        final uncaught = await _uncaughtErrorsOf(() async {
          s = await record(recorder, 2);
          // The third sample's own summary write fails before taking effect.
          Hive.registerAdapter<DrivingSession>(_WriteFailingSessionAdapter()..failures = 1, override: true);
          clock = clock.add(const Duration(seconds: 2));
          snapshots.add(TelemetrySnapshot(timestamp: clock, speedKmh: 3, gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable));
          await until(() => s.sampleCount == 3, 'the third sample accepted');
          await sessions().flush();
          Hive.registerAdapter<DrivingSession>(DrivingSessionAdapter(), override: true);
        });
        return (recorder: recorder, session: s, uncaught: uncaught);
      }

      // Disposed while recording.
      final gone = await recordingAheadOfItsFile();
      expect(gone.uncaught, hasLength(1), reason: 'setup: the unawaited summary write of the third sample failed');
      expect([gone.session.sampleCount, gone.session.endTime], [3, null], reason: 'setup: the instance says 3, and was never ended');
      expect(await onDisk(gone.session.id), 'ACTIVE declared=2 stored=0 telemetry=unknown', reason: 'setup: the file says 2');
      gone.recorder.dispose();
      sessionWrites = 0;
      final onAbandoned = await succeeded(gone.session.id);
      expect(await onDisk(gone.session.id), 'ACTIVE declared=2 stored=0 telemetry=unknown', reason: 'the file is exactly what it was: a write of that instance would store a sample count no recorder write ever did (3), and an outcome');
      expect(sessionWrites, 0);
      expect(gone.session.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown);
      expect(onAbandoned, SessionTelemetryOutcomeWrite.sessionNotFinalized);

      // Alive, still recording, in the same state.
      final alive = await recordingAheadOfItsFile();
      expect(await onDisk(alive.session.id), 'ACTIVE declared=2 stored=0 telemetry=unknown', reason: 'setup');
      sessionWrites = 0;
      final onRecording = await succeeded(alive.session.id);
      expect(await onDisk(alive.session.id), 'ACTIVE declared=2 stored=0 telemetry=unknown', reason: 'nothing is written under the recording recorder\'s hands');
      expect(sessionWrites, 0);
      await alive.recorder.stopSession();
      expect(await onDisk(alive.session.id), 'ENDED declared=3 stored=3 telemetry=success 19/19/0', reason: 'its own finalization stores everything, the outcome with it');
      expect(onRecording, SessionTelemetryOutcomeWrite.handedToRecorder);

      await nextStart();
      expect(await onDisk(gone.session.id), 'ENDED declared=0 stored=0 telemetry=unknown', reason: 'reclaimed: nothing of it had been flushed');
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });

    test('X188 — a write that took effect and still failed, on either side. The RECORDER\'s own finalizing write of the '
        'record lands and its save throws: the recorder reports a failed finalization, is disposed, and the late outcome '
        'still writes nothing — the file holds the record as the recorder\'s own write left it, finalized with every sample '
        'stored, and no outcome; with the recorder alive instead, the outcome is handed over and the retry stores it. The '
        'OUTCOME\'s own write on a session its recorder finalized lands and throws: reconciled once, recorded, and no '
        'recorder field changed', () async {
      // The sessions box cannot compact: its next write lands and then throws.
      Directory obstacle() => Directory('${dir.path}/${HiveBoxNames.drivingSessions}.hivec');

      // (i) The recorder's record write took effect and failed; recorder disposed.
      final r1 = newRecorder();
      final a = await record(r1, 3);
      obstacle().createSync();
      onSessionsWrite = () => true;
      final stopA = await _errorOf(r1.stopSession());
      onSessionsWrite = null;
      expect(stopA, isA<FileSystemException>(), reason: 'setup: the record\'s save threw, after its frame was written');
      expect(r1.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup: for the recorder this finalization failed');
      const finalizedByItsRecorder = 'ENDED declared=3 stored=3 telemetry=unknown';
      expect(await onDisk(a.id), finalizedByItsRecorder, reason: 'setup: the write is on disk all the same');
      r1.dispose();
      sessionWrites = 0;
      final onA = await failed(a.id);
      expect(await onDisk(a.id), finalizedByItsRecorder, reason: 'no outcome on it: what the recorder did not confirm is not for the outcome to assume');
      expect(sessionWrites, 0);
      expect(onA, SessionTelemetryOutcomeWrite.sessionNotFinalized);

      // (ii) The same, recorder alive: handed over, and the retry stores it.
      obstacle().deleteSync();
      await restart(); // a box whose compaction failed does not try again
      final r2 = newRecorder();
      final b = await record(r2, 3);
      obstacle().createSync();
      onSessionsWrite = () => true;
      expect(await _errorOf(r2.stopSession()), isA<FileSystemException>(), reason: 'setup');
      onSessionsWrite = null;
      sessionWrites = 0;
      final onB = await failed(b.id, accepted: 28);
      expect(await onDisk(b.id), finalizedByItsRecorder, reason: 'no outcome on disk yet');
      expect(sessionWrites, 0);
      await r2.stopSession(); // the retry
      expect(await onDisk(b.id), 'ENDED declared=3 stored=3 telemetry=failed 28/0/0', reason: 'the retry stores the outcome it was handed');
      expect(onB, SessionTelemetryOutcomeWrite.handedToRecorder);

      // (iii) The outcome's own write takes effect and fails.
      obstacle().deleteSync();
      await restart();
      final r3 = newRecorder();
      final c = await record(r3, 3);
      await r3.stopSession();
      final finalized = _recorderFields((await sessionRecordOnDisk(dir, c.id))!);
      obstacle().createSync();
      var effects = 0;
      onSessionsWrite = () {
        effects++;
        return true;
      };
      final onC = await succeeded(c.id);
      onSessionsWrite = null;
      expect(effects, 2, reason: 'the first write took effect and threw; the reconciliation wrote the same state once more');
      expect(await onDisk(c.id), 'ENDED declared=3 stored=3 telemetry=success 19/19/0', reason: 'once: the given counts');
      expect(_recorderFields((await sessionRecordOnDisk(dir, c.id))!), finalized, reason: 'and nothing of the recorder\'s changed');
      expect(onC, SessionTelemetryOutcomeWrite.recorded);

      obstacle().deleteSync();
      await nextStart();
      expect(
        [await onDisk(a.id), await onDisk(b.id), await onDisk(c.id)],
        [finalizedByItsRecorder, 'ENDED declared=3 stored=3 telemetry=failed 28/0/0', 'ENDED declared=3 stored=3 telemetry=success 19/19/0'],
        reason: 'after the next start: A is the finished session its recorder\'s own write made it — nothing to reclaim, its telemetry outcome unknown',
      );
      for (final s in [a, b, c]) {
        expect(await storedSpeeds(s.id), [1, 2, 3]);
      }
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });

    test('X189 — a deletion still takes precedence, and nothing recreates the session. A session its disposed recorder left '
        'unfinalized is deleted from the History: the late outcome brings nothing back. Its deletion interrupted midway '
        'leaves it marked: the outcome writes nothing on it, and the next start COMPLETES the deletion — the recovery does '
        'not reclaim a record being deleted. And an outcome that arrived first does not stand in the deletion\'s way', () async {
      Future<DrivingSession> abandonedAfterFailedFinalization() async {
        final recorder = newRecorder();
        final s = await record(recorder, 13); // 10 stored, 3 pending
        final undo = await failSamplesCheckpoint(_SamplesFailure.writeFailsBeforeEffect);
        expect(await _errorOf(recorder.stopSession()), isA<StateError>(), reason: 'setup');
        await undo();
        expect(await _errorOf(deleteDrivingSession(s.id)), isA<SessionDeletionRejected>(), reason: 'setup: not deletable while its recorder controls it (R2.6.6)');
        recorder.dispose();
        (await DashcamTelemetryWriter.fileForSession(s.id)).writeAsStringSync('{"t":0}\n');
        return s;
      }

      // (a) Deleted, then the outcome.
      final a = await abandonedAfterFailedFinalization();
      await deleteDrivingSession(a.id);
      sessionWrites = 0;
      final onDeleted = await succeeded(a.id);
      expect(sessionWrites, 0);
      expect(await onDisk(a.id), 'no record, stored=null', reason: 'a deleted session is not recreated — no record, no samples');
      expect((await DashcamTelemetryWriter.fileForSession(a.id)).existsSync(), isFalse);
      expect(onDeleted, isNot(SessionTelemetryOutcomeWrite.recorded));

      // (b) The deletion stops at the telemetry file: the record stays marked.
      final b = await abandonedAfterFailedFinalization();
      final blocked = await _errorOf(
        IOOverrides.runWithIOOverrides(() => deleteDrivingSession(b.id), _UndeletableTelemetry()),
      );
      expect(blocked, isA<FileSystemException>(), reason: 'setup: the deletion stopped at the telemetry file');
      expect(await onDisk(b.id), 'MARKED ENDED declared=13 stored=0 telemetry=unknown', reason: 'setup: marked — the deletion\'s own write, which the user asked for');
      sessionWrites = 0;
      final onMarked = await failed(b.id);
      expect(sessionWrites, 0, reason: 'nothing is written on a session being deleted');
      expect(await onDisk(b.id), 'MARKED ENDED declared=13 stored=0 telemetry=unknown', reason: 'marker kept, no outcome');
      expect(onMarked, isNot(SessionTelemetryOutcomeWrite.recorded));

      // (c) The outcome first, then the deletion.
      final c = await abandonedAfterFailedFinalization();
      final onC = await succeeded(c.id);
      expect(await onDisk(c.id), 'ACTIVE declared=13 stored=10 telemetry=unknown', reason: 'the outcome wrote nothing on the unfinalized record');
      expect(onC, SessionTelemetryOutcomeWrite.sessionNotFinalized);
      await deleteDrivingSession(c.id);
      expect(await onDisk(c.id), 'no record, stored=null', reason: 'the outcome did not stand in the deletion\'s way');

      // (d) A session left unfinalized and NOT deleted, for contrast.
      final d = await abandonedAfterFailedFinalization();

      await nextStart();
      expect(await onDisk(b.id), 'no record, stored=null', reason: 'the next start completes the interrupted deletion — it does not reclaim the marked record');
      expect((await DashcamTelemetryWriter.fileForSession(b.id)).existsSync(), isFalse);
      expect(await onDisk(d.id), 'ENDED declared=10 stored=10 telemetry=unknown', reason: 'while the one that was not deleted is reclaimed');
      expect(sessions().keys.toList(), [d.id], reason: 'and none of the deleted ones came back');
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// How a finalization is made to fail at its samples checkpoint.
enum _SamplesFailure {
  /// The samples box is unavailable.
  boxClosed,

  /// The box is open and the write fails before a byte reaches the file.
  writeFailsBeforeEffect,

  /// The samples are written, and the put still throws.
  writeTookEffectThenFailed,
}

Future<Object?> _errorOf(Future<Object?> f) async {
  try {
    await f.timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  }
}

/// Runs [body] in one error zone and returns its uncaught asynchronous
/// errors; a failure of [body] itself is rethrown outside the zone.
Future<List<Object>> _uncaughtErrorsOf(Future<void> Function() body) {
  final uncaught = <Object>[];
  final done = Completer<List<Object>>();
  runZonedGuarded(() async {
    try {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      done.complete(uncaught);
    } catch (e, s) {
      done.completeError(e, s);
    }
  }, (e, s) => uncaught.add(e));
  return done.future;
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

/// Fields 0–25 of [s] as the adapter persists them: everything a recorder
/// writes — end time, sample count, summary, events, the deletion marker —
/// and none of the four telemetry-outcome fields (26–29).
Map<int, Object?> _recorderFields(DrivingSession s) {
  final capture = _FieldCapture();
  DrivingSessionAdapter().write(capture, s);
  final e = capture.entries;
  return {
    for (var i = 1; i + 1 < e.length; i += 2)
      if ((e[i]! as int) <= 25) e[i]! as int: e[i + 1],
  };
}

/// A session adapter that fails its next [failures] serializations — inside
/// `writeFrames`, before a byte reaches the file (the technique of
/// session_deletion_protocol_test.dart).
class _WriteFailingSessionAdapter extends DrivingSessionAdapter {
  // TypeAdapter is @immutable: the counter lives in a final holder.
  final _Failures _counter = _Failures();

  set failures(int value) => _counter.left = value;

  @override
  void write(BinaryWriter writer, DrivingSession obj) {
    if (_counter.left > 0) {
      _counter.left--;
      throw StateError('injected failure while serializing a session record');
    }
    super.write(writer, obj);
  }
}

/// A sample adapter whose every serialization fails: a samples write that
/// fails before it takes effect, with the samples box open.
class _WriteFailingSampleAdapter extends DrivingSessionSampleAdapter {
  @override
  void write(BinaryWriter writer, DrivingSessionSample obj) => throw StateError('injected failure while serializing a sample');
}

class _Failures {
  int left = 0;
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
