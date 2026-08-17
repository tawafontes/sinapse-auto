import 'package:hive/hive.dart';

import 'hive_boxes.dart';

/// Small helper around the untyped `app_settings` Hive box, for onboarding
/// and general app state that doesn't need a dedicated model.
///
/// Deliberately does *not* track which sensors are "selected" — that state
/// lives solely in [SensorWidgetRepository] (whether a [SensorWidgetConfig]
/// exists for a sensor), so the dashboard and the tool-selection screen can
/// never disagree about it. See `SensorSelectionScreen`'s doc for why.
class AppSettings {
  AppSettings._();

  static const _dashboardPageCountKey = 'dashboardPageCount';
  static const _dashboardLastViewedPageKey = 'dashboardLastViewedPage';
  static const _hudMirroredKey = 'hudMirrored';

  static Box get _box => Hive.box(HiveBoxNames.appSettings);

  /// How many dashboard pages the user has explicitly reserved (via the
  /// page-manager sheet's add/delete actions) — defaults to 1. This is
  /// separate from, and reconciled against, the page count implied by
  /// where widgets actually sit ([DashboardScreen]'s `_pageCount` takes the
  /// larger of the two), so an explicitly-added blank page stays visible
  /// even before any widget lands on it.
  static int get dashboardPageCount => (_box.get(_dashboardPageCountKey) as int?) ?? 1;

  static Future<void> setDashboardPageCount(int count) {
    return _box.put(_dashboardPageCountKey, count);
  }

  /// Which dashboard page was on screen when the app was last closed —
  /// defaults to 0 (first page) when never set. Read once on
  /// [DashboardScreen] startup and written back on every page change (swipe,
  /// page-manager navigation, or page deletion) so the view is exactly where
  /// the user left it after a restart.
  static int get dashboardLastViewedPage => (_box.get(_dashboardLastViewedPageKey) as int?) ?? 0;

  static Future<void> setDashboardLastViewedPage(int page) {
    return _box.put(_dashboardLastViewedPageKey, page);
  }

  /// Whether [HudScreen] horizontally mirrors its display (for reflection
  /// off a windshield) — off by default. Local to that one screen, so a
  /// plain persisted flag is enough; no other screen needs to react to it,
  /// unlike [UnitPreferences]/[AlertPreferences]'s app-wide reactivity.
  static bool get hudMirrored => (_box.get(_hudMirroredKey) as bool?) ?? false;

  static Future<void> setHudMirrored(bool mirrored) {
    return _box.put(_hudMirroredKey, mirrored);
  }
}
