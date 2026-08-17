import 'package:flutter/material.dart';

import '../../models/power_profile.dart';
import '../../services/power_profile_preferences.dart';

/// Lets the user pick the active [PowerProfile] — reads/writes
/// [PowerProfilePreferencesScope], the same reactive source
/// [TelemetryEngine] already consumes, so a change here affects the next
/// telemetry emission immediately, no restart needed.
class PowerProfileScreen extends StatelessWidget {
  const PowerProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = PowerProfilePreferencesScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil de consumo')),
      body: SafeArea(
        child: ListView(
          children: PowerProfile.values.map((profile) {
            final selected = prefs.profile == profile;
            return ListTile(
              leading: Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: selected ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(powerProfileLabel(profile)),
              subtitle: Text(powerProfileDescription(profile)),
              isThreeLine: true,
              onTap: () => prefs.setProfile(profile),
            );
          }).toList(),
        ),
      ),
    );
  }
}
