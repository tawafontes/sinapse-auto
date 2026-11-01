// Fase 16.2-R4.3-R2.6.8 — X116. See recreation_checks.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';

import '../support/app_harness.dart';
import 'recreation_checks.dart';

void main() {
  testWidgets(
    'X116 "+" → Continuar (dashboard edit) while recording: the dashboard is replaced but session A, its '
    'recorder, controller and pipeline are the same, A keeps collecting, and its STOP stores every sample and clip',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          // Altitude has a single style, so the style step finishes on its own.
          await app.boot(seedTiles: {SensorType.altitude: DisplayStyle.lineChart});
          await expectRecreationKeepsSession(app, app.tapAddToolContinue);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
