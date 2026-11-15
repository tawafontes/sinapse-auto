import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/models/vehicle_profile.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/obd/obd_consumption.dart';
import 'package:synapse_auto/services/obd/obd_preferences.dart';
import 'package:synapse_auto/services/obd/obd_service.dart';
import 'package:synapse_auto/services/vehicle_repository.dart';
import 'package:synapse_auto/widgets/sensors/obd_gauges.dart';
import 'package:synapse_auto/widgets/sensors/obd_panel.dart';

import 'support/fake_obd_car.dart';

void main() {
  group('instant consumption estimate', () {
    test('the Nivus idling: about 1 L/h, no km/L stopped', () {
      final c = estimateConsumption(manifoldPressureKpa: 35, rpm: 980, intakeTempC: 35, engineDisplacementLiters: 1.0, speedKmh: 0, ethanolPercent: 27)!;
      expect(c.litersPerHour, closeTo(1.0, 0.1));
      expect(c.kmPerLiter, isNull);
      expect(c.fromMaf, isFalse);
    });

    test('moving: km/L is the speed over the flow', () {
      final c = estimateConsumption(manifoldPressureKpa: 55, rpm: 1800, intakeTempC: 30, engineDisplacementLiters: 1.0, speedKmh: 60)!;
      expect(c.kmPerLiter, closeTo(60 / c.litersPerHour, 1e-9));
    });

    test('ethanol burns more litres for the same air', () {
      double lph(double e) => estimateConsumption(mafGramsPerSecond: 5, rpm: 1500, ethanolPercent: e)!.litersPerHour;
      expect(lph(100), greaterThan(lph(27)));
      expect(lph(27), greaterThan(lph(0)));
    });

    test('a MAF needs no displacement; without either, no estimate', () {
      expect(estimateConsumption(mafGramsPerSecond: 3, rpm: 900)!.fromMaf, isTrue);
      expect(estimateConsumption(manifoldPressureKpa: 35, rpm: 900, intakeTempC: 30), isNull, reason: 'no displacement');
    });

    test('an engine at 0 rpm burns nothing', () {
      expect(estimateConsumption(manifoldPressureKpa: 100, rpm: 0, intakeTempC: 25, engineDisplacementLiters: 1.0)!.litersPerHour, 0);
    });
  });

  group('the panels over the scripted Nivus', () {
    late FakeObdCar car;
    late ObdPreferences prefs;

    setUp(() async {
      Hive.init('unused');
      for (final adapter in <TypeAdapter<Object?>>[FuelTypeAdapter(), VehicleFuelSystemAdapter(), VehiclePropulsionAdapter(), VehicleProfileAdapter()]) {
        if (!Hive.isAdapterRegistered(adapter.typeId)) Hive.registerAdapter(adapter);
      }
      await Hive.openBox(HiveBoxNames.appSettings, bytes: Uint8List(0));
      await Hive.openBox<VehicleProfile>(HiveBoxNames.vehicleProfile, bytes: Uint8List(0));
      car = FakeObdCar();
      prefs = ObdPreferences();
      await prefs.setAdapter(address: '10:21:3E:4C:3A:AF', name: 'V-LINK');
    });

    tearDown(() async {
      await Hive.close();
    });

    Future<void> profile({double? displacement}) => VehicleRepository.save(VehicleProfile(
          fuelSystem: VehicleFuelSystem.flex,
          tankCapacityLiters: 52,
          defaultFuel: FuelType.gasoline,
          engineDisplacementLiters: displacement,
        ));

    Future<ObdService> mount(WidgetTester tester, SensorType type, {bool fullscreen = false}) async {
      final service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 240, height: 240, child: ObdPanelView(sensorType: type, service: service, fullscreen: fullscreen))),
      ));
      service.connect();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      return service;
    }

    Future<void> unmount(WidgetTester tester, ObdService service) async {
      await tester.pumpWidget(const SizedBox());
      service.dispose();
      await tester.pump(const Duration(seconds: 12));
    }

    String line(WidgetTester tester, String label) => () {
          final text = tester.widget<Text>(find.byKey(ValueKey('obdPanel_$label')));
          return text.textSpan?.toPlainText() ?? text.data!;
        }();

    testWidgets('fuel: %, litres with the tank of Meu veículo; maximized, the ethanol share', (tester) async {
      await tester.runAsync(() => profile());
      var service = await mount(tester, SensorType.fuelLevel);
      expect(line(tester, 'Tanque'), '50 %');
      expect(line(tester, 'Litros'), '≈ 26 L');
      expect(find.byKey(const ValueKey('obdPanel_Etanol na mistura')), findsNothing, reason: 'only maximized');
      await unmount(tester, service);

      service = await mount(tester, SensorType.fuelLevel, fullscreen: true);
      expect(line(tester, 'Etanol na mistura'), '27 %');
      await unmount(tester, service);
    });

    testWidgets('temperatures: engine, intake, ambient, catalyst; maximized, the manifold pressure', (tester) async {
      var service = await mount(tester, SensorType.engineTemperatures);
      expect(line(tester, 'Motor'), '81 °C', reason: 'the engine temperature card moved here (2026-11-15)');
      expect(line(tester, 'Admissão'), '34 °C');
      expect(line(tester, 'Ambiente'), '27 °C');
      expect(line(tester, 'Catalisador'), '512 °C');
      expect(find.byKey(const ValueKey('obdPanel_Coletor de admissão')), findsNothing);
      await unmount(tester, service);

      service = await mount(tester, SensorType.engineTemperatures, fullscreen: true);
      expect(line(tester, 'Coletor de admissão'), '35 kPa');
      await unmount(tester, service);
    });

    testWidgets('accelerator: throttle and pedal', (tester) async {
      final service = await mount(tester, SensorType.accelerator);
      expect(line(tester, 'Acelerador'), '16 %');
      expect(line(tester, 'Pedal'), '18 %');
      expect(find.byType(ObdScaleBar), findsNWidgets(2));
      await unmount(tester, service);
    });

    testWidgets('accelerator on a car without the pedal (Haval): the throttle alone', (tester) async {
      car.gearbox.bitmaps[0x40] = [0xE0, 0x80, 0x00, 0x00];
      car.engine.bitmaps[0x40] = [0xFE, 0x50, 0xC0, 0x00]; // 49 cleared
      final service = await mount(tester, SensorType.accelerator);
      expect(service.supports(ObdSignal.pedal), isFalse);
      expect(line(tester, 'Acelerador'), '16 %');
      expect(find.byKey(const ValueKey('obdPanel_Pedal')), findsNothing);
      expect(find.byType(ObdScaleBar), findsOneWidget);
      await unmount(tester, service);
    });

    testWidgets('consumption: asks for the displacement on a car without MAF, then estimates', (tester) async {
      await tester.runAsync(() => profile());
      var service = await mount(tester, SensorType.fuelConsumption);
      expect(find.text('Informe a cilindrada em Meu veículo'), findsOneWidget);
      await unmount(tester, service);

      await tester.runAsync(() => profile(displacement: 1.0));
      service = await mount(tester, SensorType.fuelConsumption, fullscreen: true);
      // Idling: no km/L, the flow instead.
      expect(line(tester, 'Vazão'), matches(RegExp(r'^\d,\d L/h$')));
      expect(line(tester, 'Base'), 'pressão do coletor');
      expect(find.textContaining('será calibrada'), findsOneWidget);
      await unmount(tester, service);
    });

    testWidgets('every panel fits a small card, maximized or not', (tester) async {
      await tester.runAsync(() => profile(displacement: 1.0));
      for (final type in [SensorType.fuelLevel, SensorType.engineTemperatures, SensorType.accelerator, SensorType.fuelConsumption]) {
        for (final fullscreen in [false, true]) {
          final service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(body: Center(child: SizedBox(width: 110, height: 90, child: ObdPanelView(sensorType: type, service: service, fullscreen: fullscreen)))),
          ));
          service.connect();
          await tester.pump(const Duration(seconds: 5));
          expect(tester.takeException(), isNull, reason: '$type fullscreen=$fullscreen');
          await unmount(tester, service);
        }
      }
    });

    testWidgets('drawn, not listed: the tank gauge, the temperature scales, the consumption chart', (tester) async {
      await tester.runAsync(() => profile(displacement: 1.0));
      var service = await mount(tester, SensorType.fuelLevel);
      expect(find.byType(ObdArcGauge), findsOneWidget);
      await unmount(tester, service);

      service = await mount(tester, SensorType.engineTemperatures);
      expect(find.byType(ObdScaleBar), findsNWidgets(4));
      await unmount(tester, service);

      service = await mount(tester, SensorType.fuelConsumption);
      await tester.pump(const Duration(seconds: 20));
      final chart = tester.widget<ObdSparkline>(find.byType(ObdSparkline));
      expect(chart.points.length, greaterThan(10), reason: 'the last minutes, at 2 Hz');
      expect(find.text('L/h · últimos 2 min'), findsOneWidget);
      await unmount(tester, service);
    });

    testWidgets('a rebuilt card clears the red the dashboard still holds', (tester) async {
      // The phone: every card red with live values — a card recreated after a
      // drop never told the dashboard the link was back.
      final alerts = <Color?>[];
      final service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
      Widget card(Key key) => MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 240, height: 240, child: ObdPanelView(key: key, sensorType: SensorType.accelerator, service: service, onAlertColorChanged: alerts.add)),
            ),
          );
      await tester.pumpWidget(card(const ValueKey(1)));
      service.connect();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(card(const ValueKey(2)));
      await tester.pump();
      expect(alerts, isNotEmpty);
      expect(alerts.last, isNull, reason: 'the new card reports at once, even with no alert');
      await unmount(tester, service);
    });

    testWidgets('a dropped link: last values, red border; Desconectar: none', (tester) async {
      final alerts = <Color?>[];
      final service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 240,
            child: ObdPanelView(sensorType: SensorType.engineTemperatures, service: service, onAlertColorChanged: alerts.add),
          ),
        ),
      ));
      service.connect();
      await tester.pump(const Duration(seconds: 5));
      car.unplug();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(line(tester, 'Admissão'), '34 °C');
      expect(alerts.last, isNotNull);

      await service.disconnect();
      await tester.pump();
      await tester.pump();
      expect(find.text('OBD desligado'), findsOneWidget);
      expect(alerts.last, isNull);
      await unmount(tester, service);
    });
  });
}
