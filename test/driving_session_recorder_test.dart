import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

void main() {
  late Directory dir;
  late StreamController<TelemetrySnapshot> controller;
  late DrivingSessionRecorder recorder;

  final t0 = DateTime(2026, 1, 1, 12);

  TelemetrySnapshot snapshot({
    required DateTime timestamp,
    double? latitude,
    double? longitude,
    double? speedKmh,
    double? altitudeMeters,
    double? headingDegrees,
    double? longitudinalG,
    double? lateralG,
    double? gForceMagnitude,
    GnssQuality gnssQuality = GnssQuality.good,
    AltitudeTrend altitudeTrend = AltitudeTrend.stable,
  }) {
    return TelemetrySnapshot(
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      speedKmh: speedKmh,
      altitudeMeters: altitudeMeters,
      headingDegrees: headingDegrees,
      longitudinalG: longitudinalG,
      lateralG: lateralG,
      gForceMagnitude: gForceMagnitude,
      gnssQuality: gnssQuality,
      altitudeTrend: altitudeTrend,
    );
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('driving_session_recorder_test');
    // Hive.close() (in tearDown) doesn't unregister adapters, so a guard is
    // needed once this setUp runs for a second test in the same file.
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
    }
    Hive.init(dir.path);
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    // deleteDrivingSession also purges dashcam data (Fase 15) — this box
    // must exist even though nothing in this file writes to it.
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);

    controller = StreamController<TelemetrySnapshot>.broadcast();
    recorder = DrivingSessionRecorder(controller.stream);
  });

  tearDown(() async {
    // A couple of the recorder's own writes are deliberately fire-and-forget
    // (see its own doc) — give any still-pending one a chance to settle
    // before the box they write to is closed out from under them.
    await Future<void>.delayed(Duration.zero);
    await controller.close();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('no session is active initially', () {
    expect(recorder.isRecording, isFalse);
    expect(recorder.activeSession, isNull);
  });

  test('startSession creates and immediately persists a session', () {
    final session = recorder.startSession();
    expect(recorder.isRecording, isTrue);
    expect(recorder.activeSession, session);
    expect(session.isActive, isTrue);

    final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
    expect(box.get(session.id), isNotNull);
  });

  test('starting a session while one is already active is a no-op, returns the same session', () {
    final first = recorder.startSession();
    final second = recorder.startSession();
    expect(identical(first, second), isTrue);
  });

  test('stopping with no active session is a safe no-op', () async {
    await recorder.stopSession(); // must not throw.
    expect(recorder.isRecording, isFalse);
  });

  test(
    'session ids stay unique across a tight start/stop loop (Fase 14 §8/§18 — regression for a real, '
    'reproducible id collision under coarse platform clock resolution)',
    () async {
      final ids = <String>{};
      for (var i = 0; i < 50; i++) {
        final session = recorder.startSession();
        expect(ids.add(session.id), isTrue, reason: 'duplicate id generated: ${session.id}');
        await recorder.stopSession();
      }
      expect(ids, hasLength(50));
    },
  );

  test('accumulates distance between consecutive GPS fixes (haversine)', () async {
    recorder.startSession();
    controller.add(snapshot(timestamp: t0, latitude: 0, longitude: 0));
    await Future<void>.delayed(Duration.zero);
    // Roughly 111km per degree of latitude at the equator, spread over 30
    // minutes so the implied speed (~220 km/h) stays under the GPS-jump
    // plausibility ceiling this recorder now applies (see the dedicated
    // outlier-rejection test group below) — a real driving scenario would
    // never need such a wide gap for a 111km segment, this is purely to
    // keep this specific test's synthetic distance-formula check honest
    // without also tripping the (correct, intentional) jump rejection.
    controller.add(snapshot(timestamp: t0.add(const Duration(minutes: 30)), latitude: 1, longitude: 0));
    await Future<void>.delayed(Duration.zero);

    final session = recorder.activeSession!;
    expect(session.distanceMeters, greaterThan(100000));
    expect(session.distanceMeters, lessThan(112000));
  });

  test('tracks max speed and does not regress it on a lower reading', () async {
    recorder.startSession();
    controller.add(snapshot(timestamp: t0, speedKmh: 40));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), speedKmh: 90));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 4)), speedKmh: 60));
    await Future<void>.delayed(Duration.zero);

    expect(recorder.activeSession!.maxSpeedKmh, 90);
  });

  test('tracks min and max altitude independently', () async {
    recorder.startSession();
    controller.add(snapshot(timestamp: t0, altitudeMeters: 800));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), altitudeMeters: 850));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 4)), altitudeMeters: 790));
    await Future<void>.delayed(Duration.zero);

    expect(recorder.activeSession!.maxAltitudeMeters, 850);
    expect(recorder.activeSession!.minAltitudeMeters, 790);
  });

  test('tracks max acceleration (positive longitudinal G) and max deceleration (negative) separately', () async {
    recorder.startSession();
    controller.add(snapshot(timestamp: t0, longitudinalG: 0.3));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), longitudinalG: -0.6));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 4)), longitudinalG: 0.5));
    await Future<void>.delayed(Duration.zero);

    expect(recorder.activeSession!.maxAccelerationG, 0.5);
    // Stored as a positive magnitude, not the signed -0.6 reading.
    expect(recorder.activeSession!.maxDecelerationG, 0.6);
  });

  test('decimates samples faster than the recording interval (1s) instead of recording every event', () async {
    recorder.startSession();
    controller.add(snapshot(timestamp: t0, speedKmh: 10));
    await Future<void>.delayed(Duration.zero);
    // 100ms later — well within the 1s decimation window, must be ignored.
    controller.add(snapshot(timestamp: t0.add(const Duration(milliseconds: 100)), speedKmh: 999));
    await Future<void>.delayed(Duration.zero);

    // The absurd 999 reading must NOT have been accepted as a new max.
    expect(recorder.activeSession!.maxSpeedKmh, 10);
  });

  test('stopSession finalizes endTime, computes average speed, and flushes remaining samples', () async {
    recorder.startSession();
    // ~11.1m apart (0.0001° of latitude at the equator) over 10s — a
    // plausible ~4 km/h implied speed, comfortably clear of the GPS-jump
    // ceiling, so this exercises the real distance/time avgSpeedKmh
    // methodology (Fase 11 §12) rather than being rejected as a jump.
    controller.add(snapshot(timestamp: t0, latitude: 0, longitude: 0, speedKmh: 20));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 10)), latitude: 0.0001, longitude: 0, speedKmh: 40));
    await Future<void>.delayed(Duration.zero);

    await recorder.stopSession();

    expect(recorder.isRecording, isFalse);
    final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
    final persisted = box.values.first;
    expect(persisted.endTime, isNotNull);
    // distance / elapsed time between the two accepted fixes, not a plain
    // average of the two instantaneous readings — see this recorder's own
    // doc for why.
    expect(persisted.avgSpeedKmh, isNotNull);
    expect(persisted.avgSpeedKmh, closeTo(4.0, 1.0));

    final samplesBox = Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
    final raw = await samplesBox.get(persisted.id) as List?;
    final samples = raw == null ? null : List<DrivingSessionSample>.from(raw);
    expect(samples, isNotNull);
    expect(samples!.length, 2);
  });

  test('flushes samples incrementally before stopSession — a crash mid-session would not lose everything', () async {
    recorder.startSession();
    final session = recorder.activeSession!;
    var t = t0;
    for (var i = 0; i < 11; i++) {
      controller.add(snapshot(timestamp: t, speedKmh: i.toDouble()));
      await Future<void>.delayed(Duration.zero);
      t = t.add(const Duration(seconds: 2));
    }

    // The flush itself is fire-and-forget (see the recorder's own doc) and
    // is a multi-step async Hive read-then-write — give it a real chance to
    // finish rather than just one microtask turn.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 11 samples with a flush-every-10 policy must have already written at
    // least the first 10 to the samples box, without calling stopSession.
    final samplesBox = Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
    final raw = await samplesBox.get(session.id) as List?;
    final samples = raw == null ? null : List<DrivingSessionSample>.from(raw);
    expect(samples, isNotNull);
    expect(samples!.length, greaterThanOrEqualTo(10));
  });

  group('GPS-jump protection (Fase 11 §11)', () {
    test('a physically-impossible jump is excluded from the distance total', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, latitude: 0, longitude: 0));
      await Future<void>.delayed(Duration.zero);
      // 1 degree of latitude (~111km) in 2 seconds — tens of thousands of
      // km/h, far beyond anything a road vehicle (or the plausibility
      // ceiling this recorder reuses from the telemetry engine) allows.
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), latitude: 1, longitude: 0));
      await Future<void>.delayed(Duration.zero);

      expect(recorder.activeSession!.distanceMeters, 0);
    });

    test('a rejected jump does not become the new reference point — the next plausible fix is still measured from the last good one', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, latitude: 0, longitude: 0));
      await Future<void>.delayed(Duration.zero);
      // Rejected jump.
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), latitude: 1, longitude: 0));
      await Future<void>.delayed(Duration.zero);
      // A small, plausible move from the ORIGINAL (0,0) point.
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 12)), latitude: 0.0001, longitude: 0));
      await Future<void>.delayed(Duration.zero);

      // ~11m, not ~111km and not 0 — confirms the third fix was compared
      // against the last *accepted* point, not the rejected one.
      expect(recorder.activeSession!.distanceMeters, greaterThan(5));
      expect(recorder.activeSession!.distanceMeters, lessThan(100));
    });

    test('an ordinary, plausible movement is never rejected', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, latitude: 0, longitude: 0));
      await Future<void>.delayed(Duration.zero);
      // ~11m over 2s ≈ 20 km/h — perfectly ordinary.
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), latitude: 0.0001, longitude: 0));
      await Future<void>.delayed(Duration.zero);

      expect(recorder.activeSession!.distanceMeters, greaterThan(5));
    });
  });

  group('altitude gain/loss (Fase 11 §15) — reuses TelemetryEngine.altitudeTrend', () {
    test('accumulates gain only while the trend reports rising', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, altitudeMeters: 100, altitudeTrend: AltitudeTrend.stable));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), altitudeMeters: 105, altitudeTrend: AltitudeTrend.rising));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 4)), altitudeMeters: 110, altitudeTrend: AltitudeTrend.rising));
      await Future<void>.delayed(Duration.zero);

      expect(recorder.activeSession!.altitudeGainMeters, closeTo(10, 0.01));
      expect(recorder.activeSession!.altitudeLossMeters, 0);
    });

    test('a stable trend contributes nothing, even if the raw value drifts slightly', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, altitudeMeters: 100, altitudeTrend: AltitudeTrend.stable));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), altitudeMeters: 100.2, altitudeTrend: AltitudeTrend.stable));
      await Future<void>.delayed(Duration.zero);

      expect(recorder.activeSession!.altitudeGainMeters, 0);
      expect(recorder.activeSession!.altitudeLossMeters, 0);
    });

    test('accumulates loss only while the trend reports falling', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, altitudeMeters: 110, altitudeTrend: AltitudeTrend.stable));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), altitudeMeters: 105, altitudeTrend: AltitudeTrend.falling));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 4)), altitudeMeters: 100, altitudeTrend: AltitudeTrend.falling));
      await Future<void>.delayed(Duration.zero);

      expect(recorder.activeSession!.altitudeLossMeters, closeTo(10, 0.01));
      expect(recorder.activeSession!.altitudeGainMeters, 0);
    });
  });

  group('initial/final fields (Fase 11 §5)', () {
    test('captures the first valid reading as initial and keeps updating final on every sample', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, latitude: 10, longitude: 20, altitudeMeters: 500, headingDegrees: 90));
      await Future<void>.delayed(Duration.zero);
      controller.add(
        snapshot(timestamp: t0.add(const Duration(seconds: 2)), latitude: 10.001, longitude: 20.001, altitudeMeters: 520, headingDegrees: 180),
      );
      await Future<void>.delayed(Duration.zero);

      final session = recorder.activeSession!;
      expect(session.initialLatitude, 10);
      expect(session.initialLongitude, 20);
      expect(session.initialAltitudeMeters, 500);
      expect(session.initialHeadingDegrees, 90);
      expect(session.finalLatitude, 10.001);
      expect(session.finalLongitude, 20.001);
      expect(session.finalAltitudeMeters, 520);
      expect(session.finalHeadingDegrees, 180);
    });
  });

  group('max lateral G / max resultant G (Fase 11 §16)', () {
    test('tracks the largest magnitude of lateral G regardless of direction', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, lateralG: 0.2));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), lateralG: -0.7));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 4)), lateralG: 0.5));
      await Future<void>.delayed(Duration.zero);

      expect(recorder.activeSession!.maxLateralG, closeTo(0.7, 0.001));
    });

    test('tracks the largest resultant (orientation-independent) G', () async {
      recorder.startSession();
      controller.add(snapshot(timestamp: t0, gForceMagnitude: 1.02));
      await Future<void>.delayed(Duration.zero);
      controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), gForceMagnitude: 1.8));
      await Future<void>.delayed(Duration.zero);

      expect(recorder.activeSession!.maxGForceMagnitude, 1.8);
    });
  });

  test('averages GnssQuality across samples and sampleCount tracks how many were recorded', () async {
    recorder.startSession();
    controller.add(snapshot(timestamp: t0, gnssQuality: GnssQuality.excellent));
    await Future<void>.delayed(Duration.zero);
    controller.add(snapshot(timestamp: t0.add(const Duration(seconds: 2)), gnssQuality: GnssQuality.weak));
    await Future<void>.delayed(Duration.zero);

    final session = recorder.activeSession!;
    // excellent=4, weak=1 -> average index 2.5 -> rounds to "good" (index 3
    // rounds from 2.5 per Dart's round-half-up).
    expect(session.avgGnssQualityIndex, closeTo(2.5, 0.001));
    expect(session.sampleCount, 2);
  });

  // Fase 13: hysteresis/minimum-duration/cooldown detection itself moved out
  // of this class entirely, into `EventDetectionEngine` (its own dedicated
  // test file covers that state machine exhaustively). What remains this
  // class's own responsibility — and what this group now tests — is purely
  // the recorder/session integration boundary: given an already-confirmed
  // `DetectedEvent`, does it get correctly translated and attached to
  // whichever session is active, and correctly ignored when none is.
  group('recordDetectedEvent (Fase 13 §33) — session/event integration boundary', () {
    DetectedEvent detected(
      DetectedEventType type, {
      double? value,
      Duration? duration,
      EventSeverity severity = EventSeverity.warning,
      TelemetrySnapshot? snapshot,
    }) {
      return DetectedEvent(
        type: type,
        timestamp: t0,
        severity: severity,
        snapshot: snapshot ?? TelemetrySnapshot(timestamp: t0, longitudinalG: -0.6, latitude: 1, longitude: 2, speedKmh: 40, altitudeMeters: 300, lateralG: 0.1),
        value: value,
        duration: duration,
      );
    }

    test('a no-op when no session is active — never throws, never invents a session', () {
      recorder.recordDetectedEvent(detected(DetectedEventType.hardBraking));
      expect(recorder.activeSession, isNull);
    });

    test('appends a translated DrivingSessionEvent to the active session and persists it', () async {
      recorder.startSession();
      recorder.recordDetectedEvent(detected(DetectedEventType.hardBraking, value: -0.6, duration: const Duration(milliseconds: 150), severity: EventSeverity.high));
      await Future<void>.delayed(Duration.zero);

      final events = recorder.activeSession!.events;
      expect(events.length, 1);
      final event = events.single;
      expect(event.type, DrivingSessionEventType.hardBraking);
      expect(event.magnitude, -0.6);
      expect(event.durationMs, 150);
      expect(event.severity, EventSeverity.high);
      expect(event.id, isNotNull);
      expect(event.latitude, 1);
      expect(event.longitude, 2);
      expect(event.speedKmh, 40);
      expect(event.altitudeMeters, 300);
      expect(event.longitudinalG, -0.6);
      expect(event.lateralG, 0.1);

      final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
      expect(box.get(recorder.activeSession!.id)!.events.length, 1);
    });

    test('every DetectedEventType maps to a distinct DrivingSessionEventType with no invented/missing case', () {
      final mapped = DetectedEventType.values.map(detectedEventTypeToSessionEventType).toSet();
      expect(mapped.length, DetectedEventType.values.length);
    });

    test('appending does not reject a second, distinct event in the same session', () async {
      recorder.startSession();
      recorder.recordDetectedEvent(detected(DetectedEventType.hardBraking));
      recorder.recordDetectedEvent(detected(DetectedEventType.hardCorneringRight));
      await Future<void>.delayed(Duration.zero);

      final types = recorder.activeSession!.events.map((e) => e.type).toSet();
      expect(types, {DrivingSessionEventType.hardBraking, DrivingSessionEventType.hardCorneringRight});
    });

    test('an event recorded after stopSession is not silently attached to the now-finished session', () async {
      recorder.startSession();
      final finished = recorder.activeSession!;
      await recorder.stopSession();
      recorder.recordDetectedEvent(detected(DetectedEventType.stopped));
      expect(finished.events, isEmpty);
    });
  });

  test('currentSpeedKmh and currentGnssQuality update live, on every snapshot, not just decimated ones', () async {
    recorder.startSession();
    controller.add(snapshot(timestamp: t0, speedKmh: 10, gnssQuality: GnssQuality.moderate));
    await Future<void>.delayed(Duration.zero);
    // Well within the 1s decimation window — the decimated stats (e.g.
    // maxSpeedKmh) must ignore this, but the *live* fields must still
    // reflect it immediately.
    controller.add(snapshot(timestamp: t0.add(const Duration(milliseconds: 50)), speedKmh: 55, gnssQuality: GnssQuality.excellent));
    await Future<void>.delayed(Duration.zero);

    expect(recorder.currentSpeedKmh, 55);
    expect(recorder.currentGnssQuality, GnssQuality.excellent);
    expect(recorder.activeSession!.maxSpeedKmh, 10);
  });

  test(
    'Fase 14 §10 (rebuild audit) — does not notify listeners for a snapshot that changes neither '
    'currentSpeedKmh nor currentGnssQuality (e.g. a g-force-triggered snapshot, which fires at '
    'near-accelerometer rate while recording but never touches either field)',
    () async {
      recorder.startSession();

      // Prime with one snapshot first: the very first sample of a session
      // always notifies twice regardless of this fix (the live-fields
      // change AND the decimation gate, which trivially passes the first
      // time since `_lastSampleAt` starts null) — consuming that here keeps
      // the assertions below isolated to the behavior actually under test.
      controller.add(snapshot(timestamp: t0, speedKmh: 40, gnssQuality: GnssQuality.good));
      await Future<void>.delayed(Duration.zero);

      var notifyCount = 0;
      recorder.addListener(() => notifyCount++);

      // Ten more snapshots carrying the exact same speed/gnssQuality as
      // above (as a g-force-only update would, since it leaves those two
      // fields unmapped/untouched by TelemetryEngine's own g-force pipeline)
      // — none of these should add another notification.
      for (var i = 0; i < 10; i++) {
        controller.add(
          snapshot(timestamp: t0.add(Duration(milliseconds: 10 * (i + 1))), speedKmh: 40, gnssQuality: GnssQuality.good),
        );
        await Future<void>.delayed(Duration.zero);
      }
      expect(notifyCount, 0, reason: 'no genuine change happened, so no notification should fire at all');

      // A genuine change to either field still notifies.
      controller.add(snapshot(timestamp: t0.add(const Duration(milliseconds: 200)), speedKmh: 41, gnssQuality: GnssQuality.good));
      await Future<void>.delayed(Duration.zero);
      expect(notifyCount, 1);
    },
  );

  test('DrivingSessionRecorderState reflects idle vs. recording', () async {
    expect(recorder.state, DrivingSessionRecorderState.idle);
    recorder.startSession();
    expect(recorder.state, DrivingSessionRecorderState.recording);
    await recorder.stopSession();
    expect(recorder.state, DrivingSessionRecorderState.idle);
  });

  group('dispose (Fase 14 §2/§18 — stream-leak audit)', () {
    test('cancels the snapshot subscription even if disposed mid-session, without calling stopSession', () {
      recorder.startSession();
      expect(controller.hasListener, isTrue);

      recorder.dispose();

      expect(controller.hasListener, isFalse);
      // dispose() is deliberately NOT the same as stopSession(): it must stay
      // synchronous, so it neither flips the session inactive nor sets an
      // endTime — the still-`isActive` record is left for
      // reclaimOrphanedSessions to close out on the next app start (see
      // DrivingSessionRecorder.dispose's own doc).
      final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
      final persisted = box.values.first;
      expect(persisted.isActive, isTrue);
    });

    test('disposing with no active session is a safe no-op (nothing to cancel)', () {
      expect(() => recorder.dispose(), returnsNormally);
    });
  });

  group('reclaimOrphanedSessions (Fase 11 §22-23 — robustness against a killed process)', () {
    test('finalizes a session left active by a previous run using its last flushed sample', () async {
      recorder.startSession();
      final orphan = recorder.activeSession!;
      var t = t0;
      for (var i = 0; i < 11; i++) {
        controller.add(snapshot(timestamp: t, speedKmh: i.toDouble()));
        await Future<void>.delayed(Duration.zero);
        t = t.add(const Duration(seconds: 2));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50)); // let the incremental flush land.
      // Simulate the process being killed: no stopSession(), the session
      // stays `isActive` in the box exactly like it would after a real kill.

      await DrivingSessionRecorder.reclaimOrphanedSessions();

      final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
      final reclaimed = box.get(orphan.id)!;
      expect(reclaimed.isActive, isFalse);
      expect(reclaimed.endTime, isNotNull);
      expect(reclaimed.sampleCount, greaterThanOrEqualTo(10));
    });

    test('a session with no flushed samples at all falls back to its own startTime (zero duration, not a crash)', () async {
      final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
      final orphan = DrivingSession(id: 'never-flushed', startTime: t0);
      await box.put(orphan.id, orphan);

      await DrivingSessionRecorder.reclaimOrphanedSessions();

      final reclaimed = box.get(orphan.id)!;
      expect(reclaimed.isActive, isFalse);
      expect(reclaimed.endTime, t0);
    });

    test('does not touch a genuinely completed session', () async {
      final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
      final completed = DrivingSession(id: 'done', startTime: t0, endTime: t0.add(const Duration(minutes: 5)));
      await box.put(completed.id, completed);

      await DrivingSessionRecorder.reclaimOrphanedSessions();

      expect(box.get(completed.id)!.endTime, t0.add(const Duration(minutes: 5)));
    });
  });

  group('deleteDrivingSession (Fase 11 §30)', () {
    test('removes both the summary and the samples for that session only', () async {
      recorder.startSession();
      final target = recorder.activeSession!;
      controller.add(snapshot(timestamp: t0, speedKmh: 10));
      await Future<void>.delayed(Duration.zero);
      await recorder.stopSession();

      final second = recorder.startSession();
      controller.add(snapshot(timestamp: t0.add(const Duration(minutes: 1)), speedKmh: 20));
      await Future<void>.delayed(Duration.zero);
      await recorder.stopSession();

      await deleteDrivingSession(target.id);

      final sessionsBox = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
      final samplesBox = Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
      expect(sessionsBox.get(target.id), isNull);
      expect(await samplesBox.get(target.id), isNull);
      // The other session is untouched.
      expect(sessionsBox.get(second.id), isNotNull);
      expect(await samplesBox.get(second.id), isNotNull);
    });
  });
}
