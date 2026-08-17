import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:synapse_auto/services/gnss_quality.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  Position positionWithAccuracy(double accuracy, {DateTime? timestamp}) {
    return Position(
      latitude: 0,
      longitude: 0,
      timestamp: timestamp ?? t0,
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }

  group('classifyGnssQuality', () {
    test('null position is unavailable', () {
      expect(classifyGnssQuality(null, now: t0), GnssQuality.unavailable);
    });

    test('a 0.0 accuracy (the plugin\'s "unknown" contract) is unavailable, not excellent', () {
      expect(classifyGnssQuality(positionWithAccuracy(0.0), now: t0), GnssQuality.unavailable);
    });

    test('a negative accuracy is unavailable (never a real report)', () {
      expect(classifyGnssQuality(positionWithAccuracy(-1.0), now: t0), GnssQuality.unavailable);
    });

    test('accuracy at the excellent boundary (5m) is excellent', () {
      expect(classifyGnssQuality(positionWithAccuracy(5.0), now: t0), GnssQuality.excellent);
    });

    test('accuracy just past the excellent boundary is good', () {
      expect(classifyGnssQuality(positionWithAccuracy(5.1), now: t0), GnssQuality.good);
    });

    test('accuracy at the good boundary (10m) is good', () {
      expect(classifyGnssQuality(positionWithAccuracy(10.0), now: t0), GnssQuality.good);
    });

    test('accuracy at the moderate boundary (20m) is moderate', () {
      expect(classifyGnssQuality(positionWithAccuracy(20.0), now: t0), GnssQuality.moderate);
    });

    test('accuracy at the weak boundary (50m) is weak', () {
      expect(classifyGnssQuality(positionWithAccuracy(50.0), now: t0), GnssQuality.weak);
    });

    test('accuracy beyond the weak boundary is unavailable', () {
      expect(classifyGnssQuality(positionWithAccuracy(50.1), now: t0), GnssQuality.unavailable);
      expect(classifyGnssQuality(positionWithAccuracy(500.0), now: t0), GnssQuality.unavailable);
    });

    test('a stale fix (older than maxFixAge) is unavailable regardless of accuracy', () {
      final stale = positionWithAccuracy(3.0, timestamp: t0.subtract(const Duration(seconds: 30)));
      expect(classifyGnssQuality(stale, now: t0), GnssQuality.unavailable);
    });

    test('a fix right at the freshness boundary is still classified normally', () {
      final borderline = positionWithAccuracy(3.0, timestamp: t0.subtract(GnssQualityThresholds.maxFixAge));
      expect(classifyGnssQuality(borderline, now: t0), GnssQuality.excellent);
    });
  });

  group('gnssQualityFromAverageIndex', () {
    test('an exact integer average maps back to that exact quality', () {
      expect(gnssQualityFromAverageIndex(0.0), GnssQuality.unavailable);
      expect(gnssQualityFromAverageIndex(4.0), GnssQuality.excellent);
    });

    test('rounds to the nearest quality rather than truncating', () {
      expect(gnssQualityFromAverageIndex(3.6), GnssQuality.excellent); // rounds up from good.
      expect(gnssQualityFromAverageIndex(3.4), GnssQuality.good); // rounds down.
    });

    test('clamps to the valid range even given an out-of-range input', () {
      expect(gnssQualityFromAverageIndex(-1.0), GnssQuality.unavailable);
      expect(gnssQualityFromAverageIndex(10.0), GnssQuality.excellent);
    });
  });

  group('gnssQualityLabel', () {
    test('maps every GnssQuality value to a distinct Portuguese label', () {
      expect(gnssQualityLabel(GnssQuality.unavailable), 'Indisponível');
      expect(gnssQualityLabel(GnssQuality.weak), 'Fraco');
      expect(gnssQualityLabel(GnssQuality.moderate), 'Moderado');
      expect(gnssQualityLabel(GnssQuality.good), 'Bom');
      expect(gnssQualityLabel(GnssQuality.excellent), 'Excelente');
    });
  });
}
