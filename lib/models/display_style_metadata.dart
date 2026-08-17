import 'sensor_widget_config.dart';

/// Human-readable label for each [DisplayStyle], used by the style picker.
const Map<DisplayStyle, String> displayStyleLabels = {
  DisplayStyle.numericWithHistory: 'Numérico + histórico',
  DisplayStyle.lineChart: 'Gráfico de linha',
  DisplayStyle.gForceMeter: 'G-force meter',
  DisplayStyle.artificialHorizon: 'Horizonte artificial',
};

/// Which [DisplayStyle]s a given [SensorType] can be rendered with, in the
/// order they should be offered to the user. The first entry is the default
/// selection.
const Map<SensorType, List<DisplayStyle>> validDisplayStylesForSensor = {
  SensorType.speed: [DisplayStyle.numericWithHistory],
  SensorType.inclination: [DisplayStyle.artificialHorizon],
  SensorType.altitude: [DisplayStyle.lineChart],
  SensorType.gForce: [DisplayStyle.gForceMeter],
};
