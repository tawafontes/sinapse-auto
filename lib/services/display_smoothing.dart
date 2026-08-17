import 'dart:ui' show Offset;

import 'one_euro_filter.dart';

/// Cosmetic-only stream transforms used by [DashboardSensorStreams] to make
/// noisy sensors pleasant to look at: a simple moving average smooths out
/// jitter, and an optional floor threshold snaps small values to a clean
/// zero (e.g. GPS speed noise while parked reads "0" instead of "0.8").
///
/// These wrap the *derived* dashboard streams only — never
/// [SensorService]'s raw streams — so nothing else that reads raw sensor
/// data (persistence, a future dashcam G-force trigger, etc.) is affected.
extension SmoothedValueStream on Stream<double> {
  /// A [windowSize] of 1 disables averaging (each value maps to itself)
  /// while still applying [floor] — a legitimate way to get floor-only
  /// behavior out of this same function.
  Stream<double> smoothedForDisplay({int windowSize = 5, double floor = 0}) {
    assert(windowSize >= 1);
    final window = <double>[];
    return map((value) {
      window.add(value);
      if (window.length > windowSize) window.removeAt(0);
      final average = window.reduce((a, b) => a + b) / window.length;
      return average.abs() < floor ? 0 : average;
    });
  }

}

/// The 2D counterpart of [SmoothedValueStream], used for tilt/g-force dots
/// where both axes need to move together.
extension SmoothedOffsetStream on Stream<Offset> {
  Stream<Offset> smoothedForDisplay({int windowSize = 5, double floor = 0}) {
    assert(windowSize >= 1);
    final window = <Offset>[];
    return map((value) {
      window.add(value);
      if (window.length > windowSize) window.removeAt(0);
      var sumDx = 0.0;
      var sumDy = 0.0;
      for (final offset in window) {
        sumDx += offset.dx;
        sumDy += offset.dy;
      }
      final average = Offset(sumDx / window.length, sumDy / window.length);
      return average.distance < floor ? Offset.zero : average;
    });
  }
}

/// A heavier-duty stabilizer than [SmoothedOffsetStream] for a signal that
/// needs to look calm at rest — including away from zero — yet still track
/// real, sustained changes promptly (e.g. the artificial horizon, which
/// visibly trembled over small road irregularities under plain averaging,
/// and later under a fixed-alpha exponential low-pass — one alpha can't
/// simultaneously kill vibration at rest and stay responsive to a real,
/// fast incline change, since the same weighting governs both). Three
/// layers, applied in order:
///
///  1. [OneEuroFilter] (independently per axis, dx and dy) — an adaptive
///     low-pass whose own cutoff rises with the signal's estimated speed,
///     so it filters hard while essentially stationary (vibration) and
///     tracks quickly the moment the signal is genuinely, consistently
///     moving. See that class's own doc for why this — not a fixed alpha —
///     is what actually tells vibration and real change apart.
///  2. A dead zone, compared against the last *displayed* value (not the
///     filtered one), ignores whatever small residual wobble survives the
///     filter — unlike [SmoothedOffsetStream]'s `floor`, this works
///     anywhere in range, not just near zero. This doubles as the
///     "hysteresis" a signal needs once it's settled: small oscillations
///     around an already-accepted value, in any direction, don't move the
///     display until they genuinely clear it.
///  3. A slew-rate limiter caps how far the displayed value may move per
///     update, so even a large real change ramps in over a few updates
///     instead of snapping — and a value can never jump instantly right
///     after e.g. a calibration reset.
extension StabilizedOffsetStream on Stream<(Offset, DateTime)> {
  /// Keep [maxDeltaPerUpdate] well above [deadZone]: the two only stay
  /// lag-bounded in steady state if a gap that has just cleared the dead
  /// zone can still be closed in a single slew step: otherwise the display
  /// permanently lags behind by a growing margin instead of settling.
  Stream<Offset> stabilizedForDisplay({
    required double minCutoff,
    required double beta,
    required double deadZone,
    required double maxDeltaPerUpdate,
  }) {
    final filterX = OneEuroFilter(minCutoff: minCutoff, beta: beta);
    final filterY = OneEuroFilter(minCutoff: minCutoff, beta: beta);
    Offset? displayed;
    return map((sample) {
      final (raw, timestamp) = sample;
      final target = Offset(filterX.filter(raw.dx, timestamp), filterY.filter(raw.dy, timestamp));
      if (displayed == null) {
        displayed = target;
        return displayed!;
      }
      final delta = target - displayed!;
      if (delta.distance < deadZone) return displayed!;
      final step = delta.distance <= maxDeltaPerUpdate ? delta : delta * (maxDeltaPerUpdate / delta.distance);
      displayed = displayed! + step;
      return displayed!;
    });
  }
}

/// The scalar counterpart of [StabilizedOffsetStream] — same three-layer
/// treatment (OneEuroFilter → dead zone → slew-rate limiter; see that
/// extension's own doc for the full rationale), for a single-value signal
/// instead of a 2D one. Used by the g-force meter's vertical bar and
/// magnitude readout.
extension StabilizedValueStream on Stream<(double, DateTime)> {
  /// Same contract as [StabilizedOffsetStream.stabilizedForDisplay]. Pass
  /// [maxDeltaPerUpdate] as [double.infinity] to disable the slew-rate cap
  /// entirely — appropriate for a signal that also feeds a peak/record
  /// tracker (e.g. g-force magnitude), where an artificial cap on how fast
  /// the displayed value may rise would blunt a genuine, fast peak instead
  /// of merely smoothing cosmetic jitter.
  Stream<double> stabilizedForDisplay({
    required double minCutoff,
    required double beta,
    required double deadZone,
    required double maxDeltaPerUpdate,
  }) {
    final filter = OneEuroFilter(minCutoff: minCutoff, beta: beta);
    double? displayed;
    return map((sample) {
      final (raw, timestamp) = sample;
      final target = filter.filter(raw, timestamp);
      if (displayed == null) {
        displayed = target;
        return displayed!;
      }
      final delta = target - displayed!;
      if (delta.abs() < deadZone) return displayed!;
      final step = delta.abs() <= maxDeltaPerUpdate ? delta : maxDeltaPerUpdate * delta.sign;
      displayed = displayed! + step;
      return displayed!;
    });
  }
}
