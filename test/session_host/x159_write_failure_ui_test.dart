// Fase 16.2-R4.3-R2.6.10 — X159 (the real app, AppHarness): a telemetry write
// failure while recording, as the session screen shows it. The camera keeps
// recording, so "Dashcam: Gravando" stays, and the screen adds what is being
// lost ("Telemetria da dashcam incompleta: …"); the writer refuses every later sample; the STOP ends
// in "Erro" instead of a silent success. START and STOP run inside ONE captured
// error zone: the failing automatic flush is unawaited by contract (X138), so
// its error is an uncaught error that the zone records (and the test asserts).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';

import '../support/app_harness.dart';
import '../support/telemetry_io_gate.dart';

void main() {
  testWidgets(
    'X159 a telemetry write failure while recording: the session screen keeps "Gravando" and shows the telemetry loss, '
    'nothing more is accepted, and the STOP ends in "Erro"',
    (tester) async {
      final app = AppHarness(tester);
      final gate = TelemetryIoGate();
      const ioError = FileSystemException('write failed (injected)', 'x159.jsonl');
      final uncaught = <Object>[];
      late final Zone errorZone;
      try {
        await app.run(
          () => gate.run(() async {
            // Created INSIDE the gate's IOOverrides zone, so the writer opened
            // from the START handler below writes through the gated file.
            runZonedGuarded(() => errorZone = Zone.current, (e, s) => uncaught.add(e));
            await app.boot();
            final host = app.host;
            final controller = host.dashcamController;
            DashcamTelemetryWriter? writer;
            controller.openTelemetryWriterHookForTest = (w, open) {
              writer = w;
              return open();
            };
            app.emitting = true;
            await app.openSessionScreen();
            final start = tester.widget<FilledButton>(find.ancestor(of: find.text('Iniciar sessão'), matching: find.byWidgetPredicate((w) => w is FilledButton)).first);
            errorZone.run(() => start.onPressed!()); // the real handler, inside the error zone
            final a = host.recorder.activeSession!.id;
            await app.driveUntil(() => controller.status == DashcamStatus.recording, label: 'recording');
            final w = writer!;
            await app.driveUntil(() => w.persistedSampleCount >= 25, timeout: const Duration(seconds: 60), label: 'first automatic flush written');
            expect(find.textContaining('Telemetria da dashcam incompleta'), findsNothing, reason: 'healthy so far');

            gate.failNext(ioError);
            await app.driveUntil(() => w.failure != null, timeout: const Duration(seconds: 60), label: 'the next automatic flush failed');
            final accepted = w.acceptedSampleCount;
            final ticks = controller.sampleTickCountForTest;
            await app.driveUntil(() => controller.sampleTickCountForTest >= ticks + 3, label: '3 sampler ticks after the failure');
            expect(w.acceptedSampleCount, accepted, reason: 'pre-fix: every later sample accepted and lost');
            expect(w.refusedSampleCount, greaterThanOrEqualTo(3));
            expect(app.shows(dashcamStatusLabel(DashcamStatus.recording)), isTrue, reason: 'the camera is still recording video');
            expect(find.textContaining('Telemetria da dashcam incompleta'), findsOneWidget, reason: 'the loss is shown while recording');
            expect(uncaught, [same(ioError)], reason: 'the automatic flush\'s own failure, once');

            final stop = tester.widget<FilledButton>(find.ancestor(of: find.text('Finalizar sessão'), matching: find.byWidgetPredicate((w) => w is FilledButton)).first);
            errorZone.run(() => stop.onPressed!());
            await app.driveUntil(() => host.recorder.activeSession == null && controller.status == DashcamStatus.error, label: 'stopped, dashcam in error');
            expect(controller.errorMessage, contains('Telemetria da dashcam incompleta'));
            expect(gate.closes, 1);
            expect(gate.openHandles, 0);
            expect(app.telemetryLines(a), w.persistedSampleCount, reason: 'the file holds exactly what the writer reports as persisted');
            expect(w.unpersistedSampleCount, greaterThan(0), reason: 'the loss is accounted');
            await app.drive(const Duration(milliseconds: 300));
            expect(uncaught, [same(ioError)], reason: 'nothing secondary (pre-fix: "File closed" errors)');
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
