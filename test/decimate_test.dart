import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/telemetry/decimate.dart';

void main() {
  group('decimate', () {
    test('input at or below maxPoints is returned unchanged', () {
      final input = [1, 2, 3];
      expect(decimate(input, maxPoints: 3), [1, 2, 3]);
      expect(decimate(input, maxPoints: 10), [1, 2, 3]);
    });

    test('always keeps the first and last element', () {
      final input = List.generate(1000, (i) => i);
      final result = decimate(input, maxPoints: 50);
      expect(result.first, 0);
      expect(result.last, 999);
    });

    test('reduces the element count to at most maxPoints', () {
      final input = List.generate(3600, (i) => i);
      final result = decimate(input, maxPoints: 300);
      expect(result.length, lessThanOrEqualTo(300));
      expect(result.length, greaterThan(1));
    });

    test('preserves ascending order', () {
      final input = List.generate(500, (i) => i);
      final result = decimate(input, maxPoints: 50);
      for (var i = 1; i < result.length; i++) {
        expect(result[i], greaterThanOrEqualTo(result[i - 1]));
      }
    });

    test('an empty input stays empty', () {
      expect(decimate<int>([], maxPoints: 100), isEmpty);
    });
  });

  group('minMaxBucketIndices', () {
    test('input at or below maxPoints returns every index unchanged', () {
      expect(minMaxBucketIndices(3, maxPoints: 3, valueOf: (i) => i.toDouble()), [0, 1, 2]);
      expect(minMaxBucketIndices(3, maxPoints: 10, valueOf: (i) => i.toDouble()), [0, 1, 2]);
    });

    test('always includes the first and last index', () {
      final indices = minMaxBucketIndices(1000, maxPoints: 50, valueOf: (i) => (i % 7).toDouble());
      expect(indices.first, 0);
      expect(indices.last, 999);
    });

    test('meaningfully reduces a large series', () {
      final indices = minMaxBucketIndices(3600, maxPoints: 300, valueOf: (i) => i.toDouble());
      expect(indices.length, lessThan(700));
      expect(indices.length, greaterThan(1));
    });

    test('preserves the series true global maximum even when it sits between stride points', () {
      // A plain stride decimate (see `decimate`) over 100 items down to 10
      // would sample indices 0, 11, 22, ... and could easily step right
      // over a single spike like this one at index 47.
      final values = List<double>.generate(100, (i) => i == 47 ? 999.0 : 1.0);
      final indices = minMaxBucketIndices(values.length, maxPoints: 10, valueOf: (i) => values[i]);
      expect(indices, contains(47));
    });

    test('preserves the series true global minimum even when it sits between stride points', () {
      final values = List<double>.generate(100, (i) => i == 63 ? -999.0 : 1.0);
      final indices = minMaxBucketIndices(values.length, maxPoints: 10, valueOf: (i) => values[i]);
      expect(indices, contains(63));
    });

    test('an all-null bucket still emits one representative index (a gap stays visible)', () {
      final indices = minMaxBucketIndices(20, maxPoints: 4, valueOf: (i) => null);
      expect(indices, isNotEmpty);
    });

    test('indices are returned in ascending order', () {
      final indices = minMaxBucketIndices(500, maxPoints: 40, valueOf: (i) => (i * 37 % 500).toDouble());
      for (var i = 1; i < indices.length; i++) {
        expect(indices[i], greaterThan(indices[i - 1]));
      }
    });

    test('a length of zero yields no indices', () {
      expect(minMaxBucketIndices(0, maxPoints: 10, valueOf: (i) => 0), isEmpty);
    });
  });
}
