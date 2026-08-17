import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/widgets/telemetry/session_time_series_chart.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  group('ChartPoint', () {
    test('sample defaults to null — existing call sites without it keep working', () {
      const point = ChartPoint(elapsedSeconds: 5, value: 10);
      expect(point.sample, isNull);
    });

    test('carries the originating sample when supplied', () {
      final sample = DrivingSessionSample(timestamp: t0, speedKmh: 42);
      final point = ChartPoint(elapsedSeconds: 5, value: 42, sample: sample);
      expect(point.sample, sample);
    });
  });

  group('resultantGForSample', () {
    test('null when no G axis has a reading at all', () {
      expect(resultantGForSample(DrivingSessionSample(timestamp: t0)), isNull);
    });

    test('a single axis present is its own magnitude', () {
      expect(resultantGForSample(DrivingSessionSample(timestamp: t0, longitudinalG: 0.5)), closeTo(0.5, 1e-9));
    });

    test('combines all three axes as a vector magnitude (3-4-5 triangle, extended)', () {
      final sample = DrivingSessionSample(timestamp: t0, longitudinalG: 0, lateralG: 3, verticalG: 4);
      expect(resultantGForSample(sample), closeTo(5.0, 1e-9));
    });

    test('a missing axis contributes 0, not null, as long as another axis is present', () {
      final sample = DrivingSessionSample(timestamp: t0, longitudinalG: 3, lateralG: 4);
      expect(resultantGForSample(sample), closeTo(5.0, 1e-9));
    });
  });

  group('computeChartLayout', () {
    test('an empty point list has no layout', () {
      expect(computeChartLayout([], size: const Size(100, 100)), isNull);
    });

    test('points that are all null-valued (no data) have no layout', () {
      final points = [
        const ChartPoint(elapsedSeconds: 0, value: null),
        const ChartPoint(elapsedSeconds: 10, value: null),
      ];
      expect(computeChartLayout(points, size: const Size(100, 100)), isNull);
    });

    test('xMin/xMax reflect the first/last elapsed time, yMin/yMax the value range', () {
      final points = [
        const ChartPoint(elapsedSeconds: 0, value: 10),
        const ChartPoint(elapsedSeconds: 5, value: 30),
        const ChartPoint(elapsedSeconds: 10, value: 20),
      ];
      final layout = computeChartLayout(points, size: const Size(100, 100))!;
      expect(layout.xMin, 0);
      expect(layout.xMax, 10);
      expect(layout.yMin, 10);
      expect(layout.yMax, 30);
    });

    test('a perfectly flat signal still produces a valid, non-zero range', () {
      final points = [
        const ChartPoint(elapsedSeconds: 0, value: 5),
        const ChartPoint(elapsedSeconds: 1, value: 5),
      ];
      final layout = computeChartLayout(points, size: const Size(100, 100))!;
      expect(layout.yMax, greaterThan(layout.yMin));
    });

    test('null values are excluded from the value range computation', () {
      final points = [
        const ChartPoint(elapsedSeconds: 0, value: 100),
        const ChartPoint(elapsedSeconds: 1, value: null),
        const ChartPoint(elapsedSeconds: 2, value: 5),
      ];
      final layout = computeChartLayout(points, size: const Size(100, 100))!;
      expect(layout.yMin, 5);
      expect(layout.yMax, 100);
    });
  });
}
