import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/dashboard_sensor_streams.dart';

void main() {
  const g = 9.80665;

  group('pitchRollDegreesFromAccelerometer (device mounted portrait/vertical)', () {
    test('level (stationary, upright) reads zero for both axes', () {
      final result = pitchRollDegreesFromAccelerometer(0, g, 0);
      expect(result.dx, closeTo(0, 1e-6));
      expect(result.dy, closeTo(0, 1e-6));
    });

    // Pitch's sign (`-z`) has held since the very first fix. Roll's sign
    // (`-x`) is the one that took several rounds to land: earlier attempts
    // (`+x`, then a self-detecting `x.abs()`/`y.abs()` branch keeping `+x`)
    // were each validated against the *visual* roll pointer/aircraft
    // symbol, which had its own independent rendering sign bugs layered on
    // top at the time — each rendering fix happened to make the picture
    // look right while the numeric value stayed backwards underneath, until
    // checking the ROLL footer label directly (unambiguous text, no
    // rendering transform involved) exposed it. These tests call the
    // function with nothing but a raw vector — no orientation flag, no
    // rendering involved — so that failure mode can't hide here again.

    test('nose up (pitching up) is positive pitch, zero roll', () {
      const angleDeg = 30.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(0, g * math.cos(angleRad), -g * math.sin(angleRad));
      expect(result.dx, closeTo(angleDeg, 1e-6));
      expect(result.dy, closeTo(0, 1e-6));
    });

    test('nose down (pitching down) is negative pitch, zero roll', () {
      const angleDeg = 20.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(0, g * math.cos(angleRad), g * math.sin(angleRad));
      expect(result.dx, closeTo(-angleDeg, 1e-6));
      expect(result.dy, closeTo(0, 1e-6));
    });

    test('tilting right is positive roll, zero pitch', () {
      const angleDeg = 25.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(-g * math.sin(angleRad), g * math.cos(angleRad), 0);
      expect(result.dx, closeTo(0, 1e-6));
      expect(result.dy, closeTo(angleDeg, 1e-6));
    });

    test('tilting left is negative roll, zero pitch', () {
      const angleDeg = 15.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(g * math.sin(angleRad), g * math.cos(angleRad), 0);
      expect(result.dx, closeTo(0, 1e-6));
      expect(result.dy, closeTo(-angleDeg, 1e-6));
    });
  });

  group('pitchRollDegreesFromAccelerometer (device mounted landscape/horizontal)', () {
    // Landscape swaps which native axis reads gravity at level (X here,
    // instead of portrait's Y), but the native Z axis keeps the same role
    // in both mounts (roll-invariant, pitch-signed) since the screen still
    // faces the driver either way — see the doc comment on
    // pitchRollDegreesFromAccelerometer for the full derivation. That's why
    // pitch below uses the exact same vector shape as the portrait tests
    // (just with x/y swapped), while roll reads off `y` (not `x`). Which
    // branch runs is decided by the function itself (x.abs() vs y.abs())
    // purely from these vectors — nothing external to pass in.

    test('level (stationary) reads zero for both axes', () {
      final result = pitchRollDegreesFromAccelerometer(g, 0, 0);
      expect(result.dx, closeTo(0, 1e-6));
      expect(result.dy, closeTo(0, 1e-6));
    });

    test('nose up (pitching up) is positive pitch, zero roll — does not leak into roll', () {
      const angleDeg = 30.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(g * math.cos(angleRad), 0, -g * math.sin(angleRad));
      expect(result.dx, closeTo(angleDeg, 1e-6));
      expect(result.dy, closeTo(0, 1e-6));
    });

    test('nose down (pitching down) is negative pitch, zero roll — does not leak into roll', () {
      const angleDeg = 20.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(g * math.cos(angleRad), 0, g * math.sin(angleRad));
      expect(result.dx, closeTo(-angleDeg, 1e-6));
      expect(result.dy, closeTo(0, 1e-6));
    });

    test('tilting right is positive roll, zero pitch', () {
      const angleDeg = 25.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(g * math.cos(angleRad), g * math.sin(angleRad), 0);
      expect(result.dx, closeTo(0, 1e-6));
      expect(result.dy, closeTo(angleDeg, 1e-6));
    });

    test('tilting left is negative roll, zero pitch', () {
      const angleDeg = 15.0;
      final angleRad = angleDeg * math.pi / 180;
      final result = pitchRollDegreesFromAccelerometer(g * math.cos(angleRad), -g * math.sin(angleRad), 0);
      expect(result.dx, closeTo(0, 1e-6));
      expect(result.dy, closeTo(-angleDeg, 1e-6));
    });

    test('combined pitch + roll: roll reads exactly, no residual cross-axis sensitivity', () {
      // Composed as roll-about-Z then pitch-about-Y, which is exactly the
      // convention the roll formula assumes — algebraically, this makes
      // roll's reading totally independent of pitch (verified exactly
      // below). Pitch keeps a small coupling from roll at combined angles,
      // an inherent property of any Euler-angle tilt decomposition (the
      // same coupling already exists, unexamined, in the portrait formula)
      // — checked below with a wider tolerance instead of exact equality.
      const pitchDeg = 10.0;
      const rollDeg = 25.0;
      final pitchRad = pitchDeg * math.pi / 180;
      final rollRad = rollDeg * math.pi / 180;
      final x = g * math.cos(rollRad) * math.cos(pitchRad);
      final y = g * math.sin(rollRad);
      final z = -g * math.cos(rollRad) * math.sin(pitchRad);
      final result = pitchRollDegreesFromAccelerometer(x, y, z);

      expect(result.dy, closeTo(rollDeg, 1e-6));
      expect(result.dx, closeTo(pitchDeg, 1.5));
    });

    test('combined pitch + roll, opposite signs: both directions still resolve correctly', () {
      const pitchDeg = -18.0;
      const rollDeg = -12.0;
      final pitchRad = pitchDeg * math.pi / 180;
      final rollRad = rollDeg * math.pi / 180;
      final x = g * math.cos(rollRad) * math.cos(pitchRad);
      final y = g * math.sin(rollRad);
      final z = -g * math.cos(rollRad) * math.sin(pitchRad);
      final result = pitchRollDegreesFromAccelerometer(x, y, z);

      expect(result.dy, closeTo(rollDeg, 1e-6));
      expect(result.dx, closeTo(pitchDeg, 1.5));
    });
  });

  group('isLandscapeMount', () {
    test('X dominant (near ±g) is landscape', () {
      expect(isLandscapeMount(g, 0.3), true);
    });

    test('Y dominant (near ±g) is portrait', () {
      expect(isLandscapeMount(0.3, g), false);
    });
  });

  group('pitchRollRatesDegPerSecFromGyroscope — isolated axes, no cross-axis leakage', () {
    const radToDeg = 180 / math.pi;

    test('portrait: pure X activates only pitch rate, direct', () {
      final rates = pitchRollRatesDegPerSecFromGyroscope(1.0, 0, 0, isLandscape: false);
      expect(rates.pitch, closeTo(radToDeg, 1e-9));
      expect(rates.roll, 0);
    });

    test('portrait: pure Y contributes nothing to either rate', () {
      final rates = pitchRollRatesDegPerSecFromGyroscope(0, 1.0, 0, isLandscape: false);
      expect(rates.pitch, 0);
      expect(rates.roll, 0);
    });

    test('landscape: pure Y activates only pitch rate, negated', () {
      final rates = pitchRollRatesDegPerSecFromGyroscope(0, 1.0, 0, isLandscape: true);
      expect(rates.pitch, closeTo(-radToDeg, 1e-9));
      expect(rates.roll, 0);
    });

    test('landscape: pure X contributes nothing to either rate', () {
      final rates = pitchRollRatesDegPerSecFromGyroscope(1.0, 0, 0, isLandscape: true);
      expect(rates.pitch, 0);
      expect(rates.roll, 0);
    });

    test('pure Z activates only roll rate, negated, same in both mounts (Z never changes role)', () {
      for (final isLandscape in [false, true]) {
        final rates = pitchRollRatesDegPerSecFromGyroscope(0, 0, 1.0, isLandscape: isLandscape);
        expect(rates.pitch, 0);
        expect(rates.roll, closeTo(-radToDeg, 1e-9));
      }
    });
  });

  group('pitchRollRatesDegPerSecFromGyroscope — cross-checked against a numerical derivative of the '
      'already hardware-validated accelerometer formula', () {
    // This does NOT reuse pitchRollRatesDegPerSecFromGyroscope's own
    // rotating-frame derivation's *conclusion* — it independently
    // finite-differences pitchRollDegreesFromAccelerometer itself (the same
    // function, already hardware-validated in the groups above) for a tiny,
    // known perturbation of whichever native axis is angle-sensitive
    // (Z for pitch always; X portrait/Y landscape for roll).
    //
    // The perturbation is constructed from the *standard rotating-frame
    // identity* (`d(v)/dt = -ω × v` for a world-fixed v observed in a frame
    // rotating at ω) applied directly to that one axis — NOT by assuming a
    // rate-of-angle-change and asking "what would that same numeric value
    // look like as a gyro reading." That subtler, more direct-looking
    // construction was tried first and is WRONG for 3 of these 4 cases: it
    // implicitly assumes the angle-rate-to-gyro-sign relationship is
    // exactly +1, begging the question this test exists to check
    // independently. The rotating-frame identity is instead cross-checked
    // on its own via two *separate* methods before being trusted here
    // (an explicit small-angle rotation matrix, and a concrete "which way
    // does the phone's top swing" physical argument) — see this round's
    // delivery notes for the full derivation.
    const omegaDegPerSec = 5.0;
    const dt = 0.001; // small enough that both linearizations involved stay accurate.
    final omegaRadPerSec = omegaDegPerSec * math.pi / 180;
    final delta = omegaRadPerSec * g * dt; // the sensed axis's own linear perturbation over dt.

    test('portrait pitch rate (rotation about X perturbs Z: dz/dt = -gyroX*g)', () {
      final a0 = pitchRollDegreesFromAccelerometer(0, g, 0);
      final a1 = pitchRollDegreesFromAccelerometer(0, g, -delta);
      final numericalRate = (a1.dx - a0.dx) / dt;

      final rates = pitchRollRatesDegPerSecFromGyroscope(omegaRadPerSec, 0, 0, isLandscape: false);
      expect(rates.pitch, closeTo(numericalRate, 0.5));
    });

    test('landscape pitch rate (rotation about Y perturbs Z: dz/dt = +gyroY*g)', () {
      final a0 = pitchRollDegreesFromAccelerometer(g, 0, 0);
      final a1 = pitchRollDegreesFromAccelerometer(g, 0, delta);
      final numericalRate = (a1.dx - a0.dx) / dt;

      final rates = pitchRollRatesDegPerSecFromGyroscope(0, omegaRadPerSec, 0, isLandscape: true);
      expect(rates.pitch, closeTo(numericalRate, 0.5));
    });

    test('portrait roll rate (rotation about Z perturbs X: dx/dt = +gyroZ*g)', () {
      final a0 = pitchRollDegreesFromAccelerometer(0, g, 0);
      final a1 = pitchRollDegreesFromAccelerometer(delta, g, 0);
      final numericalRate = (a1.dy - a0.dy) / dt;

      final rates = pitchRollRatesDegPerSecFromGyroscope(0, 0, omegaRadPerSec, isLandscape: false);
      expect(rates.roll, closeTo(numericalRate, 0.5));
    });

    test('landscape roll rate (rotation about Z perturbs Y: dy/dt = -gyroZ*g)', () {
      final a0 = pitchRollDegreesFromAccelerometer(g, 0, 0);
      final a1 = pitchRollDegreesFromAccelerometer(g, -delta, 0);
      final numericalRate = (a1.dy - a0.dy) / dt;

      final rates = pitchRollRatesDegPerSecFromGyroscope(0, 0, omegaRadPerSec, isLandscape: true);
      expect(rates.roll, closeTo(numericalRate, 0.5));
    });
  });

  // gForceVehicleAxes/pairedWithMountOrientation tests have moved to
  // test/vehicle_coordinate_system_test.dart; pairedWithLatest's own tests
  // moved to test/stream_pairing_test.dart — alongside the production code
  // they cover.

  group('shouldEmitThrottled (Fase 13.2 root-cause fix — GPS-cadence gate, '
      'never applied to g-force emissions)', () {
    final t0 = DateTime(2026, 1, 1, 12);

    test('always true on the very first emission (no prior lastEmitted)', () {
      expect(shouldEmitThrottled(lastEmitted: null, now: t0, gap: snapshotGpsCadenceGap), isTrue);
    });

    test('false before the gap has elapsed', () {
      expect(
        shouldEmitThrottled(lastEmitted: t0, now: t0.add(const Duration(milliseconds: 150)), gap: snapshotGpsCadenceGap),
        isFalse,
      );
    });

    test('true exactly at and beyond the gap', () {
      expect(
        shouldEmitThrottled(lastEmitted: t0, now: t0.add(snapshotGpsCadenceGap), gap: snapshotGpsCadenceGap),
        isTrue,
      );
      expect(
        shouldEmitThrottled(lastEmitted: t0, now: t0.add(const Duration(milliseconds: 250)), gap: snapshotGpsCadenceGap),
        isTrue,
      );
    });

    test('the fix in one number: a 20ms-apart g-force cadence would ALWAYS be '
        'suppressed by this same gate if it were ever applied to g-force — this is '
        'exactly why gForceMagnitude/gForceOffset/gForceVertical emit via emitNow() '
        '(bypassing this gate entirely) in DashboardSensorStreams._buildSnapshotStream, '
        'not emitThrottled()', () {
      // Confirmed on-device (Fase 13.2): this app's own accelerometer
      // delivers a real sample roughly every 10ms — a 20ms gap is already a
      // generous stand-in for "much faster than the 200ms GPS-cadence gap".
      expect(
        shouldEmitThrottled(lastEmitted: t0, now: t0.add(const Duration(milliseconds: 20)), gap: snapshotGpsCadenceGap),
        isFalse,
      );
    });
  });
}
