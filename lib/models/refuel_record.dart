import 'package:hive/hive.dart';

import 'vehicle_profile.dart';

part 'refuel_record.g.dart';

/// What every entry of the refuel/recharge log has: when, and the odometer at
/// that moment — enough for the odometer suggestion and its ordering check,
/// which span both kinds.
abstract interface class OdometerRecord {
  String get id;
  DateTime get date;
  double get odometerKm;
}

/// One refuel the user registered (owner decisions, 2026-11-11): the date, the
/// odometer read off the dashboard, the litres and the price per litre from the
/// pump (the total is computed, never typed), the fuel, and whether the tank
/// was filled up — the full-to-full method measures consumption only between
/// two full refuels, adding the litres of any partial refuel in between.
///
/// typeId: 19
@HiveType(typeId: 19)
class RefuelRecord extends HiveObject implements OdometerRecord {
  RefuelRecord({
    required this.id,
    required this.date,
    required this.odometerKm,
    required this.liters,
    required this.pricePerLiter,
    required this.fuel,
    required this.fullTank,
    this.usedFuelSinceLast,
    this.panelFuelRangeBeforeKm,
    this.panelFuelRangeAfterKm,
  });

  @override
  @HiveField(0)
  final String id;

  @override
  @HiveField(1)
  DateTime date;

  @override
  @HiveField(2)
  double odometerKm;

  @HiveField(3)
  double liters;

  @HiveField(4)
  double pricePerLiter;

  @HiveField(5)
  FuelType fuel;

  @HiveField(6)
  bool fullTank;

  /// Plug-in hybrids only (2026-11-12): the answer to "Usou combustível desde o
  /// último registro?" — `null` on any other vehicle.
  @HiveField(7)
  bool? usedFuelSinceLast;

  /// Plug-in only: the fuel range the car's panel showed BEFORE this refuel,
  /// asked when fuel was used since the last record — the drop from the
  /// previous reading is the combustion kilometres (see
  /// `hybrid_consumption.dart`).
  @HiveField(8)
  double? panelFuelRangeBeforeKm;

  /// Plug-in only: the fuel range the panel shows right AFTER this refuel — the
  /// starting point for the next drop.
  @HiveField(9)
  double? panelFuelRangeAfterKm;

  double get totalPrice => liters * pricePerLiter;
}
