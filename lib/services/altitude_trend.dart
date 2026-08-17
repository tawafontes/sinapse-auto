import 'package:flutter/foundation.dart' show visibleForTesting;

/// Whether altitude is climbing, descending, or holding steady — a
/// derived-state summary [TelemetryEngine] computes on top of its own
/// already-fused/filtered [TelemetryEngine.altitudeMeters], for consumers
/// (Diagnostics today; sessions/alerts in a future phase) that want "is the
/// vehicle climbing" without re-deriving a rate of change themselves.
enum AltitudeTrend { stable, rising, falling }

/// Centralized, documented thresholds for [AltitudeTrendClassifier] — kept
/// alongside [GnssQualityThresholds]'s own convention of naming every
/// tuning constant instead of leaving it anonymous inside the algorithm.
class AltitudeTrendThresholds {
  AltitudeTrendThresholds._();

  /// Smoothed vertical rate (meters/second) at or beyond which a sample
  /// counts as a "climbing"/"descending" *candidate* — not yet enough on its
  /// own to change the confirmed trend, see [confirmSamples]. A gentle 2%
  /// road grade at highway speed (25 m/s) already implies ~0.5 m/s; this is
  /// set well below that so a real, sustained grade is never missed, while
  /// staying comfortably above the residual noise the already-Kalman/
  /// adaptive-exponential-filtered altitude signal settles to at rest.
  static const enterMetersPerSecond = 0.15;

  /// Light EMA applied to the raw per-update rate before it's compared
  /// against [enterMetersPerSecond] — enough to reject a single noisy
  /// sample-to-sample delta without adding perceptible lag to a real,
  /// sustained change.
  static const rateSmoothingAlpha = 0.25;

  /// How many consecutive samples must agree on the same reading (rising /
  /// falling / stable) before [AltitudeTrendClassifier] actually changes its
  /// confirmed state — the same "candidate streak" debounce idiom already
  /// used by `vehicle_coordinate_system.dart`'s `pairedWithMountOrientation`
  /// for the phone's mount orientation. This is what keeps a handful of
  /// ordinary GNSS/barometer jitter samples (a swing of even 0.3-0.9m
  /// between two consecutive readings) classified as [AltitudeTrend.stable]
  /// rather than flickering to rising/falling and back — required both ways
  /// (entering *and* leaving stable), not just as an entry threshold.
  static const confirmSamples = 4;
}

/// Stateful hysteresis classifier — see [AltitudeTrendThresholds] for the
/// tuning rationale. Feed it every new fused/filtered altitude sample (in
/// the same order and with the sample's own real timestamp) via [classify];
/// it never needs to be constructed more than once per telemetry session.
@visibleForTesting
class AltitudeTrendClassifier {
  AltitudeTrend _confirmed = AltitudeTrend.stable;
  AltitudeTrend? _candidate;
  int _candidateStreak = 0;
  double? _smoothedRate;
  double? _lastAltitude;
  DateTime? _lastTimestamp;

  /// Feeds one new [altitudeMeters] sample at [timestamp] and returns the
  /// current confirmed trend. The first call (nothing to compare against
  /// yet) always returns [AltitudeTrend.stable] without consuming a
  /// confirm-streak slot.
  AltitudeTrend classify(double altitudeMeters, DateTime timestamp) {
    final lastAltitude = _lastAltitude;
    final lastTimestamp = _lastTimestamp;
    _lastAltitude = altitudeMeters;
    _lastTimestamp = timestamp;
    if (lastAltitude == null || lastTimestamp == null) return _confirmed;

    final dtSeconds = timestamp.difference(lastTimestamp).inMicroseconds / 1e6;
    if (dtSeconds <= 0) return _confirmed; // duplicate/non-monotonic timestamp — nothing to derive a rate from.

    final rawRate = (altitudeMeters - lastAltitude) / dtSeconds;
    final smoothedRate = _smoothedRate;
    _smoothedRate = smoothedRate == null
        ? rawRate
        : smoothedRate + AltitudeTrendThresholds.rateSmoothingAlpha * (rawRate - smoothedRate);
    final rate = _smoothedRate!;

    final reading = rate >= AltitudeTrendThresholds.enterMetersPerSecond
        ? AltitudeTrend.rising
        : rate <= -AltitudeTrendThresholds.enterMetersPerSecond
        ? AltitudeTrend.falling
        : AltitudeTrend.stable;

    if (reading == _candidate) {
      _candidateStreak++;
    } else {
      _candidate = reading;
      _candidateStreak = 1;
    }
    if (_candidateStreak >= AltitudeTrendThresholds.confirmSamples) {
      _confirmed = reading;
    }
    return _confirmed;
  }
}
