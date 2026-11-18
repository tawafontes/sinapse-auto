import 'sensor_widget_config.dart';

/// Human-readable label for each [DisplayStyle], used by the style picker.
const Map<DisplayStyle, String> displayStyleLabels = {
  DisplayStyle.numericWithHistory: 'Numérico + histórico',
  DisplayStyle.lineChart: 'Gráfico de linha',
  DisplayStyle.gForceMeter: 'G-force meter',
  DisplayStyle.artificialHorizon: 'Horizonte artificial',
  DisplayStyle.refuelSummary: 'Autonomia e abastecimento',
  DisplayStyle.tachometer: 'Conta-giros',
  DisplayStyle.obdValue: 'Valor ao vivo',
  DisplayStyle.obdPanel: 'Painel',
};

/// Which [DisplayStyle]s a given [SensorType] can be rendered with, in the
/// order they should be offered to the user. The first entry is the default
/// selection.
const Map<SensorType, List<DisplayStyle>> validDisplayStylesForSensor = {
  SensorType.speed: [DisplayStyle.numericWithHistory],
  SensorType.inclination: [DisplayStyle.artificialHorizon],
  SensorType.altitude: [DisplayStyle.lineChart],
  SensorType.gForce: [DisplayStyle.gForceMeter],
  SensorType.refuel: [DisplayStyle.refuelSummary],
  SensorType.engineRpm: [DisplayStyle.tachometer, DisplayStyle.obdValue],
  SensorType.batteryVoltage: [DisplayStyle.obdValue],
  SensorType.engineLoad: [DisplayStyle.obdValue],
  SensorType.fuelLevel: [DisplayStyle.obdPanel],
  SensorType.engineTemperatures: [DisplayStyle.obdPanel],
  SensorType.accelerator: [DisplayStyle.obdPanel],
  SensorType.fuelConsumption: [DisplayStyle.obdPanel],
  SensorType.hybridBattery: [DisplayStyle.obdPanel],
  SensorType.energyFlow: [DisplayStyle.obdPanel],
  SensorType.driveMode: [DisplayStyle.obdPanel],
  SensorType.turboBoost: [DisplayStyle.obdPanel],
};
