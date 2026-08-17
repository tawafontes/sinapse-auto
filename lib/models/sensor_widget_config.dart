import 'package:hive/hive.dart';

part 'sensor_widget_config.g.dart';

/// The dashboard-facing sensor categories a user can pick during onboarding
/// and place widgets for. These are the *derived*/user-meaningful signals
/// (e.g. `gForce`), not the raw hardware axes — [SensorService] is
/// responsible for turning raw accelerometer/magnetometer/geolocation data
/// into these when the dashboard binds real data to a widget.
///
/// Not annotated with `@HiveType`/`@HiveField` like the other enums below:
/// [SensorType] has a hand-written adapter ([SensorTypeAdapter]) instead of
/// a generated one, so that retiring a sensor (as happened to `lightLevel`,
/// `battery`, `time` and — most recently — `compass`, byte 1, permanently
/// retired) can map old, now-unrecognized stored bytes to [unknown] — which
/// [SensorWidgetRepository] discards on startup — instead of
/// hive_generator's default behavior of silently aliasing an unrecognized
/// byte to the first remaining member (which would resurrect a removed
/// sensor's widget as a phantom duplicate of whatever sensor is first in
/// this enum).
///
/// Hive typeId registry (kept centralized here since adapters are
/// registered together in [HiveBoxes.init]): 0-4 sensor_widget_config,
/// 5-7 dashcam_config, 8-9 theme_config, 10 driving_session, 11
/// driving_session_sample, 12-13 driving_session_event, 14 event_severity
/// (`EventSeverity`, in `detected_event.dart`), 15 dashcam_clip_record.
/// Next free typeId: 16.
enum SensorType {
  speed,
  inclination,
  altitude,
  gForce,

  /// Sentinel returned by [SensorTypeAdapter.read] for a stored byte that
  /// doesn't match any case above. Never chosen by the user or written back
  /// to Hive — see [SensorWidgetRepository.discardUnknownSensors].
  unknown,
}

/// Hand-written (not generated — see the doc comment on [SensorType]) so an
/// unrecognized stored byte deserializes to [SensorType.unknown] rather
/// than silently aliasing to [SensorType.speed].
///
/// Field numbers must never be reassigned or reused for a different sensor:
/// when retiring one, delete its `case` here (and the member from
/// [SensorType]) but leave the number's gap untouched. Byte 1 (`compass`)
/// is exactly such a gap now.
class SensorTypeAdapter extends TypeAdapter<SensorType> {
  @override
  final int typeId = 0;

  @override
  SensorType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SensorType.speed;
      case 2:
        return SensorType.inclination;
      case 3:
        return SensorType.altitude;
      case 4:
        return SensorType.gForce;
      default:
        return SensorType.unknown;
    }
  }

  @override
  void write(BinaryWriter writer, SensorType obj) {
    switch (obj) {
      case SensorType.speed:
        writer.writeByte(0);
        break;
      case SensorType.inclination:
        writer.writeByte(2);
        break;
      case SensorType.altitude:
        writer.writeByte(3);
        break;
      case SensorType.gForce:
        writer.writeByte(4);
        break;
      case SensorType.unknown:
        throw ArgumentError('SensorType.unknown must never be persisted');
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensorTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

/// Visual style used to render a sensor's value on the dashboard.
///
/// Which of these are valid for a given [SensorType] is defined in
/// `models/display_style_metadata.dart`, not enforced here.
///
/// Fields 0-2 (`numeric`, `gaugeCircular`, `bar`), 4 (`compassRose`, retired
/// along with the compass widget itself) and 5 (`bubbleLevel`) are retired:
/// speed's only style is now [numericWithHistory] and inclination's only
/// style is now [artificialHorizon]. Left as permanent gaps rather than
/// reused — the generated adapter falls back to [numericWithHistory] for an
/// unrecognized stored byte, which `SensorWidgetRepository.migrateInvalidStyles`
/// then corrects to whatever's actually valid for that config's sensor (for
/// an old compass record, `SensorTypeAdapter` already routes it to
/// [SensorType.unknown] before this ever matters — see that class's doc).
///
/// typeId: 1
@HiveType(typeId: 1)
enum DisplayStyle {
  @HiveField(3)
  numericWithHistory,
  @HiveField(6)
  lineChart,
  @HiveField(7)
  gForceMeter,
  @HiveField(8)
  artificialHorizon,
}

/// Normalized position of a widget on the dashboard grid (0.0 - 1.0 range,
/// left as plain doubles so the layout engine decides units later).
///
/// typeId: 2
@HiveType(typeId: 2)
class WidgetPosition {
  WidgetPosition({required this.x, required this.y});

  @HiveField(0)
  final double x;

  @HiveField(1)
  final double y;
}

/// Size of a widget on the dashboard grid.
///
/// typeId: 3
@HiveType(typeId: 3)
class WidgetSize {
  WidgetSize({required this.width, required this.height});

  @HiveField(0)
  final double width;

  @HiveField(1)
  final double height;
}

/// Persisted configuration for a single sensor widget placed on the
/// dashboard.
///
/// typeId: 4
@HiveType(typeId: 4)
class SensorWidgetConfig extends HiveObject {
  SensorWidgetConfig({
    required this.sensorType,
    required this.displayStyle,
    required this.position,
    required this.size,
    this.page = 0,
  });

  @HiveField(0)
  SensorType sensorType;

  @HiveField(1)
  DisplayStyle displayStyle;

  @HiveField(2)
  WidgetPosition position;

  @HiveField(3)
  WidgetSize size;

  /// Which of the dashboard's up to 5 pages this widget lives on (0-based).
  /// Defaults to 0 for brand-new configs and, via the generated adapter's
  /// `defaultValue`, for any record persisted before this field existed.
  @HiveField(4, defaultValue: 0)
  int page;
}
