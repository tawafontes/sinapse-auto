// Fase 16.2-R4.3-R2.6.10 — X158 (the real app, AppHarness): DrivingSessionHost
// .dispose() while recording, and the close that dispose starts hits a real
// write failure (its final write fails at the gated file). dispose cannot
// await anything; the controller owns that close: the primary error is
// reported exactly once (FlutterError, not an uncaught error nobody owns), the
// handle is released anyway, the camera is released, and nothing reopens.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';

import '../support/app_harness.dart';
import '../support/telemetry_io_gate.dart';

void main() {
  testWidgets(
    'X158 host.dispose while recording, and dispose\'s own telemetry close fails: the primary error is reported once, '
    'the file handle and the camera are released, nothing reopens',
    (tester) async {
      final app = AppHarness(tester);
      final gate = TelemetryIoGate();
      const ioError = FileSystemException('final write failed (injected)', 'x158.jsonl');
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
            await app.startSessionViaUi();
            final w = writer!;
            await app.driveUntil(() => w.acceptedSampleCount >= 3, label: 'samples accepted');
            expect(w.acceptedSampleCount, lessThan(25), reason: 'setup: no automatic flush yet — only dispose\'s close writes');
            expect(w.failure, isNull);

            gate.failNext(ioError);
            app.emitting = false;
            await tester.pumpWidget(const SizedBox());
            expect(host.isDisposed, isTrue);
            await app.driveFuture(controller.telemetryFinalizationsForTest());
            await app.driveUntil(() => DashcamService.processOwnerCurrentForTest == null, label: 'camera released');

            expect(tester.takeException(), same(ioError), reason: 'pre-fix: an unowned close → uncaught error; now reported once');
            expect(w.failure, same(ioError));
            expect(w.state, DashcamTelemetryWriterState.closed);
            expect(w.persistedSampleCount, 0);
            expect(w.unpersistedSampleCount, w.acceptedSampleCount, reason: 'the loss is accounted, not hidden');
            expect(gate.closes, 1, reason: 'the handle is released even though the final write failed');
            expect(gate.openHandles, 0);
            expect(gate.opens, 1, reason: 'nothing reopened');
            expect(app.cameraCalls()['dispose'], 1);
            await app.drive(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull, reason: 'no secondary error');
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
