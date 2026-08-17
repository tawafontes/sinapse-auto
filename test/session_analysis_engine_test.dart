import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/services/session_analysis_engine.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  DrivingSession session({
    double? maxSpeedKmh,
    double? maxAccelerationG,
    double? maxDecelerationG,
    double? maxLateralG,
    double? maxGForceMagnitude,
    double altitudeGainMeters = 0,
    double altitudeLossMeters = 0,
  }) {
    return DrivingSession(
      id: 's',
      startTime: t0,
      endTime: t0.add(const Duration(minutes: 10)),
      maxSpeedKmh: maxSpeedKmh,
      maxAccelerationG: maxAccelerationG,
      maxDecelerationG: maxDecelerationG,
      maxLateralG: maxLateralG,
      maxGForceMagnitude: maxGForceMagnitude,
      altitudeGainMeters: altitudeGainMeters,
      altitudeLossMeters: altitudeLossMeters,
    );
  }

  group('SessionAnalysisEngine.analyze — data availability', () {
    test('an empty sample list reports no availability for any signal', () {
      final result = SessionAnalysisEngine.analyze(session(), []);
      final a = result.availability;
      expect(a.hasSpeedData, isFalse);
      expect(a.hasAltitudeData, isFalse);
      expect(a.hasLongitudinalGData, isFalse);
      expect(a.hasLateralGData, isFalse);
      expect(a.hasPitchRollData, isFalse);
      expect(a.hasTrajectoryData, isFalse);
      expect(a.hasGGData, isFalse);
      expect(a.hasAccelerationData, isFalse);
    });

    test('samples present but every field null still reports no availability (not a crash, not a false positive)', () {
      final samples = [DrivingSessionSample(timestamp: t0), DrivingSessionSample(timestamp: t0.add(const Duration(seconds: 1)))];
      final result = SessionAnalysisEngine.analyze(session(), samples);
      expect(result.availability.hasSpeedData, isFalse);
      expect(result.availability.hasAccelerationData, isFalse);
      expect(result.availability.hasTrajectoryData, isFalse);
    });

    test('a single non-null speed reading is enough to mark speed data available', () {
      final samples = [DrivingSessionSample(timestamp: t0, speedKmh: 42)];
      expect(SessionAnalysisEngine.analyze(session(), samples).availability.hasSpeedData, isTrue);
    });

    test('trajectory data requires at least 2 samples with a GPS fix, not just 1', () {
      final oneFix = [DrivingSessionSample(timestamp: t0, latitude: 1, longitude: 1)];
      expect(SessionAnalysisEngine.analyze(session(), oneFix).availability.hasTrajectoryData, isFalse);
      final twoFixes = [
        DrivingSessionSample(timestamp: t0, latitude: 1, longitude: 1),
        DrivingSessionSample(timestamp: t0.add(const Duration(seconds: 1)), latitude: 1.001, longitude: 1.001),
      ];
      expect(SessionAnalysisEngine.analyze(session(), twoFixes).availability.hasTrajectoryData, isTrue);
    });

    test('G-G data requires both longitudinal and lateral present on the same sample', () {
      final onlyLongitudinal = [DrivingSessionSample(timestamp: t0, longitudinalG: 0.2)];
      expect(SessionAnalysisEngine.analyze(session(), onlyLongitudinal).availability.hasGGData, isFalse);
      final both = [DrivingSessionSample(timestamp: t0, longitudinalG: 0.2, lateralG: 0.1)];
      expect(SessionAnalysisEngine.analyze(session(), both).availability.hasGGData, isTrue);
    });

    test('acceleration data is true if EITHER longitudinal or lateral alone is present', () {
      final onlyLateral = [DrivingSessionSample(timestamp: t0, lateralG: 0.3)];
      expect(SessionAnalysisEngine.analyze(session(), onlyLateral).availability.hasAccelerationData, isTrue);
    });

    test('pitch OR roll alone is enough for pitch/roll availability', () {
      final onlyRoll = [DrivingSessionSample(timestamp: t0, rollDegrees: 2)];
      expect(SessionAnalysisEngine.analyze(session(), onlyRoll).availability.hasPitchRollData, isTrue);
    });
  });

  group('SessionAnalysisEngine.analyze — highlights (Fase 12 §40)', () {
    test('a session with none of the tracked maxima produces no highlights', () {
      expect(SessionAnalysisEngine.analyze(session(), []).highlights, isEmpty);
    });

    test('only fields the session actually has are surfaced, nothing invented for absent ones', () {
      final result = SessionAnalysisEngine.analyze(session(maxSpeedKmh: 120), []);
      expect(result.highlights.length, 1);
      expect(result.highlights.single.kind, SessionHighlightKind.maxSpeed);
      expect(result.highlights.single.value, 120);
    });

    test('altitude gain/loss highlights only appear when actually positive (0 means none recorded)', () {
      final result = SessionAnalysisEngine.analyze(session(altitudeGainMeters: 0, altitudeLossMeters: 0), []);
      expect(result.highlights.where((h) => h.kind == SessionHighlightKind.altitudeGain), isEmpty);
      expect(result.highlights.where((h) => h.kind == SessionHighlightKind.altitudeLoss), isEmpty);
    });

    test('every possible highlight kind surfaces when the session has all of them', () {
      final result = SessionAnalysisEngine.analyze(
        session(
          maxSpeedKmh: 90,
          maxAccelerationG: 0.4,
          maxDecelerationG: 0.6,
          maxLateralG: 0.5,
          maxGForceMagnitude: 1.1,
          altitudeGainMeters: 50,
          altitudeLossMeters: 30,
        ),
        [],
      );
      expect(result.highlights.map((h) => h.kind).toSet(), SessionHighlightKind.values.toSet());
    });

    test('every highlight kind has a distinct Portuguese label', () {
      final labels = SessionHighlightKind.values.map(sessionHighlightLabel).toSet();
      expect(labels.length, SessionHighlightKind.values.length);
    });
  });

  group('SessionAnalysisEngine.analyze — altitude trend summary', () {
    final withAltitude = [DrivingSessionSample(timestamp: t0, altitudeMeters: 100)];

    test('no altitude data at all reports noData, not flat', () {
      expect(SessionAnalysisEngine.analyze(session(), []).altitudeTrendSummary, AltitudeTrendSummary.noData);
    });

    test('small gain/loss below the noise threshold reports flat', () {
      final result = SessionAnalysisEngine.analyze(session(altitudeGainMeters: 1, altitudeLossMeters: 1), withAltitude);
      expect(result.altitudeTrendSummary, AltitudeTrendSummary.flat);
    });

    test('gain clearly dominating loss reports mostlyClimbing', () {
      final result = SessionAnalysisEngine.analyze(session(altitudeGainMeters: 100, altitudeLossMeters: 10), withAltitude);
      expect(result.altitudeTrendSummary, AltitudeTrendSummary.mostlyClimbing);
    });

    test('loss clearly dominating gain reports mostlyDescending', () {
      final result = SessionAnalysisEngine.analyze(session(altitudeGainMeters: 10, altitudeLossMeters: 100), withAltitude);
      expect(result.altitudeTrendSummary, AltitudeTrendSummary.mostlyDescending);
    });

    test('comparable gain and loss (a round trip) reports mixed, not one-sided', () {
      final result = SessionAnalysisEngine.analyze(session(altitudeGainMeters: 100, altitudeLossMeters: 95), withAltitude);
      expect(result.altitudeTrendSummary, AltitudeTrendSummary.mixed);
    });

    test('every AltitudeTrendSummary value has a distinct Portuguese label', () {
      final labels = AltitudeTrendSummary.values.map(altitudeTrendSummaryLabel).toSet();
      expect(labels.length, AltitudeTrendSummary.values.length);
    });
  });
}
