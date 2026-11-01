import 'app_settings.dart';
import 'driving_session_host.dart';
import 'sensor_widget_repository.dart';
import 'theme_controller.dart';

/// Runs "Redefinir configuração": erases the chosen sensors, styles, page
/// count and theme, after which the caller sends the user back to onboarding.
///
/// Fase 16.2-R4.3-R2.6.8 — decided contract: the reset never ends a driving
/// session on its own. It is refused with [ConfigurationResetRejected], before
/// anything is erased, while the session side has an open obligation (see
/// [DrivingSessionHost.configurationResetBlocker]). The check lives here, in
/// the operation itself, not only in the button that offers it, so any caller
/// goes through it. It is repeated after the writes: a session admitted while
/// they ran must keep its dashboard (and the caller then does not navigate),
/// rather than keep recording behind onboarding with no screen to stop it.
class ConfigurationResetService {
  const ConfigurationResetService();

  Future<void> reset({required DrivingSessionHost sessionHost, required ThemeController themeController}) async {
    sessionHost.ensureConfigurationResetAllowed();
    await AppSettings.setDashboardPageCount(1);
    await SensorWidgetRepository.removeSensorsNotIn(const {});
    await themeController.resetToDefaults();
    sessionHost.ensureConfigurationResetAllowed();
  }
}
