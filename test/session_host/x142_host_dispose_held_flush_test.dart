// Fase 16.2-R4.3-R2.6.9 — X142.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_telemetry_sample.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';

import '../support/app_harness.dart';
import '../support/telemetry_io_gate.dart';

void main() {
  testWidgets(
    'X142 the host is really disposed while recording with the telemetry writer\'s automatic flush held: producers stop, '
    'the writer refuses new samples, waits for the flush, writes every accepted sample and closes the file exactly '
    'once, with no asynchronous error',
    (tester) async {
      final app = AppHarness(tester);
      // The real IOSink over a gated file consumer, for the telemetry file only.
      final gate = TelemetryIoGate();
      try {
        await app.run(
          () => gate.run(() async {
            await app.boot();
            final host = app.host;
            final controller = host.dashcamController;
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
            await app.driveUntil(() => w.acceptedSampleCountForTest >= atHeld + 3, label: 'samples pending behind the held flush');

            // The root State is disposed: DrivingSessionHost.dispose() during recording.
            app.emitting = false;
            await tester.pumpWidget(const SizedBox());
            await app.drive(const Duration(milliseconds: 500));

            expect(host.isDisposed, isTrue);
            expect(w.isClosed, isTrue, reason: 'the controller\'s dispose closed the writer');
            final accepted = w.acceptedSampleCountForTest;
            final ticks = controller.sampleTickCountForTest;
            expect(w.add(DashcamTelemetrySample(timestamp: DateTime.now(), speedKmh: 999)), isFalse, reason: 'no sample after close');
            expect(gate.heldCount, 1, reason: 'the flush is still held');
            expect(gate.closes, 0, reason: 'the file is not closed under a bound flush');
            // Producers, timers and subscriptions are gone even while the flush is held.
            expect(app.census.liveOf('services/dashcam_session_controller.dart'), 0, reason: 'sample timer cancelled');
            expect(app.gps.positions.active, 0);
            expect(app.sensors.activeSubscriptions, 0);
            await app.driveUntil(() => DashcamService.processOwnerCurrentForTest == null, label: 'camera released');
            expect(app.cameraCalls()['dispose'], 1);

            gate.hold = false;
            gate.releaseAll();
            // The same Future the controller's dispose started (close is memoized).
            // Pre-fix that close threw StateError "StreamSink is bound to a
            // stream" as an uncaught error and the file handle stayed open.
            await app.driveFuture(w.close());
            await app.drive(const Duration(milliseconds: 300));

            expect(gate.deliveries, 2, reason: 'the held flush, then close\'s final batch');
            expect(gate.maxActiveDeliveries, 1);
            expect(gate.closes, 1, reason: 'closed exactly once');
            expect(gate.openHandles, 0);
            expect(gate.opens, 1, reason: 'never reopened');
            expect(controller.sampleTickCountForTest, ticks, reason: 'no sampler tick after dispose');
            // The data: every accepted sample on disk, once, in order.
            final lines = File('${app.dir.path}/dashcam_telemetry/$a.jsonl').readAsLinesSync().where((l) => l.isNotEmpty).toList();
            expect(lines, hasLength(accepted), reason: 'pre-fix: the samples pending behind the held flush were lost');
            expect(lines, gate.writtenLines);
            final times = [for (final l in lines) DateTime.parse((jsonDecode(l) as Map<String, Object?>)['t']! as String)];
            for (var i = 1; i < times.length; i++) {
              expect(times[i].isBefore(times[i - 1]), isFalse, reason: 'order preserved at line $i');
            }
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
