/// Pure, hardware-independent plausibility checks used by the telemetry
/// engine to drop obviously-bad readings before they ever reach the filter
/// stage — e.g. a GPS glitch that reports an impossible speed or a
/// multi-hundred-meter altitude teleport. Kept as plain top-level functions
/// (no class, no state) so they're directly unit-testable, matching the
/// existing top-level-function convention already used for the sensor
/// layer's other pure math (see `dashboard_sensor_streams.dart`'s
/// `@visibleForTesting` functions).
library;

/// Generous upper bound — well beyond anything a road vehicle reaches —
/// deliberately loose so this only ever catches genuine glitches (a
/// momentary GPS speed spike), never real driving.
const double _maxPlausibleSpeedKmh = 360.0;

bool isPlausibleSpeedKmh(double speedKmh) =>
    speedKmh >= 0 && speedKmh <= _maxPlausibleSpeedKmh;

/// Generous upper bound on vertical rate, in meters per second — a car
/// climbing/descending this fast would mean the GPS fix itself teleported,
/// not that the vehicle actually moved; real driving (even a steep grade)
/// never approaches this.
const double _maxPlausibleVerticalRateMs = 15.0;

/// Rejects an altitude update whose implied climb/descent rate is
/// physically implausible for a road vehicle — the guard against a GPS fix
/// that jumps hundreds of meters between two consecutive readings.
bool isPlausibleAltitudeChange({
  required double previousMeters,
  required double candidateMeters,
  required Duration elapsed,
}) {
  final elapsedSeconds = elapsed.inMilliseconds / 1000.0;
  if (elapsedSeconds <= 0) return true; // nothing to divide by — let quality/freshness checks handle it.
  final rate = (candidateMeters - previousMeters).abs() / elapsedSeconds;
  return rate <= _maxPlausibleVerticalRateMs;
}

/// Rejects a reading whose [timestamp] is older than [maxAge] relative to
/// [now] — guards against a delayed/buffered platform callback being fed
/// into the pipeline as if it were current.
bool isReadingFresh(DateTime timestamp, {required DateTime now, required Duration maxAge}) {
  return now.difference(timestamp) <= maxAge;
}
