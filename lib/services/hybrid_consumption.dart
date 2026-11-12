import 'dart:math' as math;

import '../models/charge_record.dart';
import '../models/driving_session.dart';
import '../models/refuel_record.dart';
import '../models/vehicle_profile.dart';
import 'fuel_consumption.dart';

/// Plug-in hybrid math (owner decisions, 2026-11-12) — pure, no Hive, no
/// widgets. Designed around the owner's use: electric in town, the engine only
/// when the battery runs out. Dividing every kilometre by the litres would make
/// a nonsense km/L, so the kilometres are split instead:
///
///  * energy driven between two recharges = (% left at the previous one − % at
///    this one's start) × capacity — measured on the battery side;
///  * combustion kilometres = the drop of the fuel range the car's panel shows,
///    read when the user says fuel was used since the last record (and right
///    after each refuel, as the next starting point);
///  * km/kWh is measured only over intervals WITHOUT fuel: in HEV mode with a
///    "Forçado" reserve the engine charges the battery while driving (the
///    owner's manual), which would inflate it;
///  * the combined cost per km — money over kilometres — needs no split at all.

/// The fixed charging-loss margin (owner decision): a recharge given only as a
/// % span costs that energy plus 10%, roughly what a slow (AC) charge loses
/// between the socket and the battery.
const double chargingLossMargin = 0.10;

/// How many of the latest measurements a self-updating reference averages.
const int referenceSampleCount = 5;

/// Shorter fuel intervals are too noisy to update a km/L reference.
const double minReferenceIntervalKm = 100;

/// The battery % one km/kWh or capacity SAMPLE needs: the panel shows whole
/// percent, so a short span alone is too coarse. Short recharges are fine
/// (owner request, 2026-11-12): consecutive ones are added up until they
/// reach this — see [ElectricMeasurement] and the capacity samples. The
/// overall measured average needs no threshold at all: it sums distance and
/// energy over every interval, and the rounding averages out.
const double minMeasurementPercentSpan = 30;

/// The energy a recharge given as a % span is billed for: battery side plus
/// [chargingLossMargin].
double wallKwhFromPercent({required double startPercent, required double endPercent, required double capacityKwh}) =>
    (endPercent - startPercent) / 100 * capacityKwh * (1 + chargingLossMargin);

/// Both kinds of record in the order they happened: by date, then odometer.
List<OdometerRecord> vehicleTimeline(Iterable<RefuelRecord> refuels, Iterable<ChargeRecord> charges) {
  final all = <OdometerRecord>[...refuels, ...charges];
  all.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.odometerKm.compareTo(b.odometerKm);
  });
  return all;
}

/// The latest of [records], or `null`.
OdometerRecord? latestRecord(Iterable<OdometerRecord> records) {
  OdometerRecord? latest;
  for (final r in records) {
    if (latest == null || r.date.isAfter(latest.date) || (r.date == latest.date && r.odometerKm > latest.odometerKm)) {
      latest = r;
    }
  }
  return latest;
}

double? _meanOfLast(List<double> samples, int count) {
  if (samples.isEmpty) return null;
  final last = samples.sublist(math.max(0, samples.length - count));
  return last.reduce((a, b) => a + b) / last.length;
}

/// The driving between two consecutive recharges.
class ElectricInterval {
  const ElectricInterval({
    required this.from,
    required this.to,
    required this.km,
    required this.percentUsed,
    required this.energyKwh,
    required this.withoutFuel,
  });

  final ChargeRecord from;
  final ChargeRecord to;
  final double km;

  /// % at [from]'s end minus % at [to]'s start.
  final double percentUsed;

  /// [percentUsed] of the capacity in use; `null` without a capacity.
  final double? energyKwh;

  /// No fuel was used anywhere in between (every record in it said so).
  final bool withoutFuel;

  /// Whether this interval counts towards km/kWh: no fuel, some distance and
  /// some energy — of any size (short recharges add up, see
  /// [ElectricMeasurement]).
  bool get counts => withoutFuel && km > 0 && percentUsed > 0 && (energyKwh ?? 0) > 0;

  double get kmPerKwh => km / energyKwh!;
}

/// One km/kWh sample: consecutive counting intervals added up until at least
/// [minMeasurementPercentSpan] of the battery was used — one long interval, or
/// several short ones (a 20% recharge every day). An interval that used fuel
/// breaks the run: the partial sum before it is dropped.
class ElectricMeasurement {
  const ElectricMeasurement({required this.intervals, required this.km, required this.energyKwh, required this.percentUsed});

  final List<ElectricInterval> intervals;
  final double km;
  final double energyKwh;
  final double percentUsed;

  double get kmPerKwh => km / energyKwh;

  /// The recharge that completed this sample.
  ChargeRecord get closedBy => intervals.last.to;
}

List<ElectricMeasurement> _electricMeasurements(List<ElectricInterval> intervals) {
  final samples = <ElectricMeasurement>[];
  var run = <ElectricInterval>[];
  var km = 0.0, kwh = 0.0, percent = 0.0;
  for (final interval in intervals) {
    if (!interval.counts) {
      run = [];
      km = kwh = percent = 0;
      continue;
    }
    run.add(interval);
    km += interval.km;
    kwh += interval.energyKwh!;
    percent += interval.percentUsed;
    if (percent >= minMeasurementPercentSpan) {
      samples.add(ElectricMeasurement(intervals: run, km: km, energyKwh: kwh, percentUsed: percent));
      run = [];
      km = kwh = percent = 0;
    }
  }
  return samples;
}

/// A full-to-full fuel interval of a plug-in, with the combustion kilometres
/// driven in it (from the panel range drops).
typedef EngineInterval = ({ConsumptionInterval interval, double fuelKm});

/// Everything the plug-in reports and widget need, computed from the log.
class HybridSummary {
  HybridSummary._({
    required this.profile,
    required this.refuels,
    required this.charges,
    required this.timeline,
    required this.capacityKwh,
    required this.learnedCapacityKwh,
    required this.electricIntervals,
    required this.fuelKmAt,
    required this.engineIntervals,
  });

  factory HybridSummary.of({
    required VehicleProfile profile,
    required Iterable<RefuelRecord> refuels,
    required Iterable<ChargeRecord> charges,
  }) {
    final sortedRefuels = sortRefuels(refuels);
    final timeline = vehicleTimeline(sortedRefuels, charges);
    final sortedCharges = timeline.whereType<ChargeRecord>().toList();

    // Battery capacity: typed, or (switch on) the mean of the last samples from
    // the recharges that give the charger's kWh — short ones added up until
    // their % spans reach the threshold.
    final capacitySamples = <double>[];
    var sumKwh = 0.0, sumSpan = 0.0;
    for (final c in sortedCharges) {
      if (c.chargerKwh == null || c.percentSpan <= 0) continue;
      sumKwh += c.chargerKwh!;
      sumSpan += c.percentSpan;
      if (sumSpan >= minMeasurementPercentSpan) {
        capacitySamples.add(sumKwh / (1 + chargingLossMargin) / (sumSpan / 100));
        sumKwh = sumSpan = 0;
      }
    }
    final learnedCapacity = _meanOfLast(capacitySamples, referenceSampleCount);
    final capacity = profile.autoUpdateReferences ? (learnedCapacity ?? profile.batteryCapacityKwh) : profile.batteryCapacityKwh;

    // Intervals between recharges, and whether fuel was used in each.
    final electric = <ElectricInterval>[];
    ChargeRecord? previousCharge;
    var fuelSincePreviousCharge = false;
    for (final record in timeline) {
      if (record is RefuelRecord) {
        if (record.usedFuelSinceLast != false) fuelSincePreviousCharge = true;
        continue;
      }
      final charge = record as ChargeRecord;
      if (previousCharge != null) {
        final percentUsed = previousCharge.endPercent - charge.startPercent;
        electric.add(ElectricInterval(
          from: previousCharge,
          to: charge,
          km: charge.odometerKm - previousCharge.odometerKm,
          percentUsed: percentUsed,
          energyKwh: capacity == null ? null : percentUsed / 100 * capacity,
          withoutFuel: !charge.usedFuelSinceLast && !fuelSincePreviousCharge,
        ));
      }
      previousCharge = charge;
      fuelSincePreviousCharge = false;
    }

    // Combustion kilometres: each drop of the panel's fuel range, attributed to
    // the record where it was read.
    final fuelKmAt = <String, double>{};
    double? lastRange;
    for (final record in timeline) {
      if (record is RefuelRecord) {
        final before = record.panelFuelRangeBeforeKm;
        if (record.usedFuelSinceLast == true && before != null && lastRange != null) {
          fuelKmAt[record.id] = math.max(0, lastRange - before);
        }
        // Refilled: the next drop starts from the range after it (unknown when
        // not given — the next reading then only sets a new start).
        lastRange = record.panelFuelRangeAfterKm;
      } else if (record is ChargeRecord && record.usedFuelSinceLast && record.panelFuelRangeKm != null) {
        final range = record.panelFuelRangeKm!;
        if (lastRange != null) fuelKmAt[record.id] = math.max(0, lastRange - range);
        lastRange = range;
      }
    }

    // Engine km/L: the litres of each full-to-full interval over the
    // combustion kilometres read in it.
    final index = {for (var i = 0; i < timeline.length; i++) timeline[i].id: i};
    final engine = <EngineInterval>[];
    for (final interval in consumptionIntervals(sortedRefuels)) {
      final start = index[interval.from.id]!;
      final end = index[interval.to.id]!;
      var fuelKm = 0.0;
      for (var i = start + 1; i <= end; i++) {
        fuelKm += fuelKmAt[timeline[i].id] ?? 0;
      }
      engine.add((interval: interval, fuelKm: fuelKm));
    }

    return HybridSummary._(
      profile: profile,
      refuels: sortedRefuels,
      charges: sortedCharges,
      timeline: timeline,
      capacityKwh: capacity,
      learnedCapacityKwh: learnedCapacity,
      electricIntervals: electric,
      fuelKmAt: fuelKmAt,
      engineIntervals: engine,
    );
  }

  final VehicleProfile profile;

  /// Chronological.
  final List<RefuelRecord> refuels;

  /// Chronological.
  final List<ChargeRecord> charges;

  /// Both kinds, chronological.
  final List<OdometerRecord> timeline;

  /// The usable capacity in use: typed, or learned with the switch on.
  final double? capacityKwh;

  /// The mean of the last capacity measurements, whatever the switch says.
  final double? learnedCapacityKwh;

  final List<ElectricInterval> electricIntervals;

  /// Combustion km read at each record (by id).
  final Map<String, double> fuelKmAt;

  final List<EngineInterval> engineIntervals;

  /// The km/kWh samples (see [ElectricMeasurement]), oldest first.
  late final List<ElectricMeasurement> electricMeasurements = _electricMeasurements(electricIntervals);

  /// km/kWh over every interval without fuel, short ones included: total
  /// distance over total energy.
  double? get measuredKmPerKwh {
    var km = 0.0;
    var kwh = 0.0;
    for (final i in electricIntervals.where((i) => i.counts)) {
      km += i.km;
      kwh += i.energyKwh!;
    }
    return kwh > 0 ? km / kwh : null;
  }

  /// The km/kWh reference: with the switch on, the mean of the last samples
  /// (the typed one until there are any); off, the typed one.
  double? get kmPerKwhReference {
    final typed = profile.typedKmPerKwh;
    if (!profile.autoUpdateReferences) return typed;
    return _meanOfLast([for (final m in electricMeasurements) m.kmPerKwh], referenceSampleCount) ?? typed;
  }

  /// What estimates use: what was measured, else the reference.
  double? get kmPerKwhForEstimates =>
      _meanOfLast([for (final m in electricMeasurements) m.kmPerKwh], referenceSampleCount) ?? measuredKmPerKwh ?? profile.typedKmPerKwh;

  /// Engine km/L over the intervals with combustion kilometres read: litres
  /// over those kilometres. Estimated (panel range drops).
  double? engineKmPerLiter([FuelType? fuel]) {
    var km = 0.0;
    var liters = 0.0;
    for (final e in engineIntervals) {
      if (e.fuelKm <= 0 || (fuel != null && e.interval.fuel != fuel)) continue;
      km += e.fuelKm;
      liters += e.interval.liters;
    }
    return liters > 0 ? km / liters : null;
  }

  /// The km/L reference for [fuel]: with the switch on, the mean of the last
  /// engine intervals of at least [minReferenceIntervalKm] combustion km.
  double? engineKmPerLiterReference(FuelType fuel) {
    final typed = profile.referenceKmPerLiter(fuel);
    if (!profile.autoUpdateReferences) return typed;
    final samples = [
      for (final e in engineIntervals)
        if (e.interval.fuel == fuel && e.fuelKm >= minReferenceIntervalKm) e.fuelKm / e.interval.liters,
    ];
    return _meanOfLast(samples, referenceSampleCount) ?? typed;
  }

  /// Odometer distance covered by the log.
  double get spanKm => timeline.length < 2 ? 0 : timeline.last.odometerKm - timeline.first.odometerKm;

  double get fuelKm => fuelKmAt.values.fold(0.0, (a, b) => a + b);

  /// Share of [spanKm] driven on electricity (estimated), or `null` without a
  /// span.
  double? get electricShare => spanKm > 0 ? (1 - fuelKm / spanKm).clamp(0.0, 1.0) : null;

  double get fuelSpent => refuels.fold(0.0, (a, r) => a + r.totalPrice);
  double get energySpent => charges.fold(0.0, (a, c) => a + c.totalPrice);
  double get wallKwh => charges.fold(0.0, (a, c) => a + c.wallKwh);
  double get liters => refuels.fold(0.0, (a, r) => a + r.liters);

  /// Money per km, fuel and energy together — exact, no split needed: what was
  /// spent after the first record (that one paid for driving before the log)
  /// over the distance since it.
  double? get combinedCostPerKm {
    if (spanKm <= 0) return null;
    var spent = 0.0;
    for (final record in timeline.skip(1)) {
      spent += switch (record) {
        RefuelRecord r => r.totalPrice,
        ChargeRecord c => c.totalPrice,
        _ => 0.0,
      };
    }
    return spent / spanKm;
  }
}

/// What the dashboard's refuel widget shows for a plug-in.
class HybridOverview {
  const HybridOverview({
    required this.lastCharge,
    required this.kmSinceLastCharge,
    required this.batteryPercent,
    required this.electricRangeKm,
    required this.panelFuelRangeKm,
  });

  final ChargeRecord? lastCharge;

  /// Recorded by the app since [lastCharge], all assumed electric.
  final double kmSinceLastCharge;

  /// Estimated battery % now, or `null` without a recharge, a capacity or a
  /// km/kWh.
  final double? batteryPercent;
  final double? electricRangeKm;

  /// The last fuel range read off the panel. Not decreased by the kilometres
  /// since: in the owner's use they are electric, and the next record that
  /// used fuel brings a new reading.
  final double? panelFuelRangeKm;

  factory HybridOverview.compute({
    required VehicleProfile profile,
    required Iterable<RefuelRecord> refuels,
    required Iterable<ChargeRecord> charges,
    required Iterable<DrivingSession> sessions,
  }) {
    final summary = HybridSummary.of(profile: profile, refuels: refuels, charges: charges);
    final last = summary.charges.isEmpty ? null : summary.charges.last;
    final kmSince = last == null ? 0.0 : appDistanceKmSince(last.date, sessions);
    final capacity = summary.capacityKwh;
    final kmPerKwh = summary.kmPerKwhForEstimates;
    double? percent;
    double? range;
    if (last != null && capacity != null && capacity > 0 && kmPerKwh != null && kmPerKwh > 0) {
      final remaining = (last.endPercent / 100 * capacity - kmSince / kmPerKwh).clamp(0.0, capacity);
      percent = remaining / capacity * 100;
      range = remaining * kmPerKwh;
    }
    double? panelRange;
    for (final record in summary.timeline.reversed) {
      final reading = switch (record) {
        RefuelRecord r => r.panelFuelRangeAfterKm,
        ChargeRecord c => c.usedFuelSinceLast ? c.panelFuelRangeKm : null,
        _ => null,
      };
      if (reading != null) {
        panelRange = reading;
        break;
      }
    }
    return HybridOverview(
      lastCharge: last,
      kmSinceLastCharge: kmSince,
      batteryPercent: percent,
      electricRangeKm: range,
      panelFuelRangeKm: panelRange,
    );
  }
}

String formatKwh(double kwh) => '${formatDecimal(kwh, decimals: 1)} kWh';
String formatKmPerKwh(double v) => '${formatDecimal(v, decimals: 1)} km/kWh';
String formatPricePerKwh(double v) => 'R\$ ${formatDecimal(v, decimals: 2)}/kWh';
String formatPercent(double v) => '${formatDecimal(v, decimals: 0)}%';
