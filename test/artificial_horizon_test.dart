import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/sensors/artificial_horizon.dart';

void main() {
  group('pitchRiskZone', () {
    test('boundaries are inclusive on the safer side, symmetric for +/-', () {
      for (final sign in [1, -1]) {
        expect(pitchRiskZone(20.0 * sign), InclinationRiskZone.safe);
        expect(pitchRiskZone(20.01 * sign), InclinationRiskZone.risk);
        expect(pitchRiskZone(25.0 * sign), InclinationRiskZone.risk);
        expect(pitchRiskZone(25.01 * sign), InclinationRiskZone.highRisk);
        expect(pitchRiskZone(30.0 * sign), InclinationRiskZone.highRisk);
        expect(pitchRiskZone(30.01 * sign), InclinationRiskZone.veryHighRisk);
      }
    });
  });

  group('rollRiskZone', () {
    test('boundaries are inclusive on the safer side, symmetric for +/-', () {
      for (final sign in [1, -1]) {
        expect(rollRiskZone(15.0 * sign), InclinationRiskZone.safe);
        expect(rollRiskZone(15.01 * sign), InclinationRiskZone.risk);
        expect(rollRiskZone(20.0 * sign), InclinationRiskZone.risk);
        expect(rollRiskZone(20.01 * sign), InclinationRiskZone.highRisk);
        expect(rollRiskZone(25.0 * sign), InclinationRiskZone.highRisk);
        expect(rollRiskZone(25.01 * sign), InclinationRiskZone.veryHighRisk);
      }
    });
  });

  group('formatSignedDegrees', () {
    test('positive values get an explicit +', () {
      expect(formatSignedDegrees(10), '+10');
      expect(formatSignedDegrees(0.6), '+1'); // rounds to 1 first.
    });

    test('negative values already carry - from the default int format', () {
      expect(formatSignedDegrees(-10), '-10');
      expect(formatSignedDegrees(-0.6), '-1');
    });

    test('zero (or anything that rounds to it) never gets a sign, not even "-0"', () {
      expect(formatSignedDegrees(0), '0');
      expect(formatSignedDegrees(0.3), '0');
      expect(formatSignedDegrees(-0.3), '0');
    });
  });

  group('moreSevereZone', () {
    test('picks whichever zone is worse, either argument order', () {
      expect(moreSevereZone(InclinationRiskZone.safe, InclinationRiskZone.risk), InclinationRiskZone.risk);
      expect(moreSevereZone(InclinationRiskZone.risk, InclinationRiskZone.safe), InclinationRiskZone.risk);
      expect(
        moreSevereZone(InclinationRiskZone.veryHighRisk, InclinationRiskZone.highRisk),
        InclinationRiskZone.veryHighRisk,
      );
      expect(moreSevereZone(InclinationRiskZone.safe, InclinationRiskZone.safe), InclinationRiskZone.safe);
    });
  });

  group('ArtificialHorizon widget', () {
    Future<void> pumpWith(
      WidgetTester tester,
      StreamController<Offset> controller, {
      double initialPitchOffsetDeg = 0.0,
      double initialRollOffsetDeg = 0.0,
      void Function(double, double)? onCalibrated,
      ValueChanged<Color?>? onAlertColorChanged,
      ValueChanged<VoidCallback>? onResetRequested,
      ValueChanged<VoidCallback>? onImmediateResetRequested,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 300,
              child: ArtificialHorizon(
                pitchRollStream: controller.stream,
                initialPitchOffsetDeg: initialPitchOffsetDeg,
                initialRollOffsetDeg: initialRollOffsetDeg,
                onCalibrated: onCalibrated,
                onAlertColorChanged: onAlertColorChanged,
                onResetRequested: onResetRequested,
                onImmediateResetRequested: onImmediateResetRequested,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('an initial calibration offset is applied to raw readings', (tester) async {
      final controller = StreamController<Offset>();
      addTearDown(controller.close);
      await pumpWith(tester, controller, initialPitchOffsetDeg: 5.0, initialRollOffsetDeg: -3.0);

      controller.add(const Offset(12.0, 10.0)); // raw pitch=12, raw roll=10
      await tester.pump(const Duration(milliseconds: 1));

      // Calibrated = raw - offset: pitch 12-5=7, roll 10-(-3)=13.
      expect(find.text('PITCH +7°'), findsOneWidget);
      expect(find.text('ROLL +13°'), findsOneWidget);
    });

    testWidgets('reset trigger calibration zeroes the current raw reading and reports the offset', (tester) async {
      final controller = StreamController<Offset>();
      addTearDown(controller.close);
      double? reportedPitchOffset;
      double? reportedRollOffset;
      VoidCallback? triggerReset;
      await pumpWith(
        tester,
        controller,
        onCalibrated: (pitchOffset, rollOffset) {
          reportedPitchOffset = pitchOffset;
          reportedRollOffset = rollOffset;
        },
        onResetRequested: (trigger) => triggerReset = trigger,
      );

      controller.add(const Offset(8.0, -4.0));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('PITCH +8°'), findsOneWidget);
      expect(find.text('ROLL -4°'), findsOneWidget);

      triggerReset!();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Calibrar agora'));
      await tester.pumpAndSettle();

      // The reading that was current at calibration time becomes the new
      // zero, so the displayed value should read 0 immediately after.
      expect(find.text('PITCH 0°'), findsOneWidget);
      expect(find.text('ROLL 0°'), findsOneWidget);
      expect(reportedPitchOffset, 8.0);
      expect(reportedRollOffset, -4.0);

      // Toast confirmation shown.
      expect(find.text('Horizonte artificial calibrado.'), findsOneWidget);
    });

    testWidgets('canceling the calibration dialog leaves the offset untouched', (tester) async {
      final controller = StreamController<Offset>();
      addTearDown(controller.close);
      var calibrated = false;
      VoidCallback? triggerReset;
      await pumpWith(
        tester,
        controller,
        onCalibrated: (pitchOffset, rollOffset) => calibrated = true,
        onResetRequested: (trigger) => triggerReset = trigger,
      );

      controller.add(const Offset(8.0, -4.0));
      await tester.pump(const Duration(milliseconds: 1));

      triggerReset!();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(find.text('PITCH +8°'), findsOneWidget);
      expect(calibrated, isFalse);
    });

    testWidgets('immediate reset trigger calibrates instantly with no dialog and no SnackBar of its own', (
      tester,
    ) async {
      final controller = StreamController<Offset>();
      addTearDown(controller.close);
      double? reportedPitchOffset;
      double? reportedRollOffset;
      VoidCallback? triggerImmediateReset;
      await pumpWith(
        tester,
        controller,
        onCalibrated: (pitchOffset, rollOffset) {
          reportedPitchOffset = pitchOffset;
          reportedRollOffset = rollOffset;
        },
        onImmediateResetRequested: (trigger) => triggerImmediateReset = trigger,
      );

      controller.add(const Offset(8.0, -4.0));
      await tester.pump(const Duration(milliseconds: 1));

      triggerImmediateReset!();
      await tester.pump();

      expect(find.text('PITCH 0°'), findsOneWidget);
      expect(find.text('ROLL 0°'), findsOneWidget);
      expect(reportedPitchOffset, 8.0);
      expect(reportedRollOffset, -4.0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Horizonte artificial calibrado.'), findsNothing);
    });

    testWidgets('reports null while safe, a color once a risk zone is entered, and no duplicates', (tester) async {
      final controller = StreamController<Offset>();
      addTearDown(controller.close);
      final reported = <Color?>[];
      await pumpWith(tester, controller, onAlertColorChanged: reported.add);

      controller.add(const Offset(5, 5)); // safe: no report needed (already null).
      await tester.pump(const Duration(milliseconds: 1));
      expect(reported, isEmpty);

      controller.add(const Offset(28, 5)); // pitch 28° -> highRisk zone.
      await tester.pump(const Duration(milliseconds: 1));
      expect(reported, hasLength(1));
      expect(reported.single, isNotNull);

      controller.add(const Offset(28, 6)); // still highRisk: no new report.
      await tester.pump(const Duration(milliseconds: 1));
      expect(reported, hasLength(1));

      controller.add(const Offset(5, 5)); // back to safe.
      await tester.pump(const Duration(milliseconds: 1));
      expect(reported, [reported.first, null]);
    });
  });
}
