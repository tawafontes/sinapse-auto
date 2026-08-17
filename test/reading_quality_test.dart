import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:synapse_auto/services/reading_quality.dart';

void main() {
  Position position({
    double accuracy = 5,
    double speedAccuracy = 1,
    double altitudeAccuracy = 5,
  }) {
    return Position(
      latitude: 0,
      longitude: 0,
      timestamp: DateTime(2026, 1, 1),
      accuracy: accuracy,
      altitude: 100,
      altitudeAccuracy: altitudeAccuracy,
      heading: 0,
      headingAccuracy: 0,
      speed: 10,
      speedAccuracy: speedAccuracy,
    );
  }

  test('a position with good accuracy across the board is accepted', () {
    expect(isPositionAcceptable(position()), isTrue);
  });

  test('bad horizontal accuracy is rejected', () {
    expect(isPositionAcceptable(position(accuracy: 500), maxHorizontalAccuracyM: 30), isFalse);
  });

  test('bad speed accuracy is rejected', () {
    expect(isPositionAcceptable(position(speedAccuracy: 50), maxSpeedAccuracyMs: 3), isFalse);
  });

  test('bad altitude accuracy is rejected', () {
    expect(isPositionAcceptable(position(altitudeAccuracy: 500), maxAltitudeAccuracyM: 25), isFalse);
  });

  test('a 0.0 accuracy field (device does not report it) is treated as unknown, not rejected', () {
    expect(isPositionAcceptable(position(accuracy: 0, speedAccuracy: 0, altitudeAccuracy: 0)), isTrue);
  });
}
