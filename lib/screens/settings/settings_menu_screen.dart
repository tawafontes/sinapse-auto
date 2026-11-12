import 'package:flutter/material.dart';

import '../../services/configuration_reset_service.dart';
import '../../services/dashboard_sensor_streams.dart';
import '../../services/dashcam_session_controller.dart';
import '../../services/driving_session_host.dart';
import '../../services/driving_session_recorder.dart';
import '../../services/theme_controller.dart';
import '../hud/hud_screen.dart';
import '../onboarding/theme_selection_screen.dart';
import '../onboarding/welcome_screen.dart';
import '../sessions/session_recording_screen.dart';
import 'alerts_screen.dart';
import 'dashcam_settings_screen.dart';
import 'diagnostics_screen.dart';
import 'power_profile_screen.dart';
import 'units_screen.dart';
import '../vehicle/vehicle_menu_screen.dart';

/// Reached via the gear icon on the dashboard. Reopens the same theme
/// screen used during onboarding — it already reads its current state from
/// Hive on `initState`, so no separate "edit" screen is needed, just an
/// entry point straight into it. Sensor/style selection live entirely on
/// the dashboard itself now (the "+" button, and each tile's long-press
/// menu) rather than here.
///
/// [streams] is the app's single [DashboardSensorStreams] instance (owned by
/// `DrivingSessionHost`, threaded through by the Dashboard) so
/// [DiagnosticsScreen] can reuse it; [sessionRecorder] is likewise the app's
/// single [DrivingSessionRecorder] — this screen never constructs its own
/// sensor connection or a second recorder.
class SettingsMenuScreen extends StatelessWidget {
  const SettingsMenuScreen({
    super.key,
    required this.streams,
    required this.sessionRecorder,
    this.dashcamController,
  });

  final DashboardSensorStreams streams;
  final DrivingSessionRecorder sessionRecorder;

  /// Nullable so callers that only have a recorder keep compiling; the
  /// Dashboard always passes the app's controller (owned by
  /// `DrivingSessionHost`). Its `DashcamSessionController.status` getter
  /// already reports `DashcamStatus.disabled` on its own whenever the feature
  /// is turned off, so `null` here is never used to mean "disabled".
  final DashcamSessionController? dashcamController;

  /// Fase 16.2-R4.3-R2.6.8: a reset never ends a driving session. While the
  /// session still has an open obligation this explains what to do first
  /// instead of offering the reset — and [ConfigurationResetService] refuses
  /// on its own too, so this dialog is not the only guard.
  Future<void> _confirmReset(BuildContext context) async {
    final sessionHost = DrivingSessionScope.of(context);
    final blocker = sessionHost.configurationResetBlocker;
    if (blocker != null) {
      await _explainResetBlocked(context, blocker);
      return;
    }
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
    try {
      await const ConfigurationResetService().reset(sessionHost: sessionHost, themeController: themeController);
    } on ConfigurationResetRejected catch (rejected) {
      if (context.mounted) await _explainResetBlocked(context, rejected.blocker);
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  Future<void> _explainResetBlocked(BuildContext context, DrivingSessionRecorderState blocker) {
    final message = switch (blocker) {
      DrivingSessionRecorderState.finalizing =>
        'A sessão de condução ainda está sendo finalizada. Aguarde a finalização terminar e depois '
            'redefina a configuração.',
      DrivingSessionRecorderState.finalizationFailed =>
        'A última sessão de condução ainda não foi salva. Tente finalizá-la primeiro em '
            '"Sessão de condução" → "Tentar finalizar novamente" e depois redefina a configuração.',
      _ =>
        'Há uma sessão de condução em andamento. Encerre a sessão primeiro em "Sessão de condução" → '
            '"Finalizar sessão" e depois redefina a configuração.',
    };
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Não é possível redefinir agora'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendi'),
          ),
        ],
      ),
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
              subtitle: const Text('Iniciar ou finalizar a viagem atual e ver o histórico'),
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
              subtitle: const Text('Configurar a gravação de vídeo e ver as gravações'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DashcamSettingsScreen()),
              ),
            ),
            ListTile(
              key: const ValueKey('settings_vehicle'),
              leading: const Icon(Icons.directions_car_outlined),
              title: const Text('Veículo'),
              subtitle: const Text('Meu veículo, abastecimentos e relatórios de consumo'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const VehicleMenuScreen()),
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
