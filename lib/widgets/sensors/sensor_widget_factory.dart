import 'package:flutter/material.dart';

import '../../models/sensor_widget_config.dart';
import '../../models/unit_system.dart';
import '../../services/dashboard_sensor_streams.dart';
import '../../services/sensor_records.dart';
import '../../services/unit_preferences.dart';
import '../vehicle/refuel_summary_widget.dart';
import 'artificial_horizon.dart';
import 'g_force_meter.dart';
import 'line_chart.dart';

/// Reads the live [UnitPreferences] from [context] (via [UnitPreferencesScope]
/// — the same `InheritedNotifier` reactivity [ThemeControllerScope] already
/// gives theme changes) and supplies [LineChart] with the right unit label
/// plus a matching [LineChart.displayTransform], so a tile already on
/// screen updates immediately when the user changes their unit preference,
/// without [buildDashboardSensorWidget] itself needing a [BuildContext].
class _UnitAwareLineChart extends StatelessWidget {
  const _UnitAwareLineChart({required this.builder});

  /// Builds the actual [LineChart] given the resolved unit label and
  /// display-transform for the current preference.
  final Widget Function(String unit, double Function(double) displayTransform) builder;

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferencesScope.of(context);
    return builder(speedUnitLabel(prefs.speedUnit), (kmh) => convertSpeedFromKmh(kmh, prefs.speedUnit));
  }
}

class _UnitAwareAltitudeChart extends StatelessWidget {
  const _UnitAwareAltitudeChart({required this.builder});

  final Widget Function(String unit, double Function(double) displayTransform) builder;

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferencesScope.of(context);
    return builder(altitudeUnitLabel(prefs.altitudeUnit), (meters) => convertAltitudeFromMeters(meters, prefs.altitudeUnit));
  }
}

/// Builds the actual dashboard tile content for a [SensorType] rendered with
/// [style], fed by real (not mocked) data from [streams].
///
/// This mirrors the style-picker's preview mapping (same widget classes,
/// same styles) but wires real streams and real-world ranges instead of the
/// onboarding mock data — kept as a separate function rather than sharing
/// code with the picker, since the two have different data sources and
/// ranges and would gain little from forcing a shared abstraction.
///
/// [onAlertColorChanged] is forwarded to the artificial horizon only (the
/// one style with a risk-zone alert) — ignored for every other style. The
/// caller feeds whatever it receives into [DashboardTile.alertColor] for
/// that sensor's tile.
///
/// [onResetRequested], when given, is forwarded (wrapped with [sensorType])
/// to whichever of the four styles (speed/altitude line chart, G-force
/// meter, artificial horizon) is being built — each has a resettable
/// record, and the caller uses this to populate its long-press menu's
/// reset/calibrate trigger without needing per-style knowledge itself.
///
/// [onImmediateResetRequested] mirrors [onResetRequested] exactly, forwarded
/// to the same four styles — this is the bare (dialog-free) counterpart the
/// dashboard's global "Resetar e calibrar sistema" button uses to run every
/// tile's reset/calibration behind a single confirmation of its own.
Widget buildDashboardSensorWidget(
  SensorType sensorType,
  DisplayStyle style,
  DashboardSensorStreams streams, {
  ValueChanged<Color?>? onAlertColorChanged,
  void Function(SensorType type, VoidCallback trigger)? onResetRequested,
  void Function(SensorType type, VoidCallback trigger)? onImmediateResetRequested,
}) {
  switch (style) {
    case DisplayStyle.numericWithHistory:
      // Despite the enum's name (kept as-is — it's a persisted Hive value,
      // not worth a migration to rename), speed renders through the exact
      // same LineChart as altitude — see that class's own doc for why it's
      // already sensor-agnostic. Deliberately no fixed min/max here, same
      // as altitude: auto-scaling from the tracked session range is what
      // "the same logic, no speed-specific rule" (per the widget
      // unification spec) actually means in practice. Unlike altitude,
      // shows MÁX (a quiet, fixed black/grey — see maxBadgeHistoricalColorFor)
      // + MÉD (dynamically banded by speedAverageBandFor) instead of MÁX +
      // MÍN — average speed is the more useful figure while driving; the
      // true minimum is still tracked/persisted underneath for the chart's
      // own vertical scale, just not surfaced as a badge.
      return _UnitAwareLineChart(
        builder: (unit, displayTransform) => LineChart(
          valueStream: streams.speedKmh,
          unit: unit,
          displayTransform: displayTransform,
          initialSessionMin: SensorRecords.speedMinRecord,
          initialSessionMax: SensorRecords.speedMaxRecord,
          onSessionExtremesChanged: (min, max) => SensorRecords.setSpeedRecords(min: min, max: max),
          trackAverage: true,
          initialSessionAverage: SensorRecords.speedAverageRecord,
          initialAverageSampleCount: SensorRecords.speedAverageSampleCount,
          onSessionAverageChanged: (average, sampleCount) =>
              SensorRecords.setSpeedAverage(average: average, sampleCount: sampleCount),
          resetDialogTitle: 'Resetar máxima e média de velocidade?',
          resetDialogConfirmLabel: 'Resetar máxima e média',
          onResetRequested: onResetRequested == null ? null : (trigger) => onResetRequested(sensorType, trigger),
          onImmediateResetRequested: onImmediateResetRequested == null
              ? null
              : (trigger) => onImmediateResetRequested(sensorType, trigger),
        ),
      );
    case DisplayStyle.lineChart:
      return _UnitAwareAltitudeChart(
        builder: (unit, displayTransform) => LineChart(
          valueStream: streams.altitudeMeters,
          unit: unit,
          displayTransform: displayTransform,
          initialSessionMin: SensorRecords.altitudeMinRecord,
          initialSessionMax: SensorRecords.altitudeMaxRecord,
          onSessionExtremesChanged: (min, max) => SensorRecords.setAltitudeRecords(min: min, max: max),
          onResetRequested: onResetRequested == null ? null : (trigger) => onResetRequested(sensorType, trigger),
          onImmediateResetRequested: onImmediateResetRequested == null
              ? null
              : (trigger) => onImmediateResetRequested(sensorType, trigger),
        ),
      );
    case DisplayStyle.gForceMeter:
      return GForceMeter(
        offsetStream: streams.gForceOffset,
        magnitudeStream: streams.gForceMagnitude,
        verticalStream: streams.gForceVertical,
        initialMaxMagnitude: SensorRecords.gForceMaxRecord,
        onMaxMagnitudeChanged: SensorRecords.setGForceMaxRecord,
        initialVerticalGMin: SensorRecords.gForceVerticalMinRecord,
        initialVerticalGMax: SensorRecords.gForceVerticalMaxRecord,
        onVerticalGExtremesChanged: (min, max) => SensorRecords.setGForceVerticalRecords(min: min, max: max),
        onResetRequested: onResetRequested == null ? null : (trigger) => onResetRequested(sensorType, trigger),
        onImmediateResetRequested: onImmediateResetRequested == null
            ? null
            : (trigger) => onImmediateResetRequested(sensorType, trigger),
      );
    case DisplayStyle.artificialHorizon:
      return ArtificialHorizon(
        pitchRollStream: streams.inclinationPitchRollDegrees,
        initialPitchOffsetDeg: SensorRecords.inclinationPitchOffsetDeg,
        initialRollOffsetDeg: SensorRecords.inclinationRollOffsetDeg,
        onCalibrated: (pitchOffsetDeg, rollOffsetDeg) => SensorRecords.setInclinationCalibration(
          pitchOffsetDeg: pitchOffsetDeg,
          rollOffsetDeg: rollOffsetDeg,
        ),
        onAlertColorChanged: onAlertColorChanged,
        onResetRequested: onResetRequested == null ? null : (trigger) => onResetRequested(sensorType, trigger),
        onImmediateResetRequested: onImmediateResetRequested == null
            ? null
            : (trigger) => onImmediateResetRequested(sensorType, trigger),
      );
    case DisplayStyle.refuelSummary:
      // Not a telemetry consumer: reads the refuel log and the vehicle profile
      // from Hive (see RefuelSummaryWidget). Nothing to reset or calibrate, so
      // it registers no reset trigger.
      return const RefuelSummaryWidget();
  }
}
