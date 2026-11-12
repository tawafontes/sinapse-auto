import 'package:hive_flutter/hive_flutter.dart';

import '../models/charge_record.dart';
import '../models/dashcam_clip_record.dart';
import '../models/dashcam_config.dart';
import '../models/detected_event.dart';
import '../models/driving_session.dart';
import '../models/driving_session_event.dart';
import '../models/driving_session_sample.dart';
import '../models/refuel_record.dart';
import '../models/sensor_widget_config.dart';
import '../models/theme_config.dart';
import '../models/vehicle_profile.dart';

/// Box names used across the app. Kept centralized so screens/services never
/// need to hardcode a string.
class HiveBoxNames {
  HiveBoxNames._();

  static const sensorWidgetConfigs = 'sensor_widget_configs';
  static const dashcamConfig = 'dashcam_config';
  static const themeConfig = 'theme_config';

  /// Untyped box for simple app/onboarding state (e.g. which sensors the
  /// user picked) that doesn't warrant its own [HiveObject] model.
  static const appSettings = 'app_settings';

  /// Untyped box for persisted sensor state (inclination calibration
  /// offset, G-force peak, altitude min/max) — see [SensorRecords].
  static const sensorRecords = 'sensor_records';

  /// One [DrivingSession] summary per completed/in-progress session —
  /// lightweight (no embedded samples), so listing every past session for
  /// the History screen never deserializes trajectory/telemetry data.
  static const drivingSessions = 'driving_sessions';

  /// A [LazyBox] (values loaded from disk only when a specific session's
  /// key is actually read) mapping each [DrivingSession.id] to its
  /// `List<DrivingSessionSample>` — kept lazy specifically because a long
  /// session's sample list can be sizeable, and the History list itself
  /// never needs to touch this box at all.
  static const drivingSessionSamples = 'driving_session_samples';

  /// Maps each [DrivingSession.id] to its `List<DashcamClipRecord>` (Fase
  /// 15). A plain (non-lazy) [Box], not a [LazyBox] like
  /// [drivingSessionSamples]: entries are a handful of clip records per
  /// session — the same small order of magnitude as a [DrivingSession]
  /// summary itself, nothing like trajectory-sample volume — so keeping it
  /// eagerly resident lets the History list check "does this session have
  /// video?" via a plain hashmap lookup, no disk read, no `FutureBuilder`.
  static const dashcamSessionVideos = 'dashcam_session_videos';

  /// The single [VehicleProfile] ("Meu veículo"), under [VehicleRepository]'s
  /// fixed key.
  static const vehicleProfile = 'vehicle_profile';

  /// Every [RefuelRecord], keyed by its id — a few per month, so a plain box
  /// the refuel list, the consumption report and the dashboard widget read
  /// without touching the disk.
  static const refuelRecords = 'refuel_records';

  /// Every [ChargeRecord] of a plug-in hybrid, keyed by its id — kept apart from
  /// the refuels so the fuel consumption math never mixes in energy.
  static const chargeRecords = 'charge_records';
}

/// Initializes Hive, registers every model's [TypeAdapter] and opens the
/// boxes used by the app. Call [init] once, before [runApp].
class HiveBoxes {
  HiveBoxes._();

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    await Hive.initFlutter();

    Hive.registerAdapter(SensorTypeAdapter());
    Hive.registerAdapter(DisplayStyleAdapter());
    Hive.registerAdapter(WidgetPositionAdapter());
    Hive.registerAdapter(WidgetSizeAdapter());
    Hive.registerAdapter(SensorWidgetConfigAdapter());

    Hive.registerAdapter(CameraSelectionAdapter());
    Hive.registerAdapter(VideoResolutionAdapter());
    Hive.registerAdapter(DashcamConfigAdapter());
    Hive.registerAdapter(DashcamClipRecordAdapter());

    Hive.registerAdapter(ScreenModeAdapter());
    Hive.registerAdapter(ThemeConfigAdapter());

    Hive.registerAdapter(DrivingSessionAdapter());
    Hive.registerAdapter(DrivingSessionSampleAdapter());
    Hive.registerAdapter(DrivingSessionEventTypeAdapter());
    Hive.registerAdapter(EventSeverityAdapter());
    Hive.registerAdapter(DrivingSessionEventAdapter());

    Hive.registerAdapter(FuelTypeAdapter());
    Hive.registerAdapter(VehicleFuelSystemAdapter());
    Hive.registerAdapter(VehicleProfileAdapter());
    Hive.registerAdapter(RefuelRecordAdapter());
    Hive.registerAdapter(VehiclePropulsionAdapter());
    Hive.registerAdapter(ChargeRecordAdapter());

    await Future.wait([
      Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs),
      Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig),
      Hive.openBox<ThemeConfig>(HiveBoxNames.themeConfig),
      Hive.openBox(HiveBoxNames.appSettings),
      Hive.openBox(HiveBoxNames.sensorRecords),
      Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions),
      Hive.openLazyBox(HiveBoxNames.drivingSessionSamples),
      Hive.openBox(HiveBoxNames.dashcamSessionVideos),
      Hive.openBox<VehicleProfile>(HiveBoxNames.vehicleProfile),
      Hive.openBox<RefuelRecord>(HiveBoxNames.refuelRecords),
      Hive.openBox<ChargeRecord>(HiveBoxNames.chargeRecords),
    ]);

    _initialized = true;
  }
}
