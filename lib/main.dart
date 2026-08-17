import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'screens/dashboard/dashboard_screen.dart';
import 'screens/onboarding/welcome_screen.dart';
import 'services/alert_preferences.dart';
import 'services/dashcam_preferences.dart';
import 'services/hive_boxes.dart';
import 'services/power_profile_preferences.dart';
import 'services/sensor_records.dart';
import 'services/sensor_widget_repository.dart';
import 'services/theme_controller.dart';
import 'services/unit_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HiveBoxes.init();
  await SensorWidgetRepository.discardUnknownSensors();
  await SensorWidgetRepository.migrateInvalidStyles();
  await SensorRecords.discardRetiredCompassCalibratedFlag();
  runApp(const SynapseAutoApp());
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

  @override
  void initState() {
    super.initState();
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
    _themeController.dispose();
    _unitPreferences.dispose();
    _alertPreferences.dispose();
    _powerProfilePreferences.dispose();
    _dashcamPreferences.dispose();
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
              child: AnimatedBuilder(
                animation: _themeController,
                builder: (context, _) {
                  return MaterialApp(
                    title: 'Synapse Auto',
                    theme: _themeController.themeData,
                    home: onboardingDone
                        ? DashboardScreen(powerProfile: _powerProfilePreferences)
                        : const WelcomeScreen(),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
