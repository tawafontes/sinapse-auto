// Fase 16.2-R4.3-R2.6.8 — X119.
//
// The host is created once, in the root State's initState. Nothing that only
// rebuilds the app — the root widget reconfigured, a theme-mode change (which
// rebuilds MaterialApp), navigation, an orientation change — may create
// another one or disturb the session it holds.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/main.dart';
import 'package:synapse_auto/models/theme_config.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/theme_controller.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X119 root rebuild, theme-mode change, navigation and orientation keep the same host, root State, '
    'dashboard and recording session',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot();
          final host = app.host;
          final rootState = tester.state(find.byType(SynapseAutoApp));
          final a = await app.startSessionViaUi();
          await app.backToDashboard();
          final dashboard = app.dashboardStates().single;
          final attempts = host.dashcamController.cameraAttemptCreationCountForTest;

          void expectUnchanged(String step) {
            expect(tester.state(find.byType(SynapseAutoApp)), same(rootState), reason: step);
            expect(app.host, same(host), reason: step);
            expect(host.isDisposed, isFalse, reason: step);
            expect(app.dashboardStates().single, same(dashboard), reason: step);
            expect(host.recorder.activeSession?.id, a, reason: step);
            expect(host.recorder.state, DrivingSessionRecorderState.recording, reason: step);
            expect(host.dashcamController.cameraAttemptCreationCountForTest, attempts, reason: step);
          }

          await tester.pumpWidget(const SynapseAutoApp());
          await app.drive(const Duration(milliseconds: 300));
          expectUnchanged('root widget pumped again');

          // Theme-mode changes rebuild MaterialApp through the root AnimatedBuilder.
          // Driven on the controller: leaving ThemeSelectionScreen without
          // "Concluir" trips the pre-existing R4.3-D2 O-1.
          final themeController = tester.widget<ThemeControllerScope>(find.byType(ThemeControllerScope)).notifier!;
          themeController.previewScreenMode(ScreenMode.light);
          await app.drive(const Duration(milliseconds: 300));
          expectUnchanged('light mode');
          themeController.previewScreenMode(ScreenMode.dark);
          await app.drive(const Duration(milliseconds: 300));
          themeController.revertToPersisted();
          await app.drive(const Duration(milliseconds: 300));
          expectUnchanged('theme reverted');

          await app.openSettings();
          await app.tapText('Histórico');
          await app.backToDashboard();
          expectUnchanged('History pushed and popped');

          tester.view.physicalSize = const Size(4000, 1080);
          await app.drive(const Duration(milliseconds: 400));
          expectUnchanged('landscape');
          tester.view.physicalSize = const Size(1080, 4000);
          await app.drive(const Duration(milliseconds: 400));
          expectUnchanged('portrait');

          await app.stopSessionViaUi();
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
