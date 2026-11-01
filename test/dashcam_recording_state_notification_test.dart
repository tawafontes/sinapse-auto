// Fase 16.2-R4.3-R2.6.21 — DashcamService.cameraKnownUnavailableListenable: the
// fact the dashcam status reads is now PUBLISHED, in the same step as the write
// that changes it. Until this round it only changed: at a rotation's restart
// START deadline (R2.6.20) or stop deadline (R2.6.14) nobody was told, so the
// REC indicator and the preview kept showing a recording that no longer existed
// (see test/dashcam_recording_state_notification_session_test.dart for what the
// UI renders).
//
// Every test records, at each telling, the value told AND what
// `cameraKnownUnavailable` reads at that instant: equal means the listener is
// told after the write, never ahead of it.
import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraException;
import 'package:camera_platform_interface/camera_platform_interface.dart' show CameraPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/services/dashcam_service.dart';

import 'support/fake_camera_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeCameraPlatform fakePlatform;
  late DashcamService service;

  final timerTicks = <void Function()>[];

  /// Each telling of the published fact: the value told.
  final told = <bool>[];

  /// What `cameraKnownUnavailable` read at each telling.
  final factAtTelling = <bool>[];

  /// Every gate a test held — released at tearDown even when the test failed
  /// before releasing it (a held native call keeps the camera from being let go,
  /// and the next test could not open one).
  final held = <Completer<void>>[];

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  // Rotations are driven by hand (timerTicks), never by a real 10 min timer.
  const manualTicksOnly = Duration(minutes: 10);

  const shortDeadline = Duration(milliseconds: 60);
  const patience = Duration(seconds: 3);

  DashcamConfig config() => DashcamConfig(
    cameraSelection: CameraSelection.rear,
    storageQuotaMb: 1024,
    audioEnabled: false,
    resolution: VideoResolution.hd720,
    frameRate: 30,
    enabled: true,
  );

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;
  bool cameraRecording() => service.previewController?.value.isRecordingVideo ?? false;

  String state() =>
      'unavailable=${service.cameraKnownUnavailable}, told=$told, isRecording=${service.isRecording}, cameraRecording=${cameraRecording()}, '
      'rotationsQueued=${service.queuedRotationCountForTest}, pendingStop=${service.hasPendingNativeStop}, '
      'restartOverdue=${service.rotationRestartOverdue}, calls=${fakePlatform.calls.join(',')}';

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail('never happened within ${within.inMilliseconds} ms: $what (${state()})');
  }

  void listen() {
    service.cameraKnownUnavailableListenable.addListener(() {
      told.add(service.cameraKnownUnavailableListenable.value);
      factAtTelling.add(service.cameraKnownUnavailable);
    });
  }

  void expectToldInStep() => expect(factAtTelling, told, reason: 'at each telling the fact already read the value told');

  Future<void> record({Duration? startDeadline, Duration? stopDeadline}) async {
    service = DashcamService(
      config: config(),
      segmentDuration: manualTicksOnly,
      startVideoRecordingTimeout: startDeadline ?? const Duration(seconds: 5),
      stopVideoRecordingTimeout: stopDeadline ?? const Duration(seconds: 5),
    );
    service.segmentTimerArmedHookForTest = timerTicks.add;
    listen();
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'session-A');
    expect(cameraRecording(), isTrue, reason: 'test setup: recording');
    expect(told, isEmpty, reason: 'test setup: initializing and starting changed nothing to tell');
  }

  /// A tick stops the segment; the restart START is held on the returned gate.
  Future<Completer<void>> rotateAndHoldTheRestart() async {
    final startsBefore = count('startVideoCapturing');
    final stopsBefore = count('stopVideoRecording');
    final gate = Completer<void>();
    held.add(gate);
    fakePlatform.pendingStartVideoCapturing = gate;
    timerTicks.last();
    await waitUntil(
      () => count('stopVideoRecording') == stopsBefore + 1 && !service.hasPendingNativeStop && count('startVideoCapturing') == startsBefore + 1,
      'the rotation stopping its segment and issuing the restart START',
    );
    fakePlatform.pendingStartVideoCapturing = null;
    return gate;
  }

  Future<void> rotateOnce() async {
    final startsBefore = count('startVideoCapturing');
    timerTicks.last();
    await waitUntil(() => count('startVideoCapturing') == startsBefore + 1 && cameraRecording() && service.queuedRotationCountForTest == 0, 'an ordinary rotation');
  }

  setUp(() {
    timerTicks.clear();
    told.clear();
    held.clear();
    factAtTelling.clear();
    dir = Directory.systemTemp.createTempSync('dashcam_recording_state_notification_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    for (final gate in [...held, fakePlatform.pendingStartVideoCapturing, fakePlatform.pendingStopVideoRecording]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    fakePlatform.failStartVideoCapturingWith = null;
    await service.dispose().catchError((_) {});
    await waitUntil(() => service.previewController == null, 'the controller being released in tearDown');
    await waitUntil(() => DashcamService.processOwnerCurrentForTest == null, 'the process owner being released in tearDown');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    for (var attempt = 0; ; attempt++) {
      try {
        dir.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  group('Fase 16.2-R4.3-R2.6.21 — the fact the dashcam status reads is published when it changes', () {
    test(
      'X394 — a rotation\'s restart START outlives its deadline and then succeeds: the listener is told "unavailable" AT the '
      'deadline and "available" when the START returns, once each, and never ahead of the fact; the run then rotates '
      'normally and that tells nobody',
      () async {
        await record(startDeadline: shortDeadline);
        final gate = await rotateAndHoldTheRestart();
        try {
          expect(told, isEmpty, reason: 'before the deadline nothing changed (the historical contract, unchanged)');
          await waitUntil(() => told.isNotEmpty, 'the deadline being told');
          expect(told, [true], reason: 'the deadline is told');
          expect(service.cameraKnownUnavailable, isTrue);
          expect(cameraRecording(), isFalse, reason: 'and it is the truth: nothing is being recorded');

          gate.complete();
          await waitUntil(() => service.queuedRotationCountForTest == 0 && cameraRecording(), 'the late success settling');
          expect(told, [true, false], reason: 'the late success is told');
          expect(service.cameraKnownUnavailable, isFalse);
          expectToldInStep();

          await rotateOnce();
          expect(told, [true, false], reason: 'an ordinary rotation changes nothing to tell');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X395 — the restart START outlives its deadline and then FAILS: the listener is told "unavailable" at the deadline and '
      'is never told "available" afterwards — the camera did not come back',
      () async {
        await record(startDeadline: shortDeadline);
        final gate = await rotateAndHoldTheRestart();
        await waitUntil(() => told.isNotEmpty, 'the deadline being told');
        expect(told, [true]);

        gate.completeError(CameraException('start_failed', 'the restart START failed, late'));
        await waitUntil(() => service.queuedRotationCountForTest == 0, 'the late failure settling');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(told, [true], reason: 'nothing tells "available" between the overdue mark and the failure it ended in');
        expect(service.cameraKnownUnavailable, isTrue, reason: 'the camera stays unavailable');
        expect(service.isRecording, isFalse, reason: 'and the run is over (R2.6.20, unchanged)');
        expectToldInStep();
      },
    );

    test(
      'X396 — the restart START fails within its deadline: the listener is told "unavailable" once, by the failure itself',
      () async {
        await record();
        fakePlatform.failStartVideoCapturingWith = CameraException('start_failed', 'the restart START failed at once');
        timerTicks.last();
        await waitUntil(() => service.queuedRotationCountForTest == 0 && count('startVideoCapturing') == 2, 'the failed rotation ending');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(told, [true]);
        expect(service.cameraKnownUnavailable, isTrue);
        expectToldInStep();
      },
    );

    test(
      'X397 — a rotation\'s STOP outlives its deadline (R2.6.14) and then succeeds: the listener is told "unavailable" at the '
      'stop\'s deadline and "available" when it settles; the restart that follows is in time and tells nothing more',
      () async {
        await record(stopDeadline: shortDeadline);
        final stopGate = Completer<void>();
        held.add(stopGate);
        fakePlatform.pendingStopVideoRecording = stopGate;
        try {
          timerTicks.last();
          await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation\'s STOP being issued and held');
          fakePlatform.pendingStopVideoRecording = null;
          await waitUntil(() => told.isNotEmpty, 'the stop\'s deadline being told');
          expect(told, [true]);
          expect(cameraRecording(), isTrue, reason: 'the old segment is still being recorded: the stop has not returned');

          stopGate.complete();
          await waitUntil(() => service.queuedRotationCountForTest == 0 && count('startVideoCapturing') == 2 && cameraRecording(), 'the late stop and the restart');
          expect(told, [true, false]);
          expect(service.lastLateRotationDecisionForTest, 'resume', reason: 'R2.6.14, unchanged');
          expectToldInStep();
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X398 — the app going to the background is told; going there again changes nothing and tells nobody; a fresh '
      'initialize() is told',
      () async {
        await record();
        service.notifyAppBackgrounded();
        expect(told, [true], reason: 'told synchronously, by the call that changed it');
        service.notifyAppBackgrounded();
        expect(told, [true], reason: 'a write that does not change the fact tells nobody');

        await service.initialize();
        expect(told, [true, false]);
        expect(service.cameraKnownUnavailable, isFalse);
        expectToldInStep();
      },
    );

    test(
      'X399 — a service disposed while its restart START is overdue keeps publishing without failing: what the late '
      'settlement changes after dispose() is told in step, and nothing throws',
      () async {
        await record(startDeadline: shortDeadline);
        final gate = await rotateAndHoldTheRestart();
        await waitUntil(() => told.isNotEmpty, 'the deadline being told');
        final disposing = service.dispose();
        gate.complete();
        await disposing.timeout(patience);
        await waitUntil(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(told.first, isTrue);
        expect(told.last, service.cameraKnownUnavailable, reason: 'the last value told is the fact as it stands');
        expectToldInStep();
      },
    );
  });
}
