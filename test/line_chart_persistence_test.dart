import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/sensors/line_chart.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    StreamController<double> controller, {
    double? initialSessionMin,
    double? initialSessionMax,
    void Function(double, double)? onSessionExtremesChanged,
    ValueChanged<VoidCallback>? onResetRequested,
    ValueChanged<VoidCallback>? onImmediateResetRequested,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: LineChart(
              valueStream: controller.stream,
              unit: 'm',
              initialSessionMin: initialSessionMin,
              initialSessionMax: initialSessionMax,
              onSessionExtremesChanged: onSessionExtremesChanged,
              onResetRequested: onResetRequested,
              onImmediateResetRequested: onImmediateResetRequested,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a value inside the persisted [min,max] range does not report a change', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, double)>[];
    await pump(
      tester,
      controller,
      initialSessionMin: 100,
      initialSessionMax: 400,
      onSessionExtremesChanged: (min, max) => reported.add((min, max)),
    );

    controller.add(250); // well within [100, 400]: min/max unchanged.
    await tester.pump(const Duration(milliseconds: 1));

    expect(reported, isEmpty);
  });

  testWidgets('a new extreme beyond the persisted range is reported', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, double)>[];
    await pump(
      tester,
      controller,
      initialSessionMin: 100,
      initialSessionMax: 400,
      onSessionExtremesChanged: (min, max) => reported.add((min, max)),
    );

    controller.add(420); // new max.
    await tester.pump(const Duration(milliseconds: 1));

    expect(reported, [(100.0, 420.0)]);
  });

  testWidgets('with no persisted range, the first reading seeds both min and max', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, double)>[];
    await pump(tester, controller, onSessionExtremesChanged: (min, max) => reported.add((min, max)));

    controller.add(180);
    await tester.pump(const Duration(milliseconds: 1));

    expect(reported, [(180.0, 180.0)]);
  });

  testWidgets('reset trigger reports the reset value as the new min and max', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, double)>[];
    VoidCallback? triggerReset;
    await pump(
      tester,
      controller,
      initialSessionMin: 100,
      initialSessionMax: 400,
      onSessionExtremesChanged: (min, max) => reported.add((min, max)),
      onResetRequested: (trigger) => triggerReset = trigger,
    );

    controller.add(250);
    await tester.pump(const Duration(milliseconds: 1));

    triggerReset!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resetar mínimo e máximo'));
    await tester.pumpAndSettle();

    expect(reported, [(250.0, 250.0)]);
  });

  testWidgets('immediate reset trigger resets to the current reading with no dialog shown', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, double)>[];
    VoidCallback? triggerImmediateReset;
    await pump(
      tester,
      controller,
      initialSessionMin: 100,
      initialSessionMax: 400,
      onSessionExtremesChanged: (min, max) => reported.add((min, max)),
      onImmediateResetRequested: (trigger) => triggerImmediateReset = trigger,
    );

    controller.add(250);
    await tester.pump(const Duration(milliseconds: 1));

    triggerImmediateReset!();
    await tester.pump();

    expect(reported, [(250.0, 250.0)]);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
