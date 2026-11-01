import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';

/// Records session A, runs [recreate] (a user flow that replaces the
/// DashboardScreen) and proves, frame by frame and afterwards, that A is the
/// SAME session, owned by the same objects, never stopped or restarted, still
/// collecting, and that its final STOP stores every sample and indexes every
/// clip. R4.3-D2 reproduced the opposite 3/3 for both flows: the new
/// dashboard's reclaim closed A at frame 3, its pending samples were lost, the
/// old dashboard's dispose stopped the camera at frame ~30 and A's clip was
/// left unindexed.
Future<void> expectRecreationKeepsSession(AppHarness app, Future<void> Function() recreate) async {
  final host = app.host;
  // What the dashboard actually uses (identity with the host is asserted
  // below, after the consequences).
  final controller = app.uiController;
  final recorder = controller.sessionRecorder;
  final a = await app.startSessionViaUi();
  await app.waitSamples(3);
  await app.backToDashboard();
  final oldDashboard = app.dashboardStates().single;
  final samplesBefore = recorder.activeSession!.sampleCount;
  final attemptsBefore = controller.cameraAttemptCreationCountForTest;
  final setupsBefore = controller.initialSetupInstallCountForTest;
  final ticksBefore = controller.sampleTickCountForTest;
  final callsBefore = app.cameraCalls();
  final gpsListensBefore = app.gps.positions.listens;
  final generationBefore = controller.lifecycleGenerationForTest;

  await recreate();
  var coexistingFrames = 0;
  final violations = <String>{};
  await app.settleDashboardTransition(
    onFrame: (_) {
      if (app.dashboardCount() == 2) coexistingFrames++;
      if (!identical(app.host, host)) violations.add('the host was replaced');
      final active = recorder.activeSession;
      if (active?.id != a || recorder.state != DrivingSessionRecorderState.recording || active?.endTime != null) {
        violations.add('A stopped being the recording session: ${recorder.state.name} ${active?.id}');
      }
      if (app.sessionsBox.get(a)?.endTime != null) violations.add('A was closed in the sessions box');
      if (DrivingSessionRecorder.controllingState(a) != DrivingSessionRecorderState.recording) {
        violations.add('controllingState(A) = ${DrivingSessionRecorder.controllingState(a)?.name}');
      }
      if (app.gps.positions.active > 1) violations.add('a second GPS subscription (second pipeline)');
    },
  );
  expect(coexistingFrames, greaterThan(0), reason: 'setup: the new dashboard is mounted while the old one is still on screen');
  expect(oldDashboard.mounted, isFalse, reason: 'setup: the dashboard WAS replaced');
  expect(app.dashboardStates().single, isNot(same(oldDashboard)));
  expect(violations, isEmpty, reason: 'session A must not be touched by the recreation, at any frame');

  // No logical STOP, no new START, no camera teardown, no telemetry reset.
  final calls = app.cameraCalls();
  expect(calls['stopVideoRecording'] ?? 0, callsBefore['stopVideoRecording'] ?? 0, reason: 'no STOP of the recording');
  expect(calls['dispose'] ?? 0, callsBefore['dispose'] ?? 0, reason: 'the camera was not released');
  expect(calls['startVideoCapturing'] ?? 0, callsBefore['startVideoCapturing'] ?? 0, reason: 'no new START');
  expect(controller.cameraAttemptCreationCountForTest, attemptsBefore, reason: 'no new camera attempt');
  expect(controller.initialSetupInstallCountForTest, setupsBefore, reason: 'telemetry setup not reinstalled');
  expect(controller.lifecycleGenerationForTest, generationBefore);
  expect(controller.recordingSessionIdForTest, a);
  expect(controller.status, DashcamStatus.recording);

  // The same owners, and the ones the new dashboard renders — one authority,
  // one detector, one camera controller.
  expect(app.uiController, same(controller), reason: 'the new dashboard renders the same controller');
  expect(app.host, same(host));
  expect(host.recorder, same(recorder));
  expect(host.dashcamController, same(controller));
  expect(controller.eventStream, same(host.eventEngine.events));
  expect(host.isDisposed, isFalse);

  // A keeps collecting, into the same record; the telemetry sampler keeps ticking.
  await app.driveUntil(() => recorder.activeSession!.sampleCount >= samplesBefore + 3, label: 'A keeps collecting samples');
  await app.driveUntil(() => controller.sampleTickCountForTest > ticksBefore + 5, label: 'telemetry sampler keeps ticking');
  expect(recorder.activeSession!.id, a);
  expect(identical(app.sessionsBox.get(a), recorder.activeSession), isTrue);
  expect(app.census.liveOf(gnssTimerFile), 1, reason: 'exactly one live pipeline');
  expect(app.gps.positions.listens, gpsListensBefore, reason: 'no new GPS subscription');

  // The final STOP makes all of it durable, with no orphan clip.
  await app.stopSessionViaUi();
  final record = app.sessionsBox.get(a)!;
  expect(record.endTime, isNotNull);
  expect(record.sampleCount, greaterThanOrEqualTo(samplesBefore + 3));
  expect(await app.storedSamples(a), record.sampleCount, reason: 'every accepted sample is stored');
  expect(app.indexedClips(a), greaterThanOrEqualTo(1));
  expect(app.unindexedClipFiles(), isEmpty, reason: 'no clip file without an index');
}
