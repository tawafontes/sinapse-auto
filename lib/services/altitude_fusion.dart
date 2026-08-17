import 'dart:math' as math;

/// Barometer-rate / GPS-reference complementary filter, used by
/// [TelemetryEngine] to produce a single altitude estimate that has the
/// barometer's low noise/fast response without its long-term drift, and the
/// GPS's absolute reference without its jumpiness.
///
/// Kept as ONE running fused scalar rather than two independently-blended
/// values: each barometer sample only ever contributes its own *delta*
/// since the last one (never an absolute value), so there's nothing to
/// double-count against the GPS anchor.
///
/// No barometer available on this device? Simply never call
/// [addBarometerReading] — [fusedAltitudeMeters] then degrades gracefully
/// to GPS altitude alone (bootstrap + the same gap-aware smoothing
/// [addGpsReading] always applies), with no special-casing needed anywhere
/// else in the system. This is the "automatic, no user intervention"
/// fallback the app's spec asks for.
class AltitudeFusion {
  double? _fused;
  double? _lastBaroRelativeMeters;
  double? _baroReferencePressureHpa;
  DateTime? _lastAcceptedGpsTimestamp;

  /// Base GPS correction strength applied on a normal (few-second) gap
  /// between fixes — deliberately gentle so it never fights the
  /// barometer's fast response during ordinary driving.
  static const _baseGpsAlpha = 0.02;

  /// True once at least one barometer reading has ever been added — lets a
  /// caller (or a test/diagnostic) confirm the fusion path, as opposed to
  /// the GPS-only fallback, is actually active.
  bool get hasBarometer => _baroReferencePressureHpa != null;

  /// The current best fused altitude estimate, in meters. Null only before
  /// the first reading (of either kind) has ever arrived.
  double? get fusedAltitudeMeters => _fused;

  /// Feeds one barometer sample. The first call seeds the reference
  /// pressure used to compute a *relative* altitude (via the standard
  /// international barometric formula) — only relative drift-correction
  /// against GPS matters here, not true sea-level altitude.
  void addBarometerReading(double pressureHpa, DateTime now) {
    _baroReferencePressureHpa ??= pressureHpa;
    final relativeMeters =
        (44330.0 * (1 - math.pow(pressureHpa / _baroReferencePressureHpa!, 1 / 5.255))).toDouble();

    if (_fused != null && _lastBaroRelativeMeters != null) {
      _fused = _fused! + (relativeMeters - _lastBaroRelativeMeters!);
    }
    _lastBaroRelativeMeters = relativeMeters;
  }

  /// Feeds one quality-gated, non-outlier GPS altitude sample. Bootstraps
  /// [fusedAltitudeMeters] directly on the very first call (regardless of
  /// whether a barometer reading has already arrived). After that, pulls
  /// the fused estimate toward [altitudeMeters] with a gap-aware strength:
  /// the longer it's been since the last accepted GPS sample, the harder
  /// the pull — so a normal 1-5s cadence barely nudges the estimate (stays
  /// invisible), while a long gap (tunnel, parking garage) re-anchors
  /// quickly instead of leaving the barometer to free-run indefinitely on
  /// accumulated weather/sensor drift.
  void addGpsReading(double altitudeMeters, DateTime now) {
    if (_fused == null) {
      _fused = altitudeMeters;
    } else {
      final gapSeconds = _lastAcceptedGpsTimestamp == null
          ? 0
          : now.difference(_lastAcceptedGpsTimestamp!).inSeconds;
      final alpha = (_baseGpsAlpha * (1 + gapSeconds / 10)).clamp(_baseGpsAlpha, 1.0);
      _fused = _fused! + alpha * (altitudeMeters - _fused!);
    }
    _lastAcceptedGpsTimestamp = now;
  }
}
