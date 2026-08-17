import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/adaptive_exponential_filter.dart';

void main() {
  test('the first sample returns itself exactly, no fake ramp-up', () {
    final filter = AdaptiveExponentialFilter(minAlpha: 0.1, maxAlpha: 0.9, rateOfChangeForMaxAlpha: 5.0);
    expect(filter.filter(37.0), 37.0);
  });

  test('small deltas (heavy smoothing) take many updates to approach a new target', () {
    final filter = AdaptiveExponentialFilter(minAlpha: 0.1, maxAlpha: 0.9, rateOfChangeForMaxAlpha: 5.0);
    filter.filter(0);
    // Nudging by a tiny amount each update stays in "heavy smoothing" territory
    // (delta << rateOfChangeForMaxAlpha), so after a handful of updates the
    // output should still be far from having caught up to the input.
    double last = 0;
    for (var i = 0; i < 5; i++) {
      last = filter.filter(0.05 * (i + 1));
    }
    expect(last, lessThan(0.1));
  });

  test('large deltas (fast tracking) approach a new target almost immediately', () {
    final filter = AdaptiveExponentialFilter(minAlpha: 0.1, maxAlpha: 0.9, rateOfChangeForMaxAlpha: 5.0);
    filter.filter(0);
    final result = filter.filter(100); // delta of 100 >> rateOfChangeForMaxAlpha, so alpha ~= maxAlpha.
    expect(result, greaterThan(80));
  });

  test('effective alpha never exceeds maxAlpha even for an enormous delta', () {
    final filter = AdaptiveExponentialFilter(minAlpha: 0.1, maxAlpha: 0.5, rateOfChangeForMaxAlpha: 1.0);
    filter.filter(0);
    final result = filter.filter(1000000);
    // output = 0 + alpha * (1000000 - 0); alpha must be clamped to maxAlpha (0.5).
    expect(result, closeTo(500000, 1));
  });
}
