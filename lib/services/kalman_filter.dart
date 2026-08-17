/// A minimal, generic 1-dimensional Kalman filter used by [TelemetryEngine]
/// to denoise speed, altitude and g-force readings without the lag a plain
/// moving average introduces.
///
/// [processNoise] (Q) is how much the true value is expected to drift
/// between updates on its own — higher makes the filter track changes
/// faster at the cost of more residual noise. [measurementNoise] (R) is how
/// much to distrust each incoming reading — higher makes the filter lean
/// more on its own prediction than on the new sample. Both are tuned
/// per-signal by [TelemetryEngine]; see its own doc comments for the
/// reasoning behind each signal's values.
///
/// [filter]'s optional per-call [measurementNoise] lets a per-sample
/// confidence value (e.g. GNSS-reported `speedAccuracy`) override the
/// constructor's default R for just that one update — this is the standard
/// way a Kalman filter incorporates a sensor's own reported uncertainty:
/// a reading the platform itself flags as imprecise is trusted less, so a
/// single bad fix barely moves the estimate instead of causing a visible
/// jump.
class KalmanFilter1D {
  KalmanFilter1D({required this.processNoise, required this.measurementNoise});

  final double processNoise;
  final double measurementNoise;

  double? _estimate;
  double _errorCovariance = 1.0;

  /// The filter's current best estimate, or null before the first [filter]
  /// call.
  double? get value => _estimate;

  /// Feeds one new [measurement] through the filter and returns the updated
  /// estimate. The very first call seeds the estimate directly to
  /// [measurement] (not 0) so there's no artificial ramp-up on startup that
  /// would otherwise look like a fake acceleration/climb.
  double filter(double measurement, {double? measurementNoise}) {
    if (_estimate == null) {
      _estimate = measurement;
      return _estimate!;
    }

    final r = measurementNoise ?? this.measurementNoise;

    // Predict: the estimate itself doesn't change without a motion model,
    // but our confidence in it decays by the process noise.
    final predictedCovariance = _errorCovariance + processNoise;

    // Update: blend the prediction with the new measurement, weighted by
    // how much more we trust one over the other.
    final kalmanGain = predictedCovariance / (predictedCovariance + r);
    _estimate = _estimate! + kalmanGain * (measurement - _estimate!);
    _errorCovariance = (1 - kalmanGain) * predictedCovariance;

    return _estimate!;
  }
}
