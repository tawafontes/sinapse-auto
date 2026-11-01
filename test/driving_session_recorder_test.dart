import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError, FlutterExceptionHandler;
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

  group('startSession(onCreated) — Fase 16.2-R4.3-R2.6.1 (§3, registration point before any listener)', () {
    test('runs exactly once for a NEW session, after it is the active session but BEFORE any listener is notified', () {
      final order = <String>[];
      String? activeAtCallback;
      String? activeAtListener;
      recorder.addListener(() {
        order.add('listener');
        activeAtListener = recorder.activeSession?.id;
      });

      final session = recorder.startSession(
        onCreated: (created) {
          order.add('onCreated');
          activeAtCallback = recorder.activeSession?.id;
          expect(identical(created, recorder.activeSession), isTrue, reason: 'the callback receives the session that is already the active one');
        },
      );

      expect(order, ['onCreated', 'listener'], reason: 'registration first, then the (possibly re-entrant) listeners');
      expect(activeAtCallback, session.id);
      expect(activeAtListener, session.id);
    });

    test('is NOT invoked for the already-active alias (no new session was created)', () {
      final first = recorder.startSession();
      var calls = 0;
      final second = recorder.startSession(onCreated: (_) => calls++);
      expect(identical(first, second), isTrue);
      expect(calls, 0, reason: 'nothing was created, so there is nothing to register');
    });

    test('a throwing callback still announces the created session, and the error reaches the caller', () {
      var notifications = 0;
      recorder.addListener(() => notifications++);
      expect(
        () => recorder.startSession(onCreated: (_) => throw StateError('registration failed')),
        throwsStateError,
      );
      expect(recorder.isRecording, isTrue, reason: 'the session exists');
      expect(notifications, 1, reason: 'and was still announced — never created-but-unannounced');
    });

    test('a listener that calls back into its owner sees the session already registered there', () {
      // The scenario the hook exists for: a synchronous listener reacting to the new session must find the owner's
      // own per-session bookkeeping already in place.
      String? registered;
      String? registeredWhenListenerRan;
      recorder.addListener(() => registeredWhenListenerRan = registered);
      final session = recorder.startSession(onCreated: (created) => registered = created.id);
      expect(registeredWhenListenerRan, session.id);
    });
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

  // Fase 16.2-R4.3-R2.6.4 — finalization failure/recovery at the recorder level
  // (the controller-level scenarios live in dashcam_session_controller_test.dart,
  // X58–X66). Real Hive failures: a box closed at the precise checkpoint, always
  // reopened in `finally`.
  group('Fase 16.2-R4.3-R2.6.4 — recorder finalization', () {
    const samplesBoxName = HiveBoxNames.drivingSessionSamples;
    const sessionsBoxName = HiveBoxNames.drivingSessions;

    Future<void> restoreBoxes() async {
      if (!Hive.isBoxOpen(samplesBoxName)) await Hive.openLazyBox(samplesBoxName);
      if (!Hive.isBoxOpen(sessionsBoxName)) await Hive.openBox<DrivingSession>(sessionsBoxName);
    }

    // Harness safety (runs before the file's own tearDown closes Hive): a test
    // that failed an assertion mid-finalization leaves an attempt in flight —
    // it would otherwise race that close and surface as a secondary async
    // error. Joining it (stopSession() returns the in-flight attempt) also
    // handles its error.
    tearDown(() async {
      await restoreBoxes();
      for (var i = 0; i < 3 && recorder.hasPendingFinalization; i++) {
        try {
          await recorder.stopSession();
        } catch (_) {}
      }
    });

    Future<void> feed(int n, DateTime from) async {
      for (var i = 0; i < n; i++) {
        controller.add(snapshot(timestamp: from.add(Duration(seconds: 2 * i)), speedKmh: 30.0 + i));
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('R264-copy — DrivingSession.detachedCopy() carries EVERY persisted field (compared through the generated adapter) and is unbound', () async {
      final original = DrivingSession(
        id: 'copy-probe',
        startTime: DateTime(2026, 1, 1, 8),
        endTime: DateTime(2026, 1, 1, 9),
        distanceMeters: 1.5,
        maxSpeedKmh: 2.5,
        avgSpeedKmh: 3.5,
        maxAltitudeMeters: 4.5,
        minAltitudeMeters: 5.5,
        maxAccelerationG: 6.5,
        maxDecelerationG: 7.5,
        initialAltitudeMeters: 8.5,
        finalAltitudeMeters: 9.5,
        initialHeadingDegrees: 10.5,
        finalHeadingDegrees: 11.5,
        maxLateralG: 12.5,
        maxGForceMagnitude: 13.5,
        sampleCount: 14,
        initialLatitude: 15.5,
        initialLongitude: 16.5,
        finalLatitude: 17.5,
        finalLongitude: 18.5,
        avgGnssQualityIndex: 19.5,
        altitudeGainMeters: 20.5,
        altitudeLossMeters: 21.5,
        events: [DrivingSessionEvent(type: DrivingSessionEventType.hardBraking, timestamp: DateTime(2026, 1, 1, 8, 30), magnitude: 0.7)],
        deletionPending: true, // Fase 16.2-R4.3-R2.6.7: field 25
        // Fase 16.2-R4.3-R2.6.11: fields 26–29
        dashcamTelemetryOutcomeCode: 2,
        dashcamTelemetryAcceptedCount: 22,
        dashcamTelemetryPersistedCount: 23,
        dashcamTelemetryRefusedCount: 24,
      );
      await Hive.box<DrivingSession>(sessionsBoxName).put(original.id, original);
      final copy = original.detachedCopy();

      List<Object?> written(DrivingSession s) {
        final writer = _RecordingBinaryWriter();
        DrivingSessionAdapter().write(writer, s);
        return writer.calls;
      }

      final originalCalls = written(original);
      expect(originalCalls.where((c) => c == #writeByte).length, 31, reason: 'setup: the adapter writes a field count + 30 field indexes');
      expect(written(copy), equals(originalCalls), reason: 'every field the adapter persists is carried by the copy');
      expect(copy.box, isNull, reason: 'the copy is not bound to any box');
      expect(identical(copy.events, original.events), isFalse, reason: 'its own events list');
    });

    test('R264-states — stop runs through finalizing → idle; a concurrent stop joins; a pending session is never handed out as an alias', () async {
      final a = recorder.startSession();
      await feed(2, t0);
      expect(recorder.state, DrivingSessionRecorderState.recording);
      final first = recorder.stopSession();
      final second = recorder.stopSession();
      expect(identical(first, second), isTrue, reason: 'one finalization attempt, joined');
      expect(recorder.state, DrivingSessionRecorderState.finalizing);
      expect(recorder.hasPendingFinalization, isTrue);
      expect(() => recorder.startSession(), throwsA(isA<SessionAdmissionRejected>()), reason: 'an ending session is never returned as an alias');
      await first;
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(recorder.activeSession, isNull);
      expect(a.endTime, isNotNull);
    });

    test('R264-samples — the samples box fails at the finalization: the session is kept (ended, pending); the retry after the box is back writes exactly its samples once and keeps the original endTime', () async {
      final a = recorder.startSession();
      await feed(3, t0);
      try {
        await Hive.lazyBox(samplesBoxName).close();
        await expectLater(recorder.stopSession(), throwsA(isA<HiveError>()));
        expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);
        expect(identical(recorder.activeSession, a), isTrue);
        expect(recorder.lastFinalizationError, isA<HiveError>());
        final firstEnd = a.endTime!;
        await feed(2, t0.add(const Duration(minutes: 5)));
        expect(a.sampleCount, 3, reason: 'nothing is collected after the end');
        expect(() => recorder.startSession(), throwsA(isA<SessionAdmissionRejected>()));
        await expectLater(recorder.stopSession(), throwsA(isA<HiveError>()), reason: 'still unavailable: the retry reports it again');

        await Hive.openLazyBox(samplesBoxName);
        await recorder.stopSession();
        expect(recorder.state, DrivingSessionRecorderState.idle);
        expect(a.endTime, firstEnd, reason: 'the endTime of the first attempt is kept');
        expect(((await Hive.lazyBox(samplesBoxName).get(a.id)) as List).length, 3, reason: 'exactly once — the failed attempts duplicated nothing');
      } finally {
        await restoreBoxes();
      }
    });

    test('R264-stale-box (variant E) — the sessions box is closed when the session record is saved, then reopened: the old instance stays bound to the closed box, and the retry still persists the session by its stable id', () async {
      final a = recorder.startSession();
      await feed(3, t0);
      try {
        await Hive.box<DrivingSession>(sessionsBoxName).close();
        await expectLater(recorder.stopSession(), throwsA(isA<HiveError>()));
        expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);
        final reopened = await Hive.openBox<DrivingSession>(sessionsBoxName);
        expect(identical(a.box, reopened), isFalse, reason: 'setup: hive 2.2.3 keeps the binding to the closed box');
        await expectLater(reopened.put(a.id, a), throwsA(isA<HiveError>()), reason: 'setup: that instance cannot be put into the reopened box either');

        await recorder.stopSession();
        expect(recorder.state, DrivingSessionRecorderState.idle);
        await Hive.box<DrivingSession>(sessionsBoxName).close();
        final stored = (await Hive.openBox<DrivingSession>(sessionsBoxName)).get(a.id);
        expect(stored?.endTime, isNotNull, reason: 'the record on disk is finalized');
        expect(stored?.sampleCount, 3);
        expect(((await Hive.lazyBox(samplesBoxName).get(a.id)) as List).length, 3);
      } finally {
        await restoreBoxes();
      }
    });

    test('R264-start-box — START with the sessions box unavailable fails with NOTHING created (no active session, no announcement, no subscription); a later START creates a new session', () async {
      var notifications = 0;
      recorder.addListener(() => notifications++);
      try {
        await Hive.box<DrivingSession>(sessionsBoxName).close();
        expect(() => recorder.startSession(), throwsA(isA<HiveError>()));
        expect(recorder.activeSession, isNull);
        expect(recorder.state, DrivingSessionRecorderState.idle);
        expect(notifications, 0);
        expect(controller.hasListener, isFalse, reason: 'no subscription was made');
        await Hive.openBox<DrivingSession>(sessionsBoxName);
        final s = recorder.startSession();
        expect(recorder.activeSession, same(s));
        await recorder.stopSession();
        expect(Hive.box<DrivingSession>(sessionsBoxName).keys, [s.id]);
      } finally {
        await restoreBoxes();
      }
    });

    test('R264-onCreated — START fails after its durable put (onCreated throws): the session is real, announced, collecting and recorded; stopSession finalizes it', () async {
      Object? error;
      try {
        recorder.startSession(onCreated: (_) => throw StateError('registration failed'));
      } catch (e) {
        error = e;
      }
      expect(error, isA<StateError>());
      final s = recorder.activeSession;
      expect(s, isNotNull);
      expect(recorder.state, DrivingSessionRecorderState.recording);
      await feed(2, t0);
      expect(s!.sampleCount, 2);
      await Future<void>.delayed(Duration.zero);
      expect(Hive.box<DrivingSession>(sessionsBoxName).containsKey(s.id), isTrue);
      await recorder.stopSession();
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(Hive.box<DrivingSession>(sessionsBoxName).get(s.id)?.endTime, isNotNull);
    });
  });

  // Fase 16.2-R4.3-R2.6.5 — idempotent sample flush under an AMBIGUOUS Hive
  // write (independent review, P2). Real hive 2.2.3 failures, no mock of the
  // box: `LazyBox.putAll` writes the frame and updates the keystore, THEN asks
  // the compaction strategy and compacts. The strategy below is the probe — it
  // runs at exactly "write took effect, put has not returned" — and a DIRECTORY
  // pre-created at the `.hivec` path makes the real compaction fail
  // (PathAccessException on Windows). A write that fails BEFORE taking effect
  // uses a sample adapter that throws while serializing (inside `writeFrames`,
  // before any byte reaches the file). Everything is restored in tearDown.
  group('Fase 16.2-R4.3-R2.6.5 — idempotent sample flush under ambiguous Hive write', () {
    const samplesBoxName = HiveBoxNames.drivingSessionSamples;
    const sessionsBoxName = HiveBoxNames.drivingSessions;

    /// Called synchronously inside the samples box's `putAll` after the frame
    /// was written; returning true makes the box compact right away.
    bool Function()? onSamplesPut;
    late _WriteFailingSampleAdapter failingAdapter;
    late FlutterExceptionHandler? originalOnError;
    final reported = <Object>[];
    var clock = t0;

    setUp(() async {
      onSamplesPut = null;
      clock = t0;
      reported.clear();
      originalOnError = FlutterError.onError;
      // The incremental flush reports its (non-fatal) failure through
      // FlutterError — captured here so a test can assert it was reported.
      FlutterError.onError = (details) => reported.add(details.exception);
      await Hive.lazyBox(samplesBoxName).close();
      await Hive.openLazyBox(samplesBoxName, compactionStrategy: (entries, deleted) => onSamplesPut?.call() ?? false);
      // One superseded frame, so a compaction the probe asks for has work to do.
      await Hive.lazyBox(samplesBoxName).put('unrelated', <DrivingSessionSample>[]);
      await Hive.lazyBox(samplesBoxName).put('unrelated', <DrivingSessionSample>[]);
      failingAdapter = _WriteFailingSampleAdapter();
      Hive.registerAdapter<DrivingSessionSample>(failingAdapter, override: true);
    });

    // Harness safety (before the file's tearDown closes Hive): hooks off, the
    // original adapter back, boxes open, the compaction obstacle removed, any
    // finalization left pending by a failed assertion settled (joining it also
    // handles its error), FlutterError restored.
    tearDown(() async {
      onSamplesPut = null;
      FlutterError.onError = originalOnError; // first: nothing below may leave it overridden
      Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
      final obstacle = Directory('${dir.path}/$samplesBoxName.hivec');
      if (obstacle.existsSync()) obstacle.deleteSync(recursive: true);
      if (!Hive.isBoxOpen(samplesBoxName)) await Hive.openLazyBox(samplesBoxName);
      if (!Hive.isBoxOpen(sessionsBoxName)) await Hive.openBox<DrivingSession>(sessionsBoxName);
      for (var i = 0; i < 3 && recorder.hasPendingFinalization; i++) {
        try {
          await recorder.stopSession();
        } catch (_) {}
      }
    });

    void armCompactionFailure() => Directory('${dir.path}/$samplesBoxName.hivec').createSync();

    /// The next samples `put` writes, then fails in compaction (ambiguous).
    void nextSamplesPutIsAmbiguous() {
      armCompactionFailure();
      onSamplesPut = () {
        onSamplesPut = null;
        return true;
      };
    }

    Future<void> feed(List<double> speeds) async {
      for (final speed in speeds) {
        clock = clock.add(const Duration(seconds: 2));
        controller.add(snapshot(timestamp: clock, speedKmh: speed));
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<List<DrivingSessionSample>?> storedSamples(String id) async =>
        ((await Hive.lazyBox(samplesBoxName).get(id)) as List?)?.cast<DrivingSessionSample>();

    Future<List<double?>?> storedSpeeds(String id) async => (await storedSamples(id))?.map((s) => s.speedKmh).toList();

    Future<Object?> errorOf(Future<void> f) async {
      try {
        await f.timeout(const Duration(seconds: 10));
        return null;
      } catch (e) {
        return e;
      }
    }

    Future<void> waitUntil(bool Function() condition, String label) async {
      for (var i = 0; i < 500; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('waitUntil: "$label" never became true');
    }

    List<double> speeds(int from, int count) => [for (var i = 0; i < count; i++) (from + i).toDouble()];

    test('X70 — put fails BEFORE its write takes effect (serialization, inside writeFrames): nothing stored, the batch stays pending, the retry stores it exactly once', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 10)); // incremental checkpoint: 40..49 stored
      await waitUntil(() => recorder.pendingSampleCountForTest == 0, 'the incremental checkpoint landed');
      await feed(speeds(50, 3));
      failingAdapter.armed = true;
      final error = await errorOf(recorder.stopSession());
      expect(error, isNotNull, reason: 'the failure reaches the caller');
      expect(await storedSpeeds(s.id), speeds(40, 10), reason: 'the failed put stored nothing');
      expect(recorder.pendingSampleCountForTest, 3, reason: 'the batch is kept, not cleared');
      expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);

      failingAdapter.armed = false;
      await recorder.stopSession();
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(await storedSpeeds(s.id), speeds(40, 13), reason: 'every accepted sample exactly once, in order');
      expect(s.sampleCount, 13);
    });

    test('X71 — put WRITES then fails (real compaction failure after the frame): the retry recognises the batch already stored and does not append it again', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 3));
      nextSamplesPutIsAmbiguous();
      final error = await errorOf(recorder.stopSession());
      expect(error, isNotNull, reason: 'the put reported a failure (whatever its type: ${error.runtimeType})');
      expect(await storedSpeeds(s.id), [40, 41, 42], reason: 'setup: the write took effect although put threw');
      expect(recorder.pendingSampleCountForTest, 3, reason: 'no speculative clearing on an ambiguous result');
      expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);

      await recorder.stopSession();
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(await storedSpeeds(s.id), [40, 41, 42], reason: 'pre-fix: 40,41,42,40,41,42');
      expect(s.sampleCount, 3);
      expect(recorder.pendingSampleCountForTest, 0);
    });

    test('X72 — checkpointed samples, an ambiguous final flush, then the session record fails (sessions box closed and reopened): every retry keeps the same identity and the samples exactly once', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 10));
      await waitUntil(() => recorder.pendingSampleCountForTest == 0, 'the incremental checkpoint landed');
      await feed(speeds(50, 3));
      nextSamplesPutIsAmbiguous();
      expect(await errorOf(recorder.stopSession()), isNotNull);
      final firstEnd = s.endTime!;
      expect(await storedSpeeds(s.id), speeds(40, 13), reason: 'setup: the final batch took effect');

      await Hive.box<DrivingSession>(sessionsBoxName).close();
      expect(await errorOf(recorder.stopSession()), isA<HiveError>(), reason: 'now the session record cannot be written');
      expect(await storedSpeeds(s.id), speeds(40, 13), reason: 'the samples were reconciled, not appended again');
      expect(identical(recorder.activeSession, s), isTrue);

      await Hive.openBox<DrivingSession>(sessionsBoxName);
      await recorder.stopSession();
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(await storedSpeeds(s.id), speeds(40, 13));
      await Hive.box<DrivingSession>(sessionsBoxName).close();
      final record = (await Hive.openBox<DrivingSession>(sessionsBoxName)).get(s.id);
      // Hive stores DateTime at millisecond precision.
      expect(record?.endTime?.millisecondsSinceEpoch, firstEnd.millisecondsSinceEpoch, reason: 'the same session, its original endTime');
      expect(record?.sampleCount, 13);
    });

    test('X73 — an incremental flush whose put is ambiguous is still in flight when STOP starts: the STOP flush runs after it, reconciles, and stores each sample once', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 9));
      armCompactionFailure();
      Future<void>? stop;
      onSamplesPut = () {
        onSamplesPut = null;
        stop = recorder.stopSession(); // STOP inside the incremental put: its frame is written, put not returned
        return true; // ... and that put then fails in compaction
      };
      await feed([49]); // the 10th sample starts the incremental flush
      await waitUntil(() => stop != null, 'the incremental put reached the probe');
      expect(await errorOf(stop!), isNull, reason: 'STOP reconciled what the ambiguous flush wrote');
      expect(await storedSpeeds(s.id), speeds(40, 10), reason: 'pre-fix: the same 10 samples twice (20)');
      expect(s.sampleCount, 10);
      expect(reported, hasLength(1), reason: 'the incremental failure was reported, not swallowed');
    });

    test('X74 — two concurrent retries of the same finalization, whose own put is ambiguous: one attempt; the next concurrent pair finishes it; each sample once', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 3));
      failingAdapter.armed = true;
      expect(await errorOf(recorder.stopSession()), isNotNull, reason: 'setup: nothing written');
      failingAdapter.armed = false;

      nextSamplesPutIsAmbiguous();
      final r1 = recorder.stopSession();
      final r2 = recorder.stopSession();
      expect(identical(r1, r2), isTrue, reason: 'a concurrent retry joins the attempt in flight');
      expect(await errorOf(r1), isNotNull, reason: 'that attempt wrote, then failed');
      expect(await storedSpeeds(s.id), [40, 41, 42]);

      final r3 = recorder.stopSession();
      final r4 = recorder.stopSession();
      expect(identical(r3, r4), isTrue);
      await r3;
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(await storedSpeeds(s.id), [40, 41, 42]);
    });

    test('X75 — identical readings (a parked car: same values every second) are distinct samples: the reconciliation never drops one of them', () async {
      final s = recorder.startSession();
      await feed(List.filled(10, 40.0));
      await waitUntil(() => recorder.pendingSampleCountForTest == 0, 'the incremental checkpoint landed');
      await feed(List.filled(3, 40.0));
      nextSamplesPutIsAmbiguous();
      final firstError = await errorOf(recorder.stopSession());
      if (recorder.hasPendingFinalization) await recorder.stopSession();
      // The data first: a reconciliation that mistakes identical readings for
      // already-stored ones shows up here as missing samples.
      final stored = (await storedSamples(s.id))!;
      expect(stored, hasLength(13), reason: 'no identical-looking sample dropped, none duplicated');
      expect(stored.map((x) => x.speedKmh).toSet(), {40.0}, reason: 'setup: identical values');
      expect(stored.map((x) => x.timestamp).toSet(), hasLength(13), reason: 'each accepted sample present once');
      expect(s.sampleCount, 13);
      expect(firstError, isNotNull, reason: 'setup: the reconciliation really ran after an ambiguous write');
    });

    test('X76 — the reconciliation read fails after an ambiguous write: nothing is cleared, written or invented, and no new session starts; once readable the retry finishes with the samples once', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 3));
      nextSamplesPutIsAmbiguous();
      expect(await errorOf(recorder.stopSession()), isNotNull);
      await Hive.lazyBox(samplesBoxName).close(); // the read the retry needs fails

      expect(await errorOf(recorder.stopSession()), isNotNull, reason: 'the retry cannot reconcile');
      expect(recorder.pendingSampleCountForTest, 3, reason: 'no speculative clearing');
      expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);
      expect(() => recorder.startSession(), throwsA(isA<SessionAdmissionRejected>()), reason: 'no new session');

      await Hive.openLazyBox(samplesBoxName);
      expect(await storedSpeeds(s.id), [40, 41, 42], reason: 'nothing written or invented by the failed retry');
      await recorder.stopSession();
      expect(await storedSpeeds(s.id), [40, 41, 42]);
      expect(recorder.state, DrivingSessionRecorderState.idle);
    });

    test('X76-inconsistent — a stored list that cannot be this session\'s prefix (shorter than what is known stored) is not repaired: the finalization fails with a diagnostic and nothing is cleared or written', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 10));
      await waitUntil(() => recorder.pendingSampleCountForTest == 0, 'the incremental checkpoint landed');
      await feed(speeds(50, 3));
      final truncated = (await storedSamples(s.id))!.take(5).toList();
      await Hive.lazyBox(samplesBoxName).put(s.id, truncated); // external damage

      final error = await errorOf(recorder.stopSession());
      expect(error, isA<StateError>().having((e) => e.message, 'message', contains('cannot be reconciled')));
      expect(recorder.pendingSampleCountForTest, 3, reason: 'nothing cleared');
      expect(await storedSpeeds(s.id), speeds(40, 5), reason: 'nothing written over it');
      expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);
      expect(() => recorder.startSession(), throwsA(isA<SessionAdmissionRejected>()));
    });

    test('X78 — samples accepted WHILE a flush is inside its put (compaction running) are not lost: each accepted sample is stored once, in order', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 9));
      onSamplesPut = () {
        onSamplesPut = null;
        for (var i = 0; i < 10; i++) {
          clock = clock.add(const Duration(seconds: 2));
          controller.add(snapshot(timestamp: clock, speedKmh: 100.0 + i)); // delivered while compaction runs
        }
        return true; // real compaction, succeeds
      };
      await feed([49]);
      await waitUntil(() => s.sampleCount == 20, 'the ten samples were accepted');
      await recorder.stopSession();
      expect(await storedSpeeds(s.id), [...speeds(40, 10), ...speeds(100, 10)], reason: 'pre-fix: 100..109 lost');
      expect(s.sampleCount, 20);
    });

    test('X79 — an ambiguous INCREMENTAL flush (no STOP): reported, its batch kept; the next incremental flush reconciles and appends only new samples', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 9));
      nextSamplesPutIsAmbiguous();
      await feed([49]);
      await waitUntil(() => reported.isNotEmpty, 'the incremental failure was reported');
      expect(await storedSpeeds(s.id), speeds(40, 10), reason: 'setup: written although put threw');
      expect(recorder.pendingSampleCountForTest, 10, reason: 'kept until reconciled');
      await feed(speeds(60, 10)); // next incremental flush
      await waitUntil(() => recorder.pendingSampleCountForTest == 0, 'the next checkpoint reconciled and landed');
      expect(await storedSpeeds(s.id), [...speeds(40, 10), ...speeds(60, 10)]);
      await recorder.stopSession();
      expect(await storedSpeeds(s.id), [...speeds(40, 10), ...speeds(60, 10)]);
      expect(s.sampleCount, 20);
      expect(reported, hasLength(1));
    });
  });

  // Fase 16.2-R4.3-R2.6.6 — session deletion safety (D1 of the R2.6.5
  // pre-audit, reproduced before the fix in
  // scratchpad/fase16_2_r4_3_r2_6_6/01_prefix_repro): deleteDrivingSession — the
  // history's deletion — refuses a session a recorder still controls
  // (recording, finalizing, finalizationFailed) before anything is removed.
  // Real hive 2.2.3 failures, as in the R2.6.5 group: a sample adapter that
  // throws while serializing (a put that fails before taking effect), and the
  // samples box's compaction-strategy hook, which runs at "frame written, put
  // not returned". The history-screen flow lives in
  // session_history_screen_test.dart, the controller-level STOP/retry in
  // dashcam_session_controller_test.dart (X92).
  group('Fase 16.2-R4.3-R2.6.6 — session deletion safety', () {
    const samplesBoxName = HiveBoxNames.drivingSessionSamples;
    const sessionsBoxName = HiveBoxNames.drivingSessions;

    /// Called synchronously inside the samples box's `putAll` after the frame
    /// was written; returning true makes the box compact right away.
    bool Function()? onSamplesPut;
    late _WriteFailingSampleAdapter failingAdapter;
    late FlutterExceptionHandler? originalOnError;
    final reported = <Object>[];
    final gates = <Completer<void>>[];
    final localRecorders = <DrivingSessionRecorder>[];
    var clock = t0;

    Future<void> openSamplesBoxWithHook() async {
      await Hive.openLazyBox(samplesBoxName, compactionStrategy: (entries, deleted) => onSamplesPut?.call() ?? false);
      // One superseded frame, so a compaction the hook asks for has work to do.
      await Hive.lazyBox(samplesBoxName).put('unrelated', <DrivingSessionSample>[]);
      await Hive.lazyBox(samplesBoxName).put('unrelated', <DrivingSessionSample>[]);
    }

    setUp(() async {
      onSamplesPut = null;
      clock = t0;
      reported.clear();
      originalOnError = FlutterError.onError;
      // A failed incremental flush is reported through FlutterError (R2.6.5).
      FlutterError.onError = (details) => reported.add(details.exception);
      await Hive.lazyBox(samplesBoxName).close();
      await openSamplesBoxWithHook();
      failingAdapter = _WriteFailingSampleAdapter();
      Hive.registerAdapter<DrivingSessionSample>(failingAdapter, override: true);
    });

    // Harness safety, before the file's tearDown closes Hive: hooks off, the
    // original adapter back, the obstacle removed, boxes open, every gate
    // released, every finalization left pending by a failed assertion joined.
    tearDown(() async {
      onSamplesPut = null;
      FlutterError.onError = originalOnError;
      Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
      final obstacle = Directory('${dir.path}/$samplesBoxName.hivec');
      if (obstacle.existsSync()) obstacle.deleteSync(recursive: true);
      if (!Hive.isBoxOpen(samplesBoxName)) await Hive.openLazyBox(samplesBoxName);
      if (!Hive.isBoxOpen(sessionsBoxName)) await Hive.openBox<DrivingSession>(sessionsBoxName);
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      gates.clear();
      for (final r in [recorder, ...localRecorders]) {
        for (var i = 0; i < 3 && r.hasPendingFinalization; i++) {
          try {
            await r.stopSession();
          } catch (_) {}
        }
      }
      localRecorders.clear();
    });

    Future<void> feedInto(StreamController<TelemetrySnapshot> into, List<double> speeds) async {
      for (final speed in speeds) {
        clock = clock.add(const Duration(seconds: 2));
        into.add(snapshot(timestamp: clock, speedKmh: speed));
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<void> feed(List<double> speeds) => feedInto(controller, speeds);

    List<double> speeds(int from, int count) => [for (var i = 0; i < count; i++) (from + i).toDouble()];

    Future<List<double?>?> storedSpeeds(String id) async =>
        ((await Hive.lazyBox(samplesBoxName).get(id)) as List?)?.map((s) => (s as DrivingSessionSample).speedKmh).toList();

    Future<Object?> errorOf(Future<void> f) async {
      try {
        await f.timeout(const Duration(seconds: 10));
        return null;
      } catch (e) {
        return e;
      }
    }

    Future<void> waitUntil(bool Function() condition, String label) async {
      for (var i = 0; i < 500; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('waitUntil: "$label" never became true');
    }

    /// The record as stored ON DISK: the sessions box is reopened so its cache
    /// cannot answer. Only while no session in progress is bound to that box.
    Future<DrivingSession?> diskRecord(String id) async {
      await Hive.box<DrivingSession>(sessionsBoxName).close();
      return (await Hive.openBox<DrivingSession>(sessionsBoxName)).get(id);
    }

    /// Nothing of [id] is left: no record (cache, then disk) and no samples.
    Future<void> expectNothingLeft(String id, String when) async {
      expect(Hive.box<DrivingSession>(sessionsBoxName).containsKey(id), isFalse, reason: '$when: no record');
      expect(await storedSpeeds(id), isNull, reason: '$when: no samples');
      expect(await diskRecord(id), isNull, reason: '$when: no record on disk either');
    }

    /// A recorder over a single-subscription source whose cancel() waits for
    /// its gate: its stopSession() is held inside the finalization, before any
    /// write.
    ({DrivingSessionRecorder recorder, StreamController<TelemetrySnapshot> source, Completer<void> gate}) gatedRecorder() {
      final gate = Completer<void>();
      gates.add(gate);
      final source = StreamController<TelemetrySnapshot>(onCancel: () => gate.future);
      final r = DrivingSessionRecorder(source.stream);
      localRecorders.add(r);
      return (recorder: r, source: source, gate: gate);
    }

    test('X80 — RECORDING: the deletion is refused before anything is removed (record, checkpointed samples, binding); the session keeps recording and its finalization stores every sample; then the deletion is accepted and leaves nothing', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 10));
      await waitUntil(() => recorder.pendingSampleCountForTest == 0, 'the incremental checkpoint landed');
      await feed(speeds(50, 2));
      expect(DrivingSessionRecorder.controllingState(s.id), DrivingSessionRecorderState.recording);

      final error = await errorOf(deleteDrivingSession(s.id));
      expect(error, isA<SessionDeletionRejected>().having((e) => e.message, 'message', contains('recording')),
          reason: 'pre-fix: accepted — the record and samples of the session being recorded were removed');
      expect(Hive.box<DrivingSession>(sessionsBoxName).get(s.id), same(s), reason: 'the record is untouched');
      expect(s.box, isNotNull, reason: 'the recorder\'s instance is still bound (a deletion unbinds it)');
      expect(await storedSpeeds(s.id), speeds(40, 10), reason: 'the checkpointed samples are untouched');

      await feed([52]);
      expect(s.sampleCount, 13, reason: 'still recording');
      await recorder.stopSession();
      expect(await storedSpeeds(s.id), speeds(40, 13));
      expect(DrivingSessionRecorder.controllingState(s.id), isNull, reason: 'released once durably closed');
      await deleteDrivingSession(s.id);
      await expectNothingLeft(s.id, 'after the accepted deletion');
    });

    test('X81 — FINALIZING (held inside the finalization, before any write): the deletion is refused and removes nothing; the finalization then stores the record and every sample; then the deletion is accepted', () async {
      final g = gatedRecorder();
      final s = g.recorder.startSession();
      await feedInto(g.source, speeds(40, 3));
      await Hive.box<DrivingSession>(sessionsBoxName).flush();
      final stop = g.recorder.stopSession();
      expect(g.recorder.state, DrivingSessionRecorderState.finalizing);
      expect(DrivingSessionRecorder.controllingState(s.id), DrivingSessionRecorderState.finalizing);
      expect(Hive.box<DrivingSession>(sessionsBoxName).get(s.id)?.isActive, isFalse,
          reason: 'setup: the cached instance already reads as ended — what the history lists');

      final error = await errorOf(deleteDrivingSession(s.id));
      expect(error, isA<SessionDeletionRejected>().having((e) => e.message, 'message', contains('finalizing')),
          reason: 'pre-fix: accepted — the finalization then recreated the deleted session');
      expect(Hive.box<DrivingSession>(sessionsBoxName).get(s.id), same(s), reason: 'the record is untouched');
      expect(g.recorder.pendingSampleCountForTest, 3, reason: 'nothing written yet, nothing lost');

      g.gate.complete();
      await stop;
      expect(g.recorder.state, DrivingSessionRecorderState.idle);
      expect(await storedSpeeds(s.id), [40, 41, 42]);
      final disk = await diskRecord(s.id);
      expect(disk?.endTime, isNotNull);
      expect(disk?.sampleCount, 3);
      await deleteDrivingSession(s.id);
      await expectNothingLeft(s.id, 'after the accepted deletion');
    });

    test('X82 — FINALIZING at the exact instant its sample put has written the frame and not returned (compaction running): the deletion is refused; the session ends with its record matching its samples; the later deletion leaves no orphan record', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 3));
      String? stateAtDelete;
      Future<Object?>? deletion;
      onSamplesPut = () {
        onSamplesPut = null;
        stateAtDelete = DrivingSessionRecorder.controllingState(s.id)?.name;
        deletion = errorOf(deleteDrivingSession(s.id)); // observed at once: a refusal is not an unhandled error
        return true; // a real compaction runs (and succeeds)
      };
      await recorder.stopSession();
      expect(stateAtDelete, 'finalizing', reason: 'setup: the deletion ran inside the final put');
      expect(await deletion, isA<SessionDeletionRejected>(),
          reason: 'pre-fix: accepted — an ended record with sampleCount 3 and NO samples survived, also across a restart');
      expect(recorder.state, DrivingSessionRecorderState.idle);
      expect(await storedSpeeds(s.id), [40, 41, 42]);
      final disk = await diskRecord(s.id);
      expect(disk?.endTime, isNotNull);
      expect(disk?.sampleCount, 3, reason: 'the record matches its samples');
      await deleteDrivingSession(s.id);
      await expectNothingLeft(s.id, 'after the accepted deletion');
    });

    test('X83 — FINALIZATION FAILED with samples checkpointed: the deletion is refused and removes nothing; the retry then finalizes the SAME session (id, endTime, every sample once); START is admitted again; the deletion is accepted afterwards', () async {
      final s = recorder.startSession();
      await feed(speeds(40, 10));
      await waitUntil(() => recorder.pendingSampleCountForTest == 0, 'the incremental checkpoint landed');
      await feed(speeds(50, 3));
      failingAdapter.armed = true;
      expect(await errorOf(recorder.stopSession()), isNotNull, reason: 'setup: the final sample write failed');
      failingAdapter.armed = false;
      expect(recorder.state, DrivingSessionRecorderState.finalizationFailed);
      final firstEnd = s.endTime!;

      final error = await errorOf(deleteDrivingSession(s.id));
      expect(error, isA<SessionDeletionRejected>().having((e) => e.message, 'message', contains('finalizationFailed')));
      expect(Hive.box<DrivingSession>(sessionsBoxName).get(s.id), same(s), reason: 'the record is untouched');
      expect(await storedSpeeds(s.id), speeds(40, 10), reason: 'the checkpointed samples are untouched');
      expect(recorder.pendingSampleCountForTest, 3);

      await recorder.stopSession();
      expect(recorder.state, DrivingSessionRecorderState.idle,
          reason: 'pre-fix: every retry failed ("cannot be reconciled") and START stayed refused until the app restarted');
      expect(await storedSpeeds(s.id), speeds(40, 13), reason: 'every sample once, in order');
      final disk = await diskRecord(s.id);
      expect(disk?.id, s.id);
      // Hive stores DateTime at millisecond precision.
      expect(disk?.endTime?.millisecondsSinceEpoch, firstEnd.millisecondsSinceEpoch, reason: 'the endTime of the first attempt');
      expect(disk?.sampleCount, 13);

      final b = recorder.startSession();
      expect(b.id, isNot(s.id), reason: 'START is admitted again');
      await recorder.stopSession();
      await deleteDrivingSession(s.id);
      await expectNothingLeft(s.id, 'after the accepted deletion');
      expect(Hive.box<DrivingSession>(sessionsBoxName).containsKey(b.id), isTrue, reason: 'only that session was removed');
    });

    test('X84 — FINALIZATION FAILED with nothing stored: the deletion is refused; the retry stores the session; once deleted it never comes back (no resurrection)', () async {
      final s = recorder.startSession();
      await feed([40, 41, 42]);
      failingAdapter.armed = true;
      expect(await errorOf(recorder.stopSession()), isNotNull);
      failingAdapter.armed = false;
      expect(await storedSpeeds(s.id), isNull, reason: 'setup: nothing stored');
      final firstEnd = s.endTime!;

      expect(await errorOf(deleteDrivingSession(s.id)), isA<SessionDeletionRejected>(),
          reason: 'pre-fix: accepted, and the retry then recreated the deleted session (record and samples)');
      expect(Hive.box<DrivingSession>(sessionsBoxName).get(s.id), same(s));

      await recorder.stopSession();
      expect(await storedSpeeds(s.id), [40, 41, 42]);
      final disk = await diskRecord(s.id);
      expect(disk?.endTime?.millisecondsSinceEpoch, firstEnd.millisecondsSinceEpoch);
      expect(disk?.sampleCount, 3);

      await deleteDrivingSession(s.id);
      await recorder.stopSession(); // idle: nothing to finalize, nothing rewritten
      recorder.startSession();
      await feed([60]);
      await recorder.stopSession();
      await expectNothingLeft(s.id, 'after the deletion, a no-op stop and another session');
    });

    test('X85 — a fully finalized session is deleted normally, even while ANOTHER session records; the recording one stays protected', () async {
      final a = recorder.startSession();
      await feed([40, 41]);
      await recorder.stopSession();
      expect(DrivingSessionRecorder.controllingState(a.id), isNull);
      final b = recorder.startSession();
      await feed([50]);

      await deleteDrivingSession(a.id);
      expect(Hive.box<DrivingSession>(sessionsBoxName).containsKey(a.id), isFalse);
      expect(await storedSpeeds(a.id), isNull);
      expect(await errorOf(deleteDrivingSession(b.id)), isA<SessionDeletionRejected>(), reason: 'B is recording');
      expect(Hive.box<DrivingSession>(sessionsBoxName).get(b.id), same(b));
      await feed([51]);
      await recorder.stopSession();
      expect(await storedSpeeds(b.id), [50, 51]);
      await expectNothingLeft(a.id, 'A');
    });

    test('X86 — stress: deletions fired at every turn (and inside each sample put) while a STOP and its retries run — no failure, pre-write failure, ambiguous write, concurrent retries: each is refused while the session is controlled; at the release the record matches its samples; the earliest deletion observable after the release leaves nothing, and nothing comes back', () async {
      var refused = 0;
      var earliestDeletions = 0;
      var round = 0;
      // mode 0: no failure; 1: pre-write failure; 2: ambiguous write. n never a
      // multiple of 10: the final flush always has samples to write (so the
      // injected failure really happens), with and without an earlier
      // checkpoint. early: delete at the first instant the release is observable.
      for (final (mode, n, early) in [
        for (final mode in [0, 1, 2])
          for (final n in [3, 7, 11, 13])
            for (final early in [false, true]) (mode, n, early),
      ]) {
        round++;
        final expected = speeds(round * 100, n);
        if (mode == 2) {
          // A fresh box instance: hive stops compacting an instance after one failed compaction.
          await Hive.lazyBox(samplesBoxName).close();
          await openSamplesBoxWithHook();
        }
        final s = recorder.startSession();
        await feed(expected);
        // An incremental checkpoint of 10 landed when n >= 10.
        await waitUntil(() => recorder.pendingSampleCountForTest == n % 10, 'no incremental checkpoint in flight');

        final attempts = <Future<(DrivingSessionRecorderState?, Object?)>>[];
        void attempt() {
          final state = DrivingSessionRecorder.controllingState(s.id);
          attempts.add(errorOf(deleteDrivingSession(s.id)).then((e) => (state, e)));
        }

        Future<Object?>? earliest;
        void onControlChange() {
          if (early && earliest == null && DrivingSessionRecorder.controllingState(s.id) == null) {
            earliest = errorOf(deleteDrivingSession(s.id));
          }
        }

        var ambiguous = mode == 2;
        if (ambiguous) Directory('${dir.path}/$samplesBoxName.hivec').createSync();
        onSamplesPut = () {
          attempt(); // frame written, put not returned
          if (!ambiguous) return false;
          ambiguous = false;
          return true;
        };
        failingAdapter.armed = mode == 1;
        DrivingSessionRecorder.sessionControlChanges.addListener(onControlChange);
        try {
          Future<Object?> runWithAttempts(Future<void> f) async {
            var settled = false;
            Object? error;
            f.then<void>(
              (_) => settled = true,
              onError: (Object e) {
                error = e;
                settled = true;
              },
            );
            for (var turn = 0; !settled; turn++) {
              if (DrivingSessionRecorder.controllingState(s.id) != null) attempt();
              if (turn.isEven) {
                await Future<void>.value();
              } else {
                await Future<void>.delayed(Duration.zero);
              }
              if (turn > 20000) fail('round $round: the finalization never settled');
            }
            return error;
          }

          final first = await runWithAttempts(recorder.stopSession());
          expect(first != null, mode != 0, reason: 'round $round (mode $mode): setup — the first attempt failed exactly when a failure was injected');
          failingAdapter.armed = false;
          for (var retry = 0; recorder.hasPendingFinalization; retry++) {
            expect(retry, lessThan(3), reason: 'round $round: the retry finishes');
            final r1 = recorder.stopSession();
            if (round.isEven) expect(identical(recorder.stopSession(), r1), isTrue, reason: 'a concurrent retry joins');
            await runWithAttempts(r1);
          }
        } finally {
          DrivingSessionRecorder.sessionControlChanges.removeListener(onControlChange);
          onSamplesPut = null;
          failingAdapter.armed = false;
          final obstacle = Directory('${dir.path}/$samplesBoxName.hivec');
          if (obstacle.existsSync()) obstacle.deleteSync(recursive: true);
        }

        final outcomes = await Future.wait(attempts);
        expect(outcomes, isNotEmpty, reason: 'round $round: setup — deletions were attempted during the finalization');
        for (final (state, error) in outcomes) {
          expect(state, isNotNull, reason: 'round $round: attempted only while controlled');
          expect(error, isA<SessionDeletionRejected>(), reason: 'round $round: refused while ${state?.name}');
        }
        refused += outcomes.length;

        if (early) {
          await pumpEventQueue();
          expect(earliest, isNotNull, reason: 'round $round: the release was announced');
          expect(await earliest, isNull, reason: 'round $round: accepted once released');
          earliestDeletions++;
        } else {
          final cached = Hive.box<DrivingSession>(sessionsBoxName).get(s.id);
          expect(cached?.endTime, isNotNull, reason: 'round $round');
          expect(cached?.sampleCount, n, reason: 'round $round');
          expect(await storedSpeeds(s.id), expected, reason: 'round $round: every sample once, in order (mode $mode)');
          await deleteDrivingSession(s.id);
        }
        await recorder.stopSession(); // idle: a no-op
        await pumpEventQueue();
        await expectNothingLeft(s.id, 'round $round (mode $mode, early: $early)');
        expect(DrivingSessionRecorder.controllingState(s.id), isNull);
      }
      expect(earliestDeletions, 12);
      expect(refused, greaterThan(60), reason: 'setup: the deletions really raced the finalizations');
      expect(reported, isEmpty, reason: 'no incremental checkpoint failed');
    });

    test('X87 — dispose: a recorder disposed while a finalization attempt is in flight keeps its session protected until that attempt settles; disposed with its session failed or recording it controls nothing any more (nobody can write it) — D2 unchanged', () async {
      final g = gatedRecorder();
      final s = g.recorder.startSession();
      await feedInto(g.source, [40, 41]);
      final stop = g.recorder.stopSession();
      g.recorder.dispose();
      expect(DrivingSessionRecorder.controllingState(s.id), DrivingSessionRecorderState.finalizing);
      expect(await errorOf(deleteDrivingSession(s.id)), isA<SessionDeletionRejected>(), reason: 'its attempt still writes the session');
      g.gate.complete();
      await stop;
      expect(DrivingSessionRecorder.controllingState(s.id), isNull, reason: 'released when the attempt settled');
      expect(await storedSpeeds(s.id), [40, 41]);
      await deleteDrivingSession(s.id);
      await expectNothingLeft(s.id, 'finalizing at dispose');

      final failed = DrivingSessionRecorder(controller.stream);
      final s2 = failed.startSession();
      await feed([50, 51]);
      failingAdapter.armed = true;
      expect(await errorOf(failed.stopSession()), isNotNull);
      failingAdapter.armed = false;
      expect(DrivingSessionRecorder.controllingState(s2.id), DrivingSessionRecorderState.finalizationFailed);
      failed.dispose();
      expect(DrivingSessionRecorder.controllingState(s2.id), isNull, reason: 'failed at dispose: its owner is gone, nobody can retry it');

      final recording = DrivingSessionRecorder(controller.stream);
      final s3 = recording.startSession();
      recording.dispose();
      expect(DrivingSessionRecorder.controllingState(s3.id), isNull, reason: 'recording at dispose: reclaimOrphanedSessions closes it at the next start');
    });

    test('X88 — sessionControlChanges is announced after each transition, including those that write nothing to the sessions box (a STOP\'s start, a failed samples checkpoint, a dispose)', () async {
      var count = 0;
      void listener() => count++;
      DrivingSessionRecorder.sessionControlChanges.addListener(listener);
      try {
        recorder.startSession();
        expect(count, 0, reason: 'never synchronously');
        await Future<void>.delayed(Duration.zero);
        expect(count, 1, reason: 'START');
        await feed([40, 41]);
        expect(count, 1, reason: 'a sample changes nothing');
        failingAdapter.armed = true;
        final stop = recorder.stopSession();
        await Future<void>.value();
        expect(count, 2, reason: 'the STOP started: finalizing');
        expect(await errorOf(stop), isNotNull);
        expect(count, 3, reason: 'the attempt failed: finalizationFailed');
        failingAdapter.armed = false;
        await recorder.stopSession();
        expect(count, 5, reason: 'the retry started, then released the session');
        recorder.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(count, 6, reason: 'dispose');
      } finally {
        DrivingSessionRecorder.sessionControlChanges.removeListener(listener);
      }
    });
  });

  // Fase 16.2-R4.3-R2.6.7 — DL5 of the R2.6.6 pre-audit, reproduced before the
  // fix (scratchpad/fase16_2_r4_3_r2_6_7/01_prefix_repro, PR267-F): a
  // stopSession() on a recorder disposed in finalizationFailed put it back into
  // the registry of live recorders and rewrote a session the history had
  // deleted meanwhile.
  group('Fase 16.2-R4.3-R2.6.7 — a disposed recorder never controls a session again', () {
    const samplesBoxName = HiveBoxNames.drivingSessionSamples;
    const sessionsBoxName = HiveBoxNames.drivingSessions;
    late _WriteFailingSampleAdapter failing;
    var clock = t0;

    setUp(() {
      clock = t0;
      failing = _WriteFailingSampleAdapter();
      Hive.registerAdapter<DrivingSessionSample>(failing, override: true);
    });

    tearDown(() {
      Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
    });

    Future<void> feed(List<double> speeds) async {
      for (final speed in speeds) {
        clock = clock.add(const Duration(seconds: 2));
        controller.add(snapshot(timestamp: clock, speedKmh: speed));
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<Object?> errorOf(Future<void> f) async {
      try {
        await f.timeout(const Duration(seconds: 10));
        return null;
      } catch (e) {
        return e;
      }
    }

    Future<int?> storedCount(String id) async => ((await Hive.lazyBox(samplesBoxName).get(id)) as List?)?.length;

    /// The record as stored on disk (the sessions box reopened: its cache cannot answer).
    Future<DrivingSession?> diskRecord(String id) async {
      await Hive.box<DrivingSession>(sessionsBoxName).close();
      return (await Hive.openBox<DrivingSession>(sessionsBoxName)).get(id);
    }

    test('X108 — DL5: a recorder disposed in finalizationFailed, whose session was then deleted, refuses a stop — it does not become an authority again (not even for the attempt), writes nothing and announces nothing; an attempt already in flight at dispose is joined and keeps its semantics; one disposed while recording refuses too', () async {
      // 1. Failed, disposed, deleted — then a stop on the disposed recorder.
      final r1 = DrivingSessionRecorder(controller.stream);
      final s1 = r1.startSession();
      await feed([40, 41, 42]);
      failing.armed = true;
      expect(await errorOf(r1.stopSession()), isNotNull, reason: 'setup: the final sample write failed');
      failing.armed = false;
      expect(DrivingSessionRecorder.controllingState(s1.id), DrivingSessionRecorderState.finalizationFailed);
      r1.dispose();
      expect(DrivingSessionRecorder.controllingState(s1.id), isNull, reason: 'released at dispose (R2.6.6, X87)');
      await deleteDrivingSession(s1.id);

      var announcements = 0;
      void listener() => announcements++;
      DrivingSessionRecorder.sessionControlChanges.addListener(listener);
      try {
        final stop = r1.stopSession();
        expect(DrivingSessionRecorder.controllingState(s1.id), isNull,
            reason: 'pre-fix: finalizing — the disposed recorder was put back among the authorities for the attempt');
        expect(await errorOf(stop), isA<StateError>().having((e) => e.message, 'message', contains('disposed')));
        await pumpEventQueue();
        expect(announcements, 0, reason: 'no control transition happened');
      } finally {
        DrivingSessionRecorder.sessionControlChanges.removeListener(listener);
      }
      expect(Hive.box<DrivingSession>(sessionsBoxName).containsKey(s1.id), isFalse, reason: 'pre-fix: the deleted record was written again');
      expect(await storedCount(s1.id), isNull, reason: 'pre-fix: its 3 samples were written again');
      expect(await diskRecord(s1.id), isNull);
      expect(DrivingSessionRecorder.controllingState(s1.id), isNull);

      // 2. Disposed while an attempt is in flight: a stop joins that attempt, which completes as before.
      final gate = Completer<void>();
      final source = StreamController<TelemetrySnapshot>(onCancel: () => gate.future);
      final r2 = DrivingSessionRecorder(source.stream);
      final s2 = r2.startSession();
      for (final speed in [50.0, 51.0]) {
        clock = clock.add(const Duration(seconds: 2));
        source.add(snapshot(timestamp: clock, speedKmh: speed));
        await Future<void>.delayed(Duration.zero);
      }
      final inFlight = r2.stopSession();
      r2.dispose();
      expect(identical(r2.stopSession(), inFlight), isTrue, reason: 'joined, not refused');
      expect(DrivingSessionRecorder.controllingState(s2.id), DrivingSessionRecorderState.finalizing);
      gate.complete();
      await inFlight;
      expect(await storedCount(s2.id), 2);
      expect((await diskRecord(s2.id))?.endTime, isNotNull);
      expect(DrivingSessionRecorder.controllingState(s2.id), isNull);
      await source.close();

      // 3. Disposed while recording: a stop is refused and sets nothing; the record stays active for the startup reclaim.
      final r3 = DrivingSessionRecorder(controller.stream);
      final s3 = r3.startSession();
      await feed([60]);
      await Hive.box<DrivingSession>(sessionsBoxName).flush();
      r3.dispose();
      expect(await errorOf(r3.stopSession()), isA<StateError>());
      expect(s3.endTime, isNull, reason: 'nothing was ended');
      expect(DrivingSessionRecorder.controllingState(s3.id), isNull);
      expect((await diskRecord(s3.id))?.isActive, isTrue);
    });
  });
}

/// Fase 16.2-R4.3-R2.6.5: a sample adapter that, while [armed], fails while
/// serializing — inside `writeFrames`, before a byte reaches the file: a put
/// that fails BEFORE its write takes effect.
class _WriteFailingSampleAdapter extends DrivingSessionSampleAdapter {
  // TypeAdapter is @immutable: the switch is a final reference to mutable state.
  final _Armed _armed = _Armed();

  bool get armed => _armed.value;
  set armed(bool value) => _armed.value = value;

  @override
  void write(BinaryWriter writer, DrivingSessionSample obj) {
    if (armed) throw StateError('injected failure while serializing a sample');
    super.write(writer, obj);
  }
}

/// Fase 16.2-R4.3-R2.6.4 (R264-copy): records every call a Hive adapter makes on
/// its [BinaryWriter] — the field indexes and the values — so two objects can
/// be compared exactly as the adapter would persist them.
class _RecordingBinaryWriter implements BinaryWriter {
  final List<Object?> calls = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls
      ..add(invocation.memberName)
      ..addAll(invocation.positionalArguments);
    return null;
  }
}

class _Armed {
  bool value = false;
}
