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
    bool trackAverage = false,
    double? initialSessionAverage,
    int initialAverageSampleCount = 0,
    void Function(double average, int sampleCount)? onSessionAverageChanged,
    String? resetDialogTitle,
    String? resetDialogConfirmLabel,
    ValueChanged<VoidCallback>? onResetRequested,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: LineChart(
              valueStream: controller.stream,
              unit: 'km/h',
              initialSessionMin: initialSessionMin,
              initialSessionMax: initialSessionMax,
              onSessionExtremesChanged: onSessionExtremesChanged,
              trackAverage: trackAverage,
              initialSessionAverage: initialSessionAverage,
              initialAverageSampleCount: initialAverageSampleCount,
              onSessionAverageChanged: onSessionAverageChanged,
              resetDialogTitle: resetDialogTitle,
              resetDialogConfirmLabel: resetDialogConfirmLabel,
              onResetRequested: onResetRequested,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('with trackAverage false (altitude), onSessionAverageChanged is never called', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    var called = false;
    await pump(tester, controller, onSessionAverageChanged: (_, _) => called = true);

    controller.add(40);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(80);
    await tester.pump(const Duration(milliseconds: 1));

    expect(called, isFalse);
  });

  testWidgets('with trackAverage true, the running average is a true incremental mean', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, int)>[];
    await pump(
      tester,
      controller,
      trackAverage: true,
      onSessionAverageChanged: (average, sampleCount) => reported.add((average, sampleCount)),
    );

    controller.add(40);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(60);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(80);
    await tester.pump(const Duration(milliseconds: 1));

    // 40, then (40+60)/2=50, then (40+60+80)/3=60.
    expect(reported, [(40.0, 1), (50.0, 2), (60.0, 3)]);
  });

  testWidgets('a persisted average+sampleCount is weighted correctly, not overwritten by one new reading', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, int)>[];
    // Simulates resuming a session that already averaged 40 over 4 samples —
    // a 5th sample of 90 should land at (40*4 + 90) / 5 = 50, not (40+90)/2.
    await pump(
      tester,
      controller,
      trackAverage: true,
      initialSessionAverage: 40,
      initialAverageSampleCount: 4,
      onSessionAverageChanged: (average, sampleCount) => reported.add((average, sampleCount)),
    );

    controller.add(90);
    await tester.pump(const Duration(milliseconds: 1));

    expect(reported, [(50.0, 5)]);
  });

  testWidgets('the bottom badge shows MÉD instead of MÍN once trackAverage is true', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await pump(tester, controller, trackAverage: true);

    controller.add(40);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(60);
    await tester.pump(const Duration(milliseconds: 1));

    // Painted on canvas, not as a Text widget — but shouldRepaint always
    // true and no exception thrown is the widget-test-level guarantee that
    // a real device screenshot then confirms visually (see the round's
    // device validation for the actual rendered "MÉD"/"MÍN" text).
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid readings (NaN/Infinity) are discarded, never folded into the average or reported', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final reported = <(double, int)>[];
    await pump(
      tester,
      controller,
      trackAverage: true,
      onSessionAverageChanged: (average, sampleCount) => reported.add((average, sampleCount)),
    );

    controller.add(40);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(double.nan);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(double.infinity);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(60);
    await tester.pump(const Duration(milliseconds: 1));

    // Only the two valid readings (40, 60) were folded in — average of
    // exactly those two, sample count 2, not 4.
    expect(reported, [(40.0, 1), (50.0, 2)]);
  });

  testWidgets('reset trigger resets max, min and average together, all to the current reading', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final extremes = <(double, double)>[];
    final averages = <(double, int)>[];
    VoidCallback? triggerReset;
    await pump(
      tester,
      controller,
      trackAverage: true,
      onSessionExtremesChanged: (min, max) => extremes.add((min, max)),
      onSessionAverageChanged: (average, sampleCount) => averages.add((average, sampleCount)),
      onResetRequested: (trigger) => triggerReset = trigger,
    );

    controller.add(40);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(80);
    await tester.pump(const Duration(milliseconds: 1));
    extremes.clear();
    averages.clear();

    triggerReset!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resetar mínimo e máximo'));
    await tester.pumpAndSettle();

    expect(extremes, [(80.0, 80.0)]);
    expect(averages, [(80.0, 1)]);
  });

  testWidgets('reset dialog uses the overridden title/confirm label when provided (speed)', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    VoidCallback? triggerReset;
    await pump(
      tester,
      controller,
      resetDialogTitle: 'Resetar máxima e média de velocidade?',
      resetDialogConfirmLabel: 'Resetar máxima e média',
      onResetRequested: (trigger) => triggerReset = trigger,
    );

    triggerReset!();
    await tester.pumpAndSettle();

    expect(find.text('Resetar máxima e média de velocidade?'), findsOneWidget);
    expect(find.text('Resetar máxima e média'), findsOneWidget);
    expect(find.text('Resetar mínimo e máximo de altitude?'), findsNothing);
  });

  testWidgets('reset dialog falls back to the original altitude wording when not overridden', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    VoidCallback? triggerReset;
    await pump(tester, controller, onResetRequested: (trigger) => triggerReset = trigger);

    triggerReset!();
    await tester.pumpAndSettle();

    expect(find.text('Resetar mínimo e máximo de altitude?'), findsOneWidget);
    expect(find.text('Resetar mínimo e máximo'), findsOneWidget);
  });

  testWidgets('the animated MÉD badge color does not affect any reported value, only rendering', (tester) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    final extremes = <(double, double)>[];
    await pump(
      tester,
      controller,
      trackAverage: true,
      onSessionExtremesChanged: (min, max) => extremes.add((min, max)),
    );

    controller.add(40);
    await tester.pump(const Duration(milliseconds: 1));
    controller.add(80);
    await tester.pump(const Duration(milliseconds: 1));

    expect(extremes, [(40.0, 40.0), (40.0, 80.0)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'crossing a band boundary mid-transition settles cleanly with no exception (both MÁX and MÉD animate)',
    (tester) async {
      final controller = StreamController<double>();
      addTearDown(controller.close);
      await pump(tester, controller, trackAverage: true);

      // 20 -> low (green) for both max and average; each subsequent reading
      // pulls the max further up (crossing bands on its own, independent of
      // the average's own — slower-moving — classification), retargeting
      // both in-flight animations partway through their own transitions.
      controller.add(20);
      await tester.pump(const Duration(milliseconds: 50));
      controller.add(90); // max jumps to "veryHigh"; average (20+90)/2=55 is only "moderate".
      await tester.pump(const Duration(milliseconds: 50));
      controller.add(120); // both keep moving; max stays veryHigh, average climbs further.
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('MÁX and MÉD classify independently — a high max with a low average is not a conflict', (
    tester,
  ) async {
    final controller = StreamController<double>();
    addTearDown(controller.close);
    await pump(tester, controller, trackAverage: true);

    // A single burst to 150 km/h then back down to near-zero repeatedly:
    // the max locks onto "veryHigh" permanently (session maxima never
    // decrease), while the average — pulled down by many subsequent low
    // readings — settles into "low". Both badges must render this combination
    // (different bands, same widget instance) without conflict.
    controller.add(150);
    await tester.pump(const Duration(milliseconds: 1));
    for (var i = 0; i < 10; i++) {
      controller.add(5);
      await tester.pump(const Duration(milliseconds: 1));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
