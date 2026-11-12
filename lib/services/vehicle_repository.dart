import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/charge_record.dart';
import '../models/driving_session.dart';
import '../models/refuel_record.dart';
import '../models/vehicle_profile.dart';
import 'fuel_consumption.dart';
import 'hive_boxes.dart';
import 'hybrid_consumption.dart';

/// "Meu veículo": the one [VehicleProfile] (single vehicle, owner decision
/// 2026-11-11), under a fixed key of its own box.
class VehicleRepository {
  VehicleRepository._();

  static const _key = 'vehicle';

  static Box<VehicleProfile> get _box => Hive.box<VehicleProfile>(HiveBoxNames.vehicleProfile);

  static VehicleProfile? get profile => _box.get(_key);

  static ValueListenable<Box<VehicleProfile>> listenable() => _box.listenable();

  static Future<void> save(VehicleProfile profile) => _box.put(_key, profile);

  /// A refuel with [fuel] makes it the default for the next one (owner
  /// decision: the app assumes the default fuel until the user picks another).
  /// Ignored for a fuel the vehicle does not take.
  static Future<void> adoptDefaultFuel(FuelType fuel) async {
    final current = profile;
    if (current == null || current.defaultFuel == fuel || !current.fuelSystem.fuels.contains(fuel)) return;
    current.defaultFuel = fuel;
    await current.save();
  }
}

/// The refuel log ("Abastecimentos"), keyed by [RefuelRecord.id].
class RefuelRepository {
  RefuelRepository._();

  static Box<RefuelRecord> get _box => Hive.box<RefuelRecord>(HiveBoxNames.refuelRecords);

  /// Oldest first (see [sortRefuels]).
  static List<RefuelRecord> get chronological => sortRefuels(_box.values);

  static ValueListenable<Box<RefuelRecord>> listenable() => _box.listenable();

  static String newId() => 'refuel_${DateTime.now().microsecondsSinceEpoch}';

  /// Adds [refuel], or replaces the stored one with the same id. When it is the
  /// most recent refuel, its fuel becomes the vehicle's default
  /// ([VehicleRepository.adoptDefaultFuel]) — correcting an old entry does not
  /// change what the next refuel starts with.
  static Future<void> save(RefuelRecord refuel) async {
    await _box.put(refuel.id, refuel);
    final latest = chronological.last;
    if (latest.id == refuel.id) await VehicleRepository.adoptDefaultFuel(refuel.fuel);
  }

  static Future<void> delete(RefuelRecord refuel) => _box.delete(refuel.id);

  /// The driving sessions, for the kilometres the app recorded since a refuel
  /// ([appDistanceKmSince]) — read-only here.
  static Iterable<DrivingSession> get sessions => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).values;

  static ValueListenable<Box<DrivingSession>> sessionsListenable() =>
      Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).listenable();
}

/// A plug-in hybrid's recharges, keyed by [ChargeRecord.id] (2026-11-12).
class ChargeRepository {
  ChargeRepository._();

  static Box<ChargeRecord> get _box => Hive.box<ChargeRecord>(HiveBoxNames.chargeRecords);

  /// Oldest first.
  static List<ChargeRecord> get chronological => vehicleTimeline(const [], _box.values).cast<ChargeRecord>();

  static ValueListenable<Box<ChargeRecord>> listenable() => _box.listenable();

  static String newId() => 'charge_${DateTime.now().microsecondsSinceEpoch}';

  /// Adds [charge], or replaces the stored one with the same id.
  static Future<void> save(ChargeRecord charge) => _box.put(charge.id, charge);

  static Future<void> delete(ChargeRecord charge) => _box.delete(charge.id);
}

/// Refuels and recharges together, oldest first — the odometer suggestion and
/// its ordering check span both.
List<OdometerRecord> allVehicleRecords() => vehicleTimeline(RefuelRepository.chronological, ChargeRepository.chronological);
