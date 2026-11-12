import 'dart:math' as math;

import '../models/driving_session.dart';
import '../models/refuel_record.dart';
import '../models/vehicle_profile.dart';

/// Pure consumption math over the refuel log — no Hive, no widgets — shared by
/// the consumption report, the refuel form and the dashboard's refuel widget.
///
/// Method (owner decision, 2026-11-11): full-to-full. Consumption is measured
/// only between two refuels where the tank was filled up; the litres of every
/// refuel after the first full one, up to and including the next full one, are
/// what the car burned over that odometer distance. Partial refuels before the
/// first full refuel cannot be attributed to any interval and are left out.

/// [refuels] in chronological order: by date, then by odometer (two refuels on
/// the same instant keep the odometer's order).
List<RefuelRecord> sortRefuels(Iterable<RefuelRecord> refuels) {
  final sorted = refuels.toList();
  sorted.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.odometerKm.compareTo(b.odometerKm);
  });
  return sorted;
}

/// One full-to-full interval: from the full refuel [from] to the full refuel
/// [to].
class ConsumptionInterval {
  const ConsumptionInterval({
    required this.from,
    required this.to,
    required this.distanceKm,
    required this.liters,
    required this.cost,
    required this.fuel,
    required this.refuelCount,
  });

  final RefuelRecord from;
  final RefuelRecord to;
  final double distanceKm;

  /// Litres put in after [from], up to and including [to].
  final double liters;

  /// What those litres cost: the money spent to put back what was burned.
  final double cost;

  /// The fuel burned over the interval: what [from] filled the tank with, or
  /// `null` (mixed) when a partial refuel in between used another fuel. The
  /// closing refuel's own fuel is not part of it — those litres replace fuel
  /// already burned, they were not burned here.
  final FuelType? fuel;

  /// How many refuels (partials plus the closing full one) the interval adds.
  final int refuelCount;

  double get kmPerLiter => distanceKm / liters;
  double get costPerKm => cost / distanceKm;
}

/// Every full-to-full interval in [chronological] (see [sortRefuels]). An
/// interval with no distance or no litres (a typo the form normally refuses)
/// is dropped rather than reported as an infinite or zero consumption.
List<ConsumptionInterval> consumptionIntervals(List<RefuelRecord> chronological) {
  final intervals = <ConsumptionInterval>[];
  RefuelRecord? lastFull;
  var liters = 0.0;
  var cost = 0.0;
  var count = 0;
  final burned = <FuelType>{};
  for (final refuel in chronological) {
    if (lastFull == null) {
      if (refuel.fullTank) lastFull = refuel;
      continue;
    }
    liters += refuel.liters;
    cost += refuel.totalPrice;
    count++;
    if (!refuel.fullTank) {
      burned.add(refuel.fuel);
      continue;
    }
    burned.add(lastFull.fuel);
    final distance = refuel.odometerKm - lastFull.odometerKm;
    if (distance > 0 && liters > 0) {
      intervals.add(ConsumptionInterval(
        from: lastFull,
        to: refuel,
        distanceKm: distance,
        liters: liters,
        cost: cost,
        fuel: burned.length == 1 ? burned.single : null,
        refuelCount: count,
      ));
    }
    lastFull = refuel;
    liters = 0;
    cost = 0;
    count = 0;
    burned.clear();
  }
  return intervals;
}

/// Totals over the refuel log, for the consumption report.
class ConsumptionSummary {
  ConsumptionSummary._(this.refuels, this.intervals);

  factory ConsumptionSummary.of(Iterable<RefuelRecord> refuels) {
    final sorted = sortRefuels(refuels);
    return ConsumptionSummary._(sorted, consumptionIntervals(sorted));
  }

  /// Chronological.
  final List<RefuelRecord> refuels;

  /// Chronological.
  final List<ConsumptionInterval> intervals;

  /// Average km/L over the intervals that burned [fuel] alone (mixed intervals
  /// count only for [fuel] == null, the overall figure): total distance over
  /// total litres, not a mean of the interval figures, so a long interval
  /// weighs as much as the kilometres it covered.
  double? averageKmPerLiter([FuelType? fuel]) {
    var distance = 0.0;
    var liters = 0.0;
    for (final interval in intervals) {
      if (fuel != null && interval.fuel != fuel) continue;
      distance += interval.distanceKm;
      liters += interval.liters;
    }
    return liters > 0 ? distance / liters : null;
  }

  /// Money per kilometre over every interval.
  double? get costPerKm {
    var distance = 0.0;
    var cost = 0.0;
    for (final interval in intervals) {
      distance += interval.distanceKm;
      cost += interval.cost;
    }
    return distance > 0 ? cost / distance : null;
  }

  double get totalSpent => refuels.fold(0.0, (sum, r) => sum + r.totalPrice);
  double get totalLiters => refuels.fold(0.0, (sum, r) => sum + r.liters);

  /// Money spent per calendar month, most recent month first.
  List<({DateTime month, double spent, double liters})> get monthly {
    final byMonth = <DateTime, ({double spent, double liters})>{};
    for (final refuel in refuels) {
      final month = DateTime(refuel.date.year, refuel.date.month);
      final previous = byMonth[month] ?? (spent: 0.0, liters: 0.0);
      byMonth[month] = (spent: previous.spent + refuel.totalPrice, liters: previous.liters + refuel.liters);
    }
    final months = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final m in months) (month: m, spent: byMonth[m]!.spent, liters: byMonth[m]!.liters)];
  }

  /// The price per litre of the most recent refuel with [fuel].
  double? lastPricePerLiter(FuelType fuel) {
    for (final refuel in refuels.reversed) {
      if (refuel.fuel == fuel) return refuel.pricePerLiter;
    }
    return null;
  }

  /// km/L for [fuel]: what the user measured, else the profile's reference.
  double? kmPerLiterFor(FuelType fuel, VehicleProfile? profile) =>
      averageKmPerLiter(fuel) ?? profile?.referenceKmPerLiter(fuel);

  /// The km/L reference reports compare against (owner decision, 2026-11-12):
  /// with "Atualizar referências com as minhas medições" on, the mean of the
  /// last [referenceSampleCountForFuel] intervals of at least 100 km that
  /// burned [fuel] alone — the typed value until there are any; off, the typed
  /// value. A plug-in's own reference comes from `HybridSummary`.
  double? referenceKmPerLiter(FuelType fuel, VehicleProfile? profile) {
    final typed = profile?.referenceKmPerLiter(fuel);
    if (profile == null || !profile.autoUpdateReferences || profile.isPlugIn) return typed;
    final samples = [
      for (final i in intervals)
        if (i.fuel == fuel && i.distanceKm >= 100) i.kmPerLiter,
    ];
    if (samples.isEmpty) return typed;
    final last = samples.sublist(samples.length > referenceSampleCountForFuel ? samples.length - referenceSampleCountForFuel : 0);
    return last.reduce((a, b) => a + b) / last.length;
  }

  /// Whether [referenceKmPerLiter] is a measured one rather than the typed one.
  bool referenceIsMeasured(FuelType fuel, VehicleProfile? profile) =>
      profile != null &&
      profile.autoUpdateReferences &&
      !profile.isPlugIn &&
      intervals.any((i) => i.fuel == fuel && i.distanceKm >= 100);
}

/// How many recent intervals a self-updating km/L reference averages.
const int referenceSampleCountForFuel = 5;

/// Ethanol pays off while its price is at most [ratio] times gasoline's.
/// [measured] says whether [ratio] comes from the user's own intervals with
/// both fuels (else from the profile's reference figures).
typedef EthanolBreakEven = ({double ratio, bool measured});

/// For a flex car: the ethanol/gasoline km/L ratio — measured when the log has
/// intervals with each fuel alone, else from the reference figures. `null`
/// when neither is available (or the car is not flex).
EthanolBreakEven? ethanolBreakEven(ConsumptionSummary summary, VehicleProfile? profile) {
  if (profile == null || profile.fuelSystem != VehicleFuelSystem.flex) return null;
  final measuredEthanol = summary.averageKmPerLiter(FuelType.ethanol);
  final measuredGasoline = summary.averageKmPerLiter(FuelType.gasoline);
  if (measuredEthanol != null && measuredGasoline != null) {
    return (ratio: measuredEthanol / measuredGasoline, measured: true);
  }
  final refEthanol = profile.kmPerLiterEthanol;
  final refGasoline = profile.kmPerLiterGasoline;
  if (refEthanol != null && refGasoline != null && refGasoline > 0) {
    return (ratio: refEthanol / refGasoline, measured: false);
  }
  return null;
}

/// Kilometres the app recorded in driving sessions that started at or after
/// [since] — the distance driven since a refuel, as far as the app knows (trips
/// driven without a session are not in it). Sessions being deleted are left
/// out.
double appDistanceKmSince(DateTime since, Iterable<DrivingSession> sessions) {
  var meters = 0.0;
  for (final session in sessions) {
    if (session.deletionPending || session.startTime.isBefore(since)) continue;
    meters += session.distanceMeters;
  }
  return meters / 1000;
}

/// The odometer the refuel and recharge forms suggest (owner decision,
/// 2026-11-11): the last record's odometer — refuel or recharge — plus the
/// kilometres the app recorded since. `null` before the first record — there
/// is nothing to add to.
double? suggestedOdometerKm(OdometerRecord? lastRecord, double appKmSinceLast) =>
    lastRecord == null ? null : (lastRecord.odometerKm + appKmSinceLast).roundToDouble();

String _ofRecordKind(OdometerRecord record) => record is RefuelRecord ? 'do abastecimento' : 'da recarga';

/// Why [odometerKm] cannot be the odometer of a record on [date], or `null`
/// when it fits: the odometer only grows, so it must be above every earlier
/// record's and below every later one's — refuels and recharges alike.
/// [others] excludes the record being edited.
String? odometerConflict(double odometerKm, DateTime date, Iterable<OdometerRecord> others) {
  OdometerRecord? previous;
  OdometerRecord? next;
  for (final other in others) {
    if (!other.date.isAfter(date)) {
      if (previous == null || other.date.isAfter(previous.date)) previous = other;
    } else {
      if (next == null || other.date.isBefore(next.date)) next = other;
    }
  }
  if (previous != null && odometerKm <= previous.odometerKm) {
    return 'O hodômetro precisa ser maior que o ${_ofRecordKind(previous)} anterior (${formatKm(previous.odometerKm)}).';
  }
  if (next != null && odometerKm >= next.odometerKm) {
    return 'O hodômetro precisa ser menor que o ${_ofRecordKind(next)} seguinte (${formatKm(next.odometerKm)}).';
  }
  return null;
}

/// What the dashboard's refuel widget shows.
class RefuelOverview {
  const RefuelOverview({
    required this.lastRefuel,
    required this.lastInterval,
    required this.kmSinceLastRefuel,
    required this.estimatedLiters,
    required this.rangeKm,
  });

  final RefuelRecord? lastRefuel;
  final ConsumptionInterval? lastInterval;

  /// Recorded by the app since [lastRefuel] (see [appDistanceKmSince]).
  final double kmSinceLastRefuel;

  /// Estimated fuel in the tank now (see [estimateFuelLiters]).
  final double? estimatedLiters;

  /// [estimatedLiters] times the km/L of the fuel in the tank.
  final double? rangeKm;

  factory RefuelOverview.compute({
    required VehicleProfile? profile,
    required Iterable<RefuelRecord> refuels,
    required Iterable<DrivingSession> sessions,
  }) {
    final summary = ConsumptionSummary.of(refuels);
    final last = summary.refuels.isEmpty ? null : summary.refuels.last;
    final kmSince = last == null ? 0.0 : appDistanceKmSince(last.date, sessions);
    final liters = profile == null ? null : estimateFuelLiters(profile: profile, summary: summary, kmSinceLastRefuel: kmSince);
    final kmPerLiter = last == null ? null : summary.kmPerLiterFor(last.fuel, profile);
    return RefuelOverview(
      lastRefuel: last,
      lastInterval: summary.intervals.isEmpty ? null : summary.intervals.last,
      kmSinceLastRefuel: kmSince,
      estimatedLiters: liters,
      rangeKm: liters == null || kmPerLiter == null ? null : liters * kmPerLiter,
    );
  }
}

/// Estimated litres in the tank now: full at the last full refuel, then each
/// later (partial) refuel adds its litres after burning the distance since the
/// one before — at that fuel's km/L ([ConsumptionSummary.kmPerLiterFor]) —
/// and finally [kmSinceLastRefuel] is burned. Clamped to the tank. `null`
/// without a full refuel to start from, or without any km/L for a fuel in
/// play.
double? estimateFuelLiters({
  required VehicleProfile profile,
  required ConsumptionSummary summary,
  required double kmSinceLastRefuel,
}) {
  final refuels = summary.refuels;
  final start = refuels.lastIndexWhere((r) => r.fullTank);
  if (start < 0) return null;
  final capacity = profile.tankCapacityLiters;
  var level = capacity;
  var previous = refuels[start];
  for (final refuel in refuels.skip(start + 1)) {
    final kmPerLiter = summary.kmPerLiterFor(previous.fuel, profile);
    if (kmPerLiter == null || kmPerLiter <= 0) return null;
    level = math.max(0.0, level - (refuel.odometerKm - previous.odometerKm) / kmPerLiter);
    level = math.min(capacity, level + refuel.liters);
    previous = refuel;
  }
  final kmPerLiter = summary.kmPerLiterFor(previous.fuel, profile);
  if (kmPerLiter == null || kmPerLiter <= 0) return null;
  return (level - kmSinceLastRefuel / kmPerLiter).clamp(0.0, capacity);
}

// ---------------------------------------------------------------------------
// Brazilian-format numbers (comma decimals, dot thousands), with no intl
// dependency — the app has none.

/// [value] with [decimals] decimals, comma as the decimal separator and dots
/// grouping thousands: 12345.6 → "12.345,6".
String formatDecimal(double value, {int decimals = 1}) {
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final integer = parts[0];
  final grouped = StringBuffer();
  for (var i = 0; i < integer.length; i++) {
    if (i > 0 && (integer.length - i) % 3 == 0) grouped.write('.');
    grouped.write(integer[i]);
  }
  final decimalsPart = parts.length > 1 ? ',${parts[1]}' : '';
  return '${negative ? '-' : ''}$grouped$decimalsPart';
}

String formatKm(double km) => '${formatDecimal(km, decimals: 0)} km';
String formatKmPerLiter(double kmPerLiter) => '${formatDecimal(kmPerLiter)} km/L';
String formatLiters(double liters) => '${formatDecimal(liters, decimals: 2)} L';
String formatMoney(double value) => 'R\$ ${formatDecimal(value, decimals: 2)}';
/// Three decimals, as Brazilian pumps show it ("R$ 6,299/L").
String formatPricePerLiter(double value) => 'R\$ ${formatDecimal(value, decimals: 3)}/L';

String formatDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

const List<String> _monthNames = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
];

String formatMonth(DateTime month) => '${_monthNames[month.month - 1]} de ${month.year}';

/// Parses what a person types into a number field: "1.234,5", "1234,5" and
/// "1234.5" are all 1234.5. With a comma, it is the decimal separator and dots
/// group thousands; without one, a single dot is the decimal separator (a price
/// typed "6.299" is 6.299, not 6299) unless [dotGroupsThousands] — for whole
/// numbers like the odometer, where "12.345" means 12345. Several dots always
/// group thousands. `null` for anything else.
double? parseDecimal(String text, {bool dotGroupsThousands = false}) {
  var t = text.trim().replaceAll(' ', '');
  if (t.isEmpty) return null;
  if (t.contains(',')) {
    t = t.replaceAll('.', '').replaceAll(',', '.');
  } else if ('.'.allMatches(t).length > 1 || (dotGroupsThousands && RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(t))) {
    t = t.replaceAll('.', '');
  }
  final value = double.tryParse(t);
  return value == null || value.isNaN || value.isInfinite ? null : value;
}
