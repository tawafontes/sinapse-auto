import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/altitude_fusion.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);

  test('hasBarometer is false until a barometer reading is ever added', () {
    final fusion = AltitudeFusion();
    expect(fusion.hasBarometer, isFalse);
    fusion.addGpsReading(100, t0);
    expect(fusion.hasBarometer, isFalse);
    fusion.addBarometerReading(1013.25, t0);
    expect(fusion.hasBarometer, isTrue);
  });

  test('fusedAltitudeMeters is null before any reading has ever arrived', () {
    final fusion = AltitudeFusion();
    expect(fusion.fusedAltitudeMeters, isNull);
  });

  test('GPS-only bootstrap: the first GPS reading seeds the fused value directly', () {
    final fusion = AltitudeFusion();
    fusion.addGpsReading(250, t0);
    expect(fusion.fusedAltitudeMeters, 250);
  });

  test('GPS-only: a second reading pulls the fused value toward it, not onto it (slow-alpha blend)', () {
    final fusion = AltitudeFusion();
    fusion.addGpsReading(100, t0);
    fusion.addGpsReading(200, t0.add(const Duration(seconds: 2)));
    final result = fusion.fusedAltitudeMeters!;
    expect(result, greaterThan(100));
    expect(result, lessThan(200));
  });

  test('a barometer delta between two GPS fixes moves the fused value by exactly that delta', () {
    final fusion = AltitudeFusion();
    fusion.addGpsReading(100, t0); // bootstraps fused = 100.
    fusion.addBarometerReading(1013.25, t0); // seeds the barometer reference (no fused change yet).
    final before = fusion.fusedAltitudeMeters!;
    fusion.addBarometerReading(1012.0, t0.add(const Duration(milliseconds: 200))); // pressure drop = altitude gain.
    final after = fusion.fusedAltitudeMeters!;

    // Same standard barometric formula the implementation itself uses.
    final expectedDelta = 44330.0 * (1 - math.pow(1012.0 / 1013.25, 1 / 5.255));
    expect(after - before, closeTo(expectedDelta, 1e-6));
  });

  test('a long gap since the last accepted GPS reading produces a visibly stronger pull than a short gap', () {
    final shortGapFusion = AltitudeFusion();
    shortGapFusion.addGpsReading(100, t0);
    shortGapFusion.addGpsReading(200, t0.add(const Duration(seconds: 2)));
    final shortGapResult = shortGapFusion.fusedAltitudeMeters!;

    final longGapFusion = AltitudeFusion();
    longGapFusion.addGpsReading(100, t0);
    longGapFusion.addGpsReading(200, t0.add(const Duration(minutes: 5)));
    final longGapResult = longGapFusion.fusedAltitudeMeters!;

    // Both pull from 100 toward 200; the long-gap case must have pulled harder.
    expect(longGapResult, greaterThan(shortGapResult));
  });
}
