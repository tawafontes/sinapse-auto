import 'package:hive/hive.dart';

import 'refuel_record.dart';

part 'charge_record.g.dart';

/// One recharge of a plug-in hybrid (owner decisions, 2026-11-12):
///
///  * the battery % the car's panel showed when the recharge started and when
///    it ended — always asked: the % left at the previous recharge minus the %
///    at this one's start is the energy driven, measured on the battery side;
///  * the kWh the charger reported — optional; when given, the cost is exact;
///  * the price per kWh (0 for a free charger);
///  * "Usou combustível desde o último registro?" and, when yes, the fuel range
///    the panel shows now — the drop since the previous reading is the
///    combustion kilometres.
///
/// [wallKwh] is the energy the cost is computed from, fixed when the recharge is
/// saved: the charger's kWh when given, otherwise the battery-side energy (the
/// % span times the capacity in use then) plus the fixed 10% charging-loss
/// margin. Stored rather than recomputed so a later change of the capacity
/// never rewrites what a past recharge cost.
///
/// typeId: 21
@HiveType(typeId: 21)
class ChargeRecord extends HiveObject implements OdometerRecord {
  ChargeRecord({
    required this.id,
    required this.date,
    required this.odometerKm,
    required this.startPercent,
    required this.endPercent,
    this.chargerKwh,
    required this.pricePerKwh,
    required this.wallKwh,
    required this.usedFuelSinceLast,
    this.panelFuelRangeKm,
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
  double startPercent;

  @HiveField(4)
  double endPercent;

  @HiveField(5)
  double? chargerKwh;

  @HiveField(6)
  double pricePerKwh;

  @HiveField(7)
  double wallKwh;

  @HiveField(8)
  bool usedFuelSinceLast;

  @HiveField(9)
  double? panelFuelRangeKm;

  double get totalPrice => wallKwh * pricePerKwh;

  /// The % the battery gained.
  double get percentSpan => endPercent - startPercent;
}
