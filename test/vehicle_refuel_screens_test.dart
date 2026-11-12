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
import 'package:synapse_auto/screens/vehicle/consumption_report_screen.dart';
import 'package:synapse_auto/screens/vehicle/refuel_form_screen.dart';
import 'package:synapse_auto/screens/vehicle/refuel_list_screen.dart';
import 'package:synapse_auto/screens/vehicle/vehicle_menu_screen.dart';
import 'package:synapse_auto/screens/vehicle/vehicle_profile_screen.dart';
import 'package:synapse_auto/services/fuel_consumption.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/vehicle_repository.dart';
import 'package:synapse_auto/widgets/vehicle/refuel_summary_widget.dart';

// The vehicle screens and the dashboard's refuel widget (2026-11-12) over
// in-memory Hive boxes (`bytes:`): the screens' saves complete without file I/O,
// so they run inside the widget test's fake zone like any other future. The
// on-disk round trip is covered in vehicle_refuel_persistence_test.dart.
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

  Box<RefuelRecord> refuelsBox() => Hive.box<RefuelRecord>(HiveBoxNames.refuelRecords);

  VehicleProfile flex({FuelType defaultFuel = FuelType.gasoline}) => VehicleProfile(
        fuelSystem: VehicleFuelSystem.flex,
        tankCapacityLiters: 50,
        kmPerLiterGasoline: 12,
        kmPerLiterEthanol: 8.4,
        defaultFuel: defaultFuel,
      );

  RefuelRecord refuel(String id, DateTime date, double odometer, {double liters = 40, double price = 6, FuelType fuel = FuelType.gasoline, bool full = true}) =>
      RefuelRecord(id: id, date: date, odometerKm: odometer, liters: liters, pricePerLiter: price, fuel: fuel, fullTank: full);

  /// [screen] pushed over a home page, so a pop is observable (the home's text
  /// shows again).
  Future<void> pumpPushed(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 2400);
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

  String fieldText(WidgetTester tester, String key) => tester
      .widget<EditableText>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)))
      .controller
      .text;

  Future<void> tapSave(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  group('refuel form', () {
    setUp(() async {
      await VehicleRepository.save(flex());
      final last = now.subtract(const Duration(days: 5));
      await RefuelRepository.save(refuel('r1', last, 12000));
      await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).put(
        's1',
        DrivingSession(id: 's1', startTime: last.add(const Duration(days: 1)), endTime: last.add(const Duration(days: 1, hours: 1)))
          ..distanceMeters = 150400,
      );
    });

    testWidgets('suggests the last odometer plus the km the app recorded, and computes the total', (tester) async {
      await pumpPushed(tester, const RefuelFormScreen());
      expect(fieldText(tester, 'refuel_odometer'), '12150');
      expect(find.textContaining('150 km registrados pelo app'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('refuel_total'))).data, '—');

      await tester.enterText(find.byKey(const ValueKey('refuel_liters')), '40');
      await tester.enterText(find.byKey(const ValueKey('refuel_price')), '6,299');
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('refuel_total'))).data, 'R\$ 251,96');
    });

    testWidgets('refuses an odometer that is not above the previous refuel\'s', (tester) async {
      await pumpPushed(tester, const RefuelFormScreen());
      await tester.enterText(find.byKey(const ValueKey('refuel_odometer')), '11000');
      await tester.enterText(find.byKey(const ValueKey('refuel_liters')), '40');
      await tester.enterText(find.byKey(const ValueKey('refuel_price')), '6');
      await tapSave(tester, 'refuel_save');
      expect(find.textContaining('maior que o do abastecimento anterior (12.000 km)'), findsOneWidget);
      expect(refuelsBox().length, 1, reason: 'nothing saved');
    });

    testWidgets('refuses litres beyond the tank and a missing price', (tester) async {
      await pumpPushed(tester, const RefuelFormScreen());
      await tester.enterText(find.byKey(const ValueKey('refuel_liters')), '70');
      await tapSave(tester, 'refuel_save');
      expect(find.textContaining('Mais do que cabe no tanque'), findsOneWidget);
      expect(find.text('Informe o preço por litro.'), findsOneWidget);
      expect(refuelsBox().length, 1);
    });

    testWidgets('saves every field, closes, and a flex refuel with ethanol becomes the default', (tester) async {
      await pumpPushed(tester, const RefuelFormScreen());
      await tester.enterText(find.byKey(const ValueKey('refuel_liters')), '35,5');
      await tester.enterText(find.byKey(const ValueKey('refuel_price')), '4.19');
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('refuel_fuel')), matching: find.text('Etanol')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('refuel_fullTank')));
      await tester.tap(find.byKey(const ValueKey('refuel_fullTank')));
      await tapSave(tester, 'refuel_save');

      expect(find.text('home'), findsOneWidget, reason: 'the form closed');
      final saved = RefuelRepository.chronological.last;
      expect(
        (saved.odometerKm, saved.liters, saved.pricePerLiter, saved.fuel, saved.fullTank),
        (12150.0, 35.5, 4.19, FuelType.ethanol, false),
      );
      expect(VehicleRepository.profile!.defaultFuel, FuelType.ethanol);
    });

    testWidgets('editing keeps the id and shows the stored values', (tester) async {
      final stored = RefuelRepository.chronological.single;
      await pumpPushed(tester, RefuelFormScreen(editing: stored));
      expect(find.text('Editar abastecimento'), findsOneWidget);
      expect(fieldText(tester, 'refuel_odometer'), '12000');
      expect(fieldText(tester, 'refuel_liters'), '40');
      await tester.enterText(find.byKey(const ValueKey('refuel_liters')), '38');
      await tapSave(tester, 'refuel_save');
      expect(refuelsBox().length, 1);
      expect(RefuelRepository.chronological.single.liters, 38);
      expect(RefuelRepository.chronological.single.id, 'r1');
    });
  });

  testWidgets('without a vehicle the refuel form offers to register it first', (tester) async {
    await pumpPushed(tester, const RefuelFormScreen());
    expect(find.text('Cadastrar meu veículo'), findsOneWidget);
    expect(find.byKey(const ValueKey('refuel_save')), findsNothing);
  });

  group('Meu veículo', () {
    testWidgets('requires the tank and each reference consumption, then saves the profile', (tester) async {
      await pumpPushed(tester, const VehicleProfileScreen());
      await tapSave(tester, 'vehicle_save');
      expect(find.text('Informe a capacidade do tanque em litros.'), findsOneWidget);
      expect(find.text('Informe o consumo em km/L.'), findsNWidgets(2), reason: 'flex: gasoline and ethanol');
      expect(VehicleRepository.profile, isNull);

      await tester.enterText(find.byKey(const ValueKey('vehicle_nickname')), 'Onix');
      await tester.enterText(find.byKey(const ValueKey('vehicle_tank')), '44');
      await tester.enterText(find.byKey(const ValueKey('vehicle_reference_gasoline')), '13,1');
      await tester.enterText(find.byKey(const ValueKey('vehicle_reference_ethanol')), '9,2');
      await tester.ensureVisible(find.byKey(const ValueKey('vehicle_defaultFuel')));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('vehicle_defaultFuel')), matching: find.text('Etanol')));
      await tapSave(tester, 'vehicle_save');

      expect(find.text('home'), findsOneWidget);
      final p = VehicleRepository.profile!;
      expect(
        (p.nickname, p.fuelSystem, p.tankCapacityLiters, p.kmPerLiterGasoline, p.kmPerLiterEthanol, p.defaultFuel),
        ('Onix', VehicleFuelSystem.flex, 44.0, 13.1, 9.2, FuelType.ethanol),
      );
    });

    testWidgets('a diesel vehicle asks only for the diesel consumption and stores no other', (tester) async {
      await VehicleRepository.save(flex());
      await pumpPushed(tester, const VehicleProfileScreen());
      expect(fieldText(tester, 'vehicle_tank'), '50');
      expect(fieldText(tester, 'vehicle_reference_ethanol'), '8,4');
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('vehicle_fuelSystem')), matching: find.text('Diesel')));
      await tester.pump();
      expect(find.byKey(const ValueKey('vehicle_reference_gasoline')), findsNothing);
      expect(find.byKey(const ValueKey('vehicle_defaultFuel')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('vehicle_reference_diesel')), '11');
      await tapSave(tester, 'vehicle_save');
      final p = VehicleRepository.profile!;
      expect((p.fuelSystem, p.kmPerLiterDiesel, p.kmPerLiterGasoline, p.kmPerLiterEthanol, p.defaultFuel),
          (VehicleFuelSystem.diesel, 11.0, null, null, FuelType.diesel));
    });
  });

  group('refuel list', () {
    testWidgets('newest first, with the consumption each full refuel closes, and deletes after confirming', (tester) async {
      await VehicleRepository.save(flex());
      await RefuelRepository.save(refuel('a', now.subtract(const Duration(days: 10)), 1000));
      await RefuelRepository.save(refuel('b', now.subtract(const Duration(days: 2)), 1480));
      await pumpPushed(tester, const RefuelListScreen());

      final a = tester.getTopLeft(find.byKey(const ValueKey('refuelList_a'))).dy;
      final b = tester.getTopLeft(find.byKey(const ValueKey('refuelList_b'))).dy;
      expect(b, lessThan(a), reason: 'newest first');
      expect(find.textContaining('12,0 km/L em 480 km'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('refuelList_delete_b')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Excluir'));
      await tester.pumpAndSettle();
      expect(refuelsBox().keys, ['a']);
      expect(find.byKey(const ValueKey('refuelList_b')), findsNothing);
    });
  });

  testWidgets('consumption report: averages against the reference and the ethanol break-even', (tester) async {
    await VehicleRepository.save(flex());
    await RefuelRepository.save(refuel('1', now.subtract(const Duration(days: 20)), 1000, fuel: FuelType.gasoline));
    await RefuelRepository.save(refuel('2', now.subtract(const Duration(days: 10)), 1480, fuel: FuelType.ethanol, price: 4));
    await RefuelRepository.save(refuel('3', now.subtract(const Duration(days: 1)), 1816, fuel: FuelType.gasoline, price: 6));
    await pumpPushed(tester, const ConsumptionReportScreen());

    expect(tester.widget<Text>(find.byKey(const ValueKey('report_fuel_gasoline'))).data, '12,0 km/L');
    expect(tester.widget<Text>(find.byKey(const ValueKey('report_fuel_ethanol'))).data, '8,4 km/L');
    expect(find.textContaining('igual à referência'), findsNWidgets(2));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('report_breakEven'))).data,
      contains('até 70% do preço da gasolina (pelo consumo que você mediu)'),
    );
    expect(find.textContaining('(67%) — o etanol compensa.'), findsOneWidget, reason: '4 / 6 = 67% ≤ 70%');
  });

  testWidgets('the vehicle menu leads to Meu veículo, Abastecimentos and Relatórios → Consumo', (tester) async {
    await pumpPushed(tester, const VehicleMenuScreen());
    expect(find.text('Cadastre o tanque e o consumo de referência'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vehicleMenu_reports')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reportsMenu_consumption')));
    await tester.pumpAndSettle();
    expect(find.byType(ConsumptionReportScreen), findsOneWidget);
  });

  group('dashboard refuel widget', () {
    Future<void> pumpWidget(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(width: 200, height: 200, child: RefuelSummaryWidget()))));
    }

    testWidgets('without a vehicle: asks to register it', (tester) async {
      await pumpWidget(tester);
      expect(find.byKey(const ValueKey('refuelWidget_setUpVehicle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('refuelWidget_setUpVehicle')));
      await tester.pumpAndSettle();
      expect(find.byType(VehicleProfileScreen), findsOneWidget);
    });

    testWidgets('follows the log live: from no refuel to the estimated range', (tester) async {
      await VehicleRepository.save(flex());
      await pumpWidget(tester);
      expect(find.text('Nenhum abastecimento registrado'), findsOneWidget);

      await RefuelRepository.save(refuel('1', now.subtract(const Duration(days: 3)), 1000));
      await RefuelRepository.save(refuel('2', now.subtract(const Duration(days: 1)), 1400));
      await tester.pump();
      // 400 km / 40 L = 10 km/L; a full 50 L tank → ~500 km.
      expect(tester.widget<Text>(find.byKey(const ValueKey('refuelWidget_range'))).data, '~500 km');
      expect(find.text('50,00 L no tanque'), findsOneWidget);

      await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions)
          .put('s', DrivingSession(id: 's', startTime: now.subtract(const Duration(hours: 5)))..distanceMeters = 120000);
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('refuelWidget_range'))).data, '~380 km');
      expect(find.textContaining('120 km desde o abastecimento'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('refuelWidget_register')));
      await tester.pumpAndSettle();
      expect(find.byType(RefuelFormScreen), findsOneWidget);
    });

    testWidgets('fits a small tile without overflowing', (tester) async {
      await VehicleRepository.save(flex());
      await RefuelRepository.save(refuel('1', now.subtract(const Duration(days: 3)), 1000));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 90, height: 70, child: RefuelSummaryWidget())))));
      expect(tester.takeException(), isNull);
      expect(find.byType(RefuelSummaryView), findsOneWidget);
    });
  });

  test('editableNumber drops a trailing zero and uses a decimal comma', () {
    expect(editableNumber(50), '50');
    expect(editableNumber(47.5), '47,5');
    expect(editableNumber(6.299), '6,299');
    expect(editableNumber(12345.6), '12.345,6');
    expect(editableNumber(null), '');
    expect(formatKm(1234), '1.234 km');
  });
}
