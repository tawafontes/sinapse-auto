import 'package:hive/hive.dart';

import 'vehicle_profile.dart';

part 'refuel_record.g.dart';

/// One refuel the user registered (owner decisions, 2026-11-11): the date, the
/// odometer read off the dashboard, the litres and the price per litre from the
/// pump (the total is computed, never typed), the fuel, and whether the tank
/// was filled up — the full-to-full method measures consumption only between
/// two full refuels, adding the litres of any partial refuel in between.
///
/// typeId: 19
@HiveType(typeId: 19)
class RefuelRecord extends HiveObject {
  RefuelRecord({
    required this.id,
    required this.date,
    required this.odometerKm,
    required this.liters,
    required this.pricePerLiter,
    required this.fuel,
    required this.fullTank,
  });

  @HiveField(0)
  final String id;

  @HiveField(1)
  DateTime date;

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

  double get totalPrice => liters * pricePerLiter;
}
