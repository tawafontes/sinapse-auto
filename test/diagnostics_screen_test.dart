import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/screens/settings/diagnostics_screen.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/gnss_quality.dart';

void main() {
  // gnssQualityLabel itself now lives in, and is tested by,
  // gnss_quality_test.dart — it moved out of this screen file when
  // driving-session screens (Fase 11) needed the same label without a
  // screens-importing-screens dependency.

  group('gnssConfidenceLabel', () {
    test('excellent and good quality both read as high confidence', () {
      expect(gnssConfidenceLabel(GnssQuality.excellent), 'Alta');
      expect(gnssConfidenceLabel(GnssQuality.good), 'Alta');
    });

    test('moderate quality reads as medium confidence', () {
      expect(gnssConfidenceLabel(GnssQuality.moderate), 'Média');
    });

    test('weak and unavailable quality both read as low confidence', () {
      expect(gnssConfidenceLabel(GnssQuality.weak), 'Baixa');
      expect(gnssConfidenceLabel(GnssQuality.unavailable), 'Baixa');
    });
  });

  group('altitudeTrendLabel', () {
    test('maps every AltitudeTrend value to a distinct Portuguese label', () {
      expect(altitudeTrendLabel(AltitudeTrend.rising), 'Subindo');
      expect(altitudeTrendLabel(AltitudeTrend.falling), 'Descendo');
      expect(altitudeTrendLabel(AltitudeTrend.stable), 'Estável');
    });
  });

  group('isSampleFresh', () {
    final now = DateTime(2026, 1, 1, 12);

    test('null (no sample ever received) is never fresh', () {
      expect(isSampleFresh(null, now: now), isFalse);
    });

    test('a sample from just now is fresh', () {
      expect(isSampleFresh(now, now: now), isTrue);
    });

    test('a sample within staleAfter is fresh', () {
      final last = now.subtract(const Duration(seconds: 2));
      expect(isSampleFresh(last, now: now, staleAfter: const Duration(seconds: 3)), isTrue);
    });

    test('a sample older than staleAfter is not fresh', () {
      final last = now.subtract(const Duration(seconds: 5));
      expect(isSampleFresh(last, now: now, staleAfter: const Duration(seconds: 3)), isFalse);
    });

    test('a sample exactly at the staleAfter boundary is still fresh (inclusive)', () {
      final last = now.subtract(const Duration(seconds: 3));
      expect(isSampleFresh(last, now: now, staleAfter: const Duration(seconds: 3)), isTrue);
    });
  });
}
