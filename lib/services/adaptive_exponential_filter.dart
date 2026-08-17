/// An exponential moving-average filter whose smoothing strength adapts to
/// how fast the input is currently changing — used by [TelemetryEngine]
/// after its [KalmanFilter1D] stage to shape responsiveness explicitly:
/// heavy smoothing while a signal is essentially flat (killing residual
/// jitter at rest), fast tracking the moment it starts moving for real
/// (an acceleration/braking event, a hill climb).
///
/// This is a distinct concern from the Kalman filter's own noise-vs-trust
/// weighting: Kalman decides how much to believe *this particular
/// measurement*; this filter decides how quickly the *displayed* value
/// should be allowed to move, based on the recent trend rather than any
/// single sample.
class AdaptiveExponentialFilter {
  AdaptiveExponentialFilter({
    required this.minAlpha,
    required this.maxAlpha,
    required this.rateOfChangeForMaxAlpha,
  }) : assert(minAlpha > 0 && minAlpha <= maxAlpha && maxAlpha <= 1),
       assert(rateOfChangeForMaxAlpha > 0);

  /// Smoothing factor used when the input is essentially unchanged between
  /// updates (0-1; closer to 0 is heavier smoothing).
  final double minAlpha;

  /// Smoothing factor used once the input's rate of change reaches
  /// [rateOfChangeForMaxAlpha] or more (0-1; closer to 1 tracks the raw
  /// input almost immediately).
  final double maxAlpha;

  /// The per-update input delta (in the same unit as [filter]'s input) at
  /// and beyond which [maxAlpha] is used. Deltas between 0 and this value
  /// scale [minAlpha]..[maxAlpha] linearly.
  final double rateOfChangeForMaxAlpha;

  double? _output;
  double? _lastInput;

  /// Feeds one new [input] through the filter and returns the smoothed
  /// output. The first call returns [input] unchanged (no fake ramp-up).
  double filter(double input) {
    if (_output == null || _lastInput == null) {
      _output = input;
      _lastInput = input;
      return _output!;
    }

    final delta = (input - _lastInput!).abs();
    final t = (delta / rateOfChangeForMaxAlpha).clamp(0.0, 1.0);
    final alpha = minAlpha + (maxAlpha - minAlpha) * t;

    _output = _output! + alpha * (input - _output!);
    _lastInput = input;
    return _output!;
  }
}
