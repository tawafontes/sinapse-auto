import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

import '../models/power_profile.dart';
import 'hive_boxes.dart';

/// User's selected [PowerProfile] — persisted in the same untyped
/// `app_settings` Hive box every other preference class in this app uses,
/// reactive via [ChangeNotifier] so [TelemetryEngine] picks up a change on
/// the very next emission it evaluates, with no restart and no engine
/// reconstruction needed (see [TelemetryEngine]'s own use of this class).
class PowerProfilePreferences extends ChangeNotifier {
  PowerProfilePreferences() : _profile = _read();

  static const _key = 'powerProfile';
  static Box get _box => Hive.box(HiveBoxNames.appSettings);

  static PowerProfile _read() {
    final raw = _box.get(_key) as String?;
    return PowerProfile.values.firstWhere((p) => p.name == raw, orElse: () => PowerProfile.normal);
  }

  PowerProfile _profile;
  PowerProfile get profile => _profile;

  Future<void> setProfile(PowerProfile profile) async {
    if (_profile == profile) return;
    _profile = profile;
    notifyListeners();
    await _box.put(_key, profile.name);
  }
}

class PowerProfilePreferencesScope extends InheritedNotifier<PowerProfilePreferences> {
  const PowerProfilePreferencesScope({super.key, required PowerProfilePreferences preferences, required super.child})
    : super(notifier: preferences);

  static PowerProfilePreferences of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PowerProfilePreferencesScope>();
    assert(scope != null, 'No PowerProfilePreferencesScope found in context');
    return scope!.notifier!;
  }
}
