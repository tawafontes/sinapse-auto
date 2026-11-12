import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
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
