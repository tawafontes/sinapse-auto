import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/dashcam_config.dart';
import '../../services/dashcam_preferences.dart';
import '../sessions/dashcam_recordings_screen.dart';

/// Dashcam configuration (Fase 15) — reads/writes [DashcamPreferencesScope],
/// mirroring `PowerProfileScreen`/`UnitsScreen`'s existing settings-screen
/// shape (a plain [StatelessWidget] over a single reactive preferences
/// object, radio-style option tiles for discrete choices).
///
/// [CameraSelection.both] is deliberately not offered here — it's explicitly
/// unimplemented (`DashcamService._pickCamera` falls back to the rear
/// camera for it), matching this app's "retire/hide, never silently no-op"
/// convention for unfinished options.
class DashcamSettingsScreen extends StatelessWidget {
  const DashcamSettingsScreen({super.key});

  Future<void> _toggleAudio(BuildContext context, DashcamPreferences prefs, bool value) async {
    if (!value) {
      await prefs.setAudioEnabled(false);
      return;
    }
    // Requested just-in-time, only when the user actually asks for audio —
    // never upfront at onboarding (Fase 15's explicit "don't request a
    // permission a feature doesn't need yet" rule).
    final status = await Permission.microphone.request();
    if (status.isGranted || status.isLimited || status.isProvisional) {
      await prefs.setAudioEnabled(true);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permissão de microfone negada — áudio permanece desativado.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = DashcamPreferencesScope.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Dashcam')),
      body: SafeArea(
        child: ListView(
          children: [
            // The recordings live with the dashcam (moved here from the
            // Settings menu, owner decision 2026-11-11).
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Gravações'),
              subtitle: const Text('Assistir e excluir os vídeos gravados'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DashcamRecordingsScreen())),
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('Dashcam'),
              subtitle: const Text('Grava vídeo durante as sessões de condução, sincronizado com a telemetria.'),
              value: prefs.enabled,
              onChanged: (value) => prefs.setEnabled(value),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Câmera', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            _OptionTile(
              label: 'Traseira',
              selected: prefs.cameraSelection == CameraSelection.rear,
              onTap: () => prefs.setCameraSelection(CameraSelection.rear),
            ),
            _OptionTile(
              label: 'Frontal',
              selected: prefs.cameraSelection == CameraSelection.front,
              onTap: () => prefs.setCameraSelection(CameraSelection.front),
            ),
            const Divider(height: 32),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Resolução', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            _OptionTile(
              label: '480p',
              selected: prefs.resolution == VideoResolution.sd480,
              onTap: () => prefs.setResolution(VideoResolution.sd480),
            ),
            _OptionTile(
              label: '720p (recomendado para este aparelho)',
              selected: prefs.resolution == VideoResolution.hd720,
              onTap: () => prefs.setResolution(VideoResolution.hd720),
            ),
            _OptionTile(
              label: '1080p',
              selected: prefs.resolution == VideoResolution.fhd1080,
              onTap: () => prefs.setResolution(VideoResolution.fhd1080),
            ),
            _OptionTile(
              label: '4K',
              selected: prefs.resolution == VideoResolution.uhd4k,
              onTap: () => prefs.setResolution(VideoResolution.uhd4k),
            ),
            const Divider(height: 32),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Taxa de quadros', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final fps in const [24, 30, 60])
              _OptionTile(
                label: '$fps fps',
                selected: prefs.frameRate == fps,
                onTap: () => prefs.setFrameRate(fps),
              ),
            const Divider(height: 32),
            SwitchListTile(
              title: const Text('Áudio'),
              subtitle: const Text('Grava áudio junto ao vídeo.'),
              value: prefs.audioEnabled,
              onChanged: (value) => _toggleAudio(context, prefs, value),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Limite de armazenamento: ${prefs.storageQuotaMb} MB', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Slider(
                value: prefs.storageQuotaMb.toDouble(),
                min: 256,
                max: 4096,
                divisions: 15,
                activeColor: colorScheme.primary,
                label: '${prefs.storageQuotaMb} MB',
                onChanged: (value) => prefs.setStorageQuotaMb(value.round()),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'Clipes mais antigos são apagados automaticamente ao atingir o limite — clipes protegidos '
                '(por eventos de condução) nunca são apagados.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.label, required this.selected, required this.onTap});

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
