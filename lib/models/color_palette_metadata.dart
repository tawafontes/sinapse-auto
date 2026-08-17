import 'package:flutter/material.dart';

import 'sensor_widget_config.dart';

/// One of the 5 selectable color palettes. [schemeFor] builds a full
/// [ColorScheme] for a given [Brightness]; [swatchColors] are just the 2-4
/// dots shown in the picker UI.
class ColorPalette {
  const ColorPalette({
    required this.id,
    required this.label,
    required this.swatchColors,
    required this.schemeFor,
  });

  final String id;
  final String label;
  final List<Color> swatchColors;
  final ColorScheme Function(Brightness brightness) schemeFor;
}

const String defaultColorPaletteId = 'classic_green_amber';

/// The 5 palettes from the spec, keyed by persisted id (this id is what's
/// stored in [ThemeConfig.colorPalette]).
final Map<String, ColorPalette> colorPalettes = {
  'classic_green_amber': ColorPalette(
    id: 'classic_green_amber',
    label: 'Clássica verde-âmbar',
    swatchColors: const [Color(0xFFFFC107), Color(0xFF00C853)],
    schemeFor: (brightness) => ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFC107),
      secondary: const Color(0xFF00C853),
      brightness: brightness,
    ),
  ),
  'cyan': ColorPalette(
    id: 'cyan',
    label: 'Ciano',
    swatchColors: const [Color(0xFF00BCD4)],
    schemeFor: (brightness) => ColorScheme.fromSeed(
      seedColor: const Color(0xFF00BCD4),
      brightness: brightness,
    ),
  ),
  'orange_alert': ColorPalette(
    id: 'orange_alert',
    label: 'Laranja/Alerta',
    swatchColors: const [Color(0xFFFF5722)],
    schemeFor: (brightness) => ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF5722),
      brightness: brightness,
    ),
  ),
  'monochrome': ColorPalette(
    id: 'monochrome',
    label: 'Monocromática',
    swatchColors: const [Color(0xFF9E9E9E), Color(0xFF616161)],
    schemeFor: (brightness) => ColorScheme.fromSeed(
      seedColor: const Color(0xFF607D8B),
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    ),
  ),
  'colorful_per_widget': ColorPalette(
    id: 'colorful_per_widget',
    label: 'Colorida por widget',
    swatchColors: perWidgetAccentColors.values.toList(),
    // App chrome stays neutral; individual dashboard widgets use
    // [perWidgetAccentColors] instead of a single shared seed.
    schemeFor: (brightness) => ColorScheme.fromSeed(
      seedColor: const Color(0xFF9E9E9E),
      brightness: brightness,
    ),
  ),
};

/// Per-sensor accent color, only used by dashboard widgets (a later phase)
/// when the `colorful_per_widget` palette is active.
const Map<SensorType, Color> perWidgetAccentColors = {
  SensorType.speed: Color(0xFF2196F3),
  SensorType.inclination: Color(0xFF3F51B5),
  SensorType.altitude: Color(0xFF009688),
  SensorType.gForce: Color(0xFFF44336),
};
