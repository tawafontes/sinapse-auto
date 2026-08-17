import 'package:flutter/material.dart';

import '../../models/display_style_metadata.dart';
import '../../models/sensor_type_metadata.dart';
import '../../models/sensor_widget_config.dart';
import '../../services/sensor_widget_repository.dart';
import '../onboarding/style_preview_widgets.dart';

/// Single-sensor style picker for the dashboard's "Alterar o estilo"
/// long-press action — the one-sensor equivalent of onboarding's
/// [StyleSelectionScreen] wizard, reusing the same preview widgets but with
/// no stepping through other sensors and no wizard chrome.
class SingleSensorStyleScreen extends StatefulWidget {
  const SingleSensorStyleScreen({super.key, required this.sensorType, required this.initialStyle});

  final SensorType sensorType;
  final DisplayStyle initialStyle;

  @override
  State<SingleSensorStyleScreen> createState() => _SingleSensorStyleScreenState();
}

class _SingleSensorStyleScreenState extends State<SingleSensorStyleScreen> {
  late DisplayStyle _chosen;
  late final Map<DisplayStyle, Widget> _previews;

  @override
  void initState() {
    super.initState();
    _chosen = widget.initialStyle;
    _previews = {
      for (final style in validDisplayStylesForSensor[widget.sensorType]!)
        style: buildStylePreview(widget.sensorType, style),
    };
  }

  Future<void> _save() async {
    await SensorWidgetRepository.upsertStyle(widget.sensorType, _chosen);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final meta = sensorTypeMetadata[widget.sensorType]!;
    final styles = validDisplayStylesForSensor[widget.sensorType]!;

    return Scaffold(
      appBar: AppBar(title: Text('Estilo: ${meta.label}')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: GridView.count(
                padding: const EdgeInsets.all(16),
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.85,
                children: styles.map((style) {
                  return StyleOptionCard(
                    label: displayStyleLabels[style]!,
                    isSelected: style == _chosen,
                    onTap: () => setState(() => _chosen = style),
                    preview: _previews[style]!,
                  );
                }).toList(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Salvar'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
