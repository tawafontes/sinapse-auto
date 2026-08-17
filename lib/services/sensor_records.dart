import 'package:hive/hive.dart';

import 'hive_boxes.dart';

/// Small helper around the untyped `sensor_records` Hive box — persisted
/// sensor state that needs to survive app restarts but doesn't warrant a
/// dedicated [HiveObject] model, following the same pattern as
/// [AppSettings]. Two kinds of state live here:
///
///  * The artificial horizon's calibration offset (pitch/roll), applied to
///    every raw reading until the user recalibrates.
///  * The running records other widgets track (G-force peak + vertical
///    min/max, altitude min/max, speed min/max) — previously session-only
///    (reset on every app restart), now persisted so they only change via
///    each widget's existing manual reset.
///
/// Every widget that reads/writes these stays Hive-agnostic itself: values
/// are read once at construction (an `initial*` constructor parameter) and
/// written back through an `on*Changed` callback, both wired up only at the
/// real dashboard call site in `sensor_widget_factory.dart` — the onboarding
/// preview never touches this box, so mock data can never pollute a real
/// record.
class SensorRecords {
  SensorRecords._();

  static const _inclinationPitchOffsetKey = 'inclinationPitchOffsetDeg';
  static const _inclinationRollOffsetKey = 'inclinationRollOffsetDeg';
  static const _gForceMaxKey = 'gForceMaxRecord';
  static const _gForceVerticalMinKey = 'gForceVerticalMinRecord';
  static const _gForceVerticalMaxKey = 'gForceVerticalMaxRecord';
  static const _altitudeMinKey = 'altitudeMinRecord';
  static const _altitudeMaxKey = 'altitudeMaxRecord';
  static const _speedMaxKey = 'speedMaxRecord';
  static const _speedMinKey = 'speedMinRecord';
  static const _speedAverageKey = 'speedAverageRecord';
  static const _speedAverageSampleCountKey = 'speedAverageSampleCount';

  /// Retired key, previously tracking compass calibration state. Never
  /// reused — see [discardRetiredCompassCalibratedFlag].
  static const _compassCalibratedKey = 'compassCalibrated';

  static Box get _box => Hive.box(HiveBoxNames.sensorRecords);

  /// Degrees subtracted from every raw pitch/roll reading. Zero (the
  /// uncalibrated default) until the user calibrates via long-press.
  static double get inclinationPitchOffsetDeg =>
      (_box.get(_inclinationPitchOffsetKey) as double?) ?? 0.0;
  static double get inclinationRollOffsetDeg =>
      (_box.get(_inclinationRollOffsetKey) as double?) ?? 0.0;

  static Future<void> setInclinationCalibration({
    required double pitchOffsetDeg,
    required double rollOffsetDeg,
  }) {
    return _box.putAll({
      _inclinationPitchOffsetKey: pitchOffsetDeg,
      _inclinationRollOffsetKey: rollOffsetDeg,
    });
  }

  /// This session's/all-time peak G-force magnitude. Null until the first
  /// reading ever arrives — callers seed their own local "max so far" state
  /// with this and let their existing "if (value > max)" update logic take
  /// it from there, which naturally initializes it to the first live
  /// reading instead of a misleading zero.
  static double? get gForceMaxRecord => _box.get(_gForceMaxKey) as double?;

  static Future<void> setGForceMaxRecord(double value) => _box.put(_gForceMaxKey, value);

  /// This session's/all-time deepest dip and highest lift (vertical G, the
  /// meter's thermometer bar) — same null-until-first-reading semantics as
  /// [gForceMaxRecord], and reset together via the same "Resetar registros".
  static double? get gForceVerticalMinRecord => _box.get(_gForceVerticalMinKey) as double?;
  static double? get gForceVerticalMaxRecord => _box.get(_gForceVerticalMaxKey) as double?;

  static Future<void> setGForceVerticalRecords({required double min, required double max}) {
    return _box.putAll({_gForceVerticalMinKey: min, _gForceVerticalMaxKey: max});
  }

  static double? get altitudeMinRecord => _box.get(_altitudeMinKey) as double?;
  static double? get altitudeMaxRecord => _box.get(_altitudeMaxKey) as double?;

  static Future<void> setAltitudeRecords({required double min, required double max}) {
    return _box.putAll({_altitudeMinKey: min, _altitudeMaxKey: max});
  }

  /// This session's/all-time speed extremes — same null-until-first-reading
  /// semantics as [gForceMaxRecord], and reset together via the same
  /// "Resetar registros". [speedMinRecord] is no longer shown on the tile
  /// (replaced by [speedAverageRecord] below) but is still tracked/persisted
  /// — the chart's own vertical scale still needs a true session minimum to
  /// bound the curve correctly, it's just not surfaced as its own badge.
  static double? get speedMaxRecord => _box.get(_speedMaxKey) as double?;
  static double? get speedMinRecord => _box.get(_speedMinKey) as double?;

  static Future<void> setSpeedRecords({required double min, required double max}) {
    return _box.putAll({_speedMinKey: min, _speedMaxKey: max});
  }

  /// This session's/all-time running average speed, replacing the minimum
  /// badge on the tile (see [DisplayStyle.numericWithHistory]'s factory
  /// wiring) — reset together with [speedMaxRecord] via the same "Resetar
  /// registros". [speedAverageSampleCount] backs the incremental running
  /// mean: it must persist alongside the average itself, or a single
  /// post-restart reading would outweigh an entire prior session's worth of
  /// samples instead of being blended in proportionally.
  static double? get speedAverageRecord => _box.get(_speedAverageKey) as double?;
  static int get speedAverageSampleCount => (_box.get(_speedAverageSampleCountKey) as int?) ?? 0;

  static Future<void> setSpeedAverage({required double average, required int sampleCount}) {
    return _box.putAll({_speedAverageKey: average, _speedAverageSampleCountKey: sampleCount});
  }

  /// One-time startup migration: deletes the orphaned compass-calibration
  /// flag left behind by the now-removed compass widget. Safe to call
  /// unconditionally — `Box.delete` on an absent key is a no-op.
  static Future<void> discardRetiredCompassCalibratedFlag() =>
      _box.delete(_compassCalibratedKey);
}
