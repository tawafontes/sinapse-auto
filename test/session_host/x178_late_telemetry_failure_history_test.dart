// Fase 16.2-R4.3-R2.6.11 — X178 (the real app, AppHarness): session A is
// stopped through the UI with its telemetry write held (a hung disk), session
// B is started through the UI and records, and then A's write fails.
//  * B's UI never turns into a camera error: the session screen keeps
//    "Gravando", shows no telemetry loss (B's own telemetry is healthy) and
//    offers no "Tentar novamente"; the dashcam status never passes through
//    `error`; the camera is not restarted.
//  * The History says, on A's own tile, that A's telemetry is incomplete and
//    how much of it was written — before this round A and B were listed with
//    the very same text (scratchpad/fase16_2_r4_3_r2_6_11/01_prefix_repro) —
//    and A's detail screen says the same, with nothing to retry.
//  * B, stopped afterwards, is listed without any note and its detail screen
//    shows its telemetry as complete.
// START and STOP run inside ONE captured error zone: A's failing automatic
// flush is unawaited by contract (X138), so its error is an uncaught error that
// the zone records (and the test asserts).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_rec_indicator.dart';

import '../support/app_harness.dart';
import '../support/telemetry_io_gate.dart';

void main() {
  testWidgets(
    'X178 A\'s telemetry file fails after B started: B\'s screen keeps "Gravando" with no error and no retry, and the '
    'History shows the loss on A\'s own tile and detail — not on B\'s',
    (tester) async {
      final app = AppHarness(tester);
      final gate = TelemetryIoGate();
      const ioError = FileSystemException('late write of A failed (injected)', 'x178.jsonl');
      final uncaught = <Object>[];
      late final Zone errorZone;
      try {
        await app.run(
          () => gate.run(() async {
            // Created INSIDE the gate's IOOverrides zone, so the writers opened
            // from the START handlers below write through the gated file.
            runZonedGuarded(() => errorZone = Zone.current, (e, s) => uncaught.add(e));
            await app.boot();
            final host = app.host;
            final controller = host.dashcamController;
            final recorder = host.recorder;
            final writers = <DashcamTelemetryWriter>[];
            controller.openTelemetryWriterHookForTest = (w, open) {
              writers.add(w);
              return open();
            };

            /// The real handler of the session screen's button, inside the error zone.
            void press(String label) {
              final button = tester.widget<FilledButton>(find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is FilledButton)).first);
              errorZone.run(() => button.onPressed!());
            }

            /// The subtitle of [id]'s tile in the History list.
            String tileSubtitle(String id) {
              final tile = tester.widget<ListTile>(find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(ListTile)));
              return (tile.subtitle! as Text).data!;
            }

            Future<void> openHistory(int tiles) async {
              await app.openSettings();
              await app.tapText('Histórico');
              await app.driveUntil(() => find.byType(Dismissible).evaluate().length == tiles, label: 'history lists $tiles session(s)');
              await app.drive(const Duration(milliseconds: 800)); // the route transition has finished
            }

            Future<void> openDetail(String id) async {
              await tester.tap(find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(ListTile)));
              await app.driveUntil(() => app.shows('Amostras'), label: 'the session detail');
              await app.drive(const Duration(milliseconds: 500));
            }

            // --- A records; its first automatic flush is held ---
            gate.hold = true;
            app.emitting = true;
            await app.openSessionScreen();
            press('Iniciar sessão');
            final a = recorder.activeSession!.id;
            await app.driveUntil(() => controller.status == DashcamStatus.recording, label: 'A recording');
            final wA = writers.single;
            await app.driveUntil(() => gate.heldCount == 1, timeout: const Duration(seconds: 60), label: 'A\'s automatic flush held');
            gate.hold = false; // A's delivery stays parked; B's own writes go through

            // --- STOP A: camera released, telemetry file pending ---
            press('Finalizar sessão');
            await app.driveUntil(
              () =>
                  recorder.state == DrivingSessionRecorderState.idle &&
                  controller.status == DashcamStatus.finalizing &&
                  DashcamService.processOwnerCurrentForTest == null &&
                  app.indexedClips(a) == 1,
              label: 'A stopped: recorder idle, camera released, clip indexed, telemetry close pending',
            );
            final acceptedA = wA.acceptedSampleCount;
            expect(acceptedA, greaterThanOrEqualTo(25), reason: 'setup');
            expect(app.sessionsBox.get(a)!.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: 'nothing is claimed while the file is pending');

            // --- START B ---
            final statuses = <DashcamStatus>[];
            void onStatus() => statuses.add(controller.status);
            controller.addListener(onStatus);
            press('Iniciar sessão');
            await app.driveUntil(() => controller.status == DashcamStatus.recording, label: 'B recording');
            final b = recorder.activeSession!.id;
            expect(writers, hasLength(2), reason: 'setup: B has its own writer');
            final wB = writers.last;
            await app.driveUntil(() => wB.acceptedSampleCount >= 3, label: 'B accepted samples');

            // --- A's held write fails while B records ---
            final startsBefore = app.cameraCalls()['startVideoCapturing'];
            gate.failNext(ioError);
            gate.releaseAll();
            await app.driveUntil(() => controller.pendingTelemetryFinalizationsForTest == 0, label: 'A\'s finalization settled');
            // The result is recorded right after that; bounded, and what it
            // must have produced is asserted on the History below.
            await app.drive(const Duration(seconds: 5), until: () => app.sessionsBox.get(a)!.dashcamTelemetryOutcome != DashcamTelemetryOutcome.unknown);
            await app.drive(const Duration(milliseconds: 400));
            expect(wA.failure, same(ioError), reason: 'setup: A\'s file failed');
            expect(app.telemetryLines(a), 0, reason: 'setup: none of A\'s samples reached its file');
            expect(tester.takeException(), same(ioError), reason: 'the failure of the older file is reported (X155) — now not the only trace');
            expect(uncaught, [same(ioError)], reason: 'A\'s automatic flush failing, once (X138)');

            // B's UI: not an error, nothing to retry, nothing about A's loss.
            expect(controller.status, DashcamStatus.recording);
            expect(controller.errorMessage, isNull);
            expect(app.shows(dashcamStatusLabel(DashcamStatus.recording)), isTrue, reason: 'the session screen still says "Gravando"');
            expect(app.shows(dashcamStatusLabel(DashcamStatus.error)), isFalse, reason: 'B\'s screen is not a camera error');
            expect(app.shows('Tentar novamente'), isFalse, reason: 'there is nothing to retry: A\'s file cannot be recovered');
            expect(find.textContaining('Telemetria da dashcam'), findsNothing, reason: 'B\'s own telemetry is healthy; A\'s loss is not shown as B\'s');
            expect(app.cameraCalls()['startVideoCapturing'], startsBefore, reason: 'the camera was not restarted');
            expect(identical(writers.last, wB) && writers.length == 2, isTrue, reason: 'B keeps its writer');
            final acceptedB = wB.acceptedSampleCount;
            await app.driveUntil(() => wB.acceptedSampleCount > acceptedB, label: 'B keeps accepting samples');
            expect(wB.failure, isNull);

            // The dashboard, and A in the History, while B records.
            await app.backToDashboard();
            final indicator = tester.widget<IconButton>(
              find.descendant(of: find.byType(DashcamRecIndicator, skipOffstage: false).last, matching: find.byType(IconButton, skipOffstage: false)).first,
            );
            expect(indicator.tooltip, startsWith(dashcamStatusLabel(DashcamStatus.recording)), reason: 'the REC indicator still shows a recording');
            await openHistory(1);
            final lossOfA = 'Telemetria da dashcam incompleta: 0 de $acceptedA amostras gravadas';
            expect(tileSubtitle(a), endsWith('\n$lossOfA'), reason: 'pre-fix: A\'s tile said nothing about its telemetry');
            await openDetail(a);
            expect(find.text('Telemetria da dashcam'), findsOneWidget, reason: 'A\'s detail has the telemetry row');
            expect(find.text('Incompleta: 0 de $acceptedA amostras gravadas'), findsOneWidget);
            expect(app.shows('Tentar novamente'), isFalse, reason: 'no retry is offered for A either');

            // --- STOP B; the History of both ---
            await app.stopSessionViaUi();
            controller.removeListener(onStatus);
            expect(statuses, isNot(anyOf(contains(DashcamStatus.error), contains(DashcamStatus.cameraUnavailable))),
                reason: 'B\'s whole life, from its START to its STOP, never showed an error because of A');
            expect(controller.status, DashcamStatus.idle);
            expect(controller.errorMessage, isNull);
            final persistedB = wB.persistedSampleCount;
            expect([wB.failure, wB.unpersistedSampleCount], [null, 0], reason: 'setup: B\'s telemetry is complete');
            expect(app.telemetryLines(b), persistedB);

            await openHistory(2);
            expect(tileSubtitle(a), endsWith('\n$lossOfA'), reason: 'A\'s own result, whatever happened afterwards');
            expect(tileSubtitle(b), isNot(contains('Telemetria')), reason: 'B is listed as before: a complete telemetry adds no note');
            await openDetail(b);
            expect(find.text('Completa: $persistedB amostras gravadas'), findsOneWidget, reason: 'B\'s detail shows its telemetry as complete');

            final recordA = app.sessionsBox.get(a)!;
            final recordB = app.sessionsBox.get(b)!;
            expect(
              [recordA.dashcamTelemetryOutcome, recordA.dashcamTelemetryAcceptedCount, recordA.dashcamTelemetryPersistedCount, recordA.dashcamTelemetryRefusedCount],
              [DashcamTelemetryOutcome.failed, acceptedA, 0, 0],
            );
            expect(
              [recordB.dashcamTelemetryOutcome, recordB.dashcamTelemetryAcceptedCount, recordB.dashcamTelemetryPersistedCount, recordB.dashcamTelemetryRefusedCount],
              [DashcamTelemetryOutcome.success, persistedB, persistedB, 0],
            );
            expect(uncaught, [same(ioError)], reason: 'nothing secondary');
            expect(tester.takeException(), isNull);
          }),
        );
      } finally {
        gate.hold = false;
        gate.releaseAll();
        await app.teardown();
      }
    },
  );
}
