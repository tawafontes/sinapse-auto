import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/alert_type.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/alert_preferences.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/event_detection_engine.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  group('LevelEventTracker — the shared state machine (§22)', () {
    LevelEventTracker tracker({Duration minDuration = const Duration(milliseconds: 150), Duration cooldown = const Duration(seconds: 5)}) =>
        LevelEventTracker(exitRatio: 0.85, minDuration: minDuration, cooldown: cooldown);

    test('stays idle (no confirmation) below the enter threshold', () {
      final t = tracker();
      expect(t.update(0.1, 0.4, t0), isNull);
      expect(t.update(0.2, 0.4, t0.add(const Duration(seconds: 1))), isNull);
    });

    test('crossing the enter threshold alone does not confirm — minDuration must elapse first', () {
      final t = tracker();
      expect(t.update(0.5, 0.4, t0), isNull);
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 50))), isNull);
    });

    test('false alarm: dropping back below enter threshold before minDuration discards the candidate', () {
      final t = tracker();
      expect(t.update(0.5, 0.4, t0), isNull);
      expect(t.update(0.1, 0.4, t0.add(const Duration(milliseconds: 80))), isNull);
      // Must start a completely fresh candidate window, not resume the old one.
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 100))), isNull);
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 260))), isNotNull); // 160ms after the fresh candidate start.
    });

    test('confirms exactly once, the instant minDuration is held continuously', () {
      final t = tracker();
      expect(t.update(0.5, 0.4, t0), isNull);
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 149))), isNull);
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 150))), t0.add(const Duration(milliseconds: 150)));
    });

    test('never fires twice for one continuous episode (no duplicate events, §38/§68)', () {
      final t = tracker();
      t.update(0.5, 0.4, t0);
      t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 150)));
      // Still well above threshold, every subsequent sample — must stay silent.
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 300))), isNull);
      expect(t.update(0.5, 0.4, t0.add(const Duration(seconds: 2))), isNull);
    });

    test('hysteresis: dropping into the band between exit and enter thresholds does not end the episode', () {
      final t = tracker();
      t.update(0.5, 0.4, t0);
      t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 150))); // confirmed, active.
      // exit threshold = 0.4 * 0.85 = 0.34 — 0.35 is still inside the active band.
      expect(t.update(0.35, 0.4, t0.add(const Duration(milliseconds: 300))), isNull);
      // A moment later, still above 0.34 — still no new confirmation possible anyway (still active).
      expect(t.update(0.36, 0.4, t0.add(const Duration(milliseconds: 400))), isNull);
    });

    test('cooldown blocks a re-confirmation even if the value crosses back above enter threshold', () {
      final t = tracker(cooldown: const Duration(seconds: 5));
      t.update(0.5, 0.4, t0);
      t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 150))); // confirmed.
      t.update(0.1, 0.4, t0.add(const Duration(milliseconds: 400))); // drops below exit -> cooldown starts.
      // Re-crosses enter threshold well within the 5s cooldown.
      expect(t.update(0.5, 0.4, t0.add(const Duration(seconds: 1))), isNull);
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 1200))), isNull);
    });

    test('a fresh episode can confirm again once the cooldown has genuinely elapsed', () {
      final t = tracker(cooldown: const Duration(seconds: 5));
      t.update(0.5, 0.4, t0);
      t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 150))); // confirmed at 150ms.
      t.update(0.1, 0.4, t0.add(const Duration(milliseconds: 400))); // -> cooldown, until 400ms+5s.
      final afterCooldown = t0.add(const Duration(milliseconds: 400)).add(const Duration(seconds: 5));
      expect(t.update(0.5, 0.4, afterCooldown), isNull); // idle again, but this is only the new candidate's start.
      expect(t.update(0.5, 0.4, afterCooldown.add(const Duration(milliseconds: 150))), isNotNull);
    });

    test('a live threshold change takes effect on the very next call (no caching)', () {
      final t = tracker();
      expect(t.update(0.5, 0.6, t0), isNull); // 0.5 < 0.6, below this call's threshold.
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 10))), isNull); // now above 0.4 — starts a candidate.
      expect(t.update(0.5, 0.4, t0.add(const Duration(milliseconds: 200))), isNotNull);
    });
  });

  group('MotionTracker — stopped/resumed (§13/§14)', () {
    MotionTracker tracker() => MotionTracker(
      stopThresholdKmh: 3.0,
      resumeThresholdKmh: 8.0,
      stopMinDuration: const Duration(seconds: 3),
      resumeMinDuration: const Duration(seconds: 1),
    );

    test('moving above the stop threshold never reports stopped', () {
      final m = tracker();
      expect(m.update(40, t0), isNull);
      expect(m.update(35, t0.add(const Duration(seconds: 5))), isNull);
    });

    test('a brief dip below the stop threshold shorter than stopMinDuration is not a stop (§37: no false stop through a slow corner)', () {
      final m = tracker();
      m.update(40, t0);
      expect(m.update(2, t0.add(const Duration(seconds: 1))), isNull);
      expect(m.update(30, t0.add(const Duration(milliseconds: 1500))), isNull); // back to moving before 3s elapsed.
    });

    test('sustained low speed for stopMinDuration confirms stopped exactly once', () {
      final m = tracker();
      m.update(40, t0);
      expect(m.update(1, t0.add(const Duration(seconds: 1))), isNull);
      expect(m.update(1, t0.add(const Duration(seconds: 3))), isNull);
      expect(m.update(1, t0.add(const Duration(seconds: 4))), DetectedEventType.stopped);
      // Continuing to be stopped must not re-fire.
      expect(m.update(0, t0.add(const Duration(seconds: 10))), isNull);
    });

    test('hysteresis: speed between stop and resume thresholds while stopped does not trigger resumed', () {
      final m = tracker();
      m.update(40, t0);
      m.update(1, t0.add(const Duration(seconds: 1)));
      m.update(1, t0.add(const Duration(seconds: 4))); // stopped confirmed.
      expect(m.update(5, t0.add(const Duration(seconds: 5))), isNull); // above stop, below resume — no event either way.
    });

    test('sustained real movement past the resume threshold confirms resumed exactly once', () {
      final m = tracker();
      m.update(40, t0);
      m.update(1, t0.add(const Duration(seconds: 1)));
      m.update(1, t0.add(const Duration(seconds: 4))); // stopped.
      expect(m.update(20, t0.add(const Duration(seconds: 5))), isNull);
      expect(m.update(20, t0.add(const Duration(seconds: 6))), DetectedEventType.resumed);
    });

    test('a null speed reading leaves the state exactly where it was (§40)', () {
      final m = tracker();
      m.update(40, t0);
      expect(m.update(null, t0.add(const Duration(seconds: 1))), isNull);
      expect(m.update(null, t0.add(const Duration(seconds: 10))), isNull);
    });

    test('NaN/infinite speed is ignored, never treated as a real reading (§40)', () {
      final m = tracker();
      m.update(40, t0);
      expect(m.update(double.nan, t0.add(const Duration(seconds: 1))), isNull);
      expect(m.update(double.infinity, t0.add(const Duration(seconds: 2))), isNull);
    });
  });

  group('GnssTracker — lost/recovered (§15/§16/§56)', () {
    test('starts assuming GNSS is fine — the first good sample never fires a spurious recovered', () {
      final g = GnssTracker();
      expect(g.update(GnssQuality.excellent), isNull);
      expect(g.update(GnssQuality.good), isNull);
    });

    test('transitioning to unavailable fires gnssLost exactly once, not per sample while it lasts', () {
      final g = GnssTracker();
      g.update(GnssQuality.good);
      expect(g.update(GnssQuality.unavailable), DetectedEventType.gnssLost);
      expect(g.update(GnssQuality.unavailable), isNull);
      expect(g.update(GnssQuality.unavailable), isNull);
    });

    test('transitioning back to available fires gnssRecovered exactly once', () {
      final g = GnssTracker();
      g.update(GnssQuality.good);
      g.update(GnssQuality.unavailable);
      expect(g.update(GnssQuality.good), DetectedEventType.gnssRecovered);
      expect(g.update(GnssQuality.excellent), isNull);
    });

    test('a weak (not unavailable) reading is not treated as lost', () {
      final g = GnssTracker();
      expect(g.update(GnssQuality.weak), isNull);
    });

    test('starting already unavailable (e.g. launched deep indoors) correctly fires gnssLost on the first sample', () {
      final g = GnssTracker();
      expect(g.update(GnssQuality.unavailable), DetectedEventType.gnssLost);
    });
  });

  group('AltitudeTrendTracker — significant climbs/descents (§17)', () {
    AltitudeTrendTracker tracker() => AltitudeTrendTracker(cooldown: const Duration(seconds: 10));

    test('transitioning into rising fires altitudeRisingSignificant', () {
      final a = tracker();
      a.update(AltitudeTrend.stable, t0);
      expect(a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 1))), DetectedEventType.altitudeRisingSignificant);
    });

    test('continuing to report rising never re-fires (§38)', () {
      final a = tracker();
      a.update(AltitudeTrend.stable, t0);
      a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 1)));
      expect(a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 2))), isNull);
      expect(a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 30))), isNull);
    });

    test('transitioning into falling fires altitudeFallingSignificant', () {
      final a = tracker();
      a.update(AltitudeTrend.stable, t0);
      expect(a.update(AltitudeTrend.falling, t0.add(const Duration(seconds: 1))), DetectedEventType.altitudeFallingSignificant);
    });

    test('returning to stable is never itself a reportable event', () {
      final a = tracker();
      a.update(AltitudeTrend.stable, t0);
      a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 1)));
      expect(a.update(AltitudeTrend.stable, t0.add(const Duration(seconds: 2))), isNull);
    });

    test('a rising→stable→rising flicker within the cooldown window does not re-fire', () {
      final a = tracker();
      a.update(AltitudeTrend.stable, t0);
      a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 1)));
      a.update(AltitudeTrend.stable, t0.add(const Duration(seconds: 2)));
      expect(a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 3))), isNull);
    });

    test('a genuine new transition after the cooldown elapses fires again', () {
      final a = tracker();
      a.update(AltitudeTrend.stable, t0);
      a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 1)));
      a.update(AltitudeTrend.stable, t0.add(const Duration(seconds: 2)));
      expect(a.update(AltitudeTrend.rising, t0.add(const Duration(seconds: 15))), DetectedEventType.altitudeRisingSignificant);
    });
  });

  group('severityForLevel — objective banding (§26/§27)', () {
    test('right at the threshold is warning', () {
      expect(severityForLevel(0.4, 0.4), EventSeverity.warning);
    });

    test('just below the "high" boundary (1.5x) is still warning', () {
      expect(severityForLevel(0.4 * 1.49, 0.4), EventSeverity.warning);
    });

    test('at 1.5x threshold is high', () {
      expect(severityForLevel(0.4 * 1.5, 0.4), EventSeverity.high);
    });

    test('at 2x threshold is critical', () {
      expect(severityForLevel(0.8, 0.4), EventSeverity.critical);
    });

    test('a non-positive threshold falls back to warning rather than dividing by zero', () {
      expect(severityForLevel(1.0, 0.0), EventSeverity.warning);
    });
  });

  group('EventDetectionEngine — full pipeline (stream-level integration)', () {
    late Directory dir;
    late AlertPreferences prefs;
    late StreamController<TelemetrySnapshot> controller;
    late EventDetectionEngine engine;
    late List<DetectedEvent> events;
    late StreamSubscription<DetectedEvent> sub;

    TelemetrySnapshot snap({
      required DateTime timestamp,
      double? speedKmh,
      double? longitudinalG,
      double? lateralG,
      double? gForceMagnitude,
      double? altitudeMeters,
      GnssQuality gnssQuality = GnssQuality.good,
      AltitudeTrend altitudeTrend = AltitudeTrend.stable,
    }) {
      return TelemetrySnapshot(
        timestamp: timestamp,
        speedKmh: speedKmh,
        longitudinalG: longitudinalG,
        lateralG: lateralG,
        gForceMagnitude: gForceMagnitude,
        altitudeMeters: altitudeMeters,
        gnssQuality: gnssQuality,
        altitudeTrend: altitudeTrend,
      );
    }

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('event_detection_engine_test');
      Hive.init(dir.path);
      await Hive.openBox(HiveBoxNames.appSettings);
      prefs = AlertPreferences();
      controller = StreamController<TelemetrySnapshot>();
      engine = EventDetectionEngine(controller.stream, prefs);
      events = [];
      sub = engine.events.listen(events.add);
    });

    tearDown(() async {
      await sub.cancel();
      await controller.close();
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    test('the returned stream is broadcast', () {
      expect(engine.events.isBroadcast, isTrue);
    });

    test('hardAcceleration: sustained positive longitudinal G above threshold is detected (§8, false negative check)', () async {
      controller.add(snap(timestamp: t0, longitudinalG: 0.6));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 200)), longitudinalG: 0.6));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.hardAcceleration).length, 1);
    });

    test('hardBraking: sustained negative longitudinal G above threshold magnitude is detected (§9)', () async {
      controller.add(snap(timestamp: t0, longitudinalG: -0.6));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 200)), longitudinalG: -0.6));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.hardBraking).length, 1);
      expect(events.single.value, -0.6);
    });

    test('a brief isolated spike (pothole/vibration) shorter than minDuration produces no event (§58/§59, false positive check)', () async {
      controller.add(snap(timestamp: t0, longitudinalG: -0.6));
      await pump();
      // Back to normal after only 50ms — well under the 150ms minimum hold.
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 50)), longitudinalG: 0.0));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 300)), longitudinalG: 0.0));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.hardBraking), isEmpty);
    });

    test('hardCorneringRight: positive lateral G above threshold (§10, confirmed sign convention: +lateral = right)', () async {
      controller.add(snap(timestamp: t0, lateralG: 0.5));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 250)), lateralG: 0.5));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.hardCorneringRight).length, 1);
      expect(events.where((e) => e.type == DetectedEventType.hardCorneringLeft), isEmpty);
    });

    test('hardCorneringLeft: negative lateral G above threshold magnitude (§10)', () async {
      controller.add(snap(timestamp: t0, lateralG: -0.5));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 250)), lateralG: -0.5));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.hardCorneringLeft).length, 1);
      expect(events.where((e) => e.type == DetectedEventType.hardCorneringRight), isEmpty);
    });

    test('highResultantG: reuses TelemetrySnapshot.gForceMagnitude directly (§11, no recomputed 2-axis magnitude)', () async {
      controller.add(snap(timestamp: t0, gForceMagnitude: 0.7));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 200)), gForceMagnitude: 0.7));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.highResultantG).length, 1);
    });

    test('speedLimitExceeded: sustained speed above the configured limit, reusing AlertType.highSpeed (§12)', () async {
      controller.add(snap(timestamp: t0, speedKmh: 130));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(seconds: 2)), speedKmh: 130));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.speedLimitExceeded).length, 1);
    });

    test('a brief overshoot under the 1s minimum does not count as speedLimitExceeded (§57)', () async {
      controller.add(snap(timestamp: t0, speedKmh: 130));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 500)), speedKmh: 100));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.speedLimitExceeded), isEmpty);
    });

    test('disabling an alert type via preferences suppresses its corresponding detected event', () async {
      await prefs.setEnabled(AlertType.harshBraking, false);
      controller.add(snap(timestamp: t0, longitudinalG: -0.9));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 300)), longitudinalG: -0.9));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.hardBraking), isEmpty);
    });

    test('stopped/resumed end to end', () async {
      controller.add(snap(timestamp: t0, speedKmh: 40));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(seconds: 1)), speedKmh: 1));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(seconds: 4)), speedKmh: 1));
      await pump();
      expect(events.where((e) => e.type == DetectedEventType.stopped).length, 1);

      controller.add(snap(timestamp: t0.add(const Duration(seconds: 5)), speedKmh: 20));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(seconds: 6)), speedKmh: 20));
      await pump();
      expect(events.where((e) => e.type == DetectedEventType.resumed).length, 1);
    });

    test('gnssLost/gnssRecovered end to end', () async {
      controller.add(snap(timestamp: t0, gnssQuality: GnssQuality.good));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(seconds: 1)), gnssQuality: GnssQuality.unavailable));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(seconds: 2)), gnssQuality: GnssQuality.good));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.gnssLost).length, 1);
      expect(events.where((e) => e.type == DetectedEventType.gnssRecovered).length, 1);
    });

    test('altitude significant change end to end', () async {
      controller.add(snap(timestamp: t0, altitudeTrend: AltitudeTrend.stable));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(seconds: 1)), altitudeTrend: AltitudeTrend.rising));
      await pump();

      expect(events.where((e) => e.type == DetectedEventType.altitudeRisingSignificant).length, 1);
    });

    test('NaN/infinite G readings never produce an event (§40)', () async {
      controller.add(snap(timestamp: t0, longitudinalG: double.nan));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 200)), longitudinalG: double.infinity));
      await pump();

      expect(events, isEmpty);
    });

    test('a null reading for a signal simply skips that check, without throwing', () async {
      controller.add(snap(timestamp: t0));
      await pump();
      expect(events, isEmpty);
    });

    test('simultaneous braking + cornering are both independently detected from the same episode (§39/§70)', () async {
      controller.add(snap(timestamp: t0, longitudinalG: -0.6, lateralG: 0.6));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 250)), longitudinalG: -0.6, lateralG: 0.6));
      await pump();

      expect(events.any((e) => e.type == DetectedEventType.hardBraking), isTrue);
      expect(events.any((e) => e.type == DetectedEventType.hardCorneringRight), isTrue);
    });

    test('every DetectedEvent carries the full TelemetrySnapshot it was confirmed from (§24)', () async {
      controller.add(snap(timestamp: t0, longitudinalG: 0.6, altitudeMeters: 250));
      await pump();
      controller.add(snap(timestamp: t0.add(const Duration(milliseconds: 200)), longitudinalG: 0.6, altitudeMeters: 250));
      await pump();

      final event = events.single;
      expect(event.snapshot.altitudeMeters, 250);
    });
  });
}
