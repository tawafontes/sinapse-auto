import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/refuel_record.dart';
import 'package:synapse_auto/models/vehicle_profile.dart';
import 'package:synapse_auto/services/fuel_consumption.dart';

RefuelRecord refuel(
  String id, {
  required DateTime date,
  required double odometer,
  required double liters,
  double price = 6.0,
  FuelType fuel = FuelType.gasoline,
  bool full = true,
}) =>
    RefuelRecord(
      id: id,
      date: date,
      odometerKm: odometer,
      liters: liters,
      pricePerLiter: price,
      fuel: fuel,
      fullTank: full,
    );

VehicleProfile flexProfile({double tank = 50, double? gasoline = 12, double? ethanol = 8.4, FuelType defaultFuel = FuelType.gasoline}) =>
    VehicleProfile(
      fuelSystem: VehicleFuelSystem.flex,
      tankCapacityLiters: tank,
      kmPerLiterGasoline: gasoline,
      kmPerLiterEthanol: ethanol,
      defaultFuel: defaultFuel,
    );

void main() {
  final day = DateTime(2026, 11, 1, 10);
  DateTime d(int n) => day.add(Duration(days: n));

  group('sortRefuels', () {
    test('by date, then by odometer on the same instant', () {
      final a = refuel('a', date: d(2), odometer: 300, liters: 10);
      final b = refuel('b', date: d(1), odometer: 200, liters: 10);
      final c = refuel('c', date: d(1), odometer: 100, liters: 10);
      expect(sortRefuels([a, b, c]).map((r) => r.id), ['c', 'b', 'a']);
    });
  });

  group('consumptionIntervals (full-to-full)', () {
    test('two full refuels: distance over the closing litres', () {
      final intervals = consumptionIntervals([
        refuel('1', date: d(0), odometer: 10000, liters: 40),
        refuel('2', date: d(7), odometer: 10480, liters: 40, price: 6.5),
      ]);
      expect(intervals, hasLength(1));
      expect(intervals.single.distanceKm, 480);
      expect(intervals.single.liters, 40);
      expect(intervals.single.kmPerLiter, 12);
      expect(intervals.single.cost, closeTo(260, 1e-9));
      expect(intervals.single.costPerKm, closeTo(260 / 480, 1e-9));
      expect(intervals.single.fuel, FuelType.gasoline);
      expect(intervals.single.refuelCount, 1);
    });

    test('a partial refuel in between adds its litres and cost to the interval', () {
      final intervals = consumptionIntervals([
        refuel('1', date: d(0), odometer: 1000, liters: 45),
        refuel('2', date: d(3), odometer: 1200, liters: 10, price: 5, full: false),
        refuel('3', date: d(6), odometer: 1600, liters: 40, price: 6),
      ]);
      expect(intervals, hasLength(1));
      expect(intervals.single.distanceKm, 600);
      expect(intervals.single.liters, 50);
      expect(intervals.single.kmPerLiter, 12);
      expect(intervals.single.cost, 50 + 240);
      expect(intervals.single.refuelCount, 2);
    });

    test('refuels before the first full one are not attributed to any interval', () {
      final intervals = consumptionIntervals([
        refuel('p', date: d(0), odometer: 900, liters: 20, full: false),
        refuel('1', date: d(1), odometer: 1000, liters: 30),
        refuel('2', date: d(5), odometer: 1360, liters: 30),
      ]);
      expect(intervals.single.from.id, '1');
      expect(intervals.single.liters, 30);
    });

    test('a single full refuel, or only partials, yields nothing', () {
      expect(consumptionIntervals([refuel('1', date: d(0), odometer: 1000, liters: 30)]), isEmpty);
      expect(
        consumptionIntervals([
          refuel('1', date: d(0), odometer: 1000, liters: 30, full: false),
          refuel('2', date: d(1), odometer: 1200, liters: 30, full: false),
        ]),
        isEmpty,
      );
    });

    test('the burned fuel is the one that filled the tank, not the closing refuel\'s', () {
      final intervals = consumptionIntervals([
        refuel('1', date: d(0), odometer: 1000, liters: 40, fuel: FuelType.ethanol),
        refuel('2', date: d(4), odometer: 1300, liters: 36, fuel: FuelType.gasoline),
      ]);
      expect(intervals.single.fuel, FuelType.ethanol);
    });

    test('a partial with another fuel makes the interval mixed (null)', () {
      final intervals = consumptionIntervals([
        refuel('1', date: d(0), odometer: 1000, liters: 40, fuel: FuelType.gasoline),
        refuel('2', date: d(2), odometer: 1200, liters: 10, fuel: FuelType.ethanol, full: false),
        refuel('3', date: d(4), odometer: 1500, liters: 35, fuel: FuelType.gasoline),
      ]);
      expect(intervals.single.fuel, isNull);
    });

    test('an interval with no distance is dropped, and the next one starts from its closing refuel', () {
      final intervals = consumptionIntervals([
        refuel('1', date: d(0), odometer: 1000, liters: 40),
        refuel('2', date: d(1), odometer: 1000, liters: 2),
        refuel('3', date: d(5), odometer: 1400, liters: 40),
      ]);
      expect(intervals, hasLength(1));
      expect(intervals.single.from.id, '2');
      expect(intervals.single.kmPerLiter, 10);
    });
  });

  group('ConsumptionSummary', () {
    final log = [
      refuel('1', date: DateTime(2026, 9, 28), odometer: 1000, liters: 40, price: 6),
      refuel('2', date: DateTime(2026, 10, 5), odometer: 1480, liters: 40, price: 6, fuel: FuelType.ethanol),
      refuel('3', date: DateTime(2026, 10, 12), odometer: 1816, liters: 42, price: 4, fuel: FuelType.gasoline),
      refuel('4', date: DateTime(2026, 11, 2), odometer: 2296, liters: 40, price: 6.2),
    ];
    final summary = ConsumptionSummary.of(log.reversed);

    test('averages: distance over litres, per burned fuel and overall', () {
      expect(summary.intervals.map((i) => i.fuel), [FuelType.gasoline, FuelType.ethanol, FuelType.gasoline]);
      expect(summary.averageKmPerLiter(FuelType.gasoline), (480 + 480) / (40 + 40));
      expect(summary.averageKmPerLiter(FuelType.ethanol), 336 / 42);
      expect(summary.averageKmPerLiter(), (480 + 336 + 480) / (40 + 42 + 40));
      expect(summary.averageKmPerLiter(FuelType.diesel), isNull);
    });

    test('cost per km over every interval; totals over every refuel', () {
      expect(summary.costPerKm, closeTo((240 + 168 + 248) / 1296, 1e-9));
      expect(summary.totalSpent, closeTo(240 + 240 + 168 + 248, 1e-9));
      expect(summary.totalLiters, 162);
    });

    test('monthly spending, most recent month first', () {
      final months = summary.monthly;
      expect(months.map((m) => m.month), [DateTime(2026, 11), DateTime(2026, 10), DateTime(2026, 9)]);
      expect(months[1].spent, closeTo(240 + 168, 1e-9));
      expect(months[1].liters, 82);
    });

    test('last price per fuel, and km/L falls back to the reference without a measurement', () {
      expect(summary.lastPricePerLiter(FuelType.gasoline), 6.2);
      expect(summary.lastPricePerLiter(FuelType.ethanol), 6);
      expect(summary.lastPricePerLiter(FuelType.diesel), isNull);
      final empty = ConsumptionSummary.of(const []);
      expect(empty.kmPerLiterFor(FuelType.ethanol, flexProfile()), 8.4);
      expect(empty.kmPerLiterFor(FuelType.ethanol, null), isNull);
      expect(empty.costPerKm, isNull);
    });
  });

  group('ethanolBreakEven', () {
    test('from the measured averages when both fuels have intervals', () {
      final summary = ConsumptionSummary.of([
        refuel('1', date: d(0), odometer: 1000, liters: 40, fuel: FuelType.gasoline),
        refuel('2', date: d(4), odometer: 1480, liters: 40, fuel: FuelType.ethanol),
        refuel('3', date: d(8), odometer: 1816, liters: 40, fuel: FuelType.gasoline),
      ]);
      final result = ethanolBreakEven(summary, flexProfile());
      expect(result!.measured, isTrue);
      expect(result.ratio, closeTo((336 / 40) / (480 / 40), 1e-9));
    });

    test('from the reference figures otherwise; none for a car that is not flex', () {
      final summary = ConsumptionSummary.of(const []);
      final result = ethanolBreakEven(summary, flexProfile(gasoline: 12, ethanol: 8.4));
      expect(result!.measured, isFalse);
      expect(result.ratio, closeTo(0.7, 1e-9));
      final gasolineOnly = VehicleProfile(
        fuelSystem: VehicleFuelSystem.gasoline,
        tankCapacityLiters: 50,
        kmPerLiterGasoline: 12,
        defaultFuel: FuelType.gasoline,
      );
      expect(ethanolBreakEven(summary, gasolineOnly), isNull);
      expect(ethanolBreakEven(summary, null), isNull);
    });
  });

  group('distance since a refuel and the odometer suggestion', () {
    test('sums sessions that started at or after the refuel, leaving out sessions being deleted', () {
      final since = d(1);
      final sessions = [
        DrivingSession(id: 'before', startTime: d(0), endTime: d(0))..distanceMeters = 50000,
        DrivingSession(id: 'at', startTime: since, endTime: since)..distanceMeters = 12000,
        DrivingSession(id: 'after', startTime: d(2))..distanceMeters = 3500,
        DrivingSession(id: 'deleting', startTime: d(3), endTime: d(3), deletionPending: true)..distanceMeters = 99000,
      ];
      expect(appDistanceKmSince(since, sessions), closeTo(15.5, 1e-9));
    });

    test('the suggestion is the last odometer plus that distance, rounded; none before the first refuel', () {
      final last = refuel('1', date: d(0), odometer: 12345, liters: 40);
      expect(suggestedOdometerKm(last, 101.6), 12447);
      expect(suggestedOdometerKm(null, 101.6), isNull);
    });
  });

  group('odometerConflict', () {
    final others = [
      refuel('1', date: d(0), odometer: 1000, liters: 40),
      refuel('2', date: d(10), odometer: 2000, liters: 40),
    ];

    test('must be above the previous refuel and below the next one', () {
      expect(odometerConflict(1500, d(5), others), isNull);
      expect(odometerConflict(2500, d(11), others), isNull);
      expect(odometerConflict(1000, d(5), others), contains('anterior (1.000 km)'));
      expect(odometerConflict(2000, d(5), others), contains('seguinte (2.000 km)'));
      expect(odometerConflict(1900, d(11), others), contains('anterior (2.000 km)'));
      expect(odometerConflict(5, d(-1), others), isNull);
      expect(odometerConflict(5, d(5), const []), isNull);
    });
  });

  group('estimateFuelLiters and RefuelOverview', () {
    test('full at the last full refuel, minus what the distance since burns', () {
      final summary = ConsumptionSummary.of([refuel('1', date: d(0), odometer: 1000, liters: 40)]);
      // No interval measured yet: the reference 12 km/L applies.
      expect(estimateFuelLiters(profile: flexProfile(), summary: summary, kmSinceLastRefuel: 120), closeTo(40, 1e-9));
    });

    test('a later partial refuel burns the distance before it, then adds its litres, capped at the tank', () {
      final summary = ConsumptionSummary.of([
        refuel('1', date: d(0), odometer: 1000, liters: 40),
        refuel('2', date: d(2), odometer: 1240, liters: 10, full: false),
      ]);
      // 50 − 240/12 = 30, + 10 = 40, − 60/12 = 35.
      expect(estimateFuelLiters(profile: flexProfile(), summary: summary, kmSinceLastRefuel: 60), closeTo(35, 1e-9));
      final topped = ConsumptionSummary.of([
        refuel('1', date: d(0), odometer: 1000, liters: 40),
        refuel('2', date: d(2), odometer: 1012, liters: 30, full: false),
      ]);
      expect(estimateFuelLiters(profile: flexProfile(), summary: topped, kmSinceLastRefuel: 0), 50);
    });

    test('never below empty; unknown without a full refuel or without a km/L', () {
      final summary = ConsumptionSummary.of([refuel('1', date: d(0), odometer: 1000, liters: 40)]);
      expect(estimateFuelLiters(profile: flexProfile(), summary: summary, kmSinceLastRefuel: 5000), 0);
      final partialOnly = ConsumptionSummary.of([refuel('1', date: d(0), odometer: 1000, liters: 40, full: false)]);
      expect(estimateFuelLiters(profile: flexProfile(), summary: partialOnly, kmSinceLastRefuel: 0), isNull);
      expect(estimateFuelLiters(profile: flexProfile(gasoline: null), summary: summary, kmSinceLastRefuel: 0), isNull);
    });

    test('the measured km/L of the fuel in the tank wins over the reference', () {
      final overview = RefuelOverview.compute(
        profile: flexProfile(),
        refuels: [
          refuel('1', date: d(0), odometer: 1000, liters: 40),
          refuel('2', date: d(5), odometer: 1400, liters: 40),
        ],
        sessions: [DrivingSession(id: 's', startTime: d(6), endTime: d(6))..distanceMeters = 100000],
      );
      expect(overview.lastRefuel!.id, '2');
      expect(overview.lastInterval!.kmPerLiter, 10);
      expect(overview.kmSinceLastRefuel, 100);
      expect(overview.estimatedLiters, closeTo(40, 1e-9), reason: '50 − 100 km / 10 km/L');
      expect(overview.rangeKm, closeTo(400, 1e-9));
    });

    test('without a profile or refuels there is nothing to estimate', () {
      final none = RefuelOverview.compute(profile: flexProfile(), refuels: const [], sessions: const []);
      expect(none.lastRefuel, isNull);
      expect(none.rangeKm, isNull);
      final noProfile = RefuelOverview.compute(
        profile: null,
        refuels: [refuel('1', date: d(0), odometer: 1000, liters: 40)],
        sessions: const [],
      );
      expect(noProfile.estimatedLiters, isNull);
      expect(noProfile.rangeKm, isNull);
    });
  });

  group('Brazilian number format', () {
    test('formatDecimal groups thousands with dots and uses a decimal comma', () {
      expect(formatDecimal(12345.67, decimals: 2), '12.345,67');
      expect(formatDecimal(999.95), '1.000,0');
      expect(formatDecimal(-1234.5), '-1.234,5');
      expect(formatPricePerLiter(6.299), 'R\$ 6,299/L');
      expect(formatMoney(251.96), 'R\$ 251,96');
    });

    test('parseDecimal reads what people type', () {
      expect(parseDecimal('40,5'), 40.5);
      expect(parseDecimal('40.5'), 40.5);
      expect(parseDecimal(' 6,299 '), 6.299);
      expect(parseDecimal('6.299'), 6.299, reason: 'a pump price, not six thousand');
      expect(parseDecimal('1.234,5'), 1234.5);
      expect(parseDecimal('1.234.567'), 1234567);
      expect(parseDecimal('12.345', dotGroupsThousands: true), 12345);
      expect(parseDecimal('12.3', dotGroupsThousands: true), 12.3);
      expect(parseDecimal(''), isNull);
      expect(parseDecimal('abc'), isNull);
      expect(parseDecimal('NaN'), isNull);
    });
  });
}
