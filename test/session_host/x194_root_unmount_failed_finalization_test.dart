// Fase 16.2-R4.3-R2.6.12 — X194 (the real app, AppHarness): the app's ROOT is
// unmounted after the recorder's finalization failed, with the STOP's own
// telemetry close still pending. Independent review of R2.6.11 (P2 —
// scratchpad/fase16_2_r4_3_independent_review_r2611, "root real"): the root
// State's dispose runs DrivingSessionHost.dispose() — recorder.dispose(), then
// dashcamController.dispose() — and the STOP's callback, still alive, then
// closed the telemetry file and recorded its outcome on a session no recorder
// controlled any more: the cached record was written whole, with the end time
// of the FAILED finalization. On disk the session was finished, declaring 3
// samples with none stored, and the next start's recovery left it that way.
//
// Here nothing calls recorder.dispose() or controller.dispose(): the widget
// tree is replaced, as the reviewer's probe does. The recorder's samples write
// fails through an adapter that throws while serializing (the samples box
// stays open; the write fails before it takes effect). What is durable is read
// from the box FILES (support/hive_file_snapshot.dart). The next start is the
// sessions box closed and reopened plus the real startup recovery; the app is
// then mounted again, and the History and a new session go through the UI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/main.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import '../support/app_harness.dart';
import '../support/hive_file_snapshot.dart';
import '../support/telemetry_io_gate.dart';

/// A sample adapter whose every serialization fails.
class _WriteFailingSampleAdapter extends DrivingSessionSampleAdapter {
  @override
  void write(BinaryWriter writer, DrivingSessionSample obj) => throw StateError('injected failure while serializing a sample');
}

void main() {
  testWidgets(
    'X194 the app root is unmounted after the recorder\'s finalization failed, the STOP\'s telemetry close still pending: the '
    'late telemetry outcome writes nothing — the file keeps the unfinalized record; the next start reclaims the session, '
    'declaring the samples that are stored; the History then lists it without a telemetry claim, and a new session starts '
    'and ends normally',
    (tester) async {
      final app = AppHarness(tester);
      final gate = TelemetryIoGate();

      /// What the FILES hold about session [id], as text.
      Future<String> onDisk(String id) async => (await tester.runAsync(() async {
        final r = await sessionRecordOnDisk(app.dir, id);
        final stored = await sessionSamplesOnDisk(app.dir, id);
        if (r == null) return 'no record, stored=${stored?.length}';
        final outcome = r.dashcamTelemetryOutcome == DashcamTelemetryOutcome.unknown ? 'unknown' : r.dashcamTelemetryOutcome.name;
        return '${r.endTime == null ? 'ACTIVE' : 'ENDED'} declared=${r.sampleCount} stored=${stored?.length ?? 0} telemetry=$outcome';
      }))!;
      Future<List<String>> violations() async => (await tester.runAsync(() => durablyFinalizedViolations(app.dir)))!;

      /// The session tiles of the History list: a Dismissible keyed by its
      /// session id (a SnackBar's own Dismissible is not one).
      List<String> sessionTiles() => [
        for (final e in find.byType(Dismissible).evaluate())
          if (e.widget.key case ValueKey<String>(:final value)) value,
      ];

      try {
        await app.run(
          () => gate.run(() async {
            await app.boot();
            final host = app.host;
            final recorder = host.recorder;
            final controller = host.dashcamController;
            DashcamTelemetryWriter? writer;
            controller.openTelemetryWriterHookForTest = (w, open) {
              writer = w;
              return open();
            };

            // --- A records: a few recorder samples, below the incremental flush ---
            final a = await app.startSessionViaUi();
            await app.driveUntil(() => recorder.activeSession!.sampleCount >= 3 && writer!.acceptedSampleCount >= 3, label: 'three recorder samples');
            app.emitting = false;
            await app.drive(const Duration(milliseconds: 300));
            final session = recorder.activeSession!;
            final accepted = session.sampleCount;
            expect(accepted, lessThan(10), reason: 'setup: nothing flushed yet');
            await app.driveFuture(app.sessionsBox.flush());
            expect(await onDisk(a), 'ACTIVE declared=$accepted stored=0 telemetry=unknown', reason: 'setup');

            // --- STOP: the recorder's samples write fails, the telemetry close is held ---
            // R4.4-R2.1.1-VAL-2 — ANTES: the STOP started with whatever the telemetry buffer held. MOTIVO: the close
            // reaches the gate only through a write, and the writer empties its buffer every 25th sample, at a count
            // that depends on the machine's speed (the sampler runs on FakeAsync frames, the recorder on real time);
            // with nothing pending the close finished at once, with nothing to hold. DEPOIS: under the hold no write
            // can complete, so a sample pending here stays pending until the STOP's close. If the 25th sample's flush
            // is the write held instead, the close is queued behind it: the STOP still waits for the telemetry file.
            gate.hold = true;
            await app.driveUntil(() => writer!.unpersistedSampleCount > 0, label: 'a telemetry sample pending, its write can only be held');
            Hive.registerAdapter<DrivingSessionSample>(_WriteFailingSampleAdapter(), override: true);
            var done = false;
            Object? error;
            controller.stopSession().then<void>(
              (_) {
                done = true;
              },
              onError: (Object e, StackTrace s) {
                error = e;
                done = true;
              },
            );
            await app.driveUntil(() => gate.heldCount == 1 && recorder.state == DrivingSessionRecorderState.finalizationFailed, label: 'A: recorder finalization failed, telemetry close held');
            Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
            expect(done, isFalse, reason: 'setup: the STOP still waits for the telemetry file');
            expect(app.shows('Tentar finalizar novamente'), isTrue, reason: 'setup: the screen offers the retry');
            expect(session.endTime, isNotNull, reason: 'setup: the failed STOP left its end time on the recorder\'s instance, in memory');
            expect(await onDisk(a), 'ACTIVE declared=$accepted stored=0 telemetry=unknown', reason: 'setup: none of it is on disk');

            // --- the root is unmounted: its State's dispose runs the host's own ---
            await tester.pumpWidget(const SizedBox());
            expect(host.isDisposed, isTrue, reason: 'setup: the real teardown ran');
            expect(DrivingSessionRecorder.controllingState(a), isNull, reason: 'setup: no recorder controls A any more');

            // --- the STOP's own callback: the telemetry file closes, its outcome is due ---
            gate.hold = false;
            gate.releaseAll();
            await app.driveUntil(() => done, label: 'the STOP settled after the root unmount');
            await app.drive(const Duration(milliseconds: 200));
            expect([writer!.state, writer!.unpersistedSampleCount, writer!.failure], [DashcamTelemetryWriterState.closed, 0, null], reason: 'setup: the telemetry file itself is complete');

            expect(await onDisk(a), 'ACTIVE declared=$accepted stored=0 telemetry=unknown',
                reason: 'pre-fix: "ENDED declared=$accepted stored=0 telemetry=success" — finalized on disk by the telemetry outcome');
            expect(session.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: 'and nothing is set on the abandoned instance');
            expect(error, isA<StateError>(), reason: 'the STOP keeps the recorder\'s own failure');
            expect(tester.takeException(), isNull, reason: 'withholding the outcome reports nothing');

            // --- the next start, as far as the sessions go ---
            await app.driveFuture(app.sessionsBox.close());
            await app.driveFuture(Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions));
            expect(app.sessionsBox.get(a)!.isActive, isTrue, reason: 'setup: as its file has it, the session is still active');
            await app.driveFuture(recoverDrivingSessionsAtStartup());
            expect(await onDisk(a), 'ENDED declared=0 stored=0 telemetry=unknown', reason: 'pre-fix: the recovery skipped it — $accepted samples declared, none stored, for good');
            expect(await violations(), isEmpty);

            // --- the app again: the History, and a new session through the UI ---
            await tester.pumpWidget(const SynapseAutoApp());
            await app.drive(const Duration(milliseconds: 300));
            await app.driveUntil(() => app.dashboardCount() == 1, label: 'dashboard mounted again');
            expect(app.host, isNot(same(host)), reason: 'setup: a new host');
            await app.openSettings();
            await app.tapText('Histórico');
            await app.driveUntil(() => sessionTiles().length == 1, label: 'the History lists A');
            await app.drive(const Duration(milliseconds: 800)); // the route transition has finished
            expect(sessionTiles(), [a], reason: 'A is listed again');
            final tile = tester.widget<ListTile>(find.descendant(of: find.byKey(ValueKey(a)), matching: find.byType(ListTile)));
            expect((tile.subtitle! as Text).data, isNot(contains('Telemetria')), reason: 'no telemetry claim about A: its outcome is unknown');

            final b = await app.startSessionViaUi();
            expect(b, isNot(a));
            await app.waitSamples(2);
            await app.stopSessionViaUi();
            app.emitting = false;
            expect(await onDisk(b), startsWith('ENDED'), reason: 'a new session starts and ends normally after the convergence');
            expect(await onDisk(a), 'ENDED declared=0 stored=0 telemetry=unknown', reason: 'A is not touched by B');
            expect(await violations(), isEmpty);
            expect(tester.takeException(), isNull);
          }),
        );
      } finally {
        gate.hold = false;
        gate.releaseAll();
        Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
        await app.teardown();
      }
    },
  );
}
