import 'package:hive/hive.dart';

import '../models/display_style_metadata.dart';
import '../models/sensor_type_metadata.dart';
import '../models/sensor_widget_config.dart';
import 'hive_boxes.dart';

/// CRUD helper around the `sensor_widget_configs` Hive box — used by the
/// style-selection screen (to persist the chosen [DisplayStyle] per
/// [SensorType]) and, later, by the dashboard grid (to persist position and
/// size on every drag/resize).
class SensorWidgetRepository {
  SensorWidgetRepository._();

  static Box<SensorWidgetConfig> get _box =>
      Hive.box<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);

  static List<SensorWidgetConfig> get all => _box.values.toList();

  static SensorWidgetConfig? forSensor(SensorType type) {
    for (final config in _box.values) {
      if (config.sensorType == type) return config;
    }
    return null;
  }

  /// Creates a config for [type] with [style] if none exists yet, or updates
  /// the existing one's style in place (position/size, if already set by
  /// the dashboard grid, are left untouched).
  ///
  /// New configs get position (-1, -1) — a sentinel the dashboard's layout
  /// engine (`reconcileLayout`) reads as "not placed yet", triggering
  /// auto-placement instead of being (mis)treated as a real spot at (0, 0).
  static Future<void> upsertStyle(SensorType type, DisplayStyle style) async {
    final existing = forSensor(type);
    if (existing != null) {
      existing.displayStyle = style;
      await existing.save();
    } else {
      await _box.add(
        SensorWidgetConfig(
          sensorType: type,
          displayStyle: style,
          position: WidgetPosition(x: -1, y: -1),
          size: WidgetSize(width: 1, height: 1),
        ),
      );
    }
  }

  /// The first-run dashboard: every sensor that has no widget yet gets one in
  /// its default (first valid) style, unplaced — the dashboard places them on
  /// its first frame, in [sensorTypeMetadata]'s order. Never touches an
  /// existing widget. Called only when the first onboarding completes (see
  /// `ThemeSelectionScreen`), so a widget the user deletes later stays deleted.
  /// The OBD-II tools are left out ([obdSensorTypes]): they are added from
  /// "+" once there is an adapter.
  static Future<void> addDefaultWidgets() async {
    for (final type in sensorTypeMetadata.keys.where((t) => !obdSensorTypes.contains(t))) {
      final styles = validDisplayStylesForSensor[type];
      if (styles == null || styles.isEmpty || forSensor(type) != null) continue;
      await upsertStyle(type, styles.first);
    }
  }

  /// Persists a new grid position/size for [config] — called by the
  /// dashboard on every drag/resize gesture end (autosave), and by page
  /// placement when a new or overflowing widget lands on a page. [page] is
  /// only applied when given, so move/resize call sites that don't move a
  /// widget between pages can omit it.
  static Future<void> updateLayout(
    SensorWidgetConfig config, {
    required WidgetPosition position,
    required WidgetSize size,
    int? page,
  }) async {
    config.position = position;
    config.size = size;
    if (page != null) config.page = page;
    await config.save();
  }

  /// Deletes a single widget instance — the dashboard's long-press "Excluir"
  /// action. Unlike [removeSensorsNotIn] (which reconciles the whole sensor
  /// selection against a target set), this targets exactly the config
  /// instance the user long-pressed, with no ambiguity about which one.
  static Future<void> deleteConfig(SensorWidgetConfig config) => config.delete();

  /// Deletes every config placed on [deletedPage] — the page-manager sheet's
  /// "excluir página" action, once the user has confirmed removing a
  /// non-empty page. Returns the sensor types deleted so the caller can drop
  /// them from its own in-memory caches (alert colors, reset triggers).
  /// Callers must follow this with [shiftPagesAfterDelete] to keep page
  /// indices contiguous.
  ///
  /// [configs] is the layout the page belongs to — the stored (portrait)
  /// configs by default, or the dashboard's landscape layouts
  /// (`LandscapeWidgetLayout`, whose page is the landscape one and whose
  /// delete deletes the widget) for a page deleted in landscape.
  static Future<List<SensorType>> deleteConfigsOnPage(int deletedPage, {Iterable<SensorWidgetConfig>? configs}) async {
    final onPage = (configs ?? _box.values).where((c) => c.page == deletedPage).toList();
    for (final config in onPage) {
      await config.delete();
    }
    return [for (final config in onPage) config.sensorType];
  }

  /// Shifts every config on a page after [deletedPage] down by one, so page
  /// indices stay contiguous (0..count-1) once a page is removed via the
  /// page-manager sheet. [deletedPage] itself must already have no configs
  /// on it — callers deleting a non-empty page call
  /// [deleteConfigsOnPage] first.
  /// [configs] as in [deleteConfigsOnPage].
  static Future<void> shiftPagesAfterDelete(int deletedPage, {Iterable<SensorWidgetConfig>? configs}) async {
    for (final config in (configs ?? _box.values).toList()) {
      if (config.page > deletedPage) {
        config.page -= 1;
        await config.save();
      }
    }
  }

  /// Deletes configs for any sensor not in [keep] — keeps storage in sync
  /// when the user revisits sensor selection and removes one.
  static Future<void> removeSensorsNotIn(Set<SensorType> keep) async {
    final toDelete = _box.values.where((c) => !keep.contains(c.sensorType)).toList();
    for (final config in toDelete) {
      await config.delete();
    }
  }

  /// One-time startup migration: deletes any widget persisted for a sensor
  /// that's since been retired from the app. Old bytes for a removed
  /// [SensorType] deserialize to [SensorType.unknown] (see
  /// [SensorTypeAdapter]) rather than aliasing to a real sensor, so this
  /// can find and discard them safely instead of them silently masquerading
  /// as a duplicate of whatever sensor comes first in the enum. Called once
  /// from `main()`, after Hive finishes opening its boxes.
  static Future<void> discardUnknownSensors() async {
    final stale = _box.values.where((c) => c.sensorType == SensorType.unknown).toList();
    for (final config in stale) {
      await config.delete();
    }
  }

  /// One-time startup migration: if a persisted widget's [DisplayStyle] is
  /// no longer valid for its [SensorType] (e.g. compass narrowed down to a
  /// single style), silently resets it to that sensor's first/default valid
  /// style instead of leaving a stale, now-unselectable style in place.
  /// Called once from `main()`, after Hive finishes opening its boxes.
  static Future<void> migrateInvalidStyles() async {
    for (final config in _box.values) {
      final validStyles = validDisplayStylesForSensor[config.sensorType];
      if (validStyles == null) continue; // e.g. SensorType.unknown.
      if (!validStyles.contains(config.displayStyle)) {
        config.displayStyle = validStyles.first;
        await config.save();
      }
    }
  }
}
