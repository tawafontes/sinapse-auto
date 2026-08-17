import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_telemetry_sample.dart';
import 'package:synapse_auto/services/dashcam_telemetry_lookup.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  DashcamTelemetrySample sampleAt(int offsetSeconds) {
    return DashcamTelemetrySample(timestamp: t0.add(Duration(seconds: offsetSeconds)), speedKmh: offsetSeconds.toDouble());
  }

  test('returns null for an empty sample list', () {
    expect(nearestDashcamSample(const [], t0), isNull);
  });

  test('returns the single sample when there is only one', () {
    final sample = sampleAt(0);
    expect(nearestDashcamSample([sample], t0.add(const Duration(minutes: 5))), same(sample));
  });

  test('picks the exact match when the target timestamp equals a sample', () {
    final samples = [sampleAt(0), sampleAt(5), sampleAt(10)];
    final result = nearestDashcamSample(samples, t0.add(const Duration(seconds: 5)));
    expect(result!.speedKmh, 5);
  });

  test('picks the closer of two surrounding samples', () {
    final samples = [sampleAt(0), sampleAt(10)];
    final closerToStart = nearestDashcamSample(samples, t0.add(const Duration(seconds: 3)));
    expect(closerToStart!.speedKmh, 0);

    final closerToEnd = nearestDashcamSample(samples, t0.add(const Duration(seconds: 8)));
    expect(closerToEnd!.speedKmh, 10);
  });

  test('a target before every sample returns the earliest one', () {
    final samples = [sampleAt(10), sampleAt(20), sampleAt(30)];
    final result = nearestDashcamSample(samples, t0.add(const Duration(seconds: -100)));
    expect(result!.speedKmh, 10);
  });

  test('a target after every sample returns the latest one', () {
    final samples = [sampleAt(10), sampleAt(20), sampleAt(30)];
    final result = nearestDashcamSample(samples, t0.add(const Duration(hours: 1)));
    expect(result!.speedKmh, 30);
  });

  test('works correctly against samples that are not in chronological order', () {
    final samples = [sampleAt(30), sampleAt(0), sampleAt(15)];
    final result = nearestDashcamSample(samples, t0.add(const Duration(seconds: 16)));
    expect(result!.speedKmh, 15);
  });
}
