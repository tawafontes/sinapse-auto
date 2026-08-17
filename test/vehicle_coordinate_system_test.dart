import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_reading.dart';
import 'package:synapse_auto/services/vehicle_coordinate_system.dart';

void main() {
  const g = 9.80665;

  group('detectMountOrientation', () {
    test('Y dominant, positive -> portraitUpright', () {
      expect(detectMountOrientation(0.3, g), PhoneMountOrientation.portraitUpright);
    });

    test('Y dominant, negative -> portraitUpsideDown', () {
      expect(detectMountOrientation(0.3, -g), PhoneMountOrientation.portraitUpsideDown);
    });

    test('X dominant, positive -> landscapeCounterClockwise', () {
      expect(detectMountOrientation(g, 0.3), PhoneMountOrientation.landscapeCounterClockwise);
    });

    test('X dominant, negative -> landscapeClockwise', () {
      expect(detectMountOrientation(-g, 0.3), PhoneMountOrientation.landscapeClockwise);
    });

    test('a tie falls to the portrait branch', () {
      expect(detectMountOrientation(0, 0), PhoneMountOrientation.portraitUpright);
    });
  });

  group('vehicleAxesFromPhone — isolated axes per orientation, no cross-axis leakage', () {
    // x (longitudinal) is always -phoneZ, regardless of orientation — the
    // phone's Z axis never changes role under a rotation about itself.
    for (final orientation in PhoneMountOrientation.values) {
      test('a pure Z reading activates only x (longitudinal), negated — $orientation', () {
        final axes = vehicleAxesFromPhone(0, 0, 3.0, orientation: orientation);
        expect(axes.x, -3.0);
        expect(axes.y, 0);
        expect(axes.z, 0);
      });
    }

    test('portraitUpright: pure X -> y, pure Y -> z, both direct', () {
      final fromX = vehicleAxesFromPhone(3.0, 0, 0, orientation: PhoneMountOrientation.portraitUpright);
      expect(fromX.y, 3.0);
      expect(fromX.z, 0);

      final fromY = vehicleAxesFromPhone(0, 3.0, 0, orientation: PhoneMountOrientation.portraitUpright);
      expect(fromY.y, 0);
      expect(fromY.z, 3.0);
    });

    test('portraitUpsideDown: pure X -> y negated, pure Y -> z negated', () {
      final fromX = vehicleAxesFromPhone(3.0, 0, 0, orientation: PhoneMountOrientation.portraitUpsideDown);
      expect(fromX.y, -3.0);
      expect(fromX.z, 0);

      final fromY = vehicleAxesFromPhone(0, 3.0, 0, orientation: PhoneMountOrientation.portraitUpsideDown);
      expect(fromY.y, 0);
      expect(fromY.z, -3.0);
    });

    test('landscapeCounterClockwise: pure X -> z, pure Y -> y negated', () {
      final fromX = vehicleAxesFromPhone(3.0, 0, 0, orientation: PhoneMountOrientation.landscapeCounterClockwise);
      expect(fromX.y, 0);
      expect(fromX.z, 3.0);

      final fromY = vehicleAxesFromPhone(0, 3.0, 0, orientation: PhoneMountOrientation.landscapeCounterClockwise);
      expect(fromY.y, -3.0);
      expect(fromY.z, 0);
    });

    test('landscapeClockwise: pure X -> z negated, pure Y -> y direct', () {
      // This is the mount previous rounds left unhandled (silently reusing
      // landscapeCounterClockwise's formula) — the specific regression this
      // task exists to fix.
      final fromX = vehicleAxesFromPhone(3.0, 0, 0, orientation: PhoneMountOrientation.landscapeClockwise);
      expect(fromX.y, 0);
      expect(fromX.z, -3.0);

      final fromY = vehicleAxesFromPhone(0, 3.0, 0, orientation: PhoneMountOrientation.landscapeClockwise);
      expect(fromY.y, 3.0);
      expect(fromY.z, 0);
    });
  });

  group('vehicleAxesFromPhone — direction matches the requested vehicle convention', () {
    // Forward acceleration reads as a negative native Z (the phone's own +Z
    // points toward the driver — roughly the vehicle's rear — since the
    // screen faces them), so a forward-accelerating vehicle should produce
    // a positive x.
    test('a forward-accelerating reading (negative native Z) produces a positive x', () {
      final axes = vehicleAxesFromPhone(0, 0, -5.0, orientation: PhoneMountOrientation.portraitUpright);
      expect(axes.x, greaterThan(0));
    });

    test('a braking reading (positive native Z) produces a negative x', () {
      final axes = vehicleAxesFromPhone(0, 0, 5.0, orientation: PhoneMountOrientation.portraitUpright);
      expect(axes.x, lessThan(0));
    });

    test('a rightward reading (positive native X, portrait) produces a positive y', () {
      final axes = vehicleAxesFromPhone(5.0, 0, 0, orientation: PhoneMountOrientation.portraitUpright);
      expect(axes.y, greaterThan(0));
    });

    test('a leftward reading (negative native X, portrait) produces a negative y', () {
      final axes = vehicleAxesFromPhone(-5.0, 0, 0, orientation: PhoneMountOrientation.portraitUpright);
      expect(axes.y, lessThan(0));
    });
  });

  group('vehicleAxesFromPhone — vector composition (no per-scenario rules)', () {
    test('a combined forward-accel + right-turn reading equals the sum of each transformed alone', () {
      // Proves the transform is a single linear map, not special-cased per
      // scenario — real driving (e.g. accelerating through a right-hander)
      // is exactly this kind of superposition, and it must fall out
      // automatically from the same formula used for a pure reading.
      const forwardOnly = (x: 0.0, y: 0.0, z: -4.0); // pure forward accel.
      const rightOnly = (x: 3.0, y: 0.0, z: 0.0); // pure rightward accel.
      final combined = (
        x: forwardOnly.x + rightOnly.x,
        y: forwardOnly.y + rightOnly.y,
        z: forwardOnly.z + rightOnly.z,
      );

      final forwardResult = vehicleAxesFromPhone(
        forwardOnly.x,
        forwardOnly.y,
        forwardOnly.z,
        orientation: PhoneMountOrientation.portraitUpright,
      );
      final rightResult = vehicleAxesFromPhone(
        rightOnly.x,
        rightOnly.y,
        rightOnly.z,
        orientation: PhoneMountOrientation.portraitUpright,
      );
      final combinedResult = vehicleAxesFromPhone(
        combined.x,
        combined.y,
        combined.z,
        orientation: PhoneMountOrientation.portraitUpright,
      );

      expect(combinedResult.x, forwardResult.x + rightResult.x);
      expect(combinedResult.y, forwardResult.y + rightResult.y);
      expect(combinedResult.z, forwardResult.z + rightResult.z);
      // And it's non-trivial — both components are actually present.
      expect(combinedResult.x, isNot(0));
      expect(combinedResult.y, isNot(0));
    });
  });

  group('pairedWithMountOrientation', () {
    Future<void> feedGravity(StreamController<VectorReading> gravity, PhoneMountOrientation orientation) async {
      final (x, y) = switch (orientation) {
        PhoneMountOrientation.portraitUpright => (0.0, g),
        PhoneMountOrientation.portraitUpsideDown => (0.0, -g),
        PhoneMountOrientation.landscapeCounterClockwise => (g, 0.0),
        PhoneMountOrientation.landscapeClockwise => (-g, 0.0),
      };
      gravity.add(VectorReading(x: x, y: y, z: 0, timestamp: DateTime.now()));
      await Future<void>.delayed(Duration.zero);
    }

    test('pairs each value with the latest CONFIRMED orientation from gravitySource, debounced', () async {
      final values = StreamController<VectorReading>();
      final gravity = StreamController<VectorReading>();
      addTearDown(() {
        unawaited(values.close());
        unawaited(gravity.close());
      });

      final results = <(PhoneMountOrientation, VectorReading)>[];
      final sub = pairedWithMountOrientation(values.stream, gravity.stream, confirmSamples: 3).listen(results.add);
      addTearDown(sub.cancel);

      // No gravity sample has arrived yet: defaults to portraitUpright.
      values.add(VectorReading(x: 1, y: 0, z: 0, timestamp: DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      expect(results, hasLength(1));
      expect(results[0].$1, PhoneMountOrientation.portraitUpright);

      // landscapeClockwise gravity arrives, but not yet 3 times in a row.
      await feedGravity(gravity, PhoneMountOrientation.landscapeClockwise);
      values.add(VectorReading(x: 2, y: 0, z: 0, timestamp: DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      expect(results[1].$1, PhoneMountOrientation.portraitUpright);

      await feedGravity(gravity, PhoneMountOrientation.landscapeClockwise);
      values.add(VectorReading(x: 2, y: 0, z: 0, timestamp: DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      expect(results[2].$1, PhoneMountOrientation.portraitUpright);

      // The 3rd consecutive agreeing sample confirms the flip.
      await feedGravity(gravity, PhoneMountOrientation.landscapeClockwise);
      values.add(VectorReading(x: 2, y: 0, z: 0, timestamp: DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      expect(results, hasLength(4));
      expect(results[3].$1, PhoneMountOrientation.landscapeClockwise);

      // A different orientation flips it again, once confirmed — each
      // gravity sample must be paired with a values tick to advance the
      // debounce, mirroring how userAccelerometerStream/accelerometerStream
      // both tick at comparable real-world rates.
      for (var i = 0; i < 3; i++) {
        await feedGravity(gravity, PhoneMountOrientation.landscapeCounterClockwise);
        values.add(VectorReading(x: 3, y: 0, z: 0, timestamp: DateTime.now()));
        await Future<void>.delayed(Duration.zero);
      }
      expect(results.last.$1, PhoneMountOrientation.landscapeCounterClockwise);
    });

    test('a single transient glitch (e.g. a hard-braking spike) does not flip the confirmed orientation', () async {
      final values = StreamController<VectorReading>();
      final gravity = StreamController<VectorReading>();
      addTearDown(() {
        unawaited(values.close());
        unawaited(gravity.close());
      });

      final results = <(PhoneMountOrientation, VectorReading)>[];
      final sub = pairedWithMountOrientation(values.stream, gravity.stream, confirmSamples: 5).listen(results.add);
      addTearDown(sub.cancel);

      // Confirm landscapeClockwise first (a non-default state).
      for (var i = 0; i < 5; i++) {
        await feedGravity(gravity, PhoneMountOrientation.landscapeClockwise);
        values.add(VectorReading(x: 1, y: 0, z: 0, timestamp: DateTime.now()));
        await Future<void>.delayed(Duration.zero);
      }
      expect(results.last.$1, PhoneMountOrientation.landscapeClockwise);

      // One single portrait glitch, then straight back to landscapeClockwise.
      await feedGravity(gravity, PhoneMountOrientation.portraitUpright);
      values.add(VectorReading(x: 2, y: 0, z: 0, timestamp: DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      expect(results.last.$1, PhoneMountOrientation.landscapeClockwise); // the glitch alone can't flip it.

      await feedGravity(gravity, PhoneMountOrientation.landscapeClockwise);
      values.add(VectorReading(x: 3, y: 0, z: 0, timestamp: DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      expect(results.last.$1, PhoneMountOrientation.landscapeClockwise);
    });
  });

  // pairedWithLatest's own generic tests have moved to
  // test/stream_pairing_test.dart, alongside the production code (now in
  // lib/services/stream_pairing.dart, reused by both this file's
  // pairedWithMountOrientation and dashboard_sensor_streams.dart's
  // inclination fusion).
}
