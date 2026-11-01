// Fase 16.2-R4.3-R2.6.9 — X143.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/dashcam_telemetry_sample.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';
import '../support/telemetry_io_gate.dart';

void main() {
  testWidgets(
    'X143 a STOP through the UI while the automatic flush is held waits for it; a late callback during the close '
    'neither writes, reopens nor throws; the session ends normally with every accepted sample written; a later host '
    'dispose closes nothing twice',
    (tester) async {
      final app = AppHarness(tester);
      final gate = TelemetryIoGate();
      try {
        await app.run(
          () => gate.run(() async {
            await app.boot();
            final host = app.host;
            final controller = host.dashcamController;
            final recorder = host.recorder;
            DashcamTelemetryWriter? writer;
            controller.openTelemetryWriterHookForTest = (w, open) {
              writer = w;
              return open();
            };
            gate.hold = true;
            final a = await app.startSessionViaUi();
            expect(writer, isNotNull, reason: 'setup: the session\'s writer was opened inside the gate');
            final w = writer!;
            await app.driveUntil(() => gate.heldCount == 1, timeout: const Duration(seconds: 60), label: 'automatic flush held');
            final atHeld = w.acceptedSampleCountForTest;
            await app.driveUntil(() => w.acceptedSampleCountForTest >= atHeld + 2, label: 'samples pending behind the held flush');

            // STOP through the UI, without waiting for it to settle.
            await app.openSessionScreen();
            await app.tapText('Finalizar sessão', settle: const Duration(milliseconds: 50));
            await app.driveUntil(() => w.isClosed, label: 'STOP closing the writer');
            final accepted = w.acceptedSampleCountForTest;

            // A late callback (timer scheduled before, running during the close).
            final lateAdds = <bool>[];
            var lateFlushIsClose = false;
            Timer(const Duration(milliseconds: 10), () {
              for (var i = 0; i < 30; i++) {
                lateAdds.add(w.add(DashcamTelemetrySample(timestamp: DateTime.now(), speedKmh: 999)));
              }
              lateFlushIsClose = identical(w.flush(), w.close());
              unawaited(w.open());
            });
            await app.drive(const Duration(milliseconds: 300));
            expect(lateAdds, hasLength(30));
            expect(lateAdds, everyElement(isFalse), reason: 'no sample accepted during the close');
            expect(lateFlushIsClose, isTrue, reason: 'a late flush queues nothing');
            expect(gate.opens, 1, reason: 'the late open() does not reopen the file');
            expect(gate.closes, 0, reason: 'still waiting for the held flush');
            // Fase 16.2-R4.3-R2.6.10: with only the telemetry close pending the
            // status is `finalizing`, no longer `idle` ("Pronto" while the
            // session's file was still unfinished — pre-audit R2.6.9 P2-C).
            expect(controller.status == DashcamStatus.finalizing && recorder.state == DrivingSessionRecorderState.idle && gate.heldCount == 1, isTrue,
                reason: 'setup: the camera and the recorder are done, only the telemetry close is pending');

            gate.hold = false;
            gate.releaseAll();
            await app.driveFuture(w.close());
            await app.driveUntil(
              () =>
                  recorder.state == DrivingSessionRecorderState.idle &&
                  controller.status == DashcamStatus.idle &&
                  !controller.dashcamService.hasPendingNativeStop &&
                  app.indexedClips(a) == 1,
              label: 'session stopped and its clip indexed',
            );
            expect(app.sessionsBox.get(a)!.endTime, isNotNull);
            expect(app.unindexedClipFiles(), isEmpty);
            expect(gate.deliveries, 2);
            expect(gate.closes, 1);
            expect(gate.openHandles, 0);
            final lines = File('${app.dir.path}/dashcam_telemetry/$a.jsonl').readAsLinesSync().where((l) => l.isNotEmpty).toList();
            expect(lines, hasLength(accepted), reason: 'every accepted sample, once (pre-fix: the pending ones were lost)');
            expect(lines, gate.writtenLines);
            expect(lines.where((l) => l.contains('"spd":999')), isEmpty, reason: 'no late sample');

            // Then the host is disposed: nothing is closed or written again.
            await tester.pumpWidget(const SizedBox());
            await app.drive(const Duration(milliseconds: 500));
            expect(host.isDisposed, isTrue);
            expect(gate.closes, 1);
            expect(gate.opens, 1);
            expect(gate.deliveries, 2);
            expect(app.telemetryLines(a), accepted);
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
