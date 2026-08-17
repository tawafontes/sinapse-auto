import 'dart:math' as math;
import 'dart:ui';

/// Animated, fake data generators used purely to preview [DisplayStyle]
/// options during onboarding — none of this touches [SensorService].
///
/// Every stream ticks on a 50ms timer and is single-subscription; each
/// preview widget should call the corresponding method fresh rather than
/// sharing one instance across multiple listeners.
class MockPreviewData {
  MockPreviewData._();

  static const _tick = Duration(milliseconds: 50);

  static Stream<double> _sine({
    required double min,
    required double max,
    required Duration period,
    double phaseOffset = 0,
  }) {
    final mid = (min + max) / 2;
    final amplitude = (max - min) / 2;
    final periodSeconds = period.inMilliseconds / 1000.0;
    return Stream.periodic(_tick, (t) {
      final seconds = t * _tick.inMilliseconds / 1000.0;
      final angle = 2 * math.pi * (seconds / periodSeconds) + phaseOffset;
      return mid + amplitude * math.sin(angle);
    });
  }

  /// 0-120 km/h, breathing up and down.
  static Stream<double> speedKmh() =>
      _sine(min: 0, max: 120, period: const Duration(seconds: 6));

  /// Roll/pitch as a normalized (-1..1, -1..1) offset, orbiting slowly —
  /// only feeds unreachable-via-the-UI dead-code fallbacks now (inclination
  /// no longer offers a style that shows the preview grid at all).
  static Stream<Offset> tiltOffset() {
    const periodSeconds = 5.0;
    return Stream.periodic(_tick, (t) {
      final seconds = t * _tick.inMilliseconds / 1000.0;
      final angle = 2 * math.pi * (seconds / periodSeconds);
      return Offset(math.cos(angle) * 0.6, math.sin(angle) * 0.4);
    });
  }

  /// Meters, slow rise/fall.
  static Stream<double> altitudeMeters() =>
      _sine(min: 100, max: 400, period: const Duration(seconds: 10));

  /// Normalized (-1..1, -1..1) lateral/longitudinal G offset, wandering —
  /// drives the g-force-meter dot.
  static Stream<Offset> gForceOffset() {
    const periodSeconds = 3.0;
    return Stream.periodic(_tick, (t) {
      final seconds = t * _tick.inMilliseconds / 1000.0;
      final angle = 2 * math.pi * (seconds / periodSeconds);
      return Offset(math.cos(angle) * 0.5, math.sin(angle * 1.3) * 0.3);
    });
  }
}
