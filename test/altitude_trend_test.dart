import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/altitude_trend.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  group('AltitudeTrendClassifier', () {
    test('the first sample returns stable without consuming a confirm-streak slot', () {
      final classifier = AltitudeTrendClassifier();
      expect(classifier.classify(100.0, t0), AltitudeTrend.stable);
    });

    test(
      'ordinary altitude jitter around a level value stays stable — the exact scenario from the '
      'Fase 10 spec (100, 100.2, 99.9, 100.1, 101 at 1s spacing)',
      () {
        final classifier = AltitudeTrendClassifier();
        final samples = [100.0, 100.2, 99.9, 100.1, 101.0];
        AltitudeTrend? last;
        for (var i = 0; i < samples.length; i++) {
          last = classifier.classify(samples[i], t0.add(Duration(seconds: i)));
        }
        expect(last, AltitudeTrend.stable);
      },
    );

    test('a sustained climb is confirmed as rising after enough consecutive samples', () {
      final classifier = AltitudeTrendClassifier();
      classifier.classify(100.0, t0);
      AltitudeTrend? last;
      // +0.5 m/s sustained — clearly above the entry threshold every update.
      for (var i = 1; i <= 8; i++) {
        last = classifier.classify(100.0 + 0.5 * i, t0.add(Duration(seconds: i)));
      }
      expect(last, AltitudeTrend.rising);
    });

    test('a sustained descent is confirmed as falling after enough consecutive samples', () {
      final classifier = AltitudeTrendClassifier();
      classifier.classify(100.0, t0);
      AltitudeTrend? last;
      for (var i = 1; i <= 8; i++) {
        last = classifier.classify(100.0 - 0.5 * i, t0.add(Duration(seconds: i)));
      }
      expect(last, AltitudeTrend.falling);
    });

    test('a single climbing sample does not immediately flip the confirmed state', () {
      final classifier = AltitudeTrendClassifier();
      classifier.classify(100.0, t0);
      final result = classifier.classify(105.0, t0.add(const Duration(seconds: 1)));
      expect(result, AltitudeTrend.stable);
    });

    test('a confirmed rising trend returns to stable once the rate calms down for several samples', () {
      final classifier = AltitudeTrendClassifier();
      classifier.classify(100.0, t0);
      var t = t0;
      for (var i = 1; i <= 8; i++) {
        t = t0.add(Duration(seconds: i));
        classifier.classify(100.0 + 0.5 * i, t);
      }
      // Now level off completely. The smoothed rate itself needs several
      // samples to decay back under the entry threshold before the
      // confirm-streak toward "stable" can even start counting, so this
      // needs more leveling samples than the climb itself took.
      AltitudeTrend? last;
      var altitude = 100.0 + 0.5 * 8;
      for (var i = 1; i <= 12; i++) {
        t = t.add(const Duration(seconds: 1));
        last = classifier.classify(altitude, t);
      }
      expect(last, AltitudeTrend.stable);
    });

    test('a non-positive elapsed time (duplicate/non-monotonic timestamp) is ignored', () {
      final classifier = AltitudeTrendClassifier();
      classifier.classify(100.0, t0);
      final result = classifier.classify(150.0, t0); // same timestamp, dt == 0.
      expect(result, AltitudeTrend.stable);
    });
  });
}
