import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

import '../models/unit_system.dart';
import 'hive_boxes.dart';

/// User's unit preferences — persisted in the same untyped `app_settings`
/// Hive box [AppSettings] already uses (no second settings infrastructure),
/// reactive via [ChangeNotifier]/[UnitPreferencesScope] so every dashboard
/// tile already on screen updates immediately when the user changes a
/// preference, mirroring exactly how [ThemeController]/[ThemeControllerScope]
/// already make theme changes propagate live.
class UnitPreferences extends ChangeNotifier {
  UnitPreferences() : _speedUnit = _readSpeedUnit(), _altitudeUnit = _readAltitudeUnit();

  static const _speedUnitKey = 'speedUnit';
  static const _altitudeUnitKey = 'altitudeUnit';

  static Box get _box => Hive.box(HiveBoxNames.appSettings);

  static SpeedUnit _readSpeedUnit() {
    return (_box.get(_speedUnitKey) as String?) == 'mph' ? SpeedUnit.mph : SpeedUnit.kmh;
  }

  static AltitudeUnit _readAltitudeUnit() {
    return (_box.get(_altitudeUnitKey) as String?) == 'feet' ? AltitudeUnit.feet : AltitudeUnit.meters;
  }

  SpeedUnit _speedUnit;
  AltitudeUnit _altitudeUnit;

  SpeedUnit get speedUnit => _speedUnit;
  AltitudeUnit get altitudeUnit => _altitudeUnit;

  Future<void> setSpeedUnit(SpeedUnit unit) async {
    if (unit == _speedUnit) return;
    _speedUnit = unit;
    notifyListeners();
    await _box.put(_speedUnitKey, unit == SpeedUnit.mph ? 'mph' : 'kmh');
  }

  Future<void> setAltitudeUnit(AltitudeUnit unit) async {
    if (unit == _altitudeUnit) return;
    _altitudeUnit = unit;
    notifyListeners();
    await _box.put(_altitudeUnitKey, unit == AltitudeUnit.feet ? 'feet' : 'meters');
  }
}

/// Same [InheritedNotifier] shape as `ThemeControllerScope` — a descendant
/// simply calling [UnitPreferencesScope.of] already establishes the right
/// dependency to rebuild automatically on the next [UnitPreferences.setSpeedUnit]/
/// [UnitPreferences.setAltitudeUnit], no extra `AnimatedBuilder` needed at
/// the call site.
class UnitPreferencesScope extends InheritedNotifier<UnitPreferences> {
  const UnitPreferencesScope({super.key, required UnitPreferences preferences, required super.child})
    : super(notifier: preferences);

  static UnitPreferences of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<UnitPreferencesScope>();
    assert(scope != null, 'No UnitPreferencesScope found in context');
    return scope!.notifier!;
  }
}
