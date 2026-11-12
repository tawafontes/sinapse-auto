import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/charge_record.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/refuel_record.dart';
import 'package:synapse_auto/models/vehicle_profile.dart';
import 'package:synapse_auto/screens/vehicle/charge_form_screen.dart';
import 'package:synapse_auto/screens/vehicle/consumption_report_screen.dart';
import 'package:synapse_auto/screens/vehicle/refuel_form_screen.dart';
import 'package:synapse_auto/screens/vehicle/refuel_list_screen.dart';
import 'package:synapse_auto/screens/vehicle/vehicle_profile_screen.dart';
import 'package:synapse_auto/services/fuel_consumption.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/vehicle_repository.dart';
import 'package:synapse_auto/widgets/vehicle/refuel_summary_widget.dart';

// The plug-in hybrid screens (2026-11-12) over in-memory Hive boxes, like
// vehicle_refuel_screens_test.dart.
void main() {
  final now = DateTime.now();

  setUp(() async {
    if (!Hive.isAdapterRegistered(FuelTypeAdapter().typeId)) {
      Hive.registerAdapter(FuelTypeAdapter());
      Hive.registerAdapter(VehicleFuelSystemAdapter());
      Hive.registerAdapter(VehicleProfileAdapter());
      Hive.registerAdapter(RefuelRecordAdapter());
      Hive.registerAdapter(VehiclePropulsionAdapter());
      Hive.registerAdapter(ChargeRecordAdapter());
    }
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
    }
    await Hive.openBox<VehicleProfile>(HiveBoxNames.vehicleProfile, bytes: Uint8List(0));
    await Hive.openBox<RefuelRecord>(HiveBoxNames.refuelRecords, bytes: Uint8List(0));
    await Hive.openBox<ChargeRecord>(HiveBoxNames.chargeRecords, bytes: Uint8List(0));
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions, bytes: Uint8List(0));
  });

  tearDown(() => Hive.close());

  VehicleProfile plugIn({bool auto = true}) => VehicleProfile(
        fuelSystem: VehicleFuelSystem.gasoline,
        tankCapacityLiters: 55,
        kmPerLiterGasoline: 14,
        defaultFuel: FuelType.gasoline,
        propulsion: VehiclePropulsion.plugInHybrid,
        batteryCapacityKwh: 17,
        electricRangeKm: 68,
        autoUpdateReferences: auto,
      );

  ChargeRecord charge(String id, DateTime date, double odometer, double start, double end, {bool usedFuel = false, double? range}) =>
      ChargeRecord(
        id: id,
        date: date,
        odometerKm: odometer,
        startPercent: start,
        endPercent: end,
        pricePerKwh: 1,
        wallKwh: 10,
        usedFuelSinceLast: usedFuel,
        panelFuelRangeKm: range,
      );

  Future<void> pumpPushed(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
              child: const Text('home'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  String text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  group('Meu veículo', () {
    testWidgets('Plug-in asks for the battery and the electric range; the reference switch starts on', (tester) async {
      await pumpPushed(tester, const VehicleProfileScreen());
      expect(find.byKey(const ValueKey('vehicle_battery')), findsNothing);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('vehicle_autoUpdate'))).value, isTrue);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('vehicle_propulsion')), matching: find.text('Plug-in')));
      await tester.pump();
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('vehicle_fuelSystem')), matching: find.text('Gasolina')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('vehicle_tank')), '55');
      await tester.enterText(find.byKey(const ValueKey('vehicle_reference_gasoline')), '14');
      await tapKey(tester, 'vehicle_save');
      expect(find.text('Informe a capacidade útil da bateria em kWh.'), findsOneWidget);
      expect(find.text('Informe a autonomia elétrica em km.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('vehicle_battery')), '19,1');
      await tester.enterText(find.byKey(const ValueKey('vehicle_electricRange')), '73');
      await tester.enterText(find.byKey(const ValueKey('vehicle_kwhPrice')), '0,92');
      await tapKey(tester, 'vehicle_autoUpdate');
      await tapKey(tester, 'vehicle_save');
      final p = VehicleRepository.profile!;
      expect((p.propulsion, p.batteryCapacityKwh, p.electricRangeKm, p.autoUpdateReferences, p.defaultPricePerKwh),
          (VehiclePropulsion.plugInHybrid, 19.1, 73.0, false, 0.92));
    });

    testWidgets('a (non plug-in) hybrid stores no battery', (tester) async {
      await VehicleRepository.save(plugIn());
      await pumpPushed(tester, const VehicleProfileScreen());
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('vehicle_propulsion')), matching: find.text('Híbrido')));
      await tester.pump();
      expect(find.byKey(const ValueKey('vehicle_battery')), findsNothing);
      await tapKey(tester, 'vehicle_save');
      final p = VehicleRepository.profile!;
      expect((p.propulsion, p.batteryCapacityKwh, p.electricRangeKm), (VehiclePropulsion.hybrid, null, null));
    });
  });

  group('recharge form', () {
    setUp(() async {
      await VehicleRepository.save(plugIn()..defaultPricePerKwh = 0.85);
      await ChargeRepository.save(charge('c0', now.subtract(const Duration(days: 2)), 15000, 20, 100));
    });

    testWidgets('"Recarregar" switches the register form; the odometer suggestion spans recharges', (tester) async {
      await pumpPushed(tester, const RefuelFormScreen());
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('energyKind')), matching: find.text('Recarregar')));
      await tester.pumpAndSettle();
      expect(find.byType(ChargeFormScreen), findsOneWidget);
      expect(find.byType(RefuelFormScreen), findsNothing);
      expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('charge_odometer')), matching: find.byType(EditableText))).controller.text, '15000');
    });

    testWidgets('without the charger\'s kWh, the total comes from the % span with the 10% margin', (tester) async {
      await pumpPushed(tester, const ChargeFormScreen());
      await tester.enterText(find.byKey(const ValueKey('charge_start')), '20');
      await tester.enterText(find.byKey(const ValueKey('charge_end')), '100');
      await tester.enterText(find.byKey(const ValueKey('charge_price')), '1');
      await tester.pump();
      // 80% of 17 kWh = 13.6 kWh, + 10% = 14.96 kWh.
      expect(text(tester, 'charge_energy'), contains('15,0 kWh estimados pelo %, com 10% de perdas'));
      expect(text(tester, 'charge_total'), 'R\$ 14,96');

      await tester.enterText(find.byKey(const ValueKey('charge_kwh')), '15,2');
      await tester.pump();
      expect(text(tester, 'charge_energy'), '15,2 kWh do carregador');
      expect(text(tester, 'charge_total'), 'R\$ 15,20');
    });

    testWidgets('fuel used asks for the panel\'s fuel range; saving stores every field', (tester) async {
      await pumpPushed(tester, const ChargeFormScreen());
      await tester.enterText(find.byKey(const ValueKey('charge_odometer')), '15080');
      await tester.enterText(find.byKey(const ValueKey('charge_start')), '5');
      await tester.enterText(find.byKey(const ValueKey('charge_end')), '100');
      await tester.enterText(find.byKey(const ValueKey('charge_price')), '0,92');
      await tapKey(tester, 'charge_usedFuel');
      await tapKey(tester, 'charge_save');
      expect(find.text('Informe a autonomia a combustão que o painel mostra agora.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('charge_range')), '540');
      await tapKey(tester, 'charge_save');
      expect(find.text('home'), findsOneWidget, reason: 'saved and closed');
      final c = ChargeRepository.chronological.last;
      expect((c.odometerKm, c.startPercent, c.endPercent, c.chargerKwh, c.pricePerKwh, c.usedFuelSinceLast, c.panelFuelRangeKm),
          (15080.0, 5.0, 100.0, null, 0.92, true, 540.0));
      expect(c.wallKwh, closeTo(0.95 * 17 * 1.1, 1e-9));
    });

    testWidgets('the price starts at the default of Meu veículo; changing it for one recharge keeps the default', (tester) async {
      await pumpPushed(tester, const ChargeFormScreen());
      String price() => tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('charge_price')), matching: find.byType(EditableText))).controller.text;
      expect(price(), '0,85');
      await tester.enterText(find.byKey(const ValueKey('charge_odometer')), '15030');
      await tester.enterText(find.byKey(const ValueKey('charge_start')), '50');
      await tester.enterText(find.byKey(const ValueKey('charge_end')), '100');
      await tester.enterText(find.byKey(const ValueKey('charge_price')), '2,5');
      await tapKey(tester, 'charge_save');
      expect(ChargeRepository.chronological.last.pricePerKwh, 2.5);
      expect(VehicleRepository.profile!.defaultPricePerKwh, 0.85);
    });

    testWidgets('the end % must be above the start %', (tester) async {
      await pumpPushed(tester, const ChargeFormScreen());
      await tester.enterText(find.byKey(const ValueKey('charge_start')), '80');
      await tester.enterText(find.byKey(const ValueKey('charge_end')), '60');
      await tester.enterText(find.byKey(const ValueKey('charge_price')), '1');
      await tapKey(tester, 'charge_save');
      expect(find.text('Precisa ser maior que o % inicial.'), findsOneWidget);
      expect(ChargeRepository.chronological, hasLength(1));
    });
  });

  testWidgets('a plug-in refuel asks whether fuel was used and the panel range before and after', (tester) async {
    await VehicleRepository.save(plugIn());
    await pumpPushed(tester, const RefuelFormScreen());
    expect(find.byKey(const ValueKey('refuel_rangeBefore')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('refuel_odometer')), '15000');
    await tester.enterText(find.byKey(const ValueKey('refuel_liters')), '20');
    await tester.enterText(find.byKey(const ValueKey('refuel_price')), '6');
    await tapKey(tester, 'refuel_usedFuel');
    await tapKey(tester, 'refuel_save');
    expect(find.text('Informe a autonomia a combustão que o painel mostra.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('refuel_rangeBefore')), '320');
    await tester.enterText(find.byKey(const ValueKey('refuel_rangeAfter')), '610');
    await tapKey(tester, 'refuel_save');
    final r = RefuelRepository.chronological.single;
    expect((r.usedFuelSinceLast, r.panelFuelRangeBeforeKm, r.panelFuelRangeAfterKm), (true, 320.0, 610.0));
  });

  testWidgets('the list is one timeline, with the km/kWh each recharge measured', (tester) async {
    await VehicleRepository.save(plugIn());
    await ChargeRepository.save(charge('c1', now.subtract(const Duration(days: 4)), 15000, 20, 100));
    await RefuelRepository.save(RefuelRecord(
      id: 'r1',
      date: now.subtract(const Duration(days: 3)),
      odometerKm: 15020,
      liters: 5,
      pricePerLiter: 6,
      fuel: FuelType.gasoline,
      fullTank: false,
      usedFuelSinceLast: false,
    ));
    await ChargeRepository.save(charge('c2', now.subtract(const Duration(days: 1)), 15060, 30, 100));
    await pumpPushed(tester, const RefuelListScreen());
    expect(find.text('Abastecimentos e recargas'), findsOneWidget);
    final c2 = tester.getTopLeft(find.byKey(const ValueKey('refuelList_c2'))).dy;
    final r1 = tester.getTopLeft(find.byKey(const ValueKey('refuelList_r1'))).dy;
    final c1 = tester.getTopLeft(find.byKey(const ValueKey('refuelList_c1'))).dy;
    expect(c2 < r1 && r1 < c1, isTrue, reason: 'newest first, both kinds mixed');
    // 60 km on 70% of 17 kWh.
    expect(find.textContaining('5,0 km/kWh em 60 km elétricos'), findsOneWidget);
  });

  testWidgets('the dashboard widget of a plug-in shows the electric estimate and the panel\'s fuel range', (tester) async {
    await VehicleRepository.save(plugIn()); // 68 km / 17 kWh = 4 km/kWh
    await RefuelRepository.save(RefuelRecord(
      id: 'r1',
      date: now.subtract(const Duration(days: 5)),
      odometerKm: 14900,
      liters: 30,
      pricePerLiter: 6,
      fuel: FuelType.gasoline,
      fullTank: true,
      panelFuelRangeAfterKm: 610,
    ));
    await ChargeRepository.save(charge('c1', now.subtract(const Duration(hours: 10)), 15000, 20, 100));
    await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions)
        .put('s', DrivingSession(id: 's', startTime: now.subtract(const Duration(hours: 2)))..distanceMeters = 34000);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(width: 220, height: 300, child: RefuelSummaryWidget()))));
    expect(text(tester, 'refuelWidget_electricRange'), '~34 km');
    expect(text(tester, 'refuelWidget_batteryPercent'), '~50% de bateria');
    expect(text(tester, 'refuelWidget_fuelRange'), 'Combustão: 610 km');
    await tester.tap(find.byKey(const ValueKey('refuelWidget_register')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('energyKind')), findsOneWidget, reason: 'the form offers Abastecer | Recarregar');
  });

  testWidgets('the plug-in report: combined cost per km, electric share and km/kWh', (tester) async {
    await VehicleRepository.save(plugIn());
    await RefuelRepository.save(RefuelRecord(
      id: 'r1',
      date: now.subtract(const Duration(days: 10)),
      odometerKm: 14900,
      liters: 30,
      pricePerLiter: 6,
      fuel: FuelType.gasoline,
      fullTank: true,
      panelFuelRangeAfterKm: 600,
    ));
    await ChargeRepository.save(charge('c1', now.subtract(const Duration(days: 8)), 15000, 20, 100));
    await ChargeRepository.save(charge('c2', now.subtract(const Duration(days: 6)), 15060, 30, 100));
    await ChargeRepository.save(charge('c3', now.subtract(const Duration(days: 2)), 15300, 5, 100, usedFuel: true, range: 560));
    await pumpPushed(tester, const ConsumptionReportScreen());
    // Span 400 km; spent after the first record: 3 × R$ 10.
    expect(text(tester, 'report_hybrid_costPerKm'), formatMoney(30 / 400));
    expect(text(tester, 'report_hybrid_fuelKm'), '40 km');
    expect(text(tester, 'report_hybrid_share'), '90%');
    expect(text(tester, 'report_hybrid_kmPerKwh'), '5,0 km/kWh');
  });
}
