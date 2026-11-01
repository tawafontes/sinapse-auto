// Fase 16.2-R4.3-R2.6.8 — X125.
//
// Moving the dashcam controller into the app-lifetime host must not change
// the camera's own lifecycle contract: in background the camera becomes
// unavailable (no STOP, no release, the lifecycle generation advances), in
// foreground it recovers for the SAME session; the logical session never
// stops. And the generation is no longer reset by a dashboard recreation (it
// restarted at 0 with every recreated controller before).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X125 background → camera unavailable (no STOP), foreground → recovered for the same session and '
    'generation; a later dashboard recreation keeps the controller and its generation; STOP indexes the clips',
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
          final generation = controller.lifecycleGenerationForTest;
          final stopsBefore = app.cameraCalls()['stopVideoRecording'] ?? 0;
          final disposesBefore = app.cameraCalls()['dispose'] ?? 0;

          for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
            tester.binding.handleAppLifecycleStateChanged(state);
            await app.drive(const Duration(milliseconds: 200));
          }
          await app.driveUntil(() => controller.status == DashcamStatus.cameraUnavailable, label: 'camera unavailable in background');
          expect(controller.lifecycleGenerationForTest, generation + 1);
          expect(app.cameraCalls()['stopVideoRecording'] ?? 0, stopsBefore, reason: 'background is not a STOP');
          expect(app.cameraCalls()['dispose'] ?? 0, disposesBefore, reason: 'background does not release the camera');
          expect(recorder.activeSession!.id, a);
          expect(recorder.state, DrivingSessionRecorderState.recording, reason: 'the logical session continues');
          expect(controller.recordingSessionIdForTest, a);

          await app.drive(const Duration(milliseconds: 500));
          for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
            tester.binding.handleAppLifecycleStateChanged(state);
            await app.drive(const Duration(milliseconds: 200));
          }
          await app.driveUntil(() => controller.status == DashcamStatus.recording, label: 'camera recovered');
          expect(controller.lifecycleGenerationForTest, generation + 1, reason: 'resume does not advance the generation');
          expect(controller.recordingSessionIdForTest, a, reason: 'recovered for the same session');
          expect(recorder.activeSession!.id, a);

          await app.tapThemeConclude();
          await app.settleDashboardTransition();
          expect(app.host.dashcamController, same(controller));
          expect(controller.lifecycleGenerationForTest, generation + 1, reason: 'a recreation does not reset the generation');
          expect(controller.status, DashcamStatus.recording);
          expect(recorder.activeSession!.id, a);

          await app.stopSessionViaUi();
          expect(app.indexedClips(a), greaterThanOrEqualTo(1));
          expect(app.unindexedClipFiles(), isEmpty);
          expect(await app.storedSamples(a), app.sessionsBox.get(a)!.sampleCount);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
