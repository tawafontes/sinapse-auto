// Fase 16.2-R4.3-R2.6.8 — X126.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X126 when the root State is really disposed, the host disposes everything once and deterministically: '
    'recorder, camera controller (camera released), engines, subscriptions, writer and timers; its own API then '
    'fails with StateError and a second dispose is a no-op',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot();
          final host = app.host;
          final recorder = host.recorder;
          final controller = host.dashcamController;
          final a = await app.startSessionViaUi();
          // Setup, not a property: before the telemetry writer's first
          // automatic flush (every 25 samples). Written for the R2.6.8 writer
          // race (closing under an in-flight flush threw "StreamSink is bound
          // to a stream"); R2.6.9 serialized flush/close, and X142 covers a
          // host dispose under a held flush. Kept so X126's scenario is unchanged.
          expect(controller.sampleTickCountForTest, lessThan(20), reason: 'setup: no writer flush in flight');
          expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'setup: the camera is owned');
          expect(app.gps.positions.active, 1, reason: 'setup');

          await tester.pumpWidget(const SizedBox());
          await app.drive(const Duration(milliseconds: 500));
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(seconds: 5));
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          }

          expect(host.isDisposed, isTrue);
          // The recorder: no longer an authority, refuses a stop (DL5), and the
          // session is left as the next start's reclaim finds it.
          expect(DrivingSessionRecorder.controllingState(a), isNull);
          Object? stopError;
          try {
            await app.driveFuture(recorder.stopSession());
          } catch (e) {
            stopError = e;
          }
          expect(stopError, isA<StateError>());
          expect(app.sessionsBox.get(a)!.endTime, isNull);
          // The camera is released and the process owner freed.
          expect(app.cameraCalls()['dispose'], 1);
          expect(DashcamService.processOwnerCurrentForTest, isNull);
          // Engines: their streams are closed.
          final eventsDone = Completer<void>();
          host.eventEngine.events.listen(null, onDone: eventsDone.complete);
          final alertsDone = Completer<void>();
          host.alertEngine.events.listen(null, onDone: alertsDone.complete);
          await app.driveFuture(Future.wait([eventsDone.future, alertsDone.future]));
          // Nothing left running.
          expect(app.census.liveTotal, 0, reason: 'no periodic timer of the app survives: ${app.census.live}');
          expect(app.gps.positions.active, 0);
          expect(app.sensors.activeSubscriptions, 0);
          expect(host.isForwardingEventsForTest, isFalse);

          // The host's own API fails deterministically; dispose is idempotent.
          expect(() => host.configurationResetBlocker, throwsStateError);
          expect(host.ensureConfigurationResetAllowed, throwsStateError);
          host.dispose();
          expect(host.isDisposed, isTrue);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
