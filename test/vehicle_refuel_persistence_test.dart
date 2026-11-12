import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/charge_record.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/refuel_record.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/models/vehicle_profile.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/vehicle_repository.dart';

// "Meu veículo" and the refuel log (2026-11-12) through real Hive files: what is
// stored comes back after the boxes are closed and reopened, and the
// repositories' rules (the latest refuel's fuel becomes the default) hold.
void main() {
  late Directory dir;

  Future<void> openBoxes() async {
    await Hive.openBox<VehicleProfile>(HiveBoxNames.vehicleProfile);
    await Hive.openBox<RefuelRecord>(HiveBoxNames.refuelRecords);
    await Hive.openBox<ChargeRecord>(HiveBoxNames.chargeRecords);
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
  }

  Future<void> reopen() async {
    await Hive.close();
    await openBoxes();
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('vehicle_refuel_test');
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
    if (!Hive.isAdapterRegistered(SensorTypeAdapter().typeId)) {
      Hive.registerAdapter(SensorTypeAdapter());
      Hive.registerAdapter(DisplayStyleAdapter());
      Hive.registerAdapter(WidgetPositionAdapter());
      Hive.registerAdapter(WidgetSizeAdapter());
      Hive.registerAdapter(SensorWidgetConfigAdapter());
    }
    Hive.init(dir.path);
    await openBoxes();
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  RefuelRecord refuel(String id, DateTime date, double odometer, FuelType fuel) => RefuelRecord(
        id: id,
        date: date,
        odometerKm: odometer,
        liters: 41.25,
        pricePerLiter: 6.299,
        fuel: fuel,
        fullTank: true,
      );

  test('the vehicle profile survives closing and reopening the box', () async {
    expect(VehicleRepository.profile, isNull);
    await VehicleRepository.save(VehicleProfile(
      nickname: 'Onix',
      fuelSystem: VehicleFuelSystem.flex,
      tankCapacityLiters: 44,
      kmPerLiterGasoline: 13.1,
      kmPerLiterEthanol: 9.2,
      defaultFuel: FuelType.ethanol,
    ));
    await reopen();
    final p = VehicleRepository.profile!;
    expect(
      (p.nickname, p.fuelSystem, p.tankCapacityLiters, p.kmPerLiterGasoline, p.kmPerLiterEthanol, p.kmPerLiterDiesel, p.defaultFuel),
      ('Onix', VehicleFuelSystem.flex, 44.0, 13.1, 9.2, null, FuelType.ethanol),
    );
    expect(p.displayName, 'Onix');
  });

  test('saving again replaces the single profile', () async {
    await VehicleRepository.save(VehicleProfile(fuelSystem: VehicleFuelSystem.flex, tankCapacityLiters: 44, defaultFuel: FuelType.gasoline));
    await VehicleRepository.save(VehicleProfile(
      fuelSystem: VehicleFuelSystem.diesel,
      tankCapacityLiters: 80,
      kmPerLiterDiesel: 10,
      defaultFuel: FuelType.diesel,
    ));
    await reopen();
    expect(Hive.box<VehicleProfile>(HiveBoxNames.vehicleProfile).length, 1);
    expect(VehicleRepository.profile!.fuelSystem, VehicleFuelSystem.diesel);
    expect(VehicleRepository.profile!.displayName, 'Meu carro');
  });

  test('a refuel survives closing and reopening, every field', () async {
    final date = DateTime(2026, 11, 12, 18, 30, 5);
    await RefuelRepository.save(refuel('r1', date, 12345.6, FuelType.gasoline));
    await RefuelRepository.save(refuel('r2', date.add(const Duration(days: 9)), 12800, FuelType.ethanol)..fullTank = false);
    await reopen();
    final stored = RefuelRepository.chronological;
    expect(stored.map((r) => r.id), ['r1', 'r2']);
    final r1 = stored.first;
    expect(
      (r1.date, r1.odometerKm, r1.liters, r1.pricePerLiter, r1.fuel, r1.fullTank),
      (date, 12345.6, 41.25, 6.299, FuelType.gasoline, true),
    );
    expect((stored.last.fuel, stored.last.fullTank), (FuelType.ethanol, false));
  });

  test('saving with an existing id corrects that refuel; delete removes it', () async {
    final date = DateTime(2026, 11, 1);
    await RefuelRepository.save(refuel('r1', date, 1000, FuelType.gasoline));
    await RefuelRepository.save(refuel('r1', date, 1010, FuelType.gasoline));
    expect(RefuelRepository.chronological.single.odometerKm, 1010);
    await RefuelRepository.delete(RefuelRepository.chronological.single);
    await reopen();
    expect(RefuelRepository.chronological, isEmpty);
  });

  group('the latest refuel\'s fuel becomes the default (flex: "assume até mudar")', () {
    setUp(() => VehicleRepository.save(VehicleProfile(
          fuelSystem: VehicleFuelSystem.flex,
          tankCapacityLiters: 44,
          kmPerLiterGasoline: 13,
          kmPerLiterEthanol: 9,
          defaultFuel: FuelType.gasoline,
        )));

    test('a new latest refuel with ethanol makes ethanol the default, durably', () async {
      await RefuelRepository.save(refuel('r1', DateTime(2026, 11, 1), 1000, FuelType.ethanol));
      await reopen();
      expect(VehicleRepository.profile!.defaultFuel, FuelType.ethanol);
    });

    test('correcting an older refuel does not change the default', () async {
      await RefuelRepository.save(refuel('new', DateTime(2026, 11, 10), 2000, FuelType.gasoline));
      await RefuelRepository.save(refuel('old', DateTime(2026, 11, 1), 1000, FuelType.ethanol));
      expect(VehicleRepository.profile!.defaultFuel, FuelType.gasoline);
    });

    test('a fuel the vehicle does not take is ignored', () async {
      await VehicleRepository.adoptDefaultFuel(FuelType.diesel);
      expect(VehicleRepository.profile!.defaultFuel, FuelType.gasoline);
    });
  });

  test('the refuel widget config is stored as sensor byte 5 and style 9, and reads back', () async {
    final box = await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
    await box.add(SensorWidgetConfig(
      sensorType: SensorType.refuel,
      displayStyle: DisplayStyle.refuelSummary,
      position: WidgetPosition(x: 0, y: 2),
      size: WidgetSize(width: 2, height: 2),
    ));
    await Hive.close();
    final bytes = File('${dir.path}/${HiveBoxNames.sensorWidgetConfigs}.hive').readAsBytesSync();
    // SensorType has its hand-written adapter (typeId 0); in Hive's frame
    // format a custom-typed value is its typeId + 32, then its own bytes.
    expect(_containsSequence(bytes, [32, 5]), isTrue, reason: 'SensorType byte 5');
    expect(_containsSequence(bytes, [33, 9]), isTrue, reason: 'DisplayStyle field 9');
    final reopened = await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
    expect((reopened.values.single.sensorType, reopened.values.single.displayStyle), (SensorType.refuel, DisplayStyle.refuelSummary));
  });

  group('hybrids (2026-11-12)', () {
    test('a profile stored before hybrids existed reads as combustion, with the reference switch on', () async {
      // The exact 7-field record the previous app version wrote.
      Hive.registerAdapter(_ProfileBeforeHybrids(), override: true);
      await Hive.box<VehicleProfile>(HiveBoxNames.vehicleProfile).put('vehicle', VehicleProfile(
        fuelSystem: VehicleFuelSystem.flex,
        tankCapacityLiters: 50,
        kmPerLiterGasoline: 12,
        kmPerLiterEthanol: 8.4,
        defaultFuel: FuelType.gasoline,
      ));
      await Hive.close();
      Hive.registerAdapter(VehicleProfileAdapter(), override: true);
      await openBoxes();
      final p = VehicleRepository.profile!;
      expect((p.propulsion, p.autoUpdateReferences, p.batteryCapacityKwh, p.electricRangeKm, p.isPlugIn),
          (VehiclePropulsion.combustion, true, null, null, false));
      expect((p.tankCapacityLiters, p.kmPerLiterEthanol), (50.0, 8.4));
    });

    test('a plug-in profile and its fields survive closing and reopening', () async {
      await VehicleRepository.save(VehicleProfile(
        fuelSystem: VehicleFuelSystem.gasoline,
        tankCapacityLiters: 55,
        kmPerLiterGasoline: 14,
        defaultFuel: FuelType.gasoline,
        propulsion: VehiclePropulsion.plugInHybrid,
        batteryCapacityKwh: 19.1,
        electricRangeKm: 73,
        autoUpdateReferences: false,
        defaultPricePerKwh: 0.92,
      ));
      await reopen();
      final p = VehicleRepository.profile!;
      expect((p.propulsion, p.batteryCapacityKwh, p.electricRangeKm, p.autoUpdateReferences, p.typedKmPerKwh, p.defaultPricePerKwh),
          (VehiclePropulsion.plugInHybrid, 19.1, 73.0, false, 73 / 19.1, 0.92));
    });

    test('a recharge and a refuel\'s panel readings survive closing and reopening', () async {
      final date = DateTime(2026, 11, 12, 21, 5);
      await ChargeRepository.save(ChargeRecord(
        id: 'c1',
        date: date,
        odometerKm: 15020,
        startPercent: 8,
        endPercent: 100,
        chargerKwh: 16.4,
        pricePerKwh: 0.92,
        wallKwh: 16.4,
        usedFuelSinceLast: true,
        panelFuelRangeKm: 540,
      ));
      await RefuelRepository.save(RefuelRecord(
        id: 'r1',
        date: date.add(const Duration(days: 1)),
        odometerKm: 15100,
        liters: 10,
        pricePerLiter: 6.1,
        fuel: FuelType.gasoline,
        fullTank: true,
        usedFuelSinceLast: false,
        panelFuelRangeAfterKm: 610,
      ));
      await reopen();
      final c = ChargeRepository.chronological.single;
      expect(
        (c.date, c.odometerKm, c.startPercent, c.endPercent, c.chargerKwh, c.pricePerKwh, c.wallKwh, c.usedFuelSinceLast, c.panelFuelRangeKm),
        (date, 15020.0, 8.0, 100.0, 16.4, 0.92, 16.4, true, 540.0),
      );
      final r = RefuelRepository.chronological.single;
      expect((r.usedFuelSinceLast, r.panelFuelRangeBeforeKm, r.panelFuelRangeAfterKm), (false, null, 610.0));
      expect(allVehicleRecords().map((e) => e.id), ['c1', 'r1']);
      await ChargeRepository.delete(c);
      expect(ChargeRepository.chronological, isEmpty);
    });
  });
}

/// What the app wrote for a VehicleProfile before 2026-11-12: fields 0–6 only.
class _ProfileBeforeHybrids extends TypeAdapter<VehicleProfile> {
  @override
  final int typeId = 18;

  @override
  VehicleProfile read(BinaryReader reader) => throw UnimplementedError();

  @override
  void write(BinaryWriter writer, VehicleProfile obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.nickname)
      ..writeByte(1)
      ..write(obj.fuelSystem)
      ..writeByte(2)
      ..write(obj.tankCapacityLiters)
      ..writeByte(3)
      ..write(obj.kmPerLiterGasoline)
      ..writeByte(4)
      ..write(obj.kmPerLiterEthanol)
      ..writeByte(5)
      ..write(obj.kmPerLiterDiesel)
      ..writeByte(6)
      ..write(obj.defaultFuel);
  }
}

bool _containsSequence(List<int> bytes, List<int> sequence) {
  for (var i = 0; i + sequence.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < sequence.length; j++) {
      if (bytes[i + j] != sequence[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
