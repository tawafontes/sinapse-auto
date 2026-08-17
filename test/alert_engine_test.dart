import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/alert_event.dart';
import 'package:synapse_auto/models/alert_type.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/alert_engine.dart';
import 'package:synapse_auto/services/alert_preferences.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

void main() {
  late Directory dir;
  late AlertPreferences prefs;
  final t0 = DateTime(2026, 1, 1, 12);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('alert_engine_test');
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.appSettings);
    prefs = AlertPreferences();
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  TelemetrySnapshot snap({
    double? speedKmh,
    double? longitudinalG,
    double? lateralG,
    double? gForceMagnitude,
    double? pitchDegrees,
    double? rollDegrees,
    GnssQuality gnssQuality = GnssQuality.excellent,
    DateTime? timestamp,
  }) {
    return TelemetrySnapshot(
      timestamp: timestamp ?? t0,
      speedKmh: speedKmh,
      longitudinalG: longitudinalG,
      lateralG: lateralG,
      gForceMagnitude: gForceMagnitude,
      pitchDegrees: pitchDegrees,
      rollDegrees: rollDegrees,
      gnssQuality: gnssQuality,
    );
  }

  // NOTE (Fase 13.1 §1/§2): `evaluateAlert` stays a total, exhaustive pure
  // function over every AlertType — cheap, stateless, and worth testing in
  // full — but as of this fix `AlertEngine`'s own runtime loop only ever
  // calls it for `highInclination`/`weakGnss` (see AlertEngine's class doc).
  // The groups below for the other six types still verify the pure
  // arithmetic is correct; the "AlertEngine.events — delegated types never
  // fire" group further down is what actually locks in that AlertEngine no
  // longer independently detects them at runtime.
  group('evaluateAlert — highSpeed', () {
    test('inactive, below threshold: stays inactive', () {
      expect(
        evaluateAlert(AlertType.highSpeed, snap(speedKmh: 100), currentlyActive: false, preferences: prefs),
        isFalse,
      );
    });

    test('inactive, at/above threshold: becomes active', () {
      expect(
        evaluateAlert(AlertType.highSpeed, snap(speedKmh: 120), currentlyActive: false, preferences: prefs),
        isTrue,
      );
    });

    test('active, dropped below threshold but still above clear ratio: stays active (hysteresis)', () {
      // Default threshold 120, clear ratio 0.85 -> clears at 102.
      expect(
        evaluateAlert(AlertType.highSpeed, snap(speedKmh: 110), currentlyActive: true, preferences: prefs),
        isTrue,
      );
    });

    test('active, dropped below the clear ratio: becomes inactive', () {
      expect(
        evaluateAlert(AlertType.highSpeed, snap(speedKmh: 100), currentlyActive: true, preferences: prefs),
        isFalse,
      );
    });

    test('a missing reading (null speed) preserves the current state', () {
      expect(evaluateAlert(AlertType.highSpeed, snap(), currentlyActive: true, preferences: prefs), isTrue);
      expect(evaluateAlert(AlertType.highSpeed, snap(), currentlyActive: false, preferences: prefs), isFalse);
    });
  });

  group('evaluateAlert — harshAcceleration / harshBraking (share longitudinalG, opposite sign)', () {
    test('positive G above threshold triggers acceleration, not braking', () {
      final s = snap(longitudinalG: 0.5);
      expect(evaluateAlert(AlertType.harshAcceleration, s, currentlyActive: false, preferences: prefs), isTrue);
      expect(evaluateAlert(AlertType.harshBraking, s, currentlyActive: false, preferences: prefs), isFalse);
    });

    test('negative G beyond threshold magnitude triggers braking, not acceleration', () {
      final s = snap(longitudinalG: -0.5);
      expect(evaluateAlert(AlertType.harshBraking, s, currentlyActive: false, preferences: prefs), isTrue);
      expect(evaluateAlert(AlertType.harshAcceleration, s, currentlyActive: false, preferences: prefs), isFalse);
    });

    test('mild G (below threshold either direction) triggers neither', () {
      final s = snap(longitudinalG: 0.1);
      expect(evaluateAlert(AlertType.harshAcceleration, s, currentlyActive: false, preferences: prefs), isFalse);
      expect(evaluateAlert(AlertType.harshBraking, s, currentlyActive: false, preferences: prefs), isFalse);
    });
  });

  group('evaluateAlert — highInclination', () {
    test('triggers when either pitch or roll (whichever is larger) exceeds the threshold', () {
      expect(
        evaluateAlert(AlertType.highInclination, snap(pitchDegrees: 5, rollDegrees: 35), currentlyActive: false, preferences: prefs),
        isTrue,
      );
      expect(
        evaluateAlert(AlertType.highInclination, snap(pitchDegrees: 35, rollDegrees: 5), currentlyActive: false, preferences: prefs),
        isTrue,
      );
    });

    test('a negative angle beyond the threshold magnitude still triggers (absolute value)', () {
      expect(
        evaluateAlert(AlertType.highInclination, snap(pitchDegrees: -35, rollDegrees: 0), currentlyActive: false, preferences: prefs),
        isTrue,
      );
    });

    test('below threshold on both axes does not trigger', () {
      expect(
        evaluateAlert(AlertType.highInclination, snap(pitchDegrees: 10, rollDegrees: 10), currentlyActive: false, preferences: prefs),
        isFalse,
      );
    });
  });

  group('evaluateAlert — hardCornering (Fase 13, unsigned lateral G)', () {
    test('a rightward (positive) lateral G above threshold triggers', () {
      expect(evaluateAlert(AlertType.hardCornering, snap(lateralG: 0.5), currentlyActive: false, preferences: prefs), isTrue);
    });

    test('a leftward (negative) lateral G beyond threshold magnitude also triggers — direction-agnostic', () {
      expect(evaluateAlert(AlertType.hardCornering, snap(lateralG: -0.5), currentlyActive: false, preferences: prefs), isTrue);
    });

    test('mild lateral G (either direction) does not trigger', () {
      expect(evaluateAlert(AlertType.hardCornering, snap(lateralG: 0.1), currentlyActive: false, preferences: prefs), isFalse);
      expect(evaluateAlert(AlertType.hardCornering, snap(lateralG: -0.1), currentlyActive: false, preferences: prefs), isFalse);
    });
  });

  group('evaluateAlert — highResultantG (Fase 13, reuses TelemetrySnapshot.gForceMagnitude)', () {
    test('triggers once the already-centralized resultant magnitude clears its own, higher threshold', () {
      expect(evaluateAlert(AlertType.highResultantG, snap(gForceMagnitude: 0.7), currentlyActive: false, preferences: prefs), isTrue);
    });

    test('does not trigger below threshold', () {
      expect(evaluateAlert(AlertType.highResultantG, snap(gForceMagnitude: 0.3), currentlyActive: false, preferences: prefs), isFalse);
    });

    test('a missing reading preserves the current state', () {
      expect(evaluateAlert(AlertType.highResultantG, snap(), currentlyActive: true, preferences: prefs), isTrue);
    });
  });

  group('evaluateAlert — GNSS quality', () {
    test('weakGnss fires on weak or unavailable quality', () {
      expect(
        evaluateAlert(AlertType.weakGnss, snap(gnssQuality: GnssQuality.weak), currentlyActive: false, preferences: prefs),
        isTrue,
      );
      expect(
        evaluateAlert(AlertType.weakGnss, snap(gnssQuality: GnssQuality.unavailable), currentlyActive: false, preferences: prefs),
        isTrue,
      );
      expect(
        evaluateAlert(AlertType.weakGnss, snap(gnssQuality: GnssQuality.moderate), currentlyActive: false, preferences: prefs),
        isFalse,
      );
    });

    test('gnssLost fires only on unavailable quality, not merely weak', () {
      expect(
        evaluateAlert(AlertType.gnssLost, snap(gnssQuality: GnssQuality.unavailable), currentlyActive: false, preferences: prefs),
        isTrue,
      );
      expect(
        evaluateAlert(AlertType.gnssLost, snap(gnssQuality: GnssQuality.weak), currentlyActive: false, preferences: prefs),
        isFalse,
      );
    });
  });

  group('AlertEngine.events (stream-level) — exercised via highInclination, one of the two types '
      'AlertEngine still owns post-Fase-13.1 (see the delegated-types group below)', () {
    test('emits exactly one "active" transition when a threshold is first crossed, not one per tick', () async {
      final controller = StreamController<TelemetrySnapshot>();
      addTearDown(() => unawaited(controller.close()));
      final engine = AlertEngine(controller.stream, prefs);
      final events = <AlertEvent>[];
      final sub = engine.events.listen(events.add);
      addTearDown(sub.cancel);

      controller.add(snap(pitchDegrees: 35, timestamp: t0));
      await Future<void>.delayed(Duration.zero);
      controller.add(snap(pitchDegrees: 36, timestamp: t0.add(const Duration(milliseconds: 100))));
      await Future<void>.delayed(Duration.zero);
      controller.add(snap(pitchDegrees: 37, timestamp: t0.add(const Duration(milliseconds: 200))));
      await Future<void>.delayed(Duration.zero);

      final inclinationEvents = events.where((e) => e.type == AlertType.highInclination).toList();
      expect(inclinationEvents.length, 1);
      expect(inclinationEvents.single.active, isTrue);
    });

    test('emits a "cleared" transition once the value drops below the clear ratio', () async {
      final controller = StreamController<TelemetrySnapshot>();
      addTearDown(() => unawaited(controller.close()));
      final engine = AlertEngine(controller.stream, prefs);
      final events = <AlertEvent>[];
      final sub = engine.events.listen(events.add);
      addTearDown(sub.cancel);

      controller.add(snap(pitchDegrees: 35, timestamp: t0));
      await Future<void>.delayed(Duration.zero);
      controller.add(snap(pitchDegrees: 5, timestamp: t0.add(const Duration(seconds: 10))));
      await Future<void>.delayed(Duration.zero);

      final inclinationEvents = events.where((e) => e.type == AlertType.highInclination).toList();
      expect(inclinationEvents.length, 2);
      expect(inclinationEvents[0].active, isTrue);
      expect(inclinationEvents[1].active, isFalse);
    });

    test('a disabled alert type never fires, even when its condition is met', () async {
      await prefs.setEnabled(AlertType.highInclination, false);
      final controller = StreamController<TelemetrySnapshot>();
      addTearDown(() => unawaited(controller.close()));
      final engine = AlertEngine(controller.stream, prefs);
      final events = <AlertEvent>[];
      final sub = engine.events.listen(events.add);
      addTearDown(sub.cancel);

      controller.add(snap(pitchDegrees: 50, timestamp: t0));
      await Future<void>.delayed(Duration.zero);

      expect(events.where((e) => e.type == AlertType.highInclination), isEmpty);
    });

    test('a re-trigger within the cooldown window is suppressed (no rapid flicker)', () async {
      final controller = StreamController<TelemetrySnapshot>();
      addTearDown(() => unawaited(controller.close()));
      final engine = AlertEngine(controller.stream, prefs);
      final events = <AlertEvent>[];
      final sub = engine.events.listen(events.add);
      addTearDown(sub.cancel);

      controller.add(snap(pitchDegrees: 35, timestamp: t0)); // fires at t0.
      await Future<void>.delayed(Duration.zero);
      controller.add(snap(pitchDegrees: 5, timestamp: t0.add(const Duration(seconds: 1)))); // clears at t0+1s.
      await Future<void>.delayed(Duration.zero);
      // Crosses back above threshold at t0+2s — still within the 5s cooldown
      // measured from the ORIGINAL fire at t0, so this re-fire must be
      // suppressed.
      controller.add(snap(pitchDegrees: 35, timestamp: t0.add(const Duration(seconds: 2))));
      await Future<void>.delayed(Duration.zero);

      final suppressedCount = events.where((e) => e.type == AlertType.highInclination).length;
      expect(suppressedCount, 2); // fire, clear — the third crossing was suppressed.

      // Once the cooldown has genuinely elapsed (t0+6s, >5s after the
      // original fire), a fresh crossing IS allowed to fire again.
      controller.add(snap(pitchDegrees: 5, timestamp: t0.add(const Duration(seconds: 3)))); // already cleared, no-op.
      await Future<void>.delayed(Duration.zero);
      controller.add(snap(pitchDegrees: 35, timestamp: t0.add(const Duration(seconds: 6))));
      await Future<void>.delayed(Duration.zero);

      final inclinationEvents = events.where((e) => e.type == AlertType.highInclination).toList();
      expect(inclinationEvents.length, 3);
      expect(inclinationEvents.last.active, isTrue);
    });

    test('the returned stream is broadcast (safe for multiple listeners)', () {
      final controller = StreamController<TelemetrySnapshot>();
      addTearDown(() => unawaited(controller.close()));
      final engine = AlertEngine(controller.stream, prefs);
      expect(engine.events.isBroadcast, isTrue);
    });
  });

  group('AlertEngine.events — delegated types never fire through AlertEngine itself '
      '(Fase 13.1 §1/§2: single source of truth, no dual detection)', () {
    test('highSpeed/harshAcceleration/harshBraking/hardCornering/highResultantG/gnssLost never produce '
        'an AlertEvent, even when their condition is unmistakably met — EventDetectionEngine is now the '
        'sole detector for these; only highInclination/weakGnss remain AlertEngine-owned', () async {
      final controller = StreamController<TelemetrySnapshot>();
      addTearDown(() => unawaited(controller.close()));
      final engine = AlertEngine(controller.stream, prefs);
      final events = <AlertEvent>[];
      final sub = engine.events.listen(events.add);
      addTearDown(sub.cancel);

      // One snapshot that blows past every delegated type's threshold at once.
      controller.add(
        snap(
          speedKmh: 999,
          longitudinalG: 5.0,
          lateralG: 5.0,
          gForceMagnitude: 5.0,
          gnssQuality: GnssQuality.unavailable,
          timestamp: t0,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      const delegated = {
        AlertType.highSpeed,
        AlertType.harshAcceleration,
        AlertType.harshBraking,
        AlertType.hardCornering,
        AlertType.highResultantG,
        AlertType.gnssLost,
      };
      expect(events.where((e) => delegated.contains(e.type)), isEmpty);
    });
  });
}
