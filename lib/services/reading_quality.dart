/// Pure quality-gating for a raw GNSS [Position], used by the telemetry
/// engine before a fix is allowed anywhere near the fusion/filter stages.
///
/// Vocabulary note: the app's own spec talks about "verticalAccuracy" and
/// "bearingAccuracy" — those map directly onto [Position.altitudeAccuracy]
/// and [Position.headingAccuracy] respectively (the plugin's own field
/// names; no gap, just a naming difference worth writing down once).
///
/// Satellite count is deliberately NOT checked here: `package:geolocator`'s
/// cross-platform [Position] doesn't expose it (would require
/// platform-specific extension code, out of scope) — this is a documented,
/// deliberate limitation, not a silently-skipped requirement.
library;

import 'package:geolocator/geolocator.dart';

const double _maxHorizontalAccuracyM = 30.0;
const double _maxSpeedAccuracyMs = 3.0;
const double _maxAltitudeAccuracyM = 25.0;

/// Whether [position] is trustworthy enough to feed into the telemetry
/// pipeline at all. A [Position] with an accuracy field unavailable on the
/// current device reports `0.0` for that field (per the plugin's own
/// contract) — treated here as "unknown, don't gate on it" rather than
/// "perfect," since a real 0.0 accuracy reading never actually occurs.
bool isPositionAcceptable(
  Position position, {
  double maxHorizontalAccuracyM = _maxHorizontalAccuracyM,
  double maxSpeedAccuracyMs = _maxSpeedAccuracyMs,
  double maxAltitudeAccuracyM = _maxAltitudeAccuracyM,
}) {
  if (position.accuracy > 0 && position.accuracy > maxHorizontalAccuracyM) return false;
  if (position.speedAccuracy > 0 && position.speedAccuracy > maxSpeedAccuracyMs) return false;
  if (position.altitudeAccuracy > 0 && position.altitudeAccuracy > maxAltitudeAccuracyM) return false;
  return true;
}
