import 'package:flutter/material.dart';

import '../../models/alert_type.dart';
import '../../services/alert_preferences.dart';

/// Enable/disable each alert and, for the ones with a numeric threshold,
/// adjust it — reads/writes [AlertPreferencesScope], the same reactive
/// source [AlertEngine] consumes, so a change here takes effect on the
/// very next telemetry sample, no restart needed.
class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = AlertPreferencesScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Alertas')),
      body: SafeArea(
        child: ListView(
          children: AlertType.values.map((type) => _AlertTile(type: type, prefs: prefs)).toList(),
        ),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.type, required this.prefs});

  final AlertType type;
  final AlertPreferences prefs;

  String _thresholdUnit(AlertType type) {
    switch (type) {
      case AlertType.highSpeed:
        return 'km/h';
      case AlertType.harshAcceleration:
      case AlertType.harshBraking:
      case AlertType.hardCornering:
      case AlertType.highResultantG:
        return 'g';
      case AlertType.highInclination:
        return '°';
      case AlertType.weakGnss:
      case AlertType.gnssLost:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = prefs.isEnabled(type);
    final threshold = prefs.thresholdFor(type);
    return Column(
      children: [
        SwitchListTile(
          title: Text(alertTypeLabel(type)),
          value: enabled,
          onChanged: (value) => prefs.setEnabled(type, value),
        ),
        if (enabled && threshold != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Slider(
                    value: threshold,
                    min: _sliderMin(type),
                    max: _sliderMax(type),
                    onChanged: (value) => prefs.setThreshold(type, value),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text('${threshold.toStringAsFixed(1)} ${_thresholdUnit(type)}', textAlign: TextAlign.end),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }

  double _sliderMin(AlertType type) {
    switch (type) {
      case AlertType.highSpeed:
        return 40;
      case AlertType.harshAcceleration:
      case AlertType.harshBraking:
      case AlertType.hardCornering:
        return 0.1;
      case AlertType.highResultantG:
        return 0.2;
      case AlertType.highInclination:
        return 5;
      case AlertType.weakGnss:
      case AlertType.gnssLost:
        return 0;
    }
  }

  double _sliderMax(AlertType type) {
    switch (type) {
      case AlertType.highSpeed:
        return 220;
      case AlertType.harshAcceleration:
      case AlertType.harshBraking:
      case AlertType.hardCornering:
        return 1.0;
      case AlertType.highResultantG:
        return 1.5;
      case AlertType.highInclination:
        return 60;
      case AlertType.weakGnss:
      case AlertType.gnssLost:
        return 0;
    }
  }
}
