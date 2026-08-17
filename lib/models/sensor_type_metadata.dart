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
};
