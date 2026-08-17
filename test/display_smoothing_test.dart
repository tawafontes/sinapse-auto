import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:synapse_auto/services/display_smoothing.dart';

void main() {
  group('smoothedForDisplay (double)', () {
    test('applies a simple moving average with a growing-then-sliding window', () async {
      final controller = StreamController<double>();
      final smoothed = controller.stream.smoothedForDisplay(windowSize: 3);
      final future = expectLater(
        smoothed,
        emitsInOrder([1.0, 1.5, 2.0, 3.0, 4.0, emitsDone]),
      );
      controller
        ..add(1)
        ..add(2)
        ..add(3)
        ..add(4)
        ..add(5);
      await controller.close();
      await future;
    });

    test('floor is evaluated against the averaged value, not each raw sample', () async {
      // A lone spike to 1.2 (which alone would clear the 1.0 floor) still
      // reads as 0 while the recent average is still low — this is exactly
      // the "GPS speed noise while parked" case from the spec. Once enough
      // consecutive samples are genuinely high, the average clears the
      // floor and the real value shows through.
      final controller = StreamController<double>();
      final smoothed = controller.stream.smoothedForDisplay(windowSize: 2, floor: 1.0);
      final future = expectLater(
        smoothed,
        emitsInOrder([0.0, 0.0, closeTo(1.8, 0.0001), emitsDone]),
      );
      controller
        ..add(0.0)
        ..add(1.2)
        ..add(2.4);
      await controller.close();
      await future;
    });
  });

  group('smoothedForDisplay (Offset)', () {
    test('averages both axes together with no floor by default', () async {
      final controller = StreamController<Offset>();
      final smoothed = controller.stream.smoothedForDisplay(windowSize: 2);
      final future = expectLater(
        smoothed,
        emitsInOrder([
          offsetMoreOrLessEquals(Offset.zero),
          offsetMoreOrLessEquals(const Offset(0.1, 0.2)),
          emitsDone,
        ]),
      );
      controller
        ..add(Offset.zero)
        ..add(const Offset(0.2, 0.4));
      await controller.close();
      await future;
    });

    test('floor snaps small combined jitter to zero until it genuinely settles elsewhere', () async {
      final controller = StreamController<Offset>();
      final smoothed = controller.stream.smoothedForDisplay(windowSize: 2, floor: 0.1);
      final future = expectLater(
        smoothed,
        emitsInOrder([
          offsetMoreOrLessEquals(Offset.zero),
          offsetMoreOrLessEquals(Offset.zero),
          offsetMoreOrLessEquals(const Offset(0.315, -0.005), epsilon: 0.001),
          emitsDone,
        ]),
      );
      controller
        ..add(const Offset(0.05, 0.02))
        ..add(const Offset(0.03, -0.01))
        ..add(const Offset(0.6, 0.0));
      await controller.close();
      await future;
    });
  });

  group('stabilizedForDisplay', () {
    test('a genuine sustained step is not applied instantly, but converges within a handful of samples', () async {
      final controller = StreamController<(Offset, DateTime)>();
      final stabilized = controller.stream.stabilizedForDisplay(
        minCutoff: 0.3,
        beta: 0.5,
        deadZone: 0,
        maxDeltaPerUpdate: 1000, // never binds — isolates the OneEuroFilter itself.
      );
      final results = <Offset>[];
      final sub = stabilized.listen(results.add);

      var t = DateTime(2026, 1, 1);
      controller.add((Offset.zero, t));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 15; i++) {
        t = t.add(const Duration(milliseconds: 200));
        controller.add((const Offset(10, 0), t));
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
      await sub.cancel();

      expect(results.first, offsetMoreOrLessEquals(Offset.zero)); // seeded, not an instant jump.
      expect(results[1].dx, greaterThan(0)); // starts moving toward the step...
      expect(results[1].dx, lessThan(10)); // ...but hasn't snapped there yet.
      expect(results.last, offsetMoreOrLessEquals(const Offset(10, 0), epsilon: 0.5)); // converges.
    });

    test('the dead zone holds a sustained non-zero displayed value steady against small perturbations', () async {
      // The regression test for the bug being fixed: unlike
      // smoothedForDisplay's floor (origin-only), this dead zone works
      // anywhere in range — a real reading sitting away from zero still
      // gets its jitter absorbed. A large minCutoff plus a large gap
      // between samples pushes the OneEuroFilter's own alpha to ~1
      // (filtered output ≈ raw input), isolating the dead zone itself.
      final controller = StreamController<(Offset, DateTime)>();
      final stabilized = controller.stream.stabilizedForDisplay(
        minCutoff: 100,
        beta: 0,
        deadZone: 0.5,
        maxDeltaPerUpdate: 1000,
      );
      final future = expectLater(
        stabilized,
        emitsInOrder([
          offsetMoreOrLessEquals(const Offset(10, 0), epsilon: 0.001), // seeds displayed at 10.
          offsetMoreOrLessEquals(const Offset(10, 0), epsilon: 0.001), // 10.2: within the dead zone, ignored.
          offsetMoreOrLessEquals(const Offset(10, 0), epsilon: 0.001), // 9.8: likewise.
          offsetMoreOrLessEquals(const Offset(11, 0), epsilon: 0.001), // a genuine 1.0 jump clears it.
          emitsDone,
        ]),
      );
      var t = DateTime(2026, 1, 1);
      controller.add((const Offset(10, 0), t));
      t = t.add(const Duration(seconds: 10));
      controller.add((const Offset(10.2, 0), t));
      t = t.add(const Duration(seconds: 10));
      controller.add((const Offset(9.8, 0), t));
      t = t.add(const Duration(seconds: 10));
      controller.add((const Offset(11, 0), t));
      await controller.close();
      await future;
    });

    test('the slew-rate limiter ramps a big jump in over several updates instead of snapping', () async {
      final controller = StreamController<(Offset, DateTime)>();
      final stabilized = controller.stream.stabilizedForDisplay(
        minCutoff: 100, // same large-cutoff/large-gap trick to isolate the slew cap.
        beta: 0,
        deadZone: 0,
        maxDeltaPerUpdate: 2.0,
      );
      final future = expectLater(
        stabilized,
        emitsInOrder([
          offsetMoreOrLessEquals(Offset.zero, epsilon: 0.001), // seeds displayed at 0.
          offsetMoreOrLessEquals(const Offset(2, 0), epsilon: 0.001), // capped step toward 10.
          offsetMoreOrLessEquals(const Offset(4, 0), epsilon: 0.001), // another capped step.
          emitsDone,
        ]),
      );
      var t = DateTime(2026, 1, 1);
      controller.add((Offset.zero, t));
      t = t.add(const Duration(seconds: 10));
      controller.add((const Offset(10, 0), t));
      t = t.add(const Duration(seconds: 10));
      controller.add((const Offset(10, 0), t));
      await controller.close();
      await future;
    });
  });

  group('stabilizedForDisplay (scalar — the g-force vertical/magnitude counterpart)', () {
    test('a genuine sustained step is not applied instantly, but converges within a handful of samples', () async {
      final controller = StreamController<(double, DateTime)>();
      final stabilized = controller.stream.stabilizedForDisplay(
        minCutoff: 0.3,
        beta: 0.5,
        deadZone: 0,
        maxDeltaPerUpdate: 1000,
      );
      final results = <double>[];
      final sub = stabilized.listen(results.add);

      var t = DateTime(2026, 1, 1);
      controller.add((0.0, t));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 15; i++) {
        t = t.add(const Duration(milliseconds: 200));
        controller.add((10.0, t));
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
      await sub.cancel();

      expect(results.first, closeTo(0, 1e-9)); // seeded, not an instant jump.
      expect(results[1], greaterThan(0)); // starts moving toward the step...
      expect(results[1], lessThan(10)); // ...but hasn't snapped there yet.
      expect(results.last, closeTo(10, 0.5)); // converges.
    });

    test('the dead zone holds a sustained non-zero displayed value steady against small perturbations', () async {
      final controller = StreamController<(double, DateTime)>();
      final stabilized = controller.stream.stabilizedForDisplay(
        minCutoff: 100,
        beta: 0,
        deadZone: 0.5,
        maxDeltaPerUpdate: 1000,
      );
      final future = expectLater(
        stabilized,
        emitsInOrder([
          closeTo(10, 0.001), // seeds displayed at 10.
          closeTo(10, 0.001), // 10.2: within the dead zone, ignored.
          closeTo(10, 0.001), // 9.8: likewise.
          closeTo(11, 0.001), // a genuine 1.0 jump clears it.
          emitsDone,
        ]),
      );
      var t = DateTime(2026, 1, 1);
      controller.add((10.0, t));
      t = t.add(const Duration(seconds: 10));
      controller.add((10.2, t));
      t = t.add(const Duration(seconds: 10));
      controller.add((9.8, t));
      t = t.add(const Duration(seconds: 10));
      controller.add((11.0, t));
      await controller.close();
      await future;
    });

    test('the slew-rate limiter ramps a big jump in over several updates instead of snapping', () async {
      final controller = StreamController<(double, DateTime)>();
      final stabilized = controller.stream.stabilizedForDisplay(
        minCutoff: 100,
        beta: 0,
        deadZone: 0,
        maxDeltaPerUpdate: 2.0,
      );
      final future = expectLater(
        stabilized,
        emitsInOrder([
          closeTo(0, 0.001), // seeds displayed at 0.
          closeTo(2, 0.001), // capped step toward 10.
          closeTo(4, 0.001), // another capped step.
          emitsDone,
        ]),
      );
      var t = DateTime(2026, 1, 1);
      controller.add((0.0, t));
      t = t.add(const Duration(seconds: 10));
      controller.add((10.0, t));
      t = t.add(const Duration(seconds: 10));
      controller.add((10.0, t));
      await controller.close();
      await future;
    });

    test('maxDeltaPerUpdate of infinity disables the slew cap entirely — used by g-force magnitude', () async {
      // Regression coverage for the peak-blunting risk this parameter exists
      // to avoid for a signal that also feeds a peak/record tracker.
      final controller = StreamController<(double, DateTime)>();
      final stabilized = controller.stream.stabilizedForDisplay(
        minCutoff: 100,
        beta: 0,
        deadZone: 0,
        maxDeltaPerUpdate: double.infinity,
      );
      final future = expectLater(
        stabilized,
        emitsInOrder([
          closeTo(0, 0.001),
          closeTo(50, 0.02), // a huge instantaneous jump passes straight through — no cap (OneEuroFilter's own alpha at this huge cutoff/gap is ~0.9998, not exactly 1, hence the slightly looser tolerance than the dead-zone/slew tests above).
          emitsDone,
        ]),
      );
      var t = DateTime(2026, 1, 1);
      controller.add((0.0, t));
      t = t.add(const Duration(seconds: 10));
      controller.add((50.0, t));
      await controller.close();
      await future;
    });
  });
}
