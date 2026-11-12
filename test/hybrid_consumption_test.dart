import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/charge_record.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/refuel_record.dart';
import 'package:synapse_auto/models/vehicle_profile.dart';
import 'package:synapse_auto/services/fuel_consumption.dart';
import 'package:synapse_auto/services/hybrid_consumption.dart';

// The plug-in hybrid strategy (owner decisions, 2026-11-12), around the owner's
// own use: electric in town, the engine only when the battery runs out.

VehicleProfile plugIn({double? capacity = 17, double? range = 68, bool auto = true}) => VehicleProfile(
      fuelSystem: VehicleFuelSystem.gasoline,
      tankCapacityLiters: 55,
      kmPerLiterGasoline: 14,
      defaultFuel: FuelType.gasoline,
      propulsion: VehiclePropulsion.plugInHybrid,
      batteryCapacityKwh: capacity,
      electricRangeKm: range,
      autoUpdateReferences: auto,
    );

final _t0 = DateTime(2026, 11, 1, 8);
DateTime day(int n) => _t0.add(Duration(days: n));

ChargeRecord charge(String id, int d, double odometer, double start, double end,
        {double? kwh, double price = 1.0, double? wall, bool usedFuel = false, double? range}) =>
    ChargeRecord(
      id: id,
      date: day(d),
      odometerKm: odometer,
      startPercent: start,
      endPercent: end,
      chargerKwh: kwh,
      pricePerKwh: price,
      wallKwh: wall ?? kwh ?? 10,
      usedFuelSinceLast: usedFuel,
      panelFuelRangeKm: range,
    );

RefuelRecord refuel(String id, int d, double odometer, double liters,
        {double price = 6, bool full = true, bool? usedFuel, double? before, double? after}) =>
    RefuelRecord(
      id: id,
      date: day(d),
      odometerKm: odometer,
      liters: liters,
      pricePerLiter: price,
      fuel: FuelType.gasoline,
      fullTank: full,
      usedFuelSinceLast: usedFuel,
      panelFuelRangeBeforeKm: before,
      panelFuelRangeAfterKm: after,
    );

void main() {
  test('a recharge given only as a % span is billed with the fixed 10% loss margin', () {
    expect(wallKwhFromPercent(startPercent: 20, endPercent: 100, capacityKwh: 17), closeTo(0.8 * 17 * 1.1, 1e-9));
    expect(chargingLossMargin, 0.10);
  });

  group('battery capacity: typed, refined by the recharges that give the charger\'s kWh', () {
    test('learned from spans of at least 30% — short recharges added up —, mean of the last 5; the switch off keeps the typed one', () {
      final charges = [
        charge('a', 0, 1000, 40, 100, kwh: 11), // 11 / 1.1 / 0.6 = 16.67
        charge('b', 1, 1050, 70, 90, kwh: 3.6), // 20%: too short alone…
        charge('c', 2, 1100, 80, 100, kwh: 3.6), // …added to this one: 7.2 / 1.1 / 0.4 = 16.36
        charge('d', 3, 1150, 30, 100), // no kWh: nothing to learn
      ];
      final on = HybridSummary.of(profile: plugIn(), refuels: const [], charges: charges);
      expect(on.learnedCapacityKwh, closeTo((11 / 1.1 / 0.6 + 7.2 / 1.1 / 0.4) / 2, 1e-9));
      expect(on.capacityKwh, on.learnedCapacityKwh);
      final off = HybridSummary.of(profile: plugIn(auto: false), refuels: const [], charges: charges);
      expect(off.capacityKwh, 17);
      final none = HybridSummary.of(profile: plugIn(), refuels: const [], charges: [charges[3]]);
      expect(none.capacityKwh, 17, reason: 'nothing learned yet: the typed value');
    });

    test('only the last 5 samples count', () {
      final charges = [
        for (var i = 0; i < 7; i++) charge('c$i', i, 1000.0 + i * 50, 0, 100, kwh: (i < 2 ? 22 : 11) * 1.1),
      ];
      expect(HybridSummary.of(profile: plugIn(), refuels: const [], charges: charges).learnedCapacityKwh, closeTo(11, 1e-9));
    });
  });

  group('km/kWh is measured between recharges WITHOUT fuel', () {
    test('energy = % left at the previous recharge − % at this start, of the capacity', () {
      final s = HybridSummary.of(profile: plugIn(), refuels: const [], charges: [
        charge('a', 0, 1000, 20, 100),
        charge('b', 1, 1060, 30, 100), // 70% of 17 kWh over 60 km
      ]);
      final i = s.electricIntervals.single;
      expect((i.km, i.percentUsed, i.withoutFuel, i.counts), (60.0, 70.0, true, true));
      expect(s.electricMeasurements.single.kmPerKwh, closeTo(60 / 11.9, 1e-9));
      expect(i.energyKwh, closeTo(11.9, 1e-9));
      expect(s.measuredKmPerKwh, closeTo(60 / 11.9, 1e-9));
    });

    test('an interval where fuel was used does not measure it — the engine may have charged the battery', () {
      final s = HybridSummary.of(profile: plugIn(), refuels: const [], charges: [
        charge('a', 0, 1000, 20, 100),
        charge('b', 1, 1100, 10, 100, usedFuel: true, range: 500),
      ]);
      expect(s.electricIntervals.single.withoutFuel, isFalse);
      expect(s.measuredKmPerKwh, isNull);
    });

    test('a refuel in between counts as fuel unless it says no fuel was used', () {
      List<ElectricInterval> intervals(bool? used) => HybridSummary.of(
            profile: plugIn(),
            refuels: [refuel('r', 1, 1030, 5, full: false, usedFuel: used)],
            charges: [charge('a', 0, 1000, 20, 100), charge('b', 2, 1060, 30, 100)],
          ).electricIntervals;
      expect(intervals(true).single.withoutFuel, isFalse);
      expect(intervals(null).single.withoutFuel, isFalse);
      expect(intervals(false).single.withoutFuel, isTrue);
    });

    test('short recharges (20% a day) add up into one sample; they all count in the overall average', () {
      final s = HybridSummary.of(profile: plugIn(), refuels: const [], charges: [
        charge('a', 0, 1000, 20, 100),
        charge('b', 1, 1016, 80, 100), // 20% for 16 km
        charge('c', 2, 1034, 80, 100), // 20% for 18 km → 40%: a sample
        charge('d', 3, 1050, 80, 100), // 20%, still open
      ]);
      expect(s.electricIntervals.every((i) => i.counts), isTrue);
      final sample = s.electricMeasurements.single;
      expect((sample.km, sample.percentUsed, sample.intervals.length, sample.closedBy.id), (34.0, 40.0, 2, 'c'));
      expect(sample.kmPerKwh, closeTo(34 / (0.4 * 17), 1e-9));
      expect(s.measuredKmPerKwh, closeTo(50 / (0.6 * 17), 1e-9), reason: 'the open 20% counts here');
    });

    test('an interval that used fuel breaks a run of short ones', () {
      final s = HybridSummary.of(profile: plugIn(), refuels: const [], charges: [
        charge('a', 0, 1000, 20, 100),
        charge('b', 1, 1016, 80, 100), // 20%
        charge('c', 2, 1100, 5, 100, usedFuel: true, range: 500), // fuel: the 20% before is dropped
        charge('d', 3, 1116, 80, 100), // 20%
        charge('e', 4, 1132, 80, 100), // 20% → 40% since the fuel
      ]);
      expect(s.electricMeasurements.single.intervals.map((i) => i.to.id), ['d', 'e']);
    });

    test('the reference: the last 5 measurements with the switch on, the typed range/capacity off', () {
      final charges = [charge('a', 0, 1000, 20, 100), charge('b', 1, 1060, 30, 100)];
      expect(HybridSummary.of(profile: plugIn(), refuels: const [], charges: charges).kmPerKwhReference, closeTo(60 / 11.9, 1e-9));
      expect(HybridSummary.of(profile: plugIn(auto: false), refuels: const [], charges: charges).kmPerKwhReference, 4.0);
      expect(HybridSummary.of(profile: plugIn(), refuels: const [], charges: const []).kmPerKwhReference, 4.0);
    });
  });

  group('combustion km = the drop of the panel\'s fuel range', () {
    // The owner's pattern: full tank, weeks of electric driving, the battery
    // runs out twice, then a refuel.
    final log = (
      refuels: [
        refuel('r1', 0, 1000, 40, after: 600),
        refuel('r2', 20, 2000, 8, usedFuel: true, before: 510, after: 610),
      ],
      charges: [
        charge('c1', 1, 1050, 20, 100), // no fuel
        charge('c2', 5, 1300, 5, 100, usedFuel: true, range: 560), // 40 km on fuel
        charge('c3', 9, 1500, 30, 100), // no fuel
        charge('c4', 12, 1700, 5, 100, usedFuel: true, range: 570), // range rose (recalculated): 0, never negative
        charge('c5', 15, 1900, 5, 100, usedFuel: true, range: 530), // 40 km
      ],
    );

    test('attributed where it was read; a refuel starts again from the range after it', () {
      final s = HybridSummary.of(profile: plugIn(), refuels: log.refuels, charges: log.charges);
      expect(s.fuelKmAt, {'c2': 40.0, 'c4': 0.0, 'c5': 40.0, 'r2': 20.0});
      expect(s.fuelKm, 100);
      expect(s.spanKm, 1000);
      expect(s.electricShare, closeTo(0.9, 1e-9));
    });

    test('engine km/L: litres between full tanks over the combustion km read in between', () {
      final s = HybridSummary.of(profile: plugIn(), refuels: log.refuels, charges: log.charges);
      expect(s.engineIntervals.single.fuelKm, 100);
      expect(s.engineKmPerLiter(), closeTo(100 / 8, 1e-9));
      expect(s.engineKmPerLiterReference(FuelType.gasoline), closeTo(100 / 8, 1e-9), reason: '100 km on fuel: enough to update it');
      final off = HybridSummary.of(profile: plugIn(auto: false), refuels: log.refuels, charges: log.charges);
      expect(off.engineKmPerLiterReference(FuelType.gasoline), 14);
    });

    test('combined cost per km: everything spent after the first record over the distance since it', () {
      final s = HybridSummary.of(profile: plugIn(), refuels: log.refuels, charges: log.charges);
      // r1 paid for driving before the log; then 5 recharges at 10 kWh × R$ 1 and r2 (8 L × R$ 6).
      expect(s.combinedCostPerKm, closeTo((5 * 10 + 48) / 1000, 1e-9));
      expect((s.energySpent, s.fuelSpent, s.wallKwh, s.liters), (50.0, 240.0 + 48, 50.0, 48.0));
    });
  });

  group('the dashboard overview of a plug-in', () {
    test('battery and electric range: the last recharge minus the km recorded since, all electric', () {
      final o = HybridOverview.compute(
        profile: plugIn(), // 17 kWh, 68 km → 4 km/kWh
        refuels: [refuel('r1', 0, 1000, 40, after: 600)],
        charges: [charge('c1', 1, 1050, 20, 100)],
        sessions: [DrivingSession(id: 's', startTime: day(2), endTime: day(2))..distanceMeters = 34000],
      );
      expect(o.kmSinceLastCharge, 34);
      expect(o.batteryPercent, closeTo(50, 1e-9), reason: '17 kWh − 34 km / 4 km/kWh = 8.5 kWh');
      expect(o.electricRangeKm, closeTo(34, 1e-9));
      expect(o.panelFuelRangeKm, 600, reason: 'electric driving leaves the tank alone');
    });

    test('the fuel range follows the latest reading; nothing to estimate without a recharge or a capacity', () {
      final o = HybridOverview.compute(
        profile: plugIn(capacity: null),
        refuels: [refuel('r1', 0, 1000, 40, after: 600)],
        charges: [charge('c1', 1, 1100, 5, 100, usedFuel: true, range: 540)],
        sessions: const [],
      );
      expect(o.panelFuelRangeKm, 540);
      expect(o.batteryPercent, isNull);
      expect(HybridOverview.compute(profile: plugIn(), refuels: const [], charges: const [], sessions: const []).lastCharge, isNull);
    });
  });

  test('the timeline orders both kinds; the odometer check names the kind', () {
    final r = refuel('r', 1, 1100, 40);
    final c = charge('c', 2, 1200, 20, 100);
    expect(vehicleTimeline([r], [c]).map((e) => e.id), ['r', 'c']);
    expect(latestRecord([r, c])!.id, 'c');
    expect(odometerConflict(1150, day(3), [r, c]), contains('maior que o da recarga anterior (1.200 km)'));
    expect(odometerConflict(1150, day(0), [r, c]), contains('menor que o do abastecimento seguinte (1.100 km)'));
    expect(suggestedOdometerKm(c, 12.4), 1212);
  });
}
