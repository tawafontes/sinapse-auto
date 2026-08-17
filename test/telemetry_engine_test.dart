import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/sensor_service.dart';
import 'package:synapse_auto/services/telemetry_engine.dart';

void main() {
  group('throttleAdaptive', () {
    test(
      'serves two simultaneous listeners with shared, consistent state — the fullscreen '
      '"--" regression this exists to prevent (previously the second listener got nothing, ever)',
      () async {
        final controller = StreamController<int>.broadcast();
        addTearDown(() => unawaited(controller.close()));

        var mapCalls = 0;
        final upstream = controller.stream.map((x) {
          mapCalls++;
          return x;
        });
        final throttled = throttleAdaptive(upstream, () => const Duration(milliseconds: 50));

        final firstResults = <int>[];
        final secondResults = <int>[];
        final sub1 = throttled.listen(firstResults.add);
        final sub2 = throttled.listen(secondResults.add);
        addTearDown(() async {
          await sub1.cancel();
          await sub2.cancel();
        });

        controller.add(1);
        await Future<void>.delayed(Duration.zero);

        // The upstream transform runs exactly once per event (shared),
        // not once per listener — and, crucially, BOTH listeners actually
        // received the value, not just the first one to attach.
        expect(mapCalls, 1);
        expect(firstResults, [1]);
        expect(secondResults, [1]);
      },
    );

    test('a listener that joins after the throttle window has cleared still receives new events', () async {
      final controller = StreamController<int>.broadcast();
      addTearDown(() => unawaited(controller.close()));

      final throttled = throttleAdaptive(controller.stream, () => const Duration(milliseconds: 20));

      final earlyResults = <int>[];
      final earlySub = throttled.listen(earlyResults.add);
      addTearDown(earlySub.cancel);

      controller.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final lateResults = <int>[];
      final lateSub = throttled.listen(lateResults.add);
      addTearDown(lateSub.cancel);

      controller.add(2);
      await Future<void>.delayed(Duration.zero);

      expect(earlyResults, [1, 2]);
      expect(lateResults, [2]);
    });

    test('still drops an emission within the same throttle window, consistently for every listener', () async {
      final controller = StreamController<int>.broadcast();
      addTearDown(() => unawaited(controller.close()));

      final throttled = throttleAdaptive(controller.stream, () => const Duration(milliseconds: 200));

      final firstResults = <int>[];
      final secondResults = <int>[];
      final sub1 = throttled.listen(firstResults.add);
      final sub2 = throttled.listen(secondResults.add);
      addTearDown(() async {
        await sub1.cancel();
        await sub2.cancel();
      });

      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      controller.add(2); // well within the 200ms window — must be dropped for both.
      await Future<void>.delayed(Duration.zero);

      expect(firstResults, [1]);
      expect(secondResults, [1]);
    });

    test('the returned stream is broadcast, allowing more than one listener without throwing', () {
      final controller = StreamController<int>.broadcast();
      addTearDown(() => unawaited(controller.close()));
      final throttled = throttleAdaptive(controller.stream, () => Duration.zero);
      expect(throttled.isBroadcast, isTrue);
    });
  });

  group('g-force filtering — deliberately NOT throttled by vehicle speed', () {
    // Regression coverage for the "g-force meter stutters, especially while
    // parked/slow" bug: these three methods used to route through
    // _throttleAdaptive (the vehicle-speed-bucketed emission cap meant for
    // GPS-derived signals), capping g-force at 1Hz while parked. They must
    // still be safely shareable across two simultaneous listeners (the
    // dashboard tile and a fullscreen view) with no duplicated/corrupted
    // OneEuroFilter state and no "Stream has already been listened to" — the
    // same property _throttleAdaptive used to provide via asBroadcastStream,
    // now provided directly with no throttle attached.
    late TelemetryEngine engine;
    final t0 = DateTime(2026, 1, 1, 12);

    setUp(() {
      engine = TelemetryEngine(SensorService());
    });

    test('filterGForceMagnitude: two listeners share one filtered pass, every value, no throttle', () async {
      final controller = StreamController<(double, DateTime)>();
      addTearDown(() => unawaited(controller.close()));
      final filtered = engine.filterGForceMagnitude(controller.stream);
      expect(filtered.isBroadcast, isTrue);

      final first = <double>[];
      final second = <double>[];
      final sub1 = filtered.listen(first.add);
      final sub2 = filtered.listen(second.add);
      addTearDown(() async {
        await sub1.cancel();
        await sub2.cancel();
      });

      controller.add((0.5, t0));
      await Future<void>.delayed(Duration.zero);
      controller.add((0.6, t0.add(const Duration(milliseconds: 20)))); // immediately after — must NOT be dropped (no throttle).
      await Future<void>.delayed(Duration.zero);

      expect(first.length, 2);
      expect(second, first); // both listeners saw the exact same filtered values.
    });

    test('a fast, sustained rise in magnitude is not blunted by a slew cap (no cap on this stream)', () async {
      // Regression coverage for the peak-blunting risk: magnitude feeds the
      // peak-G record, so unlike offset/vertical it must never have an
      // artificial ceiling on how fast the displayed value may rise.
      final controller = StreamController<(double, DateTime)>();
      addTearDown(() => unawaited(controller.close()));
      final filtered = engine.filterGForceMagnitude(controller.stream);
      final results = <double>[];
      final sub = filtered.listen(results.add);
      addTearDown(sub.cancel);

      controller.add((0.0, t0));
      await Future<void>.delayed(Duration.zero);
      var t = t0;
      for (var i = 0; i < 15; i++) {
        t = t.add(const Duration(milliseconds: 20));
        controller.add((2.0, t)); // a sudden, sustained jump to a hard-impact-sized reading.
        await Future<void>.delayed(Duration.zero);
      }

      expect(results.last, closeTo(2.0, 0.2)); // tracks the real peak closely, not held back by a cap.
    });

    test('filterGForceVertical: two listeners share state consistently, no throttle', () async {
      final controller = StreamController<(double, DateTime)>();
      addTearDown(() => unawaited(controller.close()));
      final filtered = engine.filterGForceVertical(controller.stream);
      expect(filtered.isBroadcast, isTrue);

      final first = <double>[];
      final second = <double>[];
      final sub1 = filtered.listen(first.add);
      final sub2 = filtered.listen(second.add);
      addTearDown(() async {
        await sub1.cancel();
        await sub2.cancel();
      });

      controller.add((0.2, t0));
      await Future<void>.delayed(Duration.zero);
      controller.add((-0.3, t0.add(const Duration(milliseconds: 20))));
      await Future<void>.delayed(Duration.zero);

      expect(first.length, 2);
      expect(second, first);
    });

    test('filterGForceOffset: two listeners share state consistently, no throttle', () async {
      final controller = StreamController<(Offset, DateTime)>();
      addTearDown(() => unawaited(controller.close()));
      final filtered = engine.filterGForceOffset(controller.stream);
      expect(filtered.isBroadcast, isTrue);

      final first = <Offset>[];
      final second = <Offset>[];
      final sub1 = filtered.listen(first.add);
      final sub2 = filtered.listen(second.add);
      addTearDown(() async {
        await sub1.cancel();
        await sub2.cancel();
      });

      controller.add((const Offset(0.1, 0.2), t0));
      await Future<void>.delayed(Duration.zero);
      controller.add((const Offset(-0.1, 0.3), t0.add(const Duration(milliseconds: 20))));
      await Future<void>.delayed(Duration.zero);

      expect(first.length, 2);
      expect(second, first);
    });
  });

  group('CircularHeadingSmoother', () {
    test('first sample returns itself exactly', () {
      final smoother = CircularHeadingSmoother(alpha: 0.3);
      expect(smoother.smooth(90.0), closeTo(90.0, 1e-9));
    });

    test('a 359°→1° crossing smooths as the small ~2° step it actually is, not a ~358° swing', () {
      final smoother = CircularHeadingSmoother(alpha: 0.5);
      smoother.smooth(359.0);
      final result = smoother.smooth(1.0);
      // The true circular distance from 359 to 1 is +2 degrees; the smoothed
      // result must land strictly within that small arc (i.e. either
      // between 359 and 360, or between 0 and 1) — never swing the wrong
      // way around toward ~180.
      final wrapped = result > 180 ? result - 360 : result;
      expect(wrapped, inInclusiveRange(-1.0, 1.0));
    });

    test('repeated identical readings converge to (and stay at) that heading', () {
      final smoother = CircularHeadingSmoother(alpha: 0.3);
      double last = 0;
      for (var i = 0; i < 20; i++) {
        last = smoother.smooth(45.0);
      }
      expect(last, closeTo(45.0, 0.5));
    });

    test('output always stays within the valid 0-360 range', () {
      final smoother = CircularHeadingSmoother(alpha: 0.4);
      for (final heading in [0.0, 10.0, 350.0, 5.0, 355.0, 180.0]) {
        final result = smoother.smooth(heading);
        expect(result, greaterThanOrEqualTo(0.0));
        expect(result, lessThan(360.0));
      }
    });

    test(
      'the exact Fase 10 wraparound sequence (358, 359, 0, 1, 2) stays continuous — never a ~358° swing',
      () {
        final smoother = CircularHeadingSmoother(alpha: 0.5);
        final results = [358.0, 359.0, 0.0, 1.0, 2.0].map(smoother.smooth).toList();
        for (final result in results) {
          // Every intermediate result must land within the small arc this
          // sequence actually spans (roughly 355°-365°/0°-5°), never swing
          // the wrong way around toward ~180°.
          final wrapped = result > 180 ? result - 360 : result;
          expect(wrapped, inInclusiveRange(-5.0, 5.0));
        }
        // And the sequence is monotonically progressing forward around the
        // small arc, not oscillating.
        final unwrapped = results.map((r) => r > 180 ? r - 360 : r).toList();
        for (var i = 1; i < unwrapped.length; i++) {
          expect(unwrapped[i], greaterThanOrEqualTo(unwrapped[i - 1] - 0.01));
        }
      },
    );

    test('a large jump (genuine turn) moves toward the new heading, not held rigidly at the old one', () {
      final smoother = CircularHeadingSmoother(alpha: 0.5);
      smoother.smooth(90.0);
      final afterTurn = smoother.smooth(180.0);
      // Halfway (alpha=0.5) between 90 and 180 in vector space lands close
      // to 135 — confirms a real heading change is actually tracked, not
      // just wraparound-safe.
      expect(afterTurn, closeTo(135.0, 5.0));
    });
  });
}
