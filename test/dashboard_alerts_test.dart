// dashboard_alerts.dart — where and in which color the dashboard shows a confirmed alert, now
// that the red bottom banner is gone (2026-11-11).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/alert_type.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/dashboard_alerts.dart';
import 'package:synapse_auto/widgets/sensors/artificial_horizon.dart' show InclinationRiskZone, riskZoneColor;

void main() {
  test('speed alerts go to the speed widget; acceleration, braking, cornering and resultant G to the G widget', () {
    expect(dashboardTileForDetectedEvent(DetectedEventType.speedLimitExceeded), SensorType.speed);
    for (final type in [
      DetectedEventType.hardAcceleration,
      DetectedEventType.hardBraking,
      DetectedEventType.hardCorneringLeft,
      DetectedEventType.hardCorneringRight,
      DetectedEventType.highResultantG,
    ]) {
      expect(dashboardTileForDetectedEvent(type), SensorType.gForce, reason: '$type');
    }
  });

  test('GNSS, stop/resume and altitude-trend events blink nothing', () {
    for (final type in [
      DetectedEventType.gnssLost,
      DetectedEventType.gnssRecovered,
      DetectedEventType.stopped,
      DetectedEventType.resumed,
      DetectedEventType.altitudeRisingSignificant,
      DetectedEventType.altitudeFallingSignificant,
    ]) {
      expect(dashboardTileForDetectedEvent(type), isNull, reason: '$type');
    }
  });

  test('every event that has a dashboard widget is an alert the user can switch off', () {
    for (final type in DetectedEventType.values) {
      if (dashboardTileForDetectedEvent(type) == null) continue;
      expect(configurableAlertTypes, contains(alertTypeForDetectedEvent(type)), reason: '$type');
    }
  });

  test('severity → the inclination palette: warning yellow, high orange, critical red; info none', () {
    for (final b in Brightness.values) {
      expect(dashboardAlertColor(EventSeverity.info, b), isNull);
      expect(dashboardAlertColor(EventSeverity.warning, b), riskZoneColor(InclinationRiskZone.risk, b));
      expect(dashboardAlertColor(EventSeverity.high, b), riskZoneColor(InclinationRiskZone.highRisk, b));
      expect(dashboardAlertColor(EventSeverity.critical, b), riskZoneColor(InclinationRiskZone.veryHighRisk, b));
    }
  });

  test('the "Alertas" menu no longer offers the GNSS alerts', () {
    expect(configurableAlertTypes, isNot(contains(AlertType.gnssLost)));
    expect(configurableAlertTypes, isNot(contains(AlertType.weakGnss)));
    expect(configurableAlertTypes.toSet(), AlertType.values.toSet().difference({AlertType.gnssLost, AlertType.weakGnss}));
  });

  test('a blink outlasts the detector\'s 5 s cooldown, so a repeated alert does not flicker off', () {
    expect(dashboardEventAlertHold, greaterThan(const Duration(seconds: 5)));
  });
}
