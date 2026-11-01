// Fase 16.2-R4.3-R2.6.8 — X127.
//
// A DashboardScreen that goes away on its own (here: one pushed on top of the
// app's dashboard, then popped) disposes only its own view resources.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/screens/dashboard/dashboard_screen.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X127 disposing a DashboardScreen view changes nothing in the session: same recording session, no '
    'camera call, same forwarding, same single pipeline',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot();
          final host = app.host;
          final recorder = host.recorder;
          final controller = host.dashcamController;
          final a = await app.startSessionViaUi();
          await app.waitSamples(2);
          await app.backToDashboard();
          final base = app.dashboardStates().single;

          final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
          unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const DashboardScreen())));
          await app.driveUntil(() => app.dashboardCount() == 2, label: 'second dashboard mounted');
          await app.drive(const Duration(milliseconds: 600));
          final extra = app.dashboardStates().firstWhere((s) => !identical(s, base));
          final callsBefore = app.cameraCalls();
          final samples = recorder.activeSession!.sampleCount;

          nav.pop();
          await app.driveUntil(() => !extra.mounted, label: 'second dashboard disposed');
          await app.drive(const Duration(milliseconds: 300));

          expect(base.mounted, isTrue);
          expect(app.host, same(host));
          expect(recorder.state, DrivingSessionRecorderState.recording);
          expect(recorder.activeSession!.id, a);
          expect(recorder.activeSession!.endTime, isNull);
          expect(app.sessionsBox.get(a)!.endTime, isNull);
          expect(DrivingSessionRecorder.controllingState(a), DrivingSessionRecorderState.recording);
          expect(controller.status, DashcamStatus.recording);
          expect(controller.recordingSessionIdForTest, a);
          expect(app.cameraCalls(), callsBefore, reason: 'no camera call caused by a view going away');
          expect(host.isForwardingEventsForTest, isTrue);
          expect(app.census.liveOf(gnssTimerFile), 1);
          expect(app.gps.positions.active, 1);
          await app.driveUntil(() => recorder.activeSession!.sampleCount > samples, label: 'A keeps collecting');

          await app.stopSessionViaUi();
          expect(await app.storedSamples(a), app.sessionsBox.get(a)!.sampleCount);
          expect(app.unindexedClipFiles(), isEmpty);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
