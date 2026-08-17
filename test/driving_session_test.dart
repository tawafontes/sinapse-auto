import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';

void main() {
  final start = DateTime(2026, 1, 1, 12);

  group('DrivingSession', () {
    test('a session with no endTime is active, with a null duration', () {
      final session = DrivingSession(id: '1', startTime: start);
      expect(session.isActive, isTrue);
      expect(session.duration, isNull);
    });

    test('a session with an endTime is not active, and reports the correct duration', () {
      final session = DrivingSession(id: '1', startTime: start, endTime: start.add(const Duration(minutes: 15)));
      expect(session.isActive, isFalse);
      expect(session.duration, const Duration(minutes: 15));
    });

    test('defaults distanceMeters to 0 and every stat to null when not supplied', () {
      final session = DrivingSession(id: '1', startTime: start);
      expect(session.distanceMeters, 0);
      expect(session.maxSpeedKmh, isNull);
      expect(session.avgSpeedKmh, isNull);
      expect(session.maxAltitudeMeters, isNull);
      expect(session.minAltitudeMeters, isNull);
      expect(session.maxAccelerationG, isNull);
      expect(session.maxDecelerationG, isNull);
      expect(session.initialAltitudeMeters, isNull);
      expect(session.finalAltitudeMeters, isNull);
      expect(session.initialHeadingDegrees, isNull);
      expect(session.finalHeadingDegrees, isNull);
      expect(session.maxLateralG, isNull);
      expect(session.maxGForceMagnitude, isNull);
      expect(session.sampleCount, 0);
      expect(session.initialLatitude, isNull);
      expect(session.initialLongitude, isNull);
      expect(session.finalLatitude, isNull);
      expect(session.finalLongitude, isNull);
      expect(session.avgGnssQualityIndex, isNull);
      expect(session.altitudeGainMeters, 0);
      expect(session.altitudeLossMeters, 0);
      expect(session.events, isEmpty);
    });

    group('state (Fase 11 §6 — strongly typed IDLE/RECORDING/COMPLETED)', () {
      test('a session with no endTime reports DrivingSessionState.recording', () {
        final session = DrivingSession(id: '1', startTime: start);
        expect(session.state, DrivingSessionState.recording);
      });

      test('a session with an endTime reports DrivingSessionState.completed', () {
        final session = DrivingSession(id: '1', startTime: start, endTime: start.add(const Duration(minutes: 1)));
        expect(session.state, DrivingSessionState.completed);
      });
    });

    test('every new field can be independently populated', () {
      final event = DrivingSessionEvent(type: DrivingSessionEventType.hardBraking, timestamp: start, magnitude: 0.6);
      final session = DrivingSession(
        id: '1',
        startTime: start,
        initialAltitudeMeters: 500,
        finalAltitudeMeters: 520,
        initialHeadingDegrees: 90,
        finalHeadingDegrees: 180,
        maxLateralG: 0.7,
        maxGForceMagnitude: 1.8,
        sampleCount: 42,
        initialLatitude: 10,
        initialLongitude: 20,
        finalLatitude: 10.1,
        finalLongitude: 20.1,
        avgGnssQualityIndex: 3.2,
        altitudeGainMeters: 15,
        altitudeLossMeters: 5,
        events: [event],
      );
      expect(session.initialAltitudeMeters, 500);
      expect(session.finalAltitudeMeters, 520);
      expect(session.initialHeadingDegrees, 90);
      expect(session.finalHeadingDegrees, 180);
      expect(session.maxLateralG, 0.7);
      expect(session.maxGForceMagnitude, 1.8);
      expect(session.sampleCount, 42);
      expect(session.initialLatitude, 10);
      expect(session.initialLongitude, 20);
      expect(session.finalLatitude, 10.1);
      expect(session.finalLongitude, 20.1);
      expect(session.avgGnssQualityIndex, 3.2);
      expect(session.altitudeGainMeters, 15);
      expect(session.altitudeLossMeters, 5);
      expect(session.events, [event]);
    });
  });

  group('DrivingSessionEvent', () {
    test('driveSessionEventTypeLabel maps every type — including the Fase 13 additions — to a distinct Portuguese label', () {
      final labels = DrivingSessionEventType.values.map(driveSessionEventTypeLabel).toSet();
      expect(labels.length, DrivingSessionEventType.values.length);
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.hardAcceleration), 'Aceleração forte');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.hardBraking), 'Frenagem forte');
      // Legacy-only (§63) — must keep deserializing/labeling correctly even
      // though new detection never emits it anymore.
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.hardCornering), 'Curva forte');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.gnssLost), 'Perda de GNSS');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.gnssRecovered), 'Recuperação de GNSS');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.hardCorneringLeft), 'Curva forte à esquerda');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.hardCorneringRight), 'Curva forte à direita');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.highResultantG), 'G resultante elevado');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.speedLimitExceeded), 'Excesso de velocidade');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.stopped), 'Parada');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.resumed), 'Retomada de movimento');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.altitudeRisingSignificant), 'Subida significativa');
      expect(driveSessionEventTypeLabel(DrivingSessionEventType.altitudeFallingSignificant), 'Descida significativa');
    });

    test('eventSeverityLabel maps every severity to a distinct Portuguese label', () {
      final labels = EventSeverity.values.map(eventSeverityLabel).toSet();
      expect(labels.length, EventSeverity.values.length);
    });

    test('defaults: id/duration/snapshot fields are null, severity is info, when not supplied — a legacy event reads back this way', () {
      final event = DrivingSessionEvent(type: DrivingSessionEventType.hardBraking, timestamp: start);
      expect(event.id, isNull);
      expect(event.durationMs, isNull);
      expect(event.duration, isNull);
      expect(event.latitude, isNull);
      expect(event.longitude, isNull);
      expect(event.speedKmh, isNull);
      expect(event.altitudeMeters, isNull);
      expect(event.longitudinalG, isNull);
      expect(event.lateralG, isNull);
      expect(event.resultantG, isNull);
      expect(event.severity, EventSeverity.info);
    });

    test('every Fase 13 field can be independently populated', () {
      final event = DrivingSessionEvent(
        type: DrivingSessionEventType.highResultantG,
        timestamp: start,
        magnitude: 0.9,
        id: 'abc-123',
        durationMs: 250,
        latitude: 10,
        longitude: 20,
        speedKmh: 60,
        altitudeMeters: 300,
        longitudinalG: 0.4,
        lateralG: 0.3,
        resultantG: 0.9,
        severity: EventSeverity.critical,
      );
      expect(event.id, 'abc-123');
      expect(event.durationMs, 250);
      expect(event.duration, const Duration(milliseconds: 250));
      expect(event.latitude, 10);
      expect(event.longitude, 20);
      expect(event.speedKmh, 60);
      expect(event.altitudeMeters, 300);
      expect(event.longitudinalG, 0.4);
      expect(event.lateralG, 0.3);
      expect(event.resultantG, 0.9);
      expect(event.severity, EventSeverity.critical);
    });
  });
}
