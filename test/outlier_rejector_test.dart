import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/outlier_rejector.dart';

void main() {
  group('isPlausibleSpeedKmh', () {
    test('a normal driving speed is accepted', () {
      expect(isPlausibleSpeedKmh(80), isTrue);
    });

    test('zero is accepted (parked)', () {
      expect(isPlausibleSpeedKmh(0), isTrue);
    });

    test('a negative speed is rejected', () {
      expect(isPlausibleSpeedKmh(-1), isFalse);
    });

    test('an absurd speed is rejected', () {
      expect(isPlausibleSpeedKmh(1000), isFalse);
    });
  });

  group('isPlausibleAltitudeChange', () {
    test('a normal change over a normal interval is accepted', () {
      final result = isPlausibleAltitudeChange(
        previousMeters: 100,
        candidateMeters: 105,
        elapsed: const Duration(seconds: 1),
      );
      expect(result, isTrue);
    });

    test('a multi-hundred-meter jump (GPS teleport) is rejected', () {
      final result = isPlausibleAltitudeChange(
        previousMeters: 100,
        candidateMeters: 500,
        elapsed: const Duration(seconds: 1),
      );
      expect(result, isFalse);
    });

    test('the same large jump over a long enough elapsed time is accepted', () {
      final result = isPlausibleAltitudeChange(
        previousMeters: 100,
        candidateMeters: 500,
        elapsed: const Duration(minutes: 5),
      );
      expect(result, isTrue);
    });
  });

  group('isReadingFresh', () {
    final now = DateTime(2026, 1, 1, 12, 0, 0);

    test('a reading from right now is fresh', () {
      expect(isReadingFresh(now, now: now, maxAge: const Duration(seconds: 10)), isTrue);
    });

    test('a reading just within maxAge is fresh', () {
      final timestamp = now.subtract(const Duration(seconds: 9));
      expect(isReadingFresh(timestamp, now: now, maxAge: const Duration(seconds: 10)), isTrue);
    });

    test('a reading older than maxAge is stale', () {
      final timestamp = now.subtract(const Duration(seconds: 20));
      expect(isReadingFresh(timestamp, now: now, maxAge: const Duration(seconds: 10)), isFalse);
    });
  });
}
