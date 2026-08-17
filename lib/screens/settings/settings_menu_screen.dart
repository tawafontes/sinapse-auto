import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/dashboard_sensor_streams.dart';
import '../../services/dashcam_session_controller.dart';
import '../../services/driving_session_recorder.dart';
import '../../services/sensor_widget_repository.dart';
import '../../services/theme_controller.dart';
import '../hud/hud_screen.dart';
import '../onboarding/theme_selection_screen.dart';
import '../onboarding/welcome_screen.dart';
import '../sessions/session_history_screen.dart';
import '../sessions/session_recording_screen.dart';
import 'alerts_screen.dart';
import 'dashcam_settings_screen.dart';
import 'diagnostics_screen.dart';
import 'power_profile_screen.dart';
import 'units_screen.dart';

/// Reached via the gear icon on the dashboard. Reopens the same theme
/// screen used during onboarding — it already reads its current state from
/// Hive on `initState`, so no separate "edit" screen is needed, just an
/// entry point straight into it. Sensor/style selection live entirely on
/// the dashboard itself now (the "+" button, and each tile's long-press
/// menu) rather than here.
///
/// [streams] is the Dashboard's own already-constructed
/// [DashboardSensorStreams] instance, threaded through so [DiagnosticsScreen]
/// can reuse it; [sessionRecorder] is likewise the Dashboard's single
/// [DrivingSessionRecorder] — this screen never constructs its own sensor
/// connection or a second recorder.
class SettingsMenuScreen extends StatelessWidget {
  const SettingsMenuScreen({
    super.key,
    required this.streams,
    required this.sessionRecorder,
    this.dashcamController,
  });

  final DashboardSensorStreams streams;
  final DrivingSessionRecorder sessionRecorder;

  /// Nullable only for the brief window before `DashboardScreen`'s own
  /// `didChangeDependencies` first constructs it (mirrors how
  /// `sessionRecorder` itself would be nullable if this screen could be
  /// reached before `initState`, which it can't) — its
  /// `DashcamSessionController.status` getter already reports
  /// `DashcamStatus.disabled` on its own whenever the feature is turned
  /// off, so `null` here is never used to mean "disabled".
  final DashcamSessionController? dashcamController;

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Redefinir configuração?'),
        content: const Text(
          'Isso apaga os sensores, estilos e tema escolhidos. Você passará '
          'pela configuração inicial novamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Redefinir'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final themeController = ThemeControllerScope.of(context);
    await AppSettings.setDashboardPageCount(1);
    await SensorWidgetRepository.removeSensorsNotIn(const {});
    await themeController.resetToDefaults();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.palette),
              title: const Text('Tema'),
              subtitle: const Text('Cores, brilho e tipografia'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ThemeSelectionScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.straighten),
              title: const Text('Unidades'),
              subtitle: const Text('Velocidade e altitude'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UnitsScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Alertas'),
              subtitle: const Text('Velocidade, GNSS, aceleração e inclinação'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AlertsScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.query_stats),
              title: const Text('Diagnóstico'),
              subtitle: const Text('Estado técnico do GNSS e dos sensores'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DiagnosticsScreen(streams: streams)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Sessão de condução'),
              subtitle: const Text('Iniciar ou finalizar a gravação da viagem atual'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SessionRecordingScreen(recorder: sessionRecorder, dashcamController: dashcamController),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Dashcam'),
              subtitle: const Text('Gravação de vídeo sincronizada com a telemetria'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DashcamSettingsScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Histórico'),
              subtitle: const Text('Sessões de condução anteriores'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SessionHistoryScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.picture_in_picture_alt_outlined),
              title: const Text('HUD'),
              subtitle: const Text('Projeção para o para-brisa'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => HudScreen(streams: streams)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.battery_charging_full),
              title: const Text('Perfil de consumo'),
              subtitle: const Text('Normal, economia, performance ou pronto para Dashcam'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PowerProfileScreen()),
              ),
            ),
            const Divider(height: 32),
            ListTile(
              leading: Icon(Icons.restart_alt, color: errorColor),
              title: Text('Redefinir configuração', style: TextStyle(color: errorColor)),
              subtitle: const Text('Apaga tudo e reinicia a configuração inicial'),
              onTap: () => _confirmReset(context),
            ),
          ],
        ),
      ),
    );
  }
}
