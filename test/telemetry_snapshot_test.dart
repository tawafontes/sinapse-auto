import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/gnss_quality.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  group('TelemetrySnapshot', () {
    test('a snapshot with no fields set beyond timestamp has every field null/unavailable', () {
      final snapshot = TelemetrySnapshot(timestamp: t0);
      expect(snapshot.latitude, isNull);
      expect(snapshot.longitude, isNull);
      expect(snapshot.altitudeMeters, isNull);
      expect(snapshot.speedKmh, isNull);
      expect(snapshot.headingDegrees, isNull);
      expect(snapshot.horizontalAccuracyMeters, isNull);
      expect(snapshot.verticalAccuracyMeters, isNull);
      expect(snapshot.satelliteCount, isNull);
      expect(snapshot.gnssQuality, GnssQuality.unavailable);
      expect(snapshot.longitudinalG, isNull);
      expect(snapshot.lateralG, isNull);
      expect(snapshot.verticalG, isNull);
      expect(snapshot.gForceMagnitude, isNull);
      expect(snapshot.pitchDegrees, isNull);
      expect(snapshot.rollDegrees, isNull);
      expect(snapshot.hasGnssFix, isFalse);
      expect(snapshot.altitudeTrend, AltitudeTrend.stable);
      expect(snapshot.barometerActive, isFalse);
    });

    test('a valid-but-zero speed is distinguishable from "no reading" (both are legal, different states)', () {
      final noReading = TelemetrySnapshot(timestamp: t0);
      final parkedWithFix = TelemetrySnapshot(timestamp: t0, speedKmh: 0.0);
      expect(noReading.speedKmh, isNull);
      expect(parkedWithFix.speedKmh, 0.0);
      expect(parkedWithFix.speedKmh, isNotNull);
    });

    test('hasGnssFix is true once both latitude and longitude are present, independent of quality', () {
      final snapshot = TelemetrySnapshot(
        timestamp: t0,
        latitude: -23.5,
        longitude: -46.6,
        gnssQuality: GnssQuality.weak,
      );
      expect(snapshot.hasGnssFix, isTrue);
    });

    test('hasGnssFix stays false with only one of latitude/longitude present', () {
      expect(TelemetrySnapshot(timestamp: t0, latitude: -23.5).hasGnssFix, isFalse);
      expect(TelemetrySnapshot(timestamp: t0, longitude: -46.6).hasGnssFix, isFalse);
    });

    test('satelliteCount is always constructible as null — documented platform limitation, not an oversight', () {
      final snapshot = TelemetrySnapshot(timestamp: t0, latitude: 0, longitude: 0);
      expect(snapshot.satelliteCount, isNull);
    });

    test('every field can be independently populated', () {
      final snapshot = TelemetrySnapshot(
        timestamp: t0,
        latitude: 1,
        longitude: 2,
        altitudeMeters: 850,
        speedKmh: 60,
        headingDegrees: 270,
        horizontalAccuracyMeters: 4.5,
        verticalAccuracyMeters: 6.0,
        gnssQuality: GnssQuality.good,
        longitudinalG: 0.3,
        lateralG: -0.1,
        verticalG: 0.05,
        gForceMagnitude: 1.02,
        pitchDegrees: -1.5,
        rollDegrees: 0.5,
        altitudeTrend: AltitudeTrend.rising,
        barometerActive: true,
      );
      expect(snapshot.altitudeMeters, 850);
      expect(snapshot.speedKmh, 60);
      expect(snapshot.headingDegrees, 270);
      expect(snapshot.gnssQuality, GnssQuality.good);
      expect(snapshot.gForceMagnitude, 1.02);
      expect(snapshot.pitchDegrees, -1.5);
      expect(snapshot.rollDegrees, 0.5);
      expect(snapshot.altitudeTrend, AltitudeTrend.rising);
      expect(snapshot.barometerActive, isTrue);
    });
  });
}
