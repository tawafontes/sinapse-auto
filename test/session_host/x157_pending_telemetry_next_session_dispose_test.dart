// Fase 16.2-R4.3-R2.6.10 — X157 (the real app, AppHarness): the telemetry disk
// hangs (every write of the gated file is held). STOP A through the UI: the
// camera is released anyway and the dashcam is `finalizing`, not "Pronto".
// START B through the UI: B gets the released camera and its OWN file, and the
// session screen never says "Pronto". Then the root State is disposed
// (DrivingSessionHost.dispose()) with A's close still pending and B recording:
// nothing is reopened, both closes stay owned, and once the disk answers every
// accepted sample of A and of B is in its own file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';
import '../support/telemetry_io_gate.dart';

void main() {
  testWidgets(
    'X157 with the telemetry disk hung, STOP releases the camera and shows `finalizing`; the next session gets the '
    'camera and its own file and is never shown "Pronto"; host.dispose then owns both pending closes without reopening',
    (tester) async {
      final app = AppHarness(tester);
      final gate = TelemetryIoGate();
      try {
        await app.run(
          () => gate.run(() async {
            await app.boot();
            final host = app.host;
            final controller = host.dashcamController;
            final writers = <DashcamTelemetryWriter>[];
            controller.openTelemetryWriterHookForTest = (w, open) {
              writers.add(w);
              return open();
            };
            gate.hold = true;
            final a = await app.startSessionViaUi();
            final wa = writers.single;
            await app.driveUntil(() => gate.heldCount == 1, timeout: const Duration(seconds: 60), label: 'A\'s automatic flush held');
            final statuses = <DashcamStatus>[];
            void record() => statuses.add(controller.status);
            controller.addListener(record);

            // STOP A through the UI.
            await app.tapText('Finalizar sessão', settle: const Duration(milliseconds: 50));
            await app.driveUntil(
              () => DashcamService.processOwnerCurrentForTest == null && controller.status == DashcamStatus.finalizing,
              label: 'A: camera released while its telemetry close is pending',
            );
            expect(app.cameraCalls()['dispose'], 1, reason: 'pre-fix: the camera stayed held behind the writer');
            expect(host.recorder.state, DrivingSessionRecorderState.idle);
            expect(app.sessionsBox.get(a)!.endTime, isNotNull);
            expect(gate.heldCount, 1);
            expect(gate.closes, 0);

            // START B through the UI.
            await app.tapText('Iniciar sessão', settle: const Duration(milliseconds: 50));
            await app.driveUntil(() => controller.status == DashcamStatus.recording, label: 'B recording');
            final b = host.recorder.activeSession!.id;
            expect(writers, hasLength(2));
            expect(writers.last.sessionId, b, reason: 'B writes its own file');
            expect(app.shows(dashcamStatusLabel(DashcamStatus.recording)), isTrue, reason: 'the session screen says "Gravando"');
            expect(app.shows(dashcamStatusLabel(DashcamStatus.idle)), isFalse, reason: 'pre-fix: "Dashcam: Pronto" with no camera');
            expect(statuses, isNot(contains(DashcamStatus.idle)), reason: 'never Ready while A\'s file was unfinished');
            controller.removeListener(record);
            await app.driveUntil(() => writers.last.acceptedSampleCount >= 3, label: 'B accepted samples');

            // host.dispose() with A's close pending and B recording.
            app.emitting = false;
            await tester.pumpWidget(const SizedBox());
            await app.drive(const Duration(milliseconds: 500));
            expect(host.isDisposed, isTrue);
            expect(writers.last.isClosed, isTrue, reason: 'dispose started B\'s close');
            await app.driveUntil(() => DashcamService.processOwnerCurrentForTest == null, label: 'camera released');
            expect(controller.pendingTelemetryFinalizationsForTest, 2, reason: 'A\'s (its STOP) and B\'s (dispose): both still owned');
            final acceptedB = writers.last.acceptedSampleCount;

            gate.hold = false;
            gate.releaseAll();
            await app.driveFuture(controller.telemetryFinalizationsForTest());
            expect(gate.opens, 2, reason: 'nothing reopened');
            expect(gate.closes, 2);
            expect(gate.openHandles, 0);
            expect(wa.unpersistedSampleCount, 0);
            expect(writers.last.unpersistedSampleCount, 0);
            for (final (id, accepted) in [(a, wa.acceptedSampleCount), (b, acceptedB)]) {
              final lines = File('${app.dir.path}/dashcam_telemetry/$id.jsonl').readAsLinesSync().where((l) => l.isNotEmpty).toList();
              expect(lines, hasLength(accepted), reason: 'every accepted sample of $id, once');
              final times = [for (final l in lines) DateTime.parse((jsonDecode(l) as Map<String, Object?>)['t']! as String)];
              for (var i = 1; i < times.length; i++) {
                expect(times[i].isBefore(times[i - 1]), isFalse, reason: '$id: order preserved at line $i');
              }
            }
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
