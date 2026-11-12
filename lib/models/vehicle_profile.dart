import 'package:hive/hive.dart';

part 'vehicle_profile.g.dart';

/// The fuel actually put in the tank at a refuel (and the fuel the consumption
/// figures are computed for). Brazilian pump gasoline is already E30 — this is
/// the pump product, not a chemical composition.
///
/// typeId: 16
@HiveType(typeId: 16)
enum FuelType {
  @HiveField(0)
  gasoline,
  @HiveField(1)
  ethanol,
  @HiveField(2)
  diesel,
}

/// What the vehicle can burn. A flex car takes gasoline or ethanol; every other
/// system takes exactly one [FuelType] — see [VehicleFuelSystemFuels.fuels].
///
/// typeId: 17
@HiveType(typeId: 17)
enum VehicleFuelSystem {
  @HiveField(0)
  flex,
  @HiveField(1)
  gasoline,
  @HiveField(2)
  ethanol,
  @HiveField(3)
  diesel,
}

extension VehicleFuelSystemFuels on VehicleFuelSystem {
  /// The fuels this system accepts, in the order they are offered.
  List<FuelType> get fuels => switch (this) {
        VehicleFuelSystem.flex => const [FuelType.gasoline, FuelType.ethanol],
        VehicleFuelSystem.gasoline => const [FuelType.gasoline],
        VehicleFuelSystem.ethanol => const [FuelType.ethanol],
        VehicleFuelSystem.diesel => const [FuelType.diesel],
      };
}

const Map<FuelType, String> fuelTypeLabels = {
  FuelType.gasoline: 'Gasolina',
  FuelType.ethanol: 'Etanol',
  FuelType.diesel: 'Diesel',
};

const Map<VehicleFuelSystem, String> vehicleFuelSystemLabels = {
  VehicleFuelSystem.flex: 'Flex',
  VehicleFuelSystem.gasoline: 'Gasolina',
  VehicleFuelSystem.ethanol: 'Etanol',
  VehicleFuelSystem.diesel: 'Diesel',
};

/// "Meu veículo" (owner decision, 2026-11-11): the minimal single-vehicle
/// profile — no make/model/year identification at all. The tank capacity and
/// the reference consumption (the INMETRO label or manual figure, one per fuel
/// the vehicle takes) are enough for range estimates and for comparing the
/// user's measured km/L against what the car should do. One profile only; it
/// lives under a fixed key (see `VehicleRepository`).
///
/// Engine displacement is deliberately absent: it is only needed for a
/// speed-density fuel estimate on a car without a MAF sensor, which the OBD-II
/// phase 0 has not measured yet. Add it then, nullable, as field 7.
///
/// typeId: 18
@HiveType(typeId: 18)
class VehicleProfile extends HiveObject {
  VehicleProfile({
    this.nickname,
    required this.fuelSystem,
    required this.tankCapacityLiters,
    this.kmPerLiterGasoline,
    this.kmPerLiterEthanol,
    this.kmPerLiterDiesel,
    required this.defaultFuel,
  });

  /// Optional name shown in the app ("Meu carro" when absent).
  @HiveField(0)
  String? nickname;

  @HiveField(1)
  VehicleFuelSystem fuelSystem;

  @HiveField(2)
  double tankCapacityLiters;

  /// Reference consumption, km per litre, for each fuel. Only the ones in
  /// [fuelSystem]'s fuels are meaningful; the form requires those.
  @HiveField(3)
  double? kmPerLiterGasoline;

  @HiveField(4)
  double? kmPerLiterEthanol;

  @HiveField(5)
  double? kmPerLiterDiesel;

  /// The fuel a new refuel starts with. On a flex car, registering a refuel
  /// with the other fuel makes that one the default (owner decision: "assume
  /// até mudar").
  @HiveField(6)
  FuelType defaultFuel;

  String get displayName {
    final name = nickname?.trim();
    return name == null || name.isEmpty ? 'Meu carro' : name;
  }

  double? referenceKmPerLiter(FuelType fuel) => switch (fuel) {
        FuelType.gasoline => kmPerLiterGasoline,
        FuelType.ethanol => kmPerLiterEthanol,
        FuelType.diesel => kmPerLiterDiesel,
      };
}
