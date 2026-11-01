// Fase 16.2-R4.3-R2.6.8 — X128: the reset OPERATION (not only its button)
// enforces the contract, for every open obligation and for a session admitted
// while its writes run.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/app_settings.dart';
import 'package:synapse_auto/services/configuration_reset_service.dart';
import 'package:synapse_auto/services/driving_session_host.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';

import '../support/app_harness.dart';
import 'reset_checks.dart';

void main() {
  testWidgets(
    'X128 ConfigurationResetService refuses before writing anything while the session is finalizing, and '
    'refuses (keeping the session) when a session is admitted while its writes run',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot(seedTiles: {SensorType.altitude: DisplayStyle.lineChart});
          await app.driveFuture(AppSettings.setDashboardPageCount(2));
          final host = app.host;
          final recorder = host.recorder;
          final themeController = themeControllerOf(tester);
          const service = ConfigurationResetService();

          Future<Object?> resetError(Future<void> reset) async {
            try {
              await app.driveFuture(reset);
            } catch (e) {
              return e;
            }
            return null;
          }

          // Finalizing: the STOP is in flight in this very slice (the
          // controller calls the recorder's stop synchronously).
          final a = await app.startSessionViaUi();
          await app.waitSamples(2);
          final stop = host.dashcamController.stopSession();
          expect(recorder.state, DrivingSessionRecorderState.finalizing, reason: 'setup');
          final finalizing = await resetError(service.reset(sessionHost: host, themeController: themeController));
          expect(finalizing, isA<ConfigurationResetRejected>().having((e) => e.blocker, 'blocker', DrivingSessionRecorderState.finalizing));
          expectConfigurationIntact(app, pageCount: 2, step: 'refused while finalizing');
          await app.driveFuture(stop);
          await app.driveUntil(
            () => host.dashcamController.status == DashcamStatus.idle && !host.dashcamController.dashcamService.hasPendingNativeStop,
            label: 'camera side settled',
          );
          expect(recorder.state, DrivingSessionRecorderState.idle);
          expect(app.sessionsBox.get(a)!.endTime, isNotNull);

          // Idle at the call, but a session is admitted while the writes run:
          // the operation refuses at its end, so the caller stays on the
          // dashboard with the new session instead of sending it to onboarding.
          final reset = service.reset(sessionHost: host, themeController: themeController);
          final b = host.dashcamController.startSession().id;
          final late = await resetError(reset);
          expect(late, isA<ConfigurationResetRejected>().having((e) => e.blocker, 'blocker', DrivingSessionRecorderState.recording));
          expect(SensorWidgetRepository.all, isEmpty, reason: 'setup: the writes did run');
          expect(recorder.state, DrivingSessionRecorderState.recording);
          expect(recorder.activeSession!.id, b);
          expect(app.dashboardCount(), 1);

          await app.driveUntil(() => host.dashcamController.initialSetupInstallCountForTest >= 2, label: 'B camera set up');
          await app.stopSessionViaUi();
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
