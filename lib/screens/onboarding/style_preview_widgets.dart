import 'package:flutter/material.dart';

import '../../models/sensor_widget_config.dart';
import '../../services/obd/obd_service.dart' show ObdSignal;
import '../../widgets/sensors/artificial_horizon.dart';
import '../../widgets/sensors/g_force_meter.dart';
import '../../widgets/sensors/line_chart.dart';
import '../../widgets/sensors/mock_preview_data.dart';
import '../../widgets/sensors/obd_widgets.dart';
import '../../widgets/vehicle/refuel_summary_widget.dart';

/// A single selectable style option: a live mock preview over a label,
/// highlighted when selected. Shared by [StyleSelectionScreen] (onboarding's
/// multi-sensor wizard) and `SingleSensorStyleScreen` (the dashboard
/// long-press menu's "Alterar o estilo" — one sensor at a time).
class StyleOptionCard extends StatelessWidget {
  const StyleOptionCard({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.preview,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
          color: isSelected ? colorScheme.primaryContainer.withValues(alpha: 0.25) : null,
        ),
        child: Column(
          children: [
            Expanded(child: Padding(padding: const EdgeInsets.all(8), child: preview)),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(label, style: Theme.of(context).textTheme.labelMedium, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

/// Builds a live, mocked-data preview widget for [sensorType] rendered in
/// [style] — never real sensor data, always driven by [MockPreviewData].
Widget buildStylePreview(SensorType sensorType, DisplayStyle style) {
  switch (style) {
    case DisplayStyle.numericWithHistory:
      // Unreachable via the UI: speed's only valid style is numericWithHistory
      // itself (see validDisplayStylesForSensor), so it's never shown as a
      // step here — kept only for DisplayStyle's switch exhaustiveness. Uses
      // the same LineChart as altitude's preview below (see
      // sensor_widget_factory.dart for why), with a fixed bound for a stable
      // demo animation rather than altitude's own auto-scaling.
      return LineChart(
        valueStream: MockPreviewData.speedKmh(),
        min: 0,
        max: 120,
        unit: 'km/h',
        trackAverage: true,
      );
    case DisplayStyle.lineChart:
      // Unreachable via the UI: altitude's only valid style is lineChart
      // itself (see validDisplayStylesForSensor), so it's never shown as a
      // step here — kept only for DisplayStyle's switch exhaustiveness.
      return LineChart(valueStream: MockPreviewData.altitudeMeters(), min: 100, max: 400, unit: 'm');
    case DisplayStyle.gForceMeter:
      // Unreachable via the UI: gForce's only valid style is gForceMeter
      // itself (see validDisplayStylesForSensor), so it's never shown as a
      // step here — kept only for DisplayStyle's switch exhaustiveness.
      return GForceMeter(
        offsetStream: MockPreviewData.gForceOffset(),
        magnitudeStream: MockPreviewData.gForceOffset().map((o) => o.distance),
        verticalStream: MockPreviewData.gForceOffset().map((o) => o.dx * 0.4),
      );
    case DisplayStyle.artificialHorizon:
      // Unreachable via the UI: inclination's only valid style is
      // artificialHorizon itself (see validDisplayStylesForSensor), so it's
      // never shown as a step here — kept only for DisplayStyle's switch
      // exhaustiveness.
      return ArtificialHorizon(pitchRollStream: MockPreviewData.tiltOffset().map((o) => o * 45));
    case DisplayStyle.refuelSummary:
      // Unreachable via the UI, like the cases above: the refuel widget has
      // only this style.
      return RefuelSummaryView.preview();
    case DisplayStyle.tachometer:
      return const ObdSignalView.preview(signal: ObdSignal.rpm, unit: 'rpm', value: 2400, tachometer: true);
    case DisplayStyle.obdValue:
      return const ObdSignalView.preview(signal: ObdSignal.rpm, unit: 'rpm', value: 2400);
  }
}
