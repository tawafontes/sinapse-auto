import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'screens/dashboard/dashboard_screen.dart';
import 'screens/onboarding/welcome_screen.dart';
import 'services/alert_preferences.dart';
import 'services/dashcam_clip_index.dart' show reconcileCanonicalClipsAtStartup;
import 'services/dashcam_preferences.dart';
import 'services/dashcam_storage_quota.dart' show measureDashcamStorageAtStartup;
import 'services/driving_session_host.dart';
import 'services/driving_session_recorder.dart' show recoverDrivingSessionsAtStartup;
import 'services/hive_boxes.dart';
import 'services/obd/obd_preferences.dart';
import 'services/power_profile_preferences.dart';
import 'services/sensor_records.dart';
import 'services/sensor_widget_repository.dart';
import 'services/theme_controller.dart';
import 'services/unit_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await bootstrapApp();
  runApp(const SynapseAutoApp());
}

/// Everything that runs once per process before the first frame — a function
/// of its own only so a test can run exactly this startup and then pump
/// [SynapseAutoApp] itself.
Future<void> bootstrapApp() async {
  await HiveBoxes.init();
  // Fase 16.2-R4.3-R2.6.7/R2.6.8: a session deletion the previous run did not
  // finish is finished, then sessions a killed run left active are reclaimed —
  // before anything can list, open or record a session, and before the app's
  // single recorder exists (see _SynapseAutoAppState). Never throws.
  await recoverDrivingSessionsAtStartup();
  // Fase 16.2-R4.4-R1: every clip a previous run published under its canonical
  // name and did not get to index is indexed now, exactly once — AFTER the
  // deletions above (a completed one leaves its session absent: its clips are
  // orphans, never indexed; a marked one is refused) and before anything can
  // list a session. Never throws.
  await reconcileCanonicalClipsAtStartup();
  // Fase 16.2-R4.4-R2: then the storage — an index entry an eviction left
  // without its file is removed, the disk is measured, and (Android) the
  // canonical clips get the app's group back (P3-HW-1). Deletes no clip: the
  // first eviction comes with the first publication, START or quota change.
  // Never throws.
  await measureDashcamStorageAtStartup();
  await SensorWidgetRepository.discardUnknownSensors();
  await SensorWidgetRepository.migrateInvalidStyles();
  await SensorRecords.discardRetiredCompassCalibratedFlag();
}

class SynapseAutoApp extends StatefulWidget {
  const SynapseAutoApp({super.key});

  @override
  State<SynapseAutoApp> createState() => _SynapseAutoAppState();
}

class _SynapseAutoAppState extends State<SynapseAutoApp> with WidgetsBindingObserver {
  final ThemeController _themeController = ThemeController();
  final UnitPreferences _unitPreferences = UnitPreferences();
  final AlertPreferences _alertPreferences = AlertPreferences();
  final PowerProfilePreferences _powerProfilePreferences = PowerProfilePreferences();
  final DashcamPreferences _dashcamPreferences = DashcamPreferences();
  final ObdPreferences _obdPreferences = ObdPreferences();

  /// Fase 16.2-R4.3-R2.6.8: the driving session and everything it depends on
  /// (see [DrivingSessionHost]) live exactly as long as this app — not as long
  /// as whichever DashboardScreen happens to be on screen. Created once here;
  /// a rebuild of this widget, a theme change or any navigation keeps it.
  late final DrivingSessionHost _sessionHost;

  @override
  void initState() {
    super.initState();
    _sessionHost = DrivingSessionHost(
      powerProfile: _powerProfilePreferences,
      alertPreferences: _alertPreferences,
      dashcamPreferences: _dashcamPreferences,
      obdPreferences: _obdPreferences,
    );
    WidgetsBinding.instance.addObserver(this);
    // Covers the initial foreground launch; didChangeAppLifecycleState
    // covers every resume/background transition after that.
    unawaited(WakelockPlus.enable());
  }

  // Keeps the screen on for as long as the app is open and in the
  // foreground — reverts to normal system behavior (dimming/sleeping) the
  // moment it's backgrounded, minimized, or closed. Never touches
  // brightness: WakelockPlus's Android implementation is a
  // FLAG_KEEP_SCREEN_ON window flag, not a brightness override.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // OBD-II: in the background the adapter is kept only while a session
    // records (see DrivingSessionHost.didChangeAppLifecycleState).
    _sessionHost.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(WakelockPlus.enable());
    } else {
      unawaited(WakelockPlus.disable());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(WakelockPlus.disable());
    // Before the preferences it listens to.
    _sessionHost.dispose();
    _themeController.dispose();
    _unitPreferences.dispose();
    _alertPreferences.dispose();
    _powerProfilePreferences.dispose();
    _dashcamPreferences.dispose();
    _obdPreferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Theme is the true last step of onboarding (see ThemeSelectionScreen)
    // in both the old and new flows. Sensor selection moved out of
    // first-run onboarding, so a legitimately-empty dashboard no longer
    // implies onboarding is incomplete — checking SensorWidgetRepository.all
    // here as well would send a returning user with no tools yet added
    // straight back to the Welcome screen on every restart.
    final onboardingDone = _themeController.isPersisted;
    return ThemeControllerScope(
      controller: _themeController,
      child: UnitPreferencesScope(
        preferences: _unitPreferences,
        child: AlertPreferencesScope(
          preferences: _alertPreferences,
          child: PowerProfilePreferencesScope(
            preferences: _powerProfilePreferences,
            child: DashcamPreferencesScope(
              preferences: _dashcamPreferences,
              child: DrivingSessionScope(
                host: _sessionHost,
                child: AnimatedBuilder(
                  animation: _themeController,
                  builder: (context, _) {
                    return MaterialApp(
                      title: 'Synapse Auto',
                      // The app is written in Brazilian Portuguese only, so the
                      // framework's own texts (the refuel form's date picker,
                      // dialog buttons, tooltips) follow it regardless of the
                      // phone's language.
                      locale: const Locale('pt', 'BR'),
                      supportedLocales: const [Locale('pt', 'BR')],
                      localizationsDelegates: GlobalMaterialLocalizations.delegates,
                      theme: _themeController.themeData,
                      home: onboardingDone ? const DashboardScreen() : const WelcomeScreen(),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
