/// Fuses an absolute-but-noisy angle reading (from an accelerometer's tilt
/// formula) with a relative-but-clean rate of change (from a gyroscope) —
/// the classic complementary filter used in essentially every real-world
/// attitude system (drones, gimbals, AHRS units) for exactly this
/// combination of sensors.
///
/// Neither sensor alone is enough:
///  * The accelerometer's tilt angle is accurate on average, but any
///    transient linear acceleration (a pothole, braking, accelerating) adds
///    directly into the same reading used to estimate gravity's direction —
///    no amount of low-pass filtering *that* signal removes this
///    contamination, it can only trade off "smooth but laggy" against "fast
///    but shaky" on an already-corrupted input.
///  * The gyroscope's angular rate is unaffected by linear acceleration
///    (it only measures rotation), but integrating it alone accumulates
///    unbounded drift over time — a gyro-only estimate slowly wanders away
///    from the true angle even when the device is perfectly still.
///
/// The fix is to combine them: on every update, extrapolate the previous
/// fused angle forward using the gyroscope's rate (immune to the
/// accelerometer's transient corruption), then pull that extrapolation
/// gently back toward the accelerometer's own reading (correcting gyro
/// drift a little on every single sample, so it never has a chance to
/// accumulate). [gyroWeight] controls the balance — see its own doc.
class ComplementaryFilter {
  ComplementaryFilter({required this.gyroWeight}) : assert(gyroWeight > 0 && gyroWeight < 1);

  /// How much the gyroscope-extrapolated estimate is trusted on each
  /// update, in `(0, 1)` — the accelerometer contributes the remaining
  /// `1 - gyroWeight`. Higher rejects more transient accelerometer
  /// corruption (more gyro-dominated) but corrects drift more slowly;
  /// lower corrects drift faster but lets more of the accelerometer's own
  /// transient noise back in. The time constant for the accelerometer to
  /// pull a gyro-only drift back to the true value is roughly
  /// `updateInterval / (1 - gyroWeight)` — e.g. at a 20ms update interval
  /// and `gyroWeight = 0.96`, about 0.5s: fast enough to correct drift
  /// continuously, slow enough that a sub-second transient (a bump, a
  /// brief acceleration) doesn't meaningfully perturb the fused output.
  final double gyroWeight;

  double? _angle;
  DateTime? _previousTimestamp;

  /// Feeds one new sample through the filter and returns the updated fused
  /// angle (same unit as [accelAngleDeg] — this class is unit-agnostic
  /// despite the name, degrees is simply what every caller in this app
  /// happens to use).
  ///
  /// [gyroRateDegPerSec] is the signed rate of change of this same angle,
  /// in the same unit-per-second — null whenever no gyroscope reading is
  /// available yet (or the device has no gyroscope at all, and never will
  /// be). A null rate makes this call fall back to the accelerometer angle
  /// directly, with no fusion — this is the automatic no-gyroscope
  /// fallback: a device that never reports a gyroscope reading gets
  /// exactly today's accelerometer-only behavior, with no special-casing
  /// needed anywhere else (mirrors [AltitudeFusion]'s own automatic
  /// no-barometer fallback).
  ///
  /// The first call (or the first call after a null-rate gap) seeds the
  /// estimate directly to [accelAngleDeg] — no fake ramp-up from zero. A
  /// non-positive elapsed time since the previous call (a duplicate or
  /// non-monotonic timestamp) returns the last estimate unchanged rather
  /// than integrating over a zero or negative interval.
  double filter(double accelAngleDeg, double? gyroRateDegPerSec, DateTime timestamp) {
    final previousTimestamp = _previousTimestamp;
    final previousAngle = _angle;
    _previousTimestamp = timestamp;

    if (previousTimestamp == null || previousAngle == null || gyroRateDegPerSec == null) {
      _angle = accelAngleDeg;
      return accelAngleDeg;
    }

    final dt = timestamp.difference(previousTimestamp).inMicroseconds / 1e6;
    if (dt <= 0) return previousAngle;

    final gyroEstimate = previousAngle + gyroRateDegPerSec * dt;
    final fused = gyroWeight * gyroEstimate + (1 - gyroWeight) * accelAngleDeg;
    _angle = fused;
    return fused;
  }
}
