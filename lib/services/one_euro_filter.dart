import 'dart:math' as math;

/// Adaptive low-pass filter that varies its own cutoff frequency based on
/// the signal's estimated speed (rate of change) — heavy smoothing while
/// the signal is essentially static (killing jitter/noise), fast response
/// (near-raw) the moment it starts changing for real. Standard reference
/// algorithm: Casiez, Roussel & Vogel, "1€ Filter: A Simple Speed-based
/// Low-pass Filter for Noisy Input in Interactive Systems" (CHI 2012).
///
/// Unlike a fixed-alpha exponential moving average (which must compromise
/// between killing noise at rest and lagging behind real movement, since
/// one alpha governs both), this filter's cutoff is driven by an internal
/// smoothed estimate of the signal's own derivative. A signal that's
/// oscillating back and forth (vibration) keeps that estimate small — the
/// positive and negative swings partially cancel out under smoothing —
/// while a signal trending consistently in one direction (a real,
/// sustained change) pushes the estimate, and therefore the cutoff, up
/// quickly. That's what lets [minCutoff]/[beta] be tuned once for
/// "stationary jitter" and "real movement" simultaneously, rather than
/// needing a separate mode switch or trend-confirmation state machine.
class OneEuroFilter {
  OneEuroFilter({
    required this.minCutoff,
    required this.beta,
    this.dCutoff = 1.0,
  });

  /// Cutoff frequency (Hz) used when the signal is essentially static —
  /// lower means heavier smoothing (less jitter) at the cost of more lag
  /// during genuinely slow, deliberate movements.
  final double minCutoff;

  /// How much the cutoff increases per unit of estimated signal speed
  /// (signal units per second) — higher means faster response to quick
  /// real movements, at the cost of letting more noise through while
  /// moving fast.
  final double beta;

  /// Cutoff frequency (Hz) for smoothing the derivative estimate itself —
  /// standard fixed default from the original paper; rarely needs tuning.
  final double dCutoff;

  double? _filteredValue;
  double? _filteredDerivative;
  DateTime? _previousTimestamp;

  static double _alpha(double cutoffHz, double dtSeconds) {
    final r = 2 * math.pi * cutoffHz * dtSeconds;
    return r / (r + 1);
  }

  static double _lowPass(double value, double previousFiltered, double alpha) =>
      alpha * value + (1 - alpha) * previousFiltered;

  /// Feeds one new [value] sampled at [timestamp] through the filter and
  /// returns the updated estimate. The first call seeds the filter
  /// directly to [value] (no ramp-up from zero). A non-positive elapsed
  /// time since the previous call (a duplicate or non-monotonic timestamp)
  /// is ignored — returns the last estimate unchanged rather than dividing
  /// by zero.
  double filter(double value, DateTime timestamp) {
    final previousTimestamp = _previousTimestamp;
    final previousFiltered = _filteredValue;
    _previousTimestamp = timestamp;

    if (previousTimestamp == null || previousFiltered == null) {
      _filteredValue = value;
      _filteredDerivative = 0;
      return value;
    }

    final dt = timestamp.difference(previousTimestamp).inMicroseconds / 1e6;
    if (dt <= 0) return previousFiltered;

    // The derivative is estimated against the previous *filtered* value
    // (not the previous raw sample) — matching the original algorithm's
    // own reference implementation, which uses this as an implicit extra
    // measure of consistency in the speed estimate itself.
    final rawDerivative = (value - previousFiltered) / dt;
    final derivativeAlpha = _alpha(dCutoff, dt);
    final filteredDerivative = _lowPass(rawDerivative, _filteredDerivative ?? rawDerivative, derivativeAlpha);

    final cutoff = minCutoff + beta * filteredDerivative.abs();
    final valueAlpha = _alpha(cutoff, dt);
    final filteredValue = _lowPass(value, previousFiltered, valueAlpha);

    _filteredValue = filteredValue;
    _filteredDerivative = filteredDerivative;
    return filteredValue;
  }
}
