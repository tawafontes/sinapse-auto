import 'package:flutter/material.dart';

import '../../models/sensor_type_metadata.dart';
import '../../models/sensor_widget_config.dart';
import '../../services/sensor_widget_repository.dart';
import 'style_selection_screen.dart';

/// Lets the user toggle which sensors they want on their dashboard.
/// Advancing is blocked while the selection is empty.
///
/// Reached from the dashboard's own "+" button (`isEditMode: true`) to add
/// or remove tools — [isEditMode] just changes what happens after the
/// style-selection step that follows (see [StyleSelectionScreen]) — this
/// screen's own behavior is identical either way.
///
/// The initial selection always reflects [SensorWidgetRepository] — the
/// dashboard's own source of truth — rather than a separately-persisted
/// "selected sensors" set, so a sensor deleted from the dashboard (via a
/// tile's long-press menu) never lingers here as still checked. There is
/// deliberately only one place a sensor's "is it on the dashboard" state
/// lives.
class SensorSelectionScreen extends StatefulWidget {
  const SensorSelectionScreen({super.key, this.isEditMode = false, this.preferredPage});

  final bool isEditMode;

  /// Which dashboard page a newly-added tool should try to land on first —
  /// threaded through from the dashboard's own "+" button (which knows what
  /// page was on screen) all the way to [DashboardScreen]'s placement logic.
  /// Null when reached from Settings, which has no page context; placement
  /// then just scans pages from 0.
  final int? preferredPage;

  @override
  State<SensorSelectionScreen> createState() => _SensorSelectionScreenState();
}

class _SensorSelectionScreenState extends State<SensorSelectionScreen> {
  late Set<SensorType> _selected;

  @override
  void initState() {
    super.initState();
    final existing = SensorWidgetRepository.all.map((c) => c.sensorType).toSet();
    _selected = existing.isNotEmpty ? existing : {...sensorTypeMetadata.keys};
  }

  void _toggle(SensorType type, bool value) {
    setState(() {
      if (value) {
        _selected.add(type);
      } else {
        _selected.remove(type);
      }
    });
  }

  void _continue() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StyleSelectionScreen(
          selectedSensors: _selected,
          isEditMode: widget.isEditMode,
          preferredPage: widget.preferredPage,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canContinue = _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Adicione as ferramentas')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Escolha quais ferramentas você quer ver no seu painel. '
                'Você pode mudar isso depois.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: ListView(
                children: sensorTypeMetadata.keys.map((type) {
                  final meta = sensorTypeMetadata[type]!;
                  return SwitchListTile(
                    secondary: Icon(meta.icon),
                    title: Text(meta.label),
                    value: _selected.contains(type),
                    onChanged: (value) => _toggle(type, value),
                  );
                }).toList(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (!canContinue)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Selecione ao menos um sensor para continuar.',
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: canContinue ? _continue : null,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Continuar'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
