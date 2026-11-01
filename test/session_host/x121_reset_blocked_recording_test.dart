// Fase 16.2-R4.3-R2.6.8 — X121. R4.3-D2 (F23, 3/3): Redefinir during a
// recording left A active and invisible in the History, its clip unindexed.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/app_settings.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';
import 'reset_checks.dart';

void main() {
  testWidgets(
    'X121 Redefinir configuração while recording is refused — in the dialog and in the operation itself — '
    'and changes neither the configuration nor session A',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot(seedTiles: {SensorType.altitude: DisplayStyle.lineChart});
          await app.driveFuture(AppSettings.setDashboardPageCount(3));
          final host = app.host;
          final recorder = host.recorder;
          final a = await app.startSessionViaUi();
          await app.waitSamples(2);

          await expectResetBlocked(app, blocker: DrivingSessionRecorderState.recording, explanation: 'Encerre a sessão primeiro', pageCount: 3);

          expect(app.host, same(host));
          expect(recorder.state, DrivingSessionRecorderState.recording);
          expect(recorder.activeSession!.id, a);
          expect(app.sessionsBox.get(a)!.endTime, isNull);
          expect(DrivingSessionRecorder.controllingState(a), DrivingSessionRecorderState.recording);
          final samples = recorder.activeSession!.sampleCount;
          await app.driveUntil(() => recorder.activeSession!.sampleCount > samples, label: 'A keeps collecting');

          await app.stopSessionViaUi();
          expect(await app.storedSamples(a), app.sessionsBox.get(a)!.sampleCount);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
