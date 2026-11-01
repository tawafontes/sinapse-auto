// Fase 16.2-R4.3-R2.6.8 — X124.
//
// R4.3-D2 (F27-F29): every disposed dashboard left its snapshot pipeline
// subscribed forever — one more 1 Hz GNSS stale-check timer per recreation —
// because AlertEngine/EventDetectionEngine ended in a bare asBroadcastStream().
// With one host, 50 recreations (the pushAndRemoveUntil(DashboardScreen) of the
// theme/edit flows) must leave exactly what was there before: timers,
// subscriptions, pipelines and owners, and the same session recording.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X124 50 dashboard recreations while recording: live timers, GPS/sensor subscriptions, pipelines and '
    'owners stay exactly as before (no +1 per recreation), and session A records through all of them',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot();
          final host = app.host;
          final recorder = host.recorder;
          final controller = host.dashcamController;
          final a = await app.startSessionViaUi();
          await app.waitSamples(2);
          await app.backToDashboard();

          final timersBefore = app.census.live;
          final gpsListens = app.gps.positions.listens;
          final sensorListens = app.sensors.totalListens;
          final sensorActive = app.sensors.activeSubscriptions;
          final callsBefore = app.cameraCalls();
          final attemptsBefore = controller.cameraAttemptCreationCountForTest;
          final samplesBefore = recorder.activeSession!.sampleCount;
          expect(app.census.liveOf(gnssTimerFile), 1, reason: 'setup: one live pipeline');

          for (var i = 1; i <= 50; i++) {
            final old = app.dashboardStates().single;
            app.pushReplacingDashboard();
            await app.settleDashboardTransition();
            final why = 'recreation $i';
            expect(old.mounted, isFalse, reason: why);
            expect(app.dashboardStates().single, isNot(same(old)), reason: why);
            expect(app.host, same(host), reason: why);
            expect(recorder.activeSession?.id, a, reason: why);
            expect(recorder.state, DrivingSessionRecorderState.recording, reason: why);
            expect(app.census.liveOf(gnssTimerFile), 1, reason: '$why: still exactly one live pipeline');
            expect(app.gps.positions.listens, gpsListens, reason: '$why: no new GPS subscription');
            expect(app.gps.positions.active, 1, reason: why);
            expect(app.sensors.totalListens, sensorListens, reason: '$why: no new sensor subscription');
          }

          expect(app.census.live, timersBefore, reason: 'every periodic timer, per file, as before');
          expect(app.sensors.activeSubscriptions, sensorActive);
          expect(app.cameraCalls(), callsBefore, reason: 'the camera was not touched');
          expect(controller.cameraAttemptCreationCountForTest, attemptsBefore);
          expect(host.isForwardingEventsForTest, isTrue);
          await app.driveUntil(() => recorder.activeSession!.sampleCount > samplesBefore + 1, label: 'A keeps collecting');

          await app.stopSessionViaUi();
          final record = app.sessionsBox.get(a)!;
          expect(record.endTime, isNotNull);
          expect(await app.storedSamples(a), record.sampleCount);
          expect(app.unindexedClipFiles(), isEmpty);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
