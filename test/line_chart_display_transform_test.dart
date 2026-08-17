import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/sensors/line_chart.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    StreamController<double> controller, {
    required String unit,
    double Function(double)? displayTransform,
    double? initialSessionMin,
    double? initialSessionMax,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: LineChart(
              valueStream: controller.stream,
              unit: unit,
              displayTransform: displayTransform,
              initialSessionMin: initialSessionMin,
              initialSessionMax: initialSessionMax,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('with no displayTransform, the raw stream value is shown unmodified (default behavior preserved)', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await pump(tester, controller, unit: 'km/h');

    controller.add(100);
    await tester.pump();

    expect(find.text('100'), findsOneWidget);
    expect(find.text('km/h'), findsOneWidget);
  });

  testWidgets('with a displayTransform, the big number reflects the converted value, not the raw one', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await pump(tester, controller, unit: 'mph', displayTransform: (kmh) => kmh * 0.621371);

    controller.add(100); // 100 km/h in the raw stream.
    await tester.pump();

    expect(find.text('62'), findsOneWidget); // 100 km/h ≈ 62 mph, rounded.
    expect(find.text('mph'), findsOneWidget);
    expect(find.text('100'), findsNothing); // never shows the un-converted raw value.
  });

  testWidgets('a value of exactly 0 still converts and displays correctly (not treated as "no reading")', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await pump(tester, controller, unit: 'ft', displayTransform: (meters) => meters * 3.28084);

    controller.add(0);
    await tester.pump();

    expect(find.text('0'), findsOneWidget);
  });
}
