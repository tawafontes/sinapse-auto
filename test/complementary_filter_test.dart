import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/complementary_filter.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  test('the first sample seeds the filter directly to the accelerometer angle, no ramp-up from zero', () {
    final filter = ComplementaryFilter(gyroWeight: 0.96);
    expect(filter.filter(12.0, 0.0, t0), 12.0);
  });

  test('a null gyro rate (no gyroscope reading yet, or ever) falls back to the accelerometer angle directly', () {
    final filter = ComplementaryFilter(gyroWeight: 0.96);
    filter.filter(5.0, 3.0, t0); // seed with a real gyro reading first...
    // ...then a gap with no gyro data (e.g. a device with no gyroscope at
    // all — every subsequent call has a null rate): must track the
    // accelerometer directly, not keep gyro-extrapolating from stale state.
    final result = filter.filter(9.0, null, t0.add(const Duration(milliseconds: 20)));
    expect(result, 9.0);
  });

  test('a non-positive elapsed time between samples is ignored rather than dividing by zero', () {
    final filter = ComplementaryFilter(gyroWeight: 0.96);
    filter.filter(5.0, 2.0, t0);
    final result = filter.filter(100.0, 2.0, t0); // same timestamp as before -> zero dt.
    expect(result, 5.0);
    expect(result.isNaN, isFalse);
  });

  test(
    'with a misleading (constant) accelerometer but a genuine sustained gyro rate, the fused output rises '
    'toward the gyro-integrated angle — proves the gyro sign is actually used, not just ignored or inverted',
    () {
      // A transient linear-acceleration disturbance is exactly this
      // scenario: the accelerometer angle stays deceptively flat (or noisy
      // around a fixed value) while the gyroscope reports a real, sustained
      // rotation the accelerometer alone can't see through the disturbance.
      final filter = ComplementaryFilter(gyroWeight: 0.96);
      var t = t0;
      double? last;
      const gyroRateDegPerSec = 10.0;
      for (var i = 0; i < 25; i++) {
        // 0.5s at 20ms steps.
        last = filter.filter(0.0, gyroRateDegPerSec, t);
        t = t.add(const Duration(milliseconds: 20));
      }
      // Gyro-only integration over 0.5s would reach 5°; the accelerometer's
      // constant pull toward 0 keeps it below that, but it must have moved
      // substantially toward it (and never gone negative, which a
      // sign-inverted gyro term would produce).
      expect(last, greaterThan(2.0));
      expect(last, lessThan(5.0));
    },
  );

  test('gyro drift is continuously corrected by the accelerometer, not accumulated unboundedly', () {
    // A constant (non-zero) gyro bias with a *stationary* (non-changing)
    // accelerometer angle must NOT let the fused estimate drift away
    // forever — the accelerometer term pulls it back every single sample.
    final filter = ComplementaryFilter(gyroWeight: 0.9); // lower weight -> faster correction, easier to observe within a short run.
    var t = t0;
    double? last;
    const spuriousGyroBiasDegPerSec = 2.0;
    for (var i = 0; i < 200; i++) {
      // 4s at 20ms steps.
      last = filter.filter(0.0, spuriousGyroBiasDegPerSec, t);
      t = t.add(const Duration(milliseconds: 20));
    }
    // Naive integration of a 2°/s bias over 4s would reach 8° — the
    // complementary filter must settle to a small, bounded steady-state
    // offset instead (proportional to bias * (1-gyroWeight)/gyroWeight *
    // updateInterval, a small fraction of a degree here), not keep growing.
    expect(last!.abs(), lessThan(1.0));
  });

  test('a genuine sustained accelerometer change (matching gyro) is tracked closely within about a second', () {
    final filter = ComplementaryFilter(gyroWeight: 0.96);
    var t = t0;
    double? last;
    const trueRateDegPerSec = 20.0;
    for (var i = 0; i <= 50; i++) {
      // 1s at 20ms steps.
      final trueAngle = trueRateDegPerSec * (i * 0.02);
      last = filter.filter(trueAngle, trueRateDegPerSec, t);
      t = t.add(const Duration(milliseconds: 20));
    }
    expect(last, closeTo(20.0, 1.0));
  });
}
