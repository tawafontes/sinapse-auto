import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/alert_type.dart';
import 'package:synapse_auto/models/detected_event.dart';

void main() {
  group('alertTypeForDetectedEvent (Fase 13.1 §1/§2 — single source of truth seam)', () {
    test('every level-based / gnssLost type maps to its matching AlertType, one shared threshold each', () {
      expect(alertTypeForDetectedEvent(DetectedEventType.hardAcceleration), AlertType.harshAcceleration);
      expect(alertTypeForDetectedEvent(DetectedEventType.hardBraking), AlertType.harshBraking);
      expect(alertTypeForDetectedEvent(DetectedEventType.hardCorneringLeft), AlertType.hardCornering);
      expect(alertTypeForDetectedEvent(DetectedEventType.hardCorneringRight), AlertType.hardCornering);
      expect(alertTypeForDetectedEvent(DetectedEventType.highResultantG), AlertType.highResultantG);
      expect(alertTypeForDetectedEvent(DetectedEventType.speedLimitExceeded), AlertType.highSpeed);
      expect(alertTypeForDetectedEvent(DetectedEventType.gnssLost), AlertType.gnssLost);
    });

    test('types with no live-banner equivalent map to null — session-history only, exactly as before this fix', () {
      expect(alertTypeForDetectedEvent(DetectedEventType.gnssRecovered), isNull);
      expect(alertTypeForDetectedEvent(DetectedEventType.stopped), isNull);
      expect(alertTypeForDetectedEvent(DetectedEventType.resumed), isNull);
      expect(alertTypeForDetectedEvent(DetectedEventType.altitudeRisingSignificant), isNull);
      expect(alertTypeForDetectedEvent(DetectedEventType.altitudeFallingSignificant), isNull);
    });

    test('every DetectedEventType is exhaustively covered (guards against a silently-unmapped future type)', () {
      // Merely calling this for every value must not throw — the switch
      // itself is what enforces exhaustiveness at compile time.
      for (final type in DetectedEventType.values) {
        alertTypeForDetectedEvent(type);
      }
    });
  });
}
