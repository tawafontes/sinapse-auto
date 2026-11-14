import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/dashcam_config.dart';
import '../../services/dashcam_preferences.dart';
import '../../services/dual_camera/dashcam_camera_platform.dart';
import '../sessions/dashcam_recordings_screen.dart';

/// Dashcam configuration (Fase 15) — reads/writes [DashcamPreferencesScope],
/// mirroring `PowerProfileScreen`/`UnitsScreen`'s existing settings-screen
/// shape (a plain [StatelessWidget] over a single reactive preferences
/// object, radio-style option tiles for discrete choices).
///
/// [CameraSelection.both] ("Ambas", 2026-11-14) is offered only where the
/// phone runs the back and front cameras at once ([dualSupported]) — hidden,
/// never a silent no-op, elsewhere (this app's convention). With it comes the
/// choice of the camera that fills the frame (owner decision).
class DashcamSettingsScreen extends StatelessWidget {
  const DashcamSettingsScreen({super.key, this.dualSupported});

  /// Whether "Ambas" can be offered; asks the app's camera platform when
  /// `null` (tests pass a value).
  final Future<bool> Function()? dualSupported;

  static Future<bool> _askPlatform() async {
    final platform = DashcamCameraPlatform.installed;
    return platform != null && await platform.dualSupported();
  }

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
            _DualCameraOptions(
              supported: dualSupported ?? _askPlatform,
              builder: (context, snapshot) {
                if (snapshot.data != true) return const SizedBox.shrink();
                final both = prefs.cameraSelection == CameraSelection.both;
                return Column(
                  children: [
                    _OptionTile(
                      key: const ValueKey('dashcamSettings_both'),
                      label: 'Ambas (traseira e frontal no mesmo vídeo)',
                      selected: both,
                      onTap: () => prefs.setCameraSelection(CameraSelection.both),
                    ),
                    if (both) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text('Câmera principal', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      _OptionTile(
                        key: const ValueKey('dashcamSettings_backPrimary'),
                        label: 'Traseira, com a frontal no canto',
                        selected: !prefs.dualFrontPrimary,
                        onTap: () => prefs.setDualFrontPrimary(false),
                      ),
                      _OptionTile(
                        key: const ValueKey('dashcamSettings_frontPrimary'),
                        label: 'Frontal, com a traseira no canto',
                        selected: prefs.dualFrontPrimary,
                        onTap: () => prefs.setDualFrontPrimary(true),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text('Com as duas câmeras o vídeo é gravado em 720p. Ao girar o celular gravando, o vídeo para por cerca de 1 s.'),
                      ),
                    ],
                  ],
                );
              },
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

/// Asks once whether "Ambas" can be offered, then builds with the answer —
/// the question is not repeated on every preference change.
class _DualCameraOptions extends StatefulWidget {
  const _DualCameraOptions({required this.supported, required this.builder});

  final Future<bool> Function() supported;
  final AsyncWidgetBuilder<bool> builder;

  @override
  State<_DualCameraOptions> createState() => _DualCameraOptionsState();
}

class _DualCameraOptionsState extends State<_DualCameraOptions> {
  late final Future<bool> _supported = widget.supported();

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(future: _supported, builder: widget.builder);
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({super.key, required this.label, required this.selected, required this.onTap});

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
