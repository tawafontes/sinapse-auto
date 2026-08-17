import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/sensors/line_chart.dart';

void main() {
  group('trendSlope', () {
    test('fewer than 2 points is degenerate and reads as flat', () {
      expect(trendSlope(const []), 0.0);
      expect(trendSlope(const [42.0]), 0.0);
    });

    test('perfectly flat values have zero slope', () {
      expect(trendSlope(const [10, 10, 10, 10]), closeTo(0, 1e-9));
    });

    test('a perfectly linear rise has the exact per-sample slope', () {
      expect(trendSlope(const [0, 1, 2, 3, 4, 5]), closeTo(1.0, 1e-9));
    });

    test('a perfectly linear fall has the exact negative per-sample slope', () {
      expect(trendSlope(const [10, 8, 6, 4]), closeTo(-2.0, 1e-9));
    });
  });

  group('trendDirectionFromSlope', () {
    const threshold = 0.4;

    test('a slope past the positive threshold is rising', () {
      expect(trendDirectionFromSlope(0.5, threshold: threshold), TrendDirection.rising);
    });

    test('a slope past the negative threshold is falling', () {
      expect(trendDirectionFromSlope(-0.5, threshold: threshold), TrendDirection.falling);
    });

    test('a slope exactly at the threshold, either side, is still stable', () {
      expect(trendDirectionFromSlope(threshold, threshold: threshold), TrendDirection.stable);
      expect(trendDirectionFromSlope(-threshold, threshold: threshold), TrendDirection.stable);
    });

    test('a slope well within the threshold is stable', () {
      expect(trendDirectionFromSlope(0.1, threshold: threshold), TrendDirection.stable);
    });
  });

  testWidgets('the trend arrow only flips after the confirmation count, not on the first differing sample', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: LineChart(valueStream: controller.stream, unit: 'm'),
          ),
        ),
      ),
    );

    String arrow() => tester.widget<Text>(find.byKey(const ValueKey('lineChartTrendArrow'))).data!;

    expect(arrow(), '►'); // starts stable, before any reading arrives.

    controller.add(100);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(102);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(104);
    await tester.pump(const Duration(milliseconds: 1));
    expect(arrow(), '►'); // a clear rising trend, but only 2 confirmations so far.

    controller.add(106);
    await tester.pump(const Duration(milliseconds: 1));
    expect(arrow(), '▲'); // 3rd confirmation in a row: now committed to rising.
  });
}
