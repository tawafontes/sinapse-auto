import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/sensors/line_chart.dart';

void main() {
  group('speedAverageBandFor', () {
    test('well below the low threshold is low', () {
      expect(speedAverageBandFor(0), SpeedAverageBand.low);
      expect(speedAverageBandFor(20), SpeedAverageBand.low);
    });

    test('just below the low/moderate boundary is still low', () {
      expect(speedAverageBandFor(kSpeedAverageLowMaxKmh - 0.1), SpeedAverageBand.low);
    });

    test('exactly at the low/moderate boundary is moderate (inclusive upper band)', () {
      expect(speedAverageBandFor(kSpeedAverageLowMaxKmh), SpeedAverageBand.moderate);
    });

    test('mid-range value is moderate', () {
      expect(speedAverageBandFor(55), SpeedAverageBand.moderate);
    });

    test('just below the moderate/high boundary is still moderate', () {
      expect(speedAverageBandFor(kSpeedAverageModerateMaxKmh - 0.1), SpeedAverageBand.moderate);
    });

    test('exactly at the moderate/high boundary is high', () {
      expect(speedAverageBandFor(kSpeedAverageModerateMaxKmh), SpeedAverageBand.high);
    });

    test('just below the high/veryHigh boundary is still high', () {
      expect(speedAverageBandFor(kSpeedAverageHighMaxKmh - 0.1), SpeedAverageBand.high);
    });

    test('exactly at the high/veryHigh boundary is veryHigh', () {
      expect(speedAverageBandFor(kSpeedAverageHighMaxKmh), SpeedAverageBand.veryHigh);
    });

    test('well above the veryHigh threshold is still veryHigh', () {
      expect(speedAverageBandFor(200), SpeedAverageBand.veryHigh);
    });

    test('the three thresholds are in strictly ascending order (sanity check on the constants)', () {
      expect(kSpeedAverageLowMaxKmh, lessThan(kSpeedAverageModerateMaxKmh));
      expect(kSpeedAverageModerateMaxKmh, lessThan(kSpeedAverageHighMaxKmh));
    });
  });

  group('speedAverageBandColor', () {
    test('each band maps to a distinct, fully opaque color', () {
      final colors = SpeedAverageBand.values.map(speedAverageBandColor).toSet();
      expect(colors, hasLength(SpeedAverageBand.values.length), reason: 'no two bands should share a color');
      for (final color in colors) {
        expect(color.a, 1.0, reason: 'a translucent badge would let the chart show through unevenly');
      }
    });
  });

}
