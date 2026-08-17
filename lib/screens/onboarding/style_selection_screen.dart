import 'package:flutter/material.dart';

import '../../models/display_style_metadata.dart';
import '../../models/sensor_type_metadata.dart';
import '../../models/sensor_widget_config.dart';
import '../../services/power_profile_preferences.dart';
import '../../services/sensor_widget_repository.dart';
import '../dashboard/dashboard_screen.dart';
import 'style_preview_widgets.dart';
import 'theme_selection_screen.dart';

/// Sequential, one-sensor-at-a-time style picker. Every option shows a live
/// preview driven by mocked/animated data — never the real sensor stream.
///
/// A sensor with only one valid style (e.g. altitude, which only offers
/// "gráfico de linha") never gets a step here — it's auto-assigned its
/// one style in [initState]
/// and simply left out of [_sensors]. If every
/// selected sensor is like that, [_sensors] ends up empty and the whole
/// screen is skipped in favor of whatever comes next.
///
/// Reached from [SensorSelectionScreen] once the dashboard's "+" button
/// selection is confirmed, which hands over the exact set it just built
/// (rather than this screen re-reading a separately-persisted selection —
/// see that class's doc for why there's only one source for that state).
/// The only difference [isEditMode] makes is where the last step leads:
/// onboarding continues into theme selection, while editing goes straight
/// back to an up-to-date dashboard.
class StyleSelectionScreen extends StatefulWidget {
  const StyleSelectionScreen({
    super.key,
    required this.selectedSensors,
    this.isEditMode = false,
    this.preferredPage,
  });

  /// The sensors [SensorSelectionScreen] just confirmed — this screen picks
  /// a display style for each one that has more than one valid option (see
  /// [_sensors]), then persists the whole set on [_finish].
  final Set<SensorType> selectedSensors;

  final bool isEditMode;

  /// Forwarded from [SensorSelectionScreen] straight through to the
  /// [DashboardScreen] this screen lands on in edit mode — see that field's
  /// doc comment for why it has to travel as a constructor param.
  final int? preferredPage;

  @override
  State<StyleSelectionScreen> createState() => _StyleSelectionScreenState();
}

class _StyleSelectionScreenState extends State<StyleSelectionScreen> {
  late final List<SensorType> _sensors;
  late final Map<SensorType, DisplayStyle> _chosen;
  int _index = 0;

  // Preview widgets (and the mock streams backing them) for the sensor
  // currently on screen, built once per step rather than on every rebuild.
  // Stateful previews like LineChart track session min/max internally from
  // whatever stream instance they're given; rebuilding _buildPreview inline
  // in `build()` handed each of them a brand-new stream on every setState
  // (e.g. from `_selectStyle`, which fires on every tap — including
  // re-tapping the option already selected), which wiped their accumulated
  // min/max and restarted the animation each time. Caching here means
  // `_selectStyle`'s setState reuses the exact same widget instances, so
  // Flutter's element diffing skips rebuilding them entirely and their
  // internal state/subscriptions survive untouched.
  late Map<DisplayStyle, Widget> _previews;

  @override
  void initState() {
    super.initState();
    final allSelected = sensorTypeMetadata.keys.where(widget.selectedSensors.contains).toList();
    _sensors = allSelected.where((type) => validDisplayStylesForSensor[type]!.length > 1).toList();
    _chosen = {
      for (final type in allSelected)
        type: SensorWidgetRepository.forSensor(type)?.displayStyle ??
            validDisplayStylesForSensor[type]!.first,
    };
    if (_sensors.isEmpty) {
      _previews = const {};
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
    } else {
      _rebuildPreviews();
    }
  }

  void _rebuildPreviews() {
    _previews = {
      for (final style in validDisplayStylesForSensor[_current]!) style: buildStylePreview(_current, style),
    };
  }

  SensorType get _current => _sensors[_index];
  bool get _isLast => _index == _sensors.length - 1;

  void _selectStyle(DisplayStyle style) {
    setState(() => _chosen[_current] = style);
  }

  Future<void> _finish() async {
    await SensorWidgetRepository.removeSensorsNotIn(_chosen.keys.toSet());
    for (final entry in _chosen.entries) {
      await SensorWidgetRepository.upsertStyle(entry.key, entry.value);
    }
    if (!mounted) return;
    if (widget.isEditMode) {
      final powerProfile = PowerProfilePreferencesScope.of(context);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => DashboardScreen(preferredPage: widget.preferredPage, powerProfile: powerProfile),
        ),
        (route) => false,
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ThemeSelectionScreen()),
      );
    }
  }

  Future<void> _next() async {
    if (_isLast) {
      await _finish();
    } else {
      setState(() {
        _index++;
        _rebuildPreviews();
      });
    }
  }

  void _back() {
    if (_index == 0) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _index--;
        _rebuildPreviews();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sensors.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final meta = sensorTypeMetadata[_current]!;
    final styles = validDisplayStylesForSensor[_current]!;
    final selectedStyle = _chosen[_current];

    return Scaffold(
      appBar: AppBar(
        title: Text('Estilo: ${meta.label}'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _back),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: LinearProgressIndicator(value: (_index + 1) / _sensors.length),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Sensor ${_index + 1} de ${_sensors.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            Expanded(
              child: GridView.count(
                padding: const EdgeInsets.all(16),
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.85,
                children: styles.map((style) {
                  final isSelected = style == selectedStyle;
                  return StyleOptionCard(
                    label: displayStyleLabels[style]!,
                    isSelected: isSelected,
                    onTap: () => _selectStyle(style),
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
                  onPressed: _next,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_isLast ? 'Concluir' : 'Próximo'),
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
