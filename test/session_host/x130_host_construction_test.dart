// Fase 16.2-R4.3-R2.6.8 — X130.
//
// The host now exists from the first frame, including during onboarding.
// Building it must not start anything: listening to the snapshot starts GPS
// and the motion sensors and requests location permission — before the
// onboarding's own permission step (R4.3-D2 risk R2).
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/screens/onboarding/welcome_screen.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X130 on a fresh install (onboarding) the host exists but has subscribed to nothing: no GPS or sensor '
    'subscription, no permission request, no pipeline timer, no forwarding',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot(onboardingDone: false);
          await app.drive(const Duration(seconds: 2));
          expect(find.byType(WelcomeScreen), findsOneWidget, reason: 'setup: onboarding');
          expect(app.dashboardCount(), 0);
          final host = app.host;
          expect(host.isDisposed, isFalse);
          expect(host.recorder.state, DrivingSessionRecorderState.idle);
          expect(app.gps.positions.listens, 0);
          expect(app.sensors.totalListens, 0);
          expect(app.gps.permissionRequests, 0);
          expect(app.census.liveOf(gnssTimerFile), 0);
          expect(host.isForwardingEventsForTest, isFalse);
          expect(app.cameraCalls(), isEmpty);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
