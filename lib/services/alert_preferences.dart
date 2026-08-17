import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

import '../models/alert_type.dart';
import 'hive_boxes.dart';

/// Default threshold for each alert type that has one (see
/// [alertTypeHasThreshold]) — chosen with a concrete, written rationale
/// rather than an arbitrary round number:
///  * highSpeed: 120 km/h — above the highway speed limit in most
///    jurisdictions; a reasonable "you're going fast" line independent of
///    any specific local limit this app doesn't otherwise know.
///  * harshAcceleration/harshBraking: 0.4g — ordinary confident driving
///    (accelerating from a light, decelerating for a stop) stays under
///    roughly 0.2-0.3g; 0.4g is a clear step above that into "noticeably
///    hard" without requiring a genuine emergency stop (~0.6-0.8g+) to
///    trigger.
///  * highInclination: 30° — most public roads stay under 10-15° grade/bank
///    even at their steepest; 30° is a clear, unambiguous outlier (a ramp,
///    an off-road incline) rather than normal road undulation.
///  * hardCornering (Fase 13): 0.4g — the same magnitude family as
///    harshAcceleration/harshBraking, for the same reason: ordinary lane
///    changes and roundabouts stay well under this on lateral G, while a
///    genuinely brisk turn clears it without needing tire-squealing G to
///    trigger.
///  * highResultantG (Fase 13): 0.6g — deliberately higher than either
///    individual-axis threshold, since this alert exists specifically to
///    catch a combined event (e.g. braking *while* turning) that might not
///    individually cross either single-axis threshold on its own; set any
///    lower and it would just re-fire alongside every ordinary hard brake
///    or hard corner, which is exactly the redundant-event problem Fase 13
///    exists to avoid.
const Map<AlertType, double> defaultAlertThresholds = {
  AlertType.highSpeed: 120.0,
  AlertType.harshAcceleration: 0.4,
  AlertType.harshBraking: 0.4,
  AlertType.highInclination: 30.0,
  AlertType.hardCornering: 0.4,
  AlertType.highResultantG: 0.6,
};

/// User's alert configuration (enabled/disabled + threshold per
/// [AlertType]) — persisted in the same untyped `app_settings` Hive box
/// [AppSettings]/[UnitPreferences] already use, reactive via
/// [ChangeNotifier] so the alerts settings screen and [AlertEngine] both
/// see a change the instant it's made, with no manual refresh/restart.
class AlertPreferences extends ChangeNotifier {
  AlertPreferences() {
    for (final type in AlertType.values) {
      _enabled[type] = (_box.get(_enabledKey(type)) as bool?) ?? true;
      if (alertTypeHasThreshold(type)) {
        _thresholds[type] = (_box.get(_thresholdKey(type)) as double?) ?? defaultAlertThresholds[type]!;
      }
    }
  }

  static Box get _box => Hive.box(HiveBoxNames.appSettings);
  static String _enabledKey(AlertType type) => 'alertEnabled_${type.name}';
  static String _thresholdKey(AlertType type) => 'alertThreshold_${type.name}';

  final Map<AlertType, bool> _enabled = {};
  final Map<AlertType, double> _thresholds = {};

  bool isEnabled(AlertType type) => _enabled[type] ?? true;

  /// Null for an alert type with no threshold (see [alertTypeHasThreshold]).
  double? thresholdFor(AlertType type) => _thresholds[type];

  Future<void> setEnabled(AlertType type, bool enabled) async {
    if (_enabled[type] == enabled) return;
    _enabled[type] = enabled;
    notifyListeners();
    await _box.put(_enabledKey(type), enabled);
  }

  Future<void> setThreshold(AlertType type, double threshold) async {
    if (!alertTypeHasThreshold(type) || _thresholds[type] == threshold) return;
    _thresholds[type] = threshold;
    notifyListeners();
    await _box.put(_thresholdKey(type), threshold);
  }
}

class AlertPreferencesScope extends InheritedNotifier<AlertPreferences> {
  const AlertPreferencesScope({super.key, required AlertPreferences preferences, required super.child})
    : super(notifier: preferences);

  static AlertPreferences of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AlertPreferencesScope>();
    assert(scope != null, 'No AlertPreferencesScope found in context');
    return scope!.notifier!;
  }
}
