import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/widgets/telemetry/decimate.dart';
import 'package:synapse_auto/widgets/telemetry/gg_diagram.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  DrivingSessionSample sampleG(double? longitudinal, double? lateral) =>
      DrivingSessionSample(timestamp: t0, longitudinalG: longitudinal, lateralG: lateral);

  group('ggPoints', () {
    test('samples missing either G component are excluded', () {
      final points = ggPoints([sampleG(null, 0.1), sampleG(0.2, null), sampleG(0.3, 0.4)]);
      expect(points, [const Offset(0.3, 0.4)]);
    });

    test('maps longitudinal to x and lateral to y', () {
      final points = ggPoints([sampleG(0.5, -0.2)]);
      expect(points.single.dx, 0.5);
      expect(points.single.dy, -0.2);
    });

    test('an empty sample list yields no points', () {
      expect(ggPoints([]), isEmpty);
    });
  });

  group('indexOfPeakMagnitude', () {
    test('finds the point with the largest combined magnitude, not just the largest x or y', () {
      final points = [
        const Offset(0.9, 0.0), // magnitude 0.9
        const Offset(0.3, 0.3), // magnitude ~0.424
        const Offset(0.5, 0.5), // magnitude ~0.707
      ];
      expect(indexOfPeakMagnitude(points), 0);
    });

    test('a single point is trivially the peak', () {
      expect(indexOfPeakMagnitude([const Offset(0.1, 0.1)]), 0);
    });

    test('negative components are handled via magnitude, not raw value', () {
      final points = [const Offset(-0.9, 0.0), const Offset(0.1, 0.1)];
      expect(indexOfPeakMagnitude(points), 0);
    });
  });

  group('ggSamples', () {
    test('same filter and order as ggPoints, so indices correlate 1:1', () {
      final samples = [sampleG(null, 0.1), sampleG(0.2, null), sampleG(0.3, 0.4)];
      final points = ggPoints(samples);
      final correlated = ggSamples(samples);
      expect(correlated.length, points.length);
      expect(correlated.single.longitudinalG, 0.3);
      expect(correlated.single.lateralG, 0.4);
    });

    test('an empty sample list yields no samples', () {
      expect(ggSamples([]), isEmpty);
    });
  });

  group('computeGGPixelsPerG', () {
    test('scales to fit maxRingsG when no point exceeds it', () {
      final pixelsPerG = computeGGPixelsPerG([const Offset(0.2, 0.1)], maxRingsG: 1.0, size: const Size(200, 200));
      // (100 - 12) / 1.0
      expect(pixelsPerG, closeTo(88.0, 1e-9));
    });

    test('expands scale (never clips) when a point exceeds maxRingsG', () {
      final pixelsPerG = computeGGPixelsPerG([const Offset(2.0, 0.0)], maxRingsG: 1.0, size: const Size(200, 200));
      // (100 - 12) / 2.0 — the point's own magnitude, not the fixed default.
      expect(pixelsPerG, closeTo(44.0, 1e-9));
    });

    test('an empty point list still produces a finite scale from maxRingsG alone', () {
      final pixelsPerG = computeGGPixelsPerG([], maxRingsG: 1.0, size: const Size(200, 200));
      expect(pixelsPerG.isFinite, isTrue);
    });
  });

  group('GGDiagram widget — initialSelectedTimestamp (Fase 13 §37: evento → G-G)', () {
    testWidgets('pre-selects the point nearest the given timestamp on first build', (tester) async {
      final samples = [
        DrivingSessionSample(timestamp: t0, longitudinalG: 0.1, lateralG: 0.1),
        DrivingSessionSample(timestamp: t0.add(const Duration(seconds: 10)), longitudinalG: 0.5, lateralG: 0.6),
        DrivingSessionSample(timestamp: t0.add(const Duration(seconds: 20)), longitudinalG: 0.2, lateralG: 0.2),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // Matches how SessionDetailScreen's own G-G tab actually hosts
            // this widget (a scrollable, not a bare bounded body) — GGDiagram
            // itself expects unconstrained height for its Column.
            body: SingleChildScrollView(child: GGDiagram(samples: samples, initialSelectedTimestamp: t0.add(const Duration(seconds: 9)))),
          ),
        ),
      );
      await tester.pump();

      // The nearest sample to t0+9s is the one at t0+10s (0.5, 0.6) — its
      // readout must already be showing without any tap.
      expect(find.textContaining('0.50'), findsOneWidget);
      expect(find.textContaining('0.60'), findsOneWidget);
    });

    testWidgets('jumping to a new timestamp after the widget already exists updates the selection', (tester) async {
      final samples = [
        DrivingSessionSample(timestamp: t0, longitudinalG: 0.1, lateralG: 0.1),
        DrivingSessionSample(timestamp: t0.add(const Duration(seconds: 10)), longitudinalG: 0.5, lateralG: 0.6),
      ];
      Widget build(DateTime? jump) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: GGDiagram(samples: samples, initialSelectedTimestamp: jump))),
      );

      await tester.pumpWidget(build(null));
      await tester.pump();
      expect(find.textContaining('0.50'), findsNothing);

      await tester.pumpWidget(build(t0.add(const Duration(seconds: 10))));
      await tester.pump();
      expect(find.textContaining('0.50'), findsOneWidget);
    });
  });

  group('downsampling preserves the true peak (Fase 12 §18/§46)', () {
    test('the global peak magnitude survives minMaxBucketIndices even amid many near-zero samples', () {
      final samples = List.generate(
        300,
        (i) => i == 137 ? sampleG(0.9, 0.9) : sampleG(0.01, 0.01),
      );
      final points = ggPoints(samples);
      final correlatedSamples = ggSamples(samples);
      final indices = minMaxBucketIndices(points.length, maxPoints: 40, valueOf: (i) => points[i].distance);
      final downsampled = indices.map((i) => points[i]).toList();
      final downsampledPeakIndex = indexOfPeakMagnitude(downsampled);
      expect(downsampled[downsampledPeakIndex].dx, closeTo(0.9, 1e-9));
      expect(correlatedSamples[indices[downsampledPeakIndex]].longitudinalG, closeTo(0.9, 1e-9));
    });
  });
}
