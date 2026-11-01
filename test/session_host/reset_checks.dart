import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/screens/onboarding/welcome_screen.dart';
import 'package:synapse_auto/services/app_settings.dart';
import 'package:synapse_auto/services/configuration_reset_service.dart';
import 'package:synapse_auto/services/driving_session_host.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';
import 'package:synapse_auto/services/theme_controller.dart';

import '../support/app_harness.dart';

/// Fase 16.2-R4.3-R2.6.8 — decided contract for "Redefinir configuração": it
/// never ends a driving session; it is refused while the session has an open
/// obligation, with a message saying what to do first.

ThemeController themeControllerOf(WidgetTester tester) => tester.widget<ThemeControllerScope>(find.byType(ThemeControllerScope)).notifier!;

/// Taps "Redefinir configuração" in Settings and returns the texts of the
/// dialog that opens (left open).
Future<List<String>> tapResetConfiguration(AppHarness app) async {
  await app.openSettings();
  await app.tapText('Redefinir configuração', settle: const Duration(milliseconds: 50));
  await app.driveUntil(() => find.byType(AlertDialog).evaluate().isNotEmpty, label: 'reset dialog');
  await app.drive(const Duration(milliseconds: 300));
  return [for (final e in find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? ''];
}

/// The configuration (theme, tiles, page count) is untouched and the app is
/// still on its dashboard.
void expectConfigurationIntact(AppHarness app, {required int pageCount, required String step}) {
  expect(themeControllerOf(app.tester).isPersisted, isTrue, reason: '$step: theme kept');
  expect(SensorWidgetRepository.all.map((c) => c.sensorType), contains(SensorType.altitude), reason: '$step: tiles kept');
  expect(AppSettings.dashboardPageCount, pageCount, reason: '$step: page count kept');
  expect(find.byType(WelcomeScreen, skipOffstage: false), findsNothing, reason: '$step: not sent to onboarding');
  expect(app.dashboardCount(), 1, reason: step);
}

/// A blocked reset: the dialog explains [explanation], offers no reset, and
/// nothing changes; the operation itself (not only the dialog) refuses with
/// [blocker] too.
Future<void> expectResetBlocked(
  AppHarness app, {
  required DrivingSessionRecorderState blocker,
  required String explanation,
  required int pageCount,
}) async {
  final texts = await tapResetConfiguration(app);
  expect(texts, contains('Não é possível redefinir agora'));
  expect(texts.any((t) => t.contains(explanation)), isTrue, reason: 'explains: $explanation — got $texts');
  expect(find.text('Redefinir'), findsNothing, reason: 'the reset is not offered');
  await app.tapText('Entendi');
  expectConfigurationIntact(app, pageCount: pageCount, step: 'after the dialog');

  Object? error;
  try {
    await app.driveFuture(const ConfigurationResetService().reset(sessionHost: app.host, themeController: themeControllerOf(app.tester)));
  } catch (e) {
    error = e;
  }
  expect(error, isA<ConfigurationResetRejected>().having((e) => e.blocker, 'blocker', blocker));
  expectConfigurationIntact(app, pageCount: pageCount, step: 'after a direct call to the reset operation');
}

/// A reset that goes through: confirmation, then onboarding with the
/// configuration erased.
Future<void> resetThroughUi(AppHarness app) async {
  final texts = await tapResetConfiguration(app);
  expect(texts, contains('Redefinir configuração?'));
  await app.tapText('Redefinir', settle: const Duration(milliseconds: 50));
  await app.driveUntil(() => find.byType(WelcomeScreen).evaluate().isNotEmpty && app.dashboardCount() == 0, label: 'onboarding');
  await app.drive(const Duration(milliseconds: 500));
  expect(themeControllerOf(app.tester).isPersisted, isFalse);
  expect(SensorWidgetRepository.all, isEmpty);
  expect(AppSettings.dashboardPageCount, 1);
}
