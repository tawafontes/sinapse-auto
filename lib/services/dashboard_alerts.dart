import 'package:flutter/material.dart' show Brightness, Color;

import '../models/alert_type.dart';
import '../models/detected_event.dart';
import '../models/sensor_widget_config.dart';
import '../widgets/sensors/artificial_horizon.dart' show InclinationRiskZone, riskZoneColor;

/// How the dashboard shows an alert since the red bottom banner was removed
/// (owner decision, 2026-11-11): the card of the widget that measures the
/// alerted quantity blinks — the same card-wide blink the inclination widget
/// already had ([DashboardTile.alertColor]) — in yellow → red by intensity.
///
/// Nothing here detects anything: the alerts are [EventDetectionEngine]'s
/// confirmed events (the one central detector, already gated per alert by
/// the user's "Alertas" toggles and thresholds); this only says WHERE and in
/// WHICH COLOR an event is shown, and for how long.

/// The dashboard widget an alert of [type] is shown on, or `null` when it has
/// no widget there: GNSS loss/recovery (signal state, read in "Diagnóstico"),
/// stop/resume and altitude trend (session history only).
SensorType? dashboardTileForDetectedEvent(DetectedEventType type) {
  switch (type) {
    case DetectedEventType.speedLimitExceeded:
      return SensorType.speed;
    case DetectedEventType.hardAcceleration:
    case DetectedEventType.hardBraking:
    case DetectedEventType.hardCorneringLeft:
    case DetectedEventType.hardCorneringRight:
    case DetectedEventType.highResultantG:
      return SensorType.gForce;
    case DetectedEventType.gnssLost:
    case DetectedEventType.gnssRecovered:
    case DetectedEventType.stopped:
    case DetectedEventType.resumed:
    case DetectedEventType.altitudeRisingSignificant:
    case DetectedEventType.altitudeFallingSignificant:
      return null;
  }
}

/// The blink color for an event of [severity] — the inclination widget's own
/// risk palette, so every alert on the dashboard speaks one color language:
/// warning (just past the threshold) yellow, high (≥ 1.5×) orange, critical
/// (≥ 2×) red. `null` for [EventSeverity.info], which is never an alert.
Color? dashboardAlertColor(EventSeverity severity, Brightness brightness) {
  switch (severity) {
    case EventSeverity.info:
      return null;
    case EventSeverity.warning:
      return riskZoneColor(InclinationRiskZone.risk, brightness);
    case EventSeverity.high:
      return riskZoneColor(InclinationRiskZone.highRisk, brightness);
    case EventSeverity.critical:
      return riskZoneColor(InclinationRiskZone.veryHighRisk, brightness);
  }
}

/// How long a card blinks for one confirmed event. The detector reports an
/// episode once, when it is confirmed, and holds the next one back for its
/// 5 s cooldown (`EventDetectionEngine._levelCooldown`), so a little longer
/// than that keeps a repeated alert blinking without a gap.
const Duration dashboardEventAlertHold = Duration(seconds: 6);

/// The alerts the "Alertas" screen offers. The two GNSS alerts are left out:
/// their toggles only ever drove the red banner, and the signal is shown in
/// "Diagnóstico" (owner decision, 2026-11-11). GNSS loss is still recorded
/// in the session history regardless.
const List<AlertType> configurableAlertTypes = [
  AlertType.highSpeed,
  AlertType.harshAcceleration,
  AlertType.harshBraking,
  AlertType.hardCornering,
  AlertType.highResultantG,
  AlertType.highInclination,
];
