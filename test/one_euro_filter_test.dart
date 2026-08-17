import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/one_euro_filter.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);

  test('the first sample seeds the filter directly, no ramp-up from zero', () {
    final filter = OneEuroFilter(minCutoff: 1.0, beta: 0.5);
    expect(filter.filter(42.0, t0), 42.0);
  });

  test('a stationary signal oscillating around zero is smoothed well below its raw amplitude', () {
    final filter = OneEuroFilter(minCutoff: 0.3, beta: 0.5);
    filter.filter(0, t0);
    // Alternating +/-2 every 200ms (raw peak-to-peak 4) — vibration-like: no
    // sustained direction, unlike the "real change" test below.
    var t = t0;
    double last = 0;
    for (var i = 0; i < 20; i++) {
      t = t.add(const Duration(milliseconds: 200));
      last = filter.filter(i.isEven ? 2.0 : -2.0, t);
    }
    expect(last.abs(), lessThan(1.5)); // meaningfully damped from the raw +/-2 swing.
  });

  test('a fast, sustained change is tracked closely within a couple of seconds', () {
    final filter = OneEuroFilter(minCutoff: 0.3, beta: 0.5);
    filter.filter(0, t0);
    var t = t0;
    double last = 0;
    for (var i = 0; i < 20; i++) {
      t = t.add(const Duration(milliseconds: 200));
      last = filter.filter(20.0, t); // a real, sustained step to 20.
    }
    expect(last, closeTo(20, 1.0));
  });

  test('a sustained real change is tracked faster than a non-adaptive (beta=0) filter at the same minCutoff', () {
    final adaptive = OneEuroFilter(minCutoff: 0.3, beta: 0.5);
    adaptive.filter(0, t0);
    final fixed = OneEuroFilter(minCutoff: 0.3, beta: 0.0);
    fixed.filter(0, t0);

    final t1 = t0.add(const Duration(milliseconds: 200));
    final adaptiveAfterOneSample = adaptive.filter(20.0, t1);
    final fixedAfterOneSample = fixed.filter(20.0, t1);

    expect(adaptiveAfterOneSample, greaterThan(fixedAfterOneSample));
  });

  test('a non-positive elapsed time between samples is ignored rather than dividing by zero', () {
    final filter = OneEuroFilter(minCutoff: 1.0, beta: 0.5);
    filter.filter(5.0, t0);
    final result = filter.filter(100.0, t0); // same timestamp as before -> zero dt.
    expect(result, 5.0);
    expect(result.isNaN, isFalse);
  });
}
