import 'package:flutter/material.dart';

import '../../models/unit_system.dart';
import '../../services/unit_preferences.dart';

/// Lets the user pick their preferred speed/altitude unit — reads/writes
/// [UnitPreferencesScope], the single reactive source every dashboard tile
/// already listens to, so a change here is reflected on the dashboard the
/// instant this screen is popped (no separate "apply" step, matching how
/// the theme screen's own live-preview behaves).
class UnitsScreen extends StatelessWidget {
  const UnitsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferencesScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Unidades')),
      body: SafeArea(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Velocidade', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            _UnitOptionTile(
              label: 'Quilômetros por hora (km/h)',
              selected: prefs.speedUnit == SpeedUnit.kmh,
              onTap: () => prefs.setSpeedUnit(SpeedUnit.kmh),
            ),
            _UnitOptionTile(
              label: 'Milhas por hora (mph)',
              selected: prefs.speedUnit == SpeedUnit.mph,
              onTap: () => prefs.setSpeedUnit(SpeedUnit.mph),
            ),
            const Divider(height: 32),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Altitude', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            _UnitOptionTile(
              label: 'Metros (m)',
              selected: prefs.altitudeUnit == AltitudeUnit.meters,
              onTap: () => prefs.setAltitudeUnit(AltitudeUnit.meters),
            ),
            _UnitOptionTile(
              label: 'Pés (ft)',
              selected: prefs.altitudeUnit == AltitudeUnit.feet,
              onTap: () => prefs.setAltitudeUnit(AltitudeUnit.feet),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnitOptionTile extends StatelessWidget {
  const _UnitOptionTile({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(label),
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? colorScheme.primary : null,
      ),
      onTap: onTap,
    );
  }
}
