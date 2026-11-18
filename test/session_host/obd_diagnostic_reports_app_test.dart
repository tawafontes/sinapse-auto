import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/diagnostic_report.dart';
import 'package:synapse_auto/services/driving_session_host.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/obd/diagnostic/diagnostic_report_repository.dart';
import 'package:synapse_auto/services/obd/obd_service.dart';

import '../support/app_harness.dart';
import '../support/fake_obd_car.dart';

/// The diagnostic reports in the REAL app over the scripted Nivus with a
/// misfire code: Configurações → Diagnóstico, down to "Diagnóstico do carro",
/// Saúde do veículo → Executar → the codes with their descriptions; clearing
/// them (engine off, held button) and the report after, linked to the one
/// before; both in the history.
void main() {
  testWidgets('the health report, clearing the codes, the history', (tester) async {
    final app = AppHarness(tester);
    final car = FakeObdCar()..withEngineCodes();
    DrivingSessionHost.debugObdBridgeOverride = car;
    try {
      await app.run(() async {
        await app.boot(beforeBootstrap: () async {
          final box = Hive.box(HiveBoxNames.appSettings);
          await box.put('obdAdapterAddress', '10:21:3E:4C:3A:AF');
          await box.put('obdAdapterName', 'V-LINK');
        });
        final obd = app.host.obd!;
        await app.driveUntil(() => obd.state == ObdLinkState.receiving, label: 'receiving');

        await app.openSettings();
        await app.tapText('Diagnóstico');
        await tester.dragUntilVisible(find.byKey(const ValueKey('carDiagnostics_health')), find.byType(ListView).last, const Offset(0, -300));
        await app.drive(const Duration(milliseconds: 300));
        expect(app.shows('Recebendo dados'), isTrue);
        expect(app.shows('último: —'), isTrue);
        await tester.tap(find.byKey(const ValueKey('carDiagnostics_health')));
        await app.drive(const Duration(milliseconds: 500));

        await tester.tap(find.byKey(const ValueKey('diagRun_execute')));
        await app.driveUntil(() => find.byKey(const ValueKey('diagReport_summary')).evaluate().isNotEmpty, label: 'the report');
        expect(tester.widget<Text>(find.byKey(const ValueKey('diagReport_summary'))).data, '2 códigos · luz de injeção acesa');
        await app.driveUntil(() => find.textContaining('cilindro 1').evaluate().isNotEmpty, label: 'P0301 described from the table');
        expect(find.text('P0301 · armazenado'), findsOneWidget);
        expect(find.text('P0171 · pendente'), findsOneWidget);
        expect(find.textContaining('9BW'), findsWidgets, reason: 'the VIN, masked');
        expect(find.textContaining(car.vin), findsNothing, reason: 'never whole on screen');

        // Clearing: the engine off, the ignition on, the button held.
        car.ignition = FakeIgnition.on;
        await app.drive(const Duration(seconds: 2));
        await tester.dragUntilVisible(find.byKey(const ValueKey('diagRun_clear')), find.byType(ListView).last, const Offset(0, -300));
        await tester.tap(find.byKey(const ValueKey('diagRun_clear')));
        await app.drive(const Duration(milliseconds: 500));
        expect(app.shows('Apagar os códigos do motor?'), isTrue);
        // A tap is not enough.
        await tester.tap(find.byKey(const ValueKey('diagRun_holdToClear')));
        await app.drive(const Duration(milliseconds: 500));
        expect(app.shows('Apagar os códigos do motor?'), isTrue);
        expect(car.sent, isNot(contains('04')));
        final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('diagRun_holdToClear'))));
        await app.drive(const Duration(milliseconds: 2500));
        await gesture.up();
        await app.driveUntil(() => app.shows('Depois de apagar os códigos:'), label: 'the report after clearing');
        await app.driveUntil(() => tester.widget<Text>(find.byKey(const ValueKey('diagReport_summary')).first).data == 'Sem códigos de falha',
            label: 'no codes left');
        expect(car.sent, contains('04'));

        final reports = DiagnosticReportRepository.newestFirst;
        expect(reports.length, 2);
        expect(reports.first.beforeId, reports.last.id);
        expect(reports.every((r) => r.type == DiagnosticReportType.health), isTrue);

        await tester.tap(find.byType(BackButton).last);
        await app.drive(const Duration(milliseconds: 500));
        await tester.dragUntilVisible(find.byKey(const ValueKey('carDiagnostics_history')), find.byType(ListView).last, const Offset(0, -300));
        expect(find.text('2 relatórios'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('carDiagnostics_history')));
        await app.drive(const Duration(milliseconds: 500));
        expect(find.byKey(ValueKey('diagHistory_${reports.first.id}')), findsOneWidget);
        expect(find.textContaining('Depois de apagar os códigos'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('diagHistory_star_${reports.last.id}')));
        await app.drive(const Duration(milliseconds: 300));
        expect(DiagnosticReportRepository.byId(reports.last.id)!.starred, isTrue);

        // Emissions after the clear: the monitors start over.
        await tester.tap(find.byType(BackButton).last);
        await app.drive(const Duration(milliseconds: 500));
        await tester.dragUntilVisible(find.byKey(const ValueKey('carDiagnostics_emissions')), find.byType(ListView).last, const Offset(0, 300));
        await tester.tap(find.byKey(const ValueKey('carDiagnostics_emissions')));
        await app.drive(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const ValueKey('diagRun_execute')));
        await app.driveUntil(() => find.byKey(const ValueKey('diagReport_advice')).evaluate().isNotEmpty, label: 'the emissions report');
        expect(app.shows('Ainda não está pronto'), isTrue);

        // The battery's rest step.
        await tester.tap(find.byType(BackButton).last);
        await app.drive(const Duration(milliseconds: 500));
        await tester.dragUntilVisible(find.byKey(const ValueKey('carDiagnostics_battery')), find.byType(ListView).last, const Offset(0, 300));
        await tester.tap(find.byKey(const ValueKey('carDiagnostics_battery')));
        await app.drive(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const ValueKey('diagBattery_rest')));
        await app.driveUntil(() => find.byKey(const ValueKey('diagBatteryStep_rest')).evaluate().isNotEmpty || find.byKey(const ValueKey('diagBattery_saved')).evaluate().isNotEmpty,
            label: 'the rest step');
        expect(find.byKey(const ValueKey('diagBattery_rest')), findsOneWidget);
        expect(DiagnosticReportRepository.newestFirst.where((r) => r.type == DiagnosticReportType.battery).length, 1);
      });
    } finally {
      DrivingSessionHost.debugObdBridgeOverride = null;
      await app.teardown();
    }
  });
}
