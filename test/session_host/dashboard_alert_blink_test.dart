// The red bottom banner is gone (2026-11-11): a confirmed alert makes the card of the widget that
// measures it blink instead. Here a real "Velocidade elevada" — the fake GPS drives at ~15.8 km/h
// against a limit lowered to 8 km/h — confirmed by the real EventDetectionEngine makes the SPEED
// card blink (in the inclination palette), never the G card, and the blink ends after its hold.
// Through the real app over platform fakes (support/app_harness.dart). One test per file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/alert_type.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/sensor_type_metadata.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/screens/dashboard/dashboard_screen.dart';
import 'package:synapse_auto/services/alert_preferences.dart';
import 'package:synapse_auto/services/dashboard_alerts.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('a confirmed speed alert blinks the speed card, not another one, and stops after its hold', (tester) async {
    final app = AppHarness(tester);
    try {
      await app.run(() async {
        await app.boot(seedTiles: const {SensorType.speed: DisplayStyle.numericWithHistory, SensorType.gForce: DisplayStyle.gForceMeter});
        DashboardTile tile(SensorType type) => tester.widget<DashboardTile>(
          find.byWidgetPredicate((w) => w is DashboardTile && w.label == sensorTypeMetadata[type]!.label),
        );
        final context = tester.element(find.byType(DashboardScreen));
        final prefs = AlertPreferencesScope.of(context);
        await app.driveFuture(prefs.setThreshold(AlertType.highSpeed, 8));
        expect(tile(SensorType.speed).alertColor, isNull, reason: 'setup: nothing alerted yet');

        app.emitting = true;
        await app.driveUntil(() => tile(SensorType.speed).alertColor != null, label: 'the speed card blinking');
        app.emitting = false;

        final palette = {
          for (final s in [EventSeverity.warning, EventSeverity.high, EventSeverity.critical]) dashboardAlertColor(s, Theme.of(context).brightness),
        };
        expect(palette, contains(tile(SensorType.speed).alertColor), reason: 'in the severity palette');
        expect(tile(SensorType.gForce).alertColor, isNull, reason: 'only the alerted quantity\'s card');

        await tester.pump(dashboardEventAlertHold + const Duration(seconds: 1));
        await tester.pump();
        expect(tile(SensorType.speed).alertColor, isNull, reason: 'the blink ends after its hold');
      });
    } finally {
      await app.teardown();
    }
  });
}
