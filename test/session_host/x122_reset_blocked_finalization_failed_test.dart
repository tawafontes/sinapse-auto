// Fase 16.2-R4.3-R2.6.8 — X122.
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/app_settings.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import '../support/app_harness.dart';
import 'reset_checks.dart';

void main() {
  testWidgets(
    'X122 Redefinir configuração with A in finalizationFailed is refused and says to retry the finalization; '
    'once the retry stores A, the same reset goes through to onboarding and leaves A intact',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot(seedTiles: {SensorType.altitude: DisplayStyle.lineChart});
          await app.driveFuture(AppSettings.setDashboardPageCount(2));
          final host = app.host;
          final recorder = host.recorder;
          final controller = host.dashcamController;
          final a = await app.startSessionViaUi();
          await app.waitSamples(3);
          await app.driveFuture(Hive.lazyBox(HiveBoxNames.drivingSessionSamples).close());
          app.emitting = false;
          await app.tapText('Finalizar sessão', settle: const Duration(milliseconds: 50));
          await app.driveUntil(() => recorder.state == DrivingSessionRecorderState.finalizationFailed, label: 'finalizationFailed');
          await app.driveUntil(() => controller.status == DashcamStatus.idle && !controller.dashcamService.hasPendingNativeStop, label: 'camera side settled');
          await app.driveFuture(Hive.openLazyBox(HiveBoxNames.drivingSessionSamples));
          final accepted = recorder.activeSession!.sampleCount;

          await expectResetBlocked(app, blocker: DrivingSessionRecorderState.finalizationFailed, explanation: 'Tente finalizá-la primeiro', pageCount: 2);
          expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);
          expect(recorder.activeSession!.id, a);

          // Retry, then the same reset is allowed.
          await app.stopSessionViaUi();
          expect(recorder.state, DrivingSessionRecorderState.idle);
          await resetThroughUi(app);

          expect(app.host, same(host), reason: 'the reset does not replace the host');
          expect(host.isDisposed, isFalse);
          final record = app.sessionsBox.get(a)!;
          expect(record.endTime, isNotNull);
          expect(record.sampleCount, accepted);
          expect(await app.storedSamples(a), accepted, reason: 'the reset does not touch sessions');
          expect(app.unindexedClipFiles(), isEmpty);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
