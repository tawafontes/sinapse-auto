import 'package:hive/hive.dart';

part 'theme_config.g.dart';

/// Preferred screen brightness mode.
///
/// typeId: 8
@HiveType(typeId: 8)
enum ScreenMode {
  @HiveField(0)
  dark,
  @HiveField(1)
  light,
  @HiveField(2)
  auto,
}

/// Persisted configuration for the app's visual theme.
///
/// typeId: 9
@HiveType(typeId: 9)
class ThemeConfig extends HiveObject {
  ThemeConfig({
    required this.screenMode,
    required this.colorPalette,
    required this.fontFamily,
  });

  @HiveField(0)
  ScreenMode screenMode;

  /// Identifier of the selected color palette (resolved to actual colors by
  /// the theming layer, not implemented yet).
  @HiveField(1)
  String colorPalette;

  @HiveField(2)
  String fontFamily;
}
