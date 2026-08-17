import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/unit_system.dart';

void main() {
  group('convertSpeedFromKmh', () {
    test('kmh is identity', () {
      expect(convertSpeedFromKmh(100, SpeedUnit.kmh), 100);
    });

    test('mph conversion is correct within a small tolerance', () {
      expect(convertSpeedFromKmh(100, SpeedUnit.mph), closeTo(62.1371, 0.01));
    });

    test('zero converts to zero regardless of unit', () {
      expect(convertSpeedFromKmh(0, SpeedUnit.kmh), 0);
      expect(convertSpeedFromKmh(0, SpeedUnit.mph), 0);
    });
  });

  group('convertAltitudeFromMeters', () {
    test('meters is identity', () {
      expect(convertAltitudeFromMeters(850, AltitudeUnit.meters), 850);
    });

    test('feet conversion is correct within a small tolerance', () {
      expect(convertAltitudeFromMeters(1000, AltitudeUnit.feet), closeTo(3280.84, 0.1));
    });
  });

  group('unit labels', () {
    test('speedUnitLabel', () {
      expect(speedUnitLabel(SpeedUnit.kmh), 'km/h');
      expect(speedUnitLabel(SpeedUnit.mph), 'mph');
    });

    test('altitudeUnitLabel', () {
      expect(altitudeUnitLabel(AltitudeUnit.meters), 'm');
      expect(altitudeUnitLabel(AltitudeUnit.feet), 'ft');
    });
  });
}
