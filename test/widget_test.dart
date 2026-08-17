import 'package:flutter_test/flutter_test.dart';

import 'package:synapse_auto/models/sensor_reading.dart';

void main() {
  test('VectorReading computes magnitude', () {
    final reading = VectorReading(x: 3, y: 4, z: 0, timestamp: DateTime.now());
    expect(reading.magnitude, 5);
  });
}
