// Fase 16.2-R4.3-R2.6.8 — X123.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';
import 'reset_checks.dart';

void main() {
  testWidgets(
    'X123 with no session obligation Redefinir configuração goes to onboarding: configuration erased, '
    'the finished session intact, the host kept, and its snapshot pipeline released (no GNSS timer)',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot(seedTiles: {SensorType.altitude: DisplayStyle.lineChart});
          final host = app.host;
          final a = await app.startSessionViaUi();
          await app.waitSamples(2);
          await app.stopSessionViaUi();
          final stored = await app.storedSamples(a);
          expect(host.configurationResetBlocker, isNull, reason: 'setup: the session side is free');

          await resetThroughUi(app);

          expect(app.host, same(host));
          expect(host.isDisposed, isFalse);
          expect(host.recorder.state, DrivingSessionRecorderState.idle);
          expect(app.sessionsBox.get(a)!.endTime, isNotNull);
          expect(await app.storedSamples(a), stored);

          // Nothing observes the pipeline during onboarding: the snapshot is
          // released, so its GNSS stale-check timer is gone, and nothing of the
          // session or camera keeps a timer.
          await app.drive(const Duration(seconds: 1));
          expect(host.isForwardingEventsForTest, isFalse);
          expect(app.census.liveOf(gnssTimerFile), 0);
          expect(app.census.liveOf('dashcam_session_controller.dart'), 0);
          expect(app.census.liveOf('dashcam_service.dart'), 0);
          expect(app.census.liveOf('dashcam_rec_indicator.dart'), 0);
          // Platform subscriptions stay bounded by the ONE pipeline (see the
          // R2.6.8 report: the pipeline's internal shared stages keep theirs).
          expect(app.gps.positions.active, lessThanOrEqualTo(1));
          expect(app.sensors.accelerometer.active, lessThanOrEqualTo(1));
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
