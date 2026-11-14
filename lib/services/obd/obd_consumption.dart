/// The OBD-II instant fuel consumption (2026-11-14) — an ESTIMATE, pure
/// functions, no I/O. Phase 2 calibrates it against the refuels
/// ([calibration]); until then the figure is indicative.
///
/// The air the engine takes in comes from the MAF sensor when the car has one
/// (g/s), otherwise from the manifold pressure by speed-density — the Nivus'
/// engine has no MAF:
///
///   air (kg/s) = ρ(MAP, IAT) × displacement × rpm / 120 × VE
///
/// with ρ = MAP / (R × T) for dry air and a four-stroke engine filling its
/// displacement every two turns. The fuel is that air over the
/// stoichiometric air–fuel ratio of the blend in the tank (from the ethanol
/// share the car reports — 14.7 for pure gasoline, 9.0 for ethanol — or,
/// without it, Brazilian gasoline's 27 % ethanol), turned into litres by the
/// blend's density. Real lambda (rich at full load, fuel cut on the overrun)
/// and the true volumetric efficiency are what [calibration] will absorb.
library;

/// Dry air's specific gas constant, J/(kg·K).
const double _airGasConstant = 287.05;

/// The ethanol share assumed when the car does not report it: Brazilian
/// gasoline (E27, since 2015 by law; E30 from August 2025).
const double brazilianGasolineEthanolPercent = 27;

/// A mid-range volumetric efficiency for a modern engine at part load.
const double defaultVolumetricEfficiency = 0.85;

/// What the estimate says now.
typedef ObdConsumption = ({double litersPerHour, double? kmPerLiter, bool fromMaf});

/// The instant consumption, or `null` when what it needs is missing (no MAF
/// and no MAP + rpm + intake temperature + displacement).
///
/// [kmPerLiter] only while moving (≥ 5 km/h): stopped, only the flow means
/// anything. An engine at 0 rpm (switched off, or a hybrid driving electric)
/// burns nothing.
ObdConsumption? estimateConsumption({
  double? mafGramsPerSecond,
  double? manifoldPressureKpa,
  double? rpm,
  double? intakeTempC,
  double? engineDisplacementLiters,
  double? speedKmh,
  double? ethanolPercent,
  double volumetricEfficiency = defaultVolumetricEfficiency,
  double calibration = 1.0,
}) {
  final double airGramsPerSecond;
  final fromMaf = mafGramsPerSecond != null;
  if (mafGramsPerSecond != null) {
    airGramsPerSecond = mafGramsPerSecond;
  } else {
    if (manifoldPressureKpa == null || rpm == null || intakeTempC == null || engineDisplacementLiters == null) return null;
    if (rpm <= 0) return (litersPerHour: 0, kmPerLiter: null, fromMaf: false);
    final density = manifoldPressureKpa * 1000 / (_airGasConstant * (intakeTempC + 273.15)); // kg/m³
    final volumeFlow = engineDisplacementLiters / 1000 * rpm / 120 * volumetricEfficiency; // m³/s
    airGramsPerSecond = density * volumeFlow * 1000;
  }
  if (rpm != null && rpm <= 0) return (litersPerHour: 0, kmPerLiter: null, fromMaf: fromMaf);

  final e = ((ethanolPercent ?? brazilianGasolineEthanolPercent) / 100).clamp(0.0, 1.0);
  final airFuelRatio = 14.7 * (1 - e) + 9.0 * e;
  final densityGramsPerLiter = 745 * (1 - e) + 789 * e;
  final fuelGramsPerSecond = airGramsPerSecond / airFuelRatio;
  final litersPerHour = fuelGramsPerSecond * 3600 / densityGramsPerLiter * calibration;

  final speed = speedKmh;
  final kmPerLiter = speed != null && speed >= 5 && litersPerHour > 0 ? speed / litersPerHour : null;
  return (litersPerHour: litersPerHour, kmPerLiter: kmPerLiter, fromMaf: fromMaf);
}
