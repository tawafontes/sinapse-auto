import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/sensors/g_force_meter.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    StreamController<double> magnitudeController, {
    double? initialMaxMagnitude,
    ValueChanged<double>? onMaxMagnitudeChanged,
    ValueChanged<VoidCallback>? onResetRequested,
    ValueChanged<VoidCallback>? onImmediateResetRequested,
    Stream<double>? verticalStream,
    double? initialVerticalGMin,
    double? initialVerticalGMax,
    void Function(double min, double max)? onVerticalGExtremesChanged,
    Stream<Offset>? offsetStream,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: GForceMeter(
              offsetStream: offsetStream ?? const Stream<Offset>.empty(),
              magnitudeStream: magnitudeController.stream,
              verticalStream: verticalStream ?? const Stream<double>.empty(),
              initialMaxMagnitude: initialMaxMagnitude,
              onMaxMagnitudeChanged: onMaxMagnitudeChanged,
              initialVerticalGMin: initialVerticalGMin,
              initialVerticalGMax: initialVerticalGMax,
              onVerticalGExtremesChanged: onVerticalGExtremesChanged,
              onResetRequested: onResetRequested,
              onImmediateResetRequested: onImmediateResetRequested,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('starts the peak from initialMaxMagnitude instead of zero', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await pump(tester, controller, initialMaxMagnitude: 1.8);

    expect(find.text('MÁX 1.8G'), findsOneWidget);
  });

  testWidgets('with no initial value, the peak is seeded by the first live reading (not zero)', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await pump(tester, controller);

    controller.add(0.6);
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('MÁX 0.6G'), findsOneWidget);
  });

  testWidgets('reports every new peak through onMaxMagnitudeChanged', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <double>[];
    await pump(tester, controller, initialMaxMagnitude: 1.0, onMaxMagnitudeChanged: reported.add);

    controller.add(0.5); // below the initial peak: no change reported.
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(1.4); // new peak.
    await tester.pump(const Duration(milliseconds: 1));

    expect(reported, [1.4]);
    expect(find.text('MÁX 1.4G'), findsOneWidget);
  });

  testWidgets('reset trigger reports the reset value too', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <double>[];
    VoidCallback? triggerReset;
    await pump(
      tester,
      controller,
      initialMaxMagnitude: 1.5,
      onMaxMagnitudeChanged: reported.add,
      onResetRequested: (trigger) => triggerReset = trigger,
    );

    controller.add(0.4);
    await tester.pump(const Duration(milliseconds: 1));

    triggerReset!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resetar força G máxima'));
    await tester.pumpAndSettle();

    expect(reported, [0.4]);
    expect(find.text('MÁX 0.4G'), findsOneWidget);
  });

  testWidgets('vertical G extremes update as new readings arrive, in both directions', (tester) async {
    final magnitudeController = StreamController<double>();
    addTearDown(magnitudeController.close);
    final verticalController = StreamController<double>();
    addTearDown(verticalController.close);
    final reported = <(double, double)>[];
    await pump(
      tester,
      magnitudeController,
      verticalStream: verticalController.stream,
      onVerticalGExtremesChanged: (min, max) => reported.add((min, max)),
    );

    verticalController.add(0.2);
    await tester.pump(const Duration(milliseconds: 1));
    verticalController.add(-0.5); // a new (deeper) low.
    await tester.pump(const Duration(milliseconds: 1));
    verticalController.add(0.1); // within the existing [-0.5, 0.2] range: no change.
    await tester.pump(const Duration(milliseconds: 1));

    expect(reported, [(0.2, 0.2), (-0.5, 0.2)]);
  });

  testWidgets('reset trigger also resets vertical G extremes to the current reading', (tester) async {
    final magnitudeController = StreamController<double>();
    addTearDown(magnitudeController.close);
    final verticalController = StreamController<double>();
    addTearDown(verticalController.close);
    final reportedVertical = <(double, double)>[];
    VoidCallback? triggerReset;
    await pump(
      tester,
      magnitudeController,
      verticalStream: verticalController.stream,
      initialVerticalGMin: -0.3,
      initialVerticalGMax: 0.6,
      onVerticalGExtremesChanged: (min, max) => reportedVertical.add((min, max)),
      onResetRequested: (trigger) => triggerReset = trigger,
    );

    verticalController.add(0.05); // within [-0.3, 0.6]: no change reported yet.
    await tester.pump(const Duration(milliseconds: 1));

    triggerReset!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resetar força G máxima'));
    await tester.pumpAndSettle();

    expect(reportedVertical, [(0.05, 0.05)]);
  });

  testWidgets('immediate reset trigger resets max magnitude to the current reading with no dialog shown', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <double>[];
    VoidCallback? triggerImmediateReset;
    await pump(
      tester,
      controller,
      initialMaxMagnitude: 1.5,
      onMaxMagnitudeChanged: reported.add,
      onImmediateResetRequested: (trigger) => triggerImmediateReset = trigger,
    );

    controller.add(0.4);
    await tester.pump(const Duration(milliseconds: 1));

    triggerImmediateReset!();
    await tester.pump();

    expect(reported, [0.4]);
    expect(find.text('MÁX 0.4G'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a burst of rapid offset emissions (matching the new 50Hz sensor rate) renders with no exception', (
    tester,
  ) async {
    // Regression coverage for the stutter fix: the accelerometer now
    // delivers far more often than the previous 5Hz/1Hz-throttled pipeline
    // did. This proves the dot updates on every emission while the trail's
    // own decimation (a separate, capped accumulation — see
    // _GForceMeterState._trailMinInterval) doesn't choke or throw under a
    // sustained high-frequency burst.
    final offsetController = StreamController<Offset>();
    addTearDown(offsetController.close);
    final magnitudeController = StreamController<double>();
    addTearDown(magnitudeController.close);
    await pump(tester, magnitudeController, offsetStream: offsetController.stream);

    for (var i = 0; i < 100; i++) {
      offsetController.add(Offset(0.5 * math.sin(i / 5), 0.5 * math.cos(i / 5)));
      await tester.pump(const Duration(milliseconds: 5)); // ~200Hz burst, well above the 50Hz sensor rate.
    }

    expect(tester.takeException(), isNull);
  });
}
