import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../models/color_palette_metadata.dart';
import '../models/font_family_metadata.dart';
import '../models/theme_config.dart';
import 'hive_boxes.dart';

/// Owns the app's [ThemeConfig], resolves it to a concrete [ThemeData], and
/// persists it to Hive.
///
/// Screen-mode `auto` switches between light and dark purely by time of day
/// (dark 18:00-06:00, see [_brightnessForTimeOfDay]) — this app has no
/// ambient-light sensor to key off instead.
///
/// Screens edit the theme via [previewScreenMode]/[previewColorPalette]/
/// [previewFontFamily], which update the live app instantly (so "aplicar
/// globalmente" is visible while choosing) without touching disk. Call
/// [commit] to persist, or [revertToPersisted] to discard the preview.
class ThemeController extends ChangeNotifier {
  ThemeController() : _config = _readPersistedOrDefault() {
    _syncAutoTimer();
  }

  static const _key = 'config';

  static Box<ThemeConfig> get _box =>
      Hive.box<ThemeConfig>(HiveBoxNames.themeConfig);

  static ThemeConfig _readPersistedOrDefault() {
    return _box.get(_key) ??
        ThemeConfig(
          screenMode: ScreenMode.auto,
          colorPalette: defaultColorPaletteId,
          fontFamily: defaultFontFamilyId,
        );
  }

  ThemeConfig _config;
  Timer? _autoTimer;
  Brightness _resolvedAutoBrightness = _brightnessForTimeOfDay(DateTime.now());

  bool get isPersisted => _box.containsKey(_key);

  ScreenMode get screenMode => _config.screenMode;
  String get colorPaletteId => _config.colorPalette;
  String get fontFamilyId => _config.fontFamily;

  void previewScreenMode(ScreenMode mode) {
    _config.screenMode = mode;
    _syncAutoTimer();
    notifyListeners();
  }

  void previewColorPalette(String paletteId) {
    _config.colorPalette = paletteId;
    notifyListeners();
  }

  void previewFontFamily(String fontId) {
    _config.fontFamily = fontId;
    notifyListeners();
  }

  Future<void> commit() => _box.put(_key, _config);

  void revertToPersisted() {
    _autoTimer?.cancel();
    _config = _readPersistedOrDefault();
    _syncAutoTimer();
    notifyListeners();
  }

  /// Clears the persisted theme and resets the live preview to defaults —
  /// used when the user redoes onboarding from scratch.
  Future<void> resetToDefaults() async {
    await _box.delete(_key);
    _autoTimer?.cancel();
    _config = ThemeConfig(
      screenMode: ScreenMode.auto,
      colorPalette: defaultColorPaletteId,
      fontFamily: defaultFontFamilyId,
    );
    _syncAutoTimer();
    notifyListeners();
  }

  void _syncAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (_config.screenMode != ScreenMode.auto) return;

    _resolvedAutoBrightness = _brightnessForTimeOfDay(DateTime.now());
    _autoTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final next = _brightnessForTimeOfDay(DateTime.now());
      if (next != _resolvedAutoBrightness) {
        _resolvedAutoBrightness = next;
        notifyListeners();
      }
    });
  }

  static Brightness _brightnessForTimeOfDay(DateTime time) {
    final hour = time.hour;
    return (hour < 6 || hour >= 18) ? Brightness.dark : Brightness.light;
  }

  Brightness get effectiveBrightness {
    switch (_config.screenMode) {
      case ScreenMode.dark:
        return Brightness.dark;
      case ScreenMode.light:
        return Brightness.light;
      case ScreenMode.auto:
        return _resolvedAutoBrightness;
    }
  }

  ThemeData get themeData {
    final palette = colorPalettes[_config.colorPalette] ?? colorPalettes[defaultColorPaletteId]!;
    return ThemeData(
      useMaterial3: true,
      colorScheme: palette.schemeFor(effectiveBrightness),
      fontFamily: resolveFontFamily(_config.fontFamily),
    );
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }
}

/// Makes the app's single [ThemeController] instance reachable from any
/// descendant via [ThemeControllerScope.of].
class ThemeControllerScope extends InheritedNotifier<ThemeController> {
  const ThemeControllerScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeControllerScope>();
    assert(scope != null, 'No ThemeControllerScope found in context');
    return scope!.notifier!;
  }
}
