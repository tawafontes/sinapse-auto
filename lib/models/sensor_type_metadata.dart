import 'package:flutter/material.dart';

import 'sensor_widget_config.dart';

/// Display label, icon and unit for each [SensorType], shared by the sensor
/// selection screen, the style picker and the dashboard.
class SensorTypeMetadata {
  const SensorTypeMetadata({required this.label, required this.icon, required this.unit});

  final String label;
  final IconData icon;

  /// Empty string for a sensor with no meaningful unit.
  final String unit;
}

const Map<SensorType, SensorTypeMetadata> sensorTypeMetadata = {
  SensorType.speed: SensorTypeMetadata(label: 'Velocidade', icon: Icons.speed, unit: 'km/h'),
  SensorType.inclination: SensorTypeMetadata(label: 'Inclinação', icon: Icons.architecture, unit: '°'),
  SensorType.altitude: SensorTypeMetadata(label: 'Altitude', icon: Icons.terrain, unit: 'm'),
  SensorType.gForce: SensorTypeMetadata(label: 'Aceleração G', icon: Icons.bolt, unit: 'g'),
  SensorType.refuel: SensorTypeMetadata(label: 'Abastecimento', icon: Icons.local_gas_station, unit: 'km'),
  SensorType.engineRpm: SensorTypeMetadata(label: 'Rotação', icon: Icons.av_timer, unit: 'rpm'),
  SensorType.batteryVoltage: SensorTypeMetadata(label: 'Bateria', icon: Icons.battery_charging_full, unit: 'V'),
  SensorType.engineLoad: SensorTypeMetadata(label: 'Carga do motor', icon: Icons.speed, unit: '%'),
  SensorType.fuelLevel: SensorTypeMetadata(label: 'Nível do tanque', icon: Icons.local_gas_station_outlined, unit: '%'),
  SensorType.engineTemperatures: SensorTypeMetadata(label: 'Temperaturas', icon: Icons.device_thermostat, unit: '°C'),
  SensorType.accelerator: SensorTypeMetadata(label: 'Acelerador', icon: Icons.trending_up, unit: '%'),
  SensorType.fuelConsumption: SensorTypeMetadata(label: 'Consumo instantâneo', icon: Icons.eco_outlined, unit: 'km/L'),
  SensorType.hybridBattery: SensorTypeMetadata(label: 'Bateria de alta tensão', icon: Icons.battery_std, unit: '%'),
  SensorType.energyFlow: SensorTypeMetadata(label: 'Fluxo de energia', icon: Icons.bolt, unit: 'kW'),
  SensorType.driveMode: SensorTypeMetadata(label: 'Modo de condução', icon: Icons.electric_car, unit: '%'),
  SensorType.turboBoost: SensorTypeMetadata(label: 'Turbo', icon: Icons.air, unit: 'bar'),
};

/// The sensors read from the car through the OBD-II adapter (phase 1). Left
/// out of the first-run dashboard and the first-run selection: without an
/// adapter they would only say "Configurar adaptador".
const Set<SensorType> obdSensorTypes = {
  SensorType.engineRpm,
  SensorType.batteryVoltage,
  SensorType.engineLoad,
  SensorType.fuelLevel,
  SensorType.engineTemperatures,
  SensorType.accelerator,
  SensorType.fuelConsumption,
  SensorType.hybridBattery,
  SensorType.energyFlow,
  SensorType.driveMode,
  SensorType.turboBoost,
};
