// Fase 16.2-R4.3-R2.6.14 — late STOP settlement / automatic rotation recovery,
// at the DashcamService level.
//
// Physical finding (Samsung SM-A326B, 2026-10-07): 1 of 24 segment rotations
// never recorded again. The rotation's own native stop took 6.95 s against the
// 5 s stopVideoRecordingTimeout and then SUCCEEDED; the deadline had already
// marked the camera unavailable for good, so the next segment never started
// and the session went on without video until the user intervened.
//
// The contract pinned here: for a rotation the deadline is a liveness and
// diagnostic signal only. The raw native stop stays the physical authority;
// when it settles, the rotation starts the next segment by itself — unless
// something changed while it waited (a stop, a background, a new generation, a
// failure), in which case it must NOT.
//
// How the tests wait: by cause. The fake camera's stop is held on a Completer
// the test releases only after it has OBSERVED the service report the deadline
// (rotationStopOverdue), so "the stop returned after the deadline" is a fact of
// the run, never an assumption about elapsed time. The three tests with the
// product's own numbers (5 s; 5.1 / 7 / 10 s) additionally hold the stop until
// the stated real time has passed.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
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

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  DashcamConfig config() => DashcamConfig(
    cameraSelection: CameraSelection.rear,
    storageQuotaMb: 1024,
    audioEnabled: false,
    resolution: VideoResolution.hd720,
    frameRate: 30,
    enabled: true,
  );

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;

  /// The largest number of cameras that were open at the same time, from the
  /// fake platform's own call order (a camera opens at
  /// `createCameraWithSettings` and closes at `dispose`).
  int maxCamerasOpenAtOnce() {
    var open = 0;
    var max = 0;
    for (final call in fakePlatform.calls) {
      if (call == 'createCameraWithSettings') open++;
      if (call == 'dispose') open--;
      if (open > max) max = open;
    }
    return max;
  }

  /// Waits for [condition] and fails the test, naming [what], if it never holds.
  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail(
      'never happened within ${within.inMilliseconds} ms: $what '
      '(overdue=${service.rotationStopOverdue}, pendingStop=${service.hasPendingNativeStop}, unavailable=${service.cameraKnownUnavailable}, '
      'isRecording=${service.isRecording}, lateDecision=${service.lastLateRotationDecisionForTest}, calls=${fakePlatform.calls.join(',')})',
    );
  }

  /// Observes [window] of real time and fails if [condition] ever holds —
  /// for facts that must stay false ("no second native start").
  Future<void> neverDuring(Duration window, bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      if (condition()) fail('must not happen, but did after ${clock.elapsedMilliseconds} ms: $what (calls=${fakePlatform.calls.join(',')})');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A service that rotates every [segment], recording already started. The
  /// native stop of the rotation(s) to come is held on the returned gate.
  Future<Completer<void>> startWithHeldRotationStop({required Duration segment, required Duration deadline}) async {
    service = DashcamService(config: config(), segmentDuration: segment, stopVideoRecordingTimeout: deadline);
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'session-A');
    final gate = Completer<void>();
    fakePlatform.pendingStopVideoRecording = gate;
    return gate;
  }

  /// The rotation tick issued its native stop, and the service reported it past
  /// the deadline while it is still in flight.
  Future<void> waitForOverdueRotationStop({Duration within = const Duration(seconds: 5)}) async {
    await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation tick issuing its native stop', within: within);
    await waitUntil(() => service.rotationStopOverdue, 'the rotation stop being reported as overdue', within: within);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dashcam_rotation_late_stop_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    // Last-resort barrier, as in dashcam_service_test.dart: every test below
    // releases its own gates in a `finally`; this only releases an idle
    // controller and proves the process-wide owner is free for the next test.
    final gate = fakePlatform.pendingStopVideoRecording;
    if (gate != null && !gate.isCompleted) gate.complete();
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

  group('Fase 16.2-R4.3-R2.6.14 — a rotation whose stop outlives the deadline and then succeeds', () {
    test(
      'X212 — the deadline only marks the stop as slow; when the raw stop returns, the next segment starts by itself on the '
      'SAME controller, and the service is healthy again',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final firstRecording = service.activeRecordingId;
          await waitForOverdueRotationStop();

          // Past the deadline, stop still in flight: degraded, and nothing new was issued.
          expect(service.hasPendingNativeStop, isTrue, reason: 'the raw native stop is still the authority');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'no video is being captured: the published state must say so');
          expect(service.isRecording, isTrue, reason: 'the intent to keep recording is not abandoned');
          expect(count('startVideoCapturing'), 1, reason: 'no native start while the stop is in flight');
          expect(count('createCameraWithSettings'), 1, reason: 'no other camera');
          expect(service.lateRotationSettlementCountForTest, 0, reason: 'nothing is decided at the deadline');
          expect(service.clips, isEmpty);

          gate.complete();
          await waitUntil(() => count('startVideoCapturing') == 2, 'the next segment starting by itself after the late stop returned');

          expect(service.lastLateRotationDecisionForTest, 'resume');
          expect(service.lateRotationSettlementCountForTest, 1);
          expect(service.previewController, same(controller), reason: 'same controller: no re-initialization, no second camera');
          expect(count('createCameraWithSettings'), 1);
          expect(count('stopVideoRecording'), 1, reason: 'one stop for one Recording');
          await waitUntil(() => controller.value.isRecordingVideo, 'the controller reporting the new Recording');
          expect(service.rotationStopOverdue, isFalse);
          expect(service.hasPendingNativeStop, isFalse);
          expect(service.cameraKnownUnavailable, isFalse, reason: 'slow is not lost: nothing keeps the camera marked unavailable');
          expect(service.isRecording, isTrue);
          expect(service.clips, hasLength(1), reason: 'the late stop\'s own clip was collected exactly once');
          expect(service.clips.single.producerToken, 'session-A');
          expect(service.activeRecordingId, isNot(firstRecording), reason: 'a new Recording, with its own identity');
          expect(errors, isEmpty, reason: 'a slow stop that succeeds is not an error, at the deadline or afterwards');

          // The rotation keeps working afterwards: the next tick stops the new
          // Recording and starts a third one.
          await waitUntil(() => count('startVideoCapturing') >= 3, 'the following rotation', within: const Duration(seconds: 3));
          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop, 'the final stop settling');
          expect(service.clips.length, greaterThanOrEqualTo(3));
          expect(service.clips.every((c) => c.producerToken == 'session-A'), isTrue, reason: 'every segment keeps the producer of the Recording chain');
          expect(maxCamerasOpenAtOnce(), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
    );

    // The product's own numbers: stopVideoRecordingTimeout = 5 s (the default),
    // and a stop that takes 5.1 s, 7 s and 10 s. On the phone it took 6.95 s.
    for (final (id, hold, segment) in [
      ('X213', Duration(milliseconds: 5100), Duration(milliseconds: 5600)),
      ('X214', Duration(seconds: 7), Duration(milliseconds: 7500)),
      ('X215', Duration(seconds: 10), Duration(milliseconds: 10500)),
    ]) {
      test(
        '$id — production deadline (5 s): a rotation stop that takes ${hold.inMilliseconds / 1000} s converges and the next segment '
        'starts automatically',
        () async {
          service = DashcamService(config: config(), segmentDuration: segment);
          expect(service.stopVideoRecordingTimeout, const Duration(seconds: 5), reason: 'this test is about the product\'s own default');
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'session-A');
          final controller = service.previewController!;
          final gate = Completer<void>();
          fakePlatform.pendingStopVideoRecording = gate;
          try {
            await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation tick issuing its native stop', within: segment + const Duration(seconds: 5));
            final sinceStop = Stopwatch()..start();
            await waitUntil(() => service.rotationStopOverdue, 'the 5 s deadline being reported', within: const Duration(seconds: 8));
            expect(sinceStop.elapsedMilliseconds, greaterThanOrEqualTo(4900), reason: 'reported at the deadline, not before');
            expect(service.cameraKnownUnavailable, isTrue);
            expect(count('startVideoCapturing'), 1);

            final remaining = hold - sinceStop.elapsed;
            if (remaining > Duration.zero) await Future<void>.delayed(remaining);
            expect(count('startVideoCapturing'), 1, reason: 'nothing starts while the stop is in flight, however long it takes');
            expect(count('createCameraWithSettings'), 1);
            expect(service.hasPendingNativeStop, isTrue);
            gate.complete();

            await waitUntil(() => count('startVideoCapturing') == 2, 'the next segment starting by itself', within: const Duration(seconds: 3));
            expect(service.lastLateRotationDecisionForTest, 'resume');
            expect(service.previewController, same(controller));
            expect(count('createCameraWithSettings'), 1);
            expect(service.cameraKnownUnavailable, isFalse);
            expect(service.clips, hasLength(1));
          } finally {
            if (!gate.isCompleted) gate.complete();
          }
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }

    test(
      'X216 — the file processing (not the native call) is what outlives the deadline: same soft handling, same automatic restart',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 400), stopVideoRecordingTimeout: const Duration(milliseconds: 60));
        final processingGate = Completer<void>();
        var held = 0;
        // The seam sits after the clip is published and before the stop's own
        // processing ends: holding it keeps the operation unresolved exactly as
        // a slow file copy would.
        service.afterClipPublishedHookForTest = (_) async {
          if (held++ == 0) await processingGate.future;
        };
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'session-A');
        try {
          await waitUntil(() => count('stopVideoRecording') == 1 && held == 1, 'the rotation stop returning natively and entering processing');
          await waitUntil(() => service.rotationStopOverdue, 'the deadline being reported while processing is still running');
          expect(service.cameraKnownUnavailable, isTrue);
          expect(count('startVideoCapturing'), 1);

          processingGate.complete();
          await waitUntil(() => count('startVideoCapturing') == 2, 'the next segment starting once processing finished');
          expect(service.lastLateRotationDecisionForTest, 'resume');
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.rotationStopOverdue, isFalse);
        } finally {
          if (!processingGate.isCompleted) processingGate.complete();
        }
      },
    );

    test(
      'X217 — two slow rotations in a row both resume: the degraded state never sticks',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 400), stopVideoRecordingTimeout: const Duration(milliseconds: 60));
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'session-A');
        final first = Completer<void>();
        final second = Completer<void>();
        try {
          fakePlatform.pendingStopVideoRecording = first;
          await waitUntil(() => count('stopVideoRecording') == 1, 'rotation 1 issuing its stop');
          await waitUntil(() => service.rotationStopOverdue, 'rotation 1 overdue');
          fakePlatform.pendingStopVideoRecording = second; // held for the NEXT stop
          first.complete();
          await waitUntil(() => count('startVideoCapturing') == 2, 'segment 2 starting after the first late stop');
          expect(service.lateRotationSettlementCountForTest, 1);
          expect(service.cameraKnownUnavailable, isFalse);

          await waitUntil(() => count('stopVideoRecording') == 2, 'rotation 2 issuing its stop', within: const Duration(seconds: 3));
          await waitUntil(() => service.rotationStopOverdue, 'rotation 2 overdue');
          expect(count('startVideoCapturing'), 2);
          second.complete();
          await waitUntil(() => count('startVideoCapturing') == 3, 'segment 3 starting after the second late stop');
          expect(service.lateRotationSettlementCountForTest, 2);
          expect(service.lastLateRotationDecisionForTest, 'resume');
          expect(service.cameraKnownUnavailable, isFalse);
          expect(count('createCameraWithSettings'), 1);
        } finally {
          if (!first.isCompleted) first.complete();
          if (!second.isCompleted) second.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.14 — a stop that never returns stays fail-closed', () {
    test(
      'X218 — no restart, no second camera, degraded for as long as it lasts; later ticks change nothing',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 150), deadline: const Duration(milliseconds: 60));
        try {
          await waitForOverdueRotationStop();
          // Several segment periods go by with the stop still in flight.
          await neverDuring(
            const Duration(milliseconds: 700),
            () => count('startVideoCapturing') != 1 || count('createCameraWithSettings') != 1 || count('stopVideoRecording') != 1,
            'any native start, stop or camera creation while the stop never returns',
          );
          expect(service.rotationStopOverdue, isTrue);
          expect(service.hasPendingNativeStop, isTrue);
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.lateRotationSettlementCountForTest, 0, reason: 'nothing settled, so nothing was decided');
          expect(service.clips, isEmpty);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X219 — a recovery attempt (initialize, as a foreground resume or a retry would issue) while the stop never returns cannot '
      'open a camera: it stays behind the stop, and its own deadline only ends its caller\'s wait',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 400),
          stopVideoRecordingTimeout: const Duration(milliseconds: 60),
          initializeCameraTimeout: const Duration(milliseconds: 150),
        );
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'session-A');
        final controller = service.previewController!;
        final gate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = gate;
        try {
          await waitForOverdueRotationStop();

          Object? recoveryError;
          await service.initialize().catchError((Object e) => recoveryError = e);
          expect(recoveryError, isNotNull, reason: 'the recovery\'s own presentation deadline elapsed behind the stop');
          expect(count('createCameraWithSettings'), 1, reason: 'no camera was opened for it');
          expect(service.previewController, same(controller), reason: 'the old controller is untouched while its stop is in flight');
          expect(service.hasPendingNativeStop, isTrue);
          await neverDuring(const Duration(milliseconds: 300), () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 1, 'a camera or a start while the stop never returns');

          // Only when the stop finally returns does anything move — and the
          // late rotation does not start: a re-initialization was requested.
          gate.complete();
          await waitUntil(() => !service.hasPendingNativeStop, 'the stop settling');
          await waitUntil(() => service.previewController == null, 'the expired recovery releasing the old controller');
          expect(count('startVideoCapturing'), 1, reason: 'the late rotation must not start on a controller that is being replaced');
          expect(count('createCameraWithSettings'), 1, reason: 'the expired recovery opens nothing either');
          expect(maxCamerasOpenAtOnce(), 1);
          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'and this is why it did not start');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.14 — what happened while the stop was in flight decides; the late rotation never overrides it', () {
    test(
      'X220 — the user stops recording while the slow rotation stop is pending: the stop returns to its caller at once, and '
      'when the raw stop settles nothing restarts',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        try {
          await waitForOverdueRotationStop();

          final outcome = service.beginStopLoopRecording();
          await outcome.presentation.timeout(const Duration(seconds: 1));
          final handle = await outcome.handle.timeout(const Duration(seconds: 1));
          expect(handle, isNotNull, reason: 'the session stop adopts the rotation\'s own physical stop: one Recording, one stop');
          expect(service.isRecording, isFalse);
          expect(count('stopVideoRecording'), 1);

          gate.complete();
          await handle!.settlement;
          await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
          await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1, 'a native start after the user stopped');
          expect(service.clips, hasLength(1), reason: 'the clip of the stopped Recording is still collected');
          expect(service.isRecording, isFalse);
          expect(service.previewController!.value.isRecordingVideo, isFalse);
          expect(count('stopVideoRecording'), 1);
          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'and this is why it did not start');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X221 — same, with the stop requested BEFORE the deadline elapses (the rotation stop is slow, not yet overdue)',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 150));
        try {
          await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation tick issuing its native stop');
          expect(service.rotationStopOverdue, isFalse, reason: 'test setup: still within the deadline');
          final stopping = service.stopLoopRecording();
          await waitUntil(() => service.rotationStopOverdue, 'the deadline elapsing with the stop still in flight');
          await stopping.timeout(const Duration(seconds: 1));

          gate.complete();
          await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
          await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1, 'a native start after the user stopped');
          expect(service.clips, hasLength(1));
          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'and this is why it did not start');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X222 — the app goes to the background while the slow stop is pending: lifecycle is re-read when the stop settles, nothing '
      'restarts on that controller, and the camera stays unavailable until a fresh initialize',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        try {
          final controller = service.previewController!;
          await waitForOverdueRotationStop();
          service.notifyAppBackgrounded();

          gate.complete();
          await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
          await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1, 'a native start while backgrounded');
          expect(service.rotationStopOverdue, isFalse, reason: 'the stop itself did settle');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'the background mark is a different, lasting cause');
          expect(service.isRecording, isTrue, reason: 'the intent survives for the foreground recovery, as for any background loss');
          expect(service.clips, hasLength(1));
          expect(service.lastLateRotationDecisionForTest, 'cameraUnavailable', reason: 'and this is why it did not start');

          // Foreground recovery, exactly the controller's own sequence: a fresh
          // camera — the old one released first — then a real start.
          await service.initialize();
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.previewController, isNot(same(controller)));
          await service.startLoopRecording(clipOwnerToken: 'session-A');
          expect(count('startVideoCapturing'), 2);
          expect(count('createCameraWithSettings'), 2);
          expect(maxCamerasOpenAtOnce(), 1, reason: 'the new camera opened only after the old one was disposed');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X223 — same, with the background arriving BEFORE the deadline elapses',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 150));
        try {
          await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation tick issuing its native stop');
          expect(service.rotationStopOverdue, isFalse, reason: 'test setup: still within the deadline');
          service.notifyAppBackgrounded();
          await waitUntil(() => service.rotationStopOverdue, 'the deadline elapsing with the stop still in flight');

          gate.complete();
          await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
          await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1, 'a native start while backgrounded');
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.lastLateRotationDecisionForTest, 'cameraUnavailable', reason: 'and this is why it did not start');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X224 — a new camera generation is requested while the slow stop is pending: the late continuation does not start on the '
      'stale generation; the new one opens only after the old stop settled and the old camera was released',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        Future<void>? recovery;
        try {
          final staleController = service.previewController!;
          await waitForOverdueRotationStop();

          var recoveryDone = false;
          recovery = service.initialize(lifecycleGeneration: 2).whenComplete(() => recoveryDone = true);
          await neverDuring(const Duration(milliseconds: 200), () => recoveryDone || count('createCameraWithSettings') != 1, 'the new generation opening while the old stop is in flight');
          expect(service.previewController, same(staleController));

          final callsAtRelease = fakePlatform.calls.length;
          gate.complete();
          await recovery;

          final afterRelease = fakePlatform.calls.skip(callsAtRelease).toList();
          expect(afterRelease, isNot(contains('startVideoCapturing')), reason: 'nothing started on the stale generation');
          expect(afterRelease.indexOf('dispose'), lessThan(afterRelease.indexOf('createCameraWithSettings')), reason: 'old camera released before the new one opens');
          expect(service.previewController, isNot(same(staleController)));
          expect(count('createCameraWithSettings'), 2);
          expect(maxCamerasOpenAtOnce(), 1);
          expect(service.clips, hasLength(1), reason: 'the stale generation\'s clip is still collected');
          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'and this is why nothing started on it');

          // The new generation records normally.
          await service.startLoopRecording(clipOwnerToken: 'session-A');
          expect(count('startVideoCapturing'), 2);
          expect(service.previewController!.value.isRecordingVideo, isTrue);
        } finally {
          if (!gate.isCompleted) gate.complete();
          if (recovery != null) await recovery.catchError((_) {});
        }
      },
    );

    test(
      'X225 — recording is stopped and started again while the slow stop is pending: the new START owns starting — exactly one '
      'native start follows, and it succeeds',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        try {
          await waitForOverdueRotationStop();

          await service.stopLoopRecording().timeout(const Duration(seconds: 1));
          Object? startError;
          final starting = service.startLoopRecording(clipOwnerToken: 'session-B').catchError((Object e) => startError = e);
          expect(service.isRecording, isTrue, reason: 'test setup: the new START\'s intent is already visible to the late rotation');

          gate.complete();
          await starting;
          expect(startError, isNull, reason: 'the new START must not find a Recording the late rotation started in its place');
          expect(service.lastLateRotationDecisionForTest, 'supersededByNewerStart');
          expect(count('startVideoCapturing'), 2, reason: 'one start for the first Recording, one for the new START — none from the late rotation');
          expect(service.previewController!.value.isRecordingVideo, isTrue);

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop, 'the final stop settling');
          expect(service.clips.map((c) => c.producerToken), ['session-A', 'session-B']);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X226 — the late stop ends in an ERROR: no restart, the camera is marked unavailable, the failure is reported once, and '
      'no second stop is ever issued for that Recording',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        final errors = <String>[];
        final sub = service.errors.listen(errors.add);
        try {
          await waitForOverdueRotationStop();
          expect(errors, isEmpty, reason: 'the deadline itself is not an error');

          gate.completeError(CameraException('stop_failed', 'forced late failure for this test'));
          await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
          await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1, 'a native start after a failed stop');
          expect(service.rotationStopOverdue, isFalse);
          expect(service.cameraKnownUnavailable, isTrue, reason: 'a stop that failed leaves the generation untrusted');
          expect(errors, hasLength(1), reason: 'the stop\'s own failure, once — and no failed restart on top of it');
          expect(service.clips, isEmpty);
          expect(service.lastLateRotationDecisionForTest, 'stopFailed', reason: 'and this is why it did not start');

          await service.stopLoopRecording();
          expect(count('stopVideoRecording'), 1, reason: 'a terminally failed stop is never retried');
        } finally {
          if (!gate.isCompleted) gate.complete();
          await sub.cancel();
        }
      },
    );

    test(
      'X237 — a targeted cleanup aimed at a DIFFERENT Recording arrives while the slow stop is pending: it is a no-op, as '
      'always, and does not cancel the rotation — the next segment still starts',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        try {
          final current = service.activeRecordingId!;
          await waitForOverdueRotationStop();

          final outcome = service.beginStopLoopRecording(expectedRecordingId: current + 100, expectedController: service.previewController);
          await outcome.presentation.timeout(const Duration(seconds: 1));
          expect(await outcome.handle, isNull, reason: 'a stale caller\'s target does not match: nothing is adopted');
          expect(service.isRecording, isTrue, reason: 'a mismatched targeted stop changes nothing');

          gate.complete();
          await waitUntil(() => count('startVideoCapturing') == 2, 'the next segment starting by itself');
          expect(service.lastLateRotationDecisionForTest, 'resume');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X238 — a targeted cleanup aimed at THIS Recording arrives while the slow stop is pending: it adopts the rotation\'s own '
      'stop (one Recording, one stop), and nothing restarts',
      () async {
        final gate = await startWithHeldRotationStop(segment: const Duration(milliseconds: 400), deadline: const Duration(milliseconds: 60));
        try {
          final current = service.activeRecordingId!;
          await waitForOverdueRotationStop();

          final outcome = service.beginStopLoopRecording(expectedRecordingId: current, expectedController: service.previewController);
          await outcome.presentation.timeout(const Duration(seconds: 1));
          final handle = await outcome.handle;
          expect(handle, isNotNull);
          expect(handle!.recordingId, current);
          expect(service.isRecording, isFalse);

          gate.complete();
          await handle.settlement;
          await waitUntil(() => service.lateRotationSettlementCountForTest == 1, 'the late rotation being decided');
          await neverDuring(const Duration(milliseconds: 300), () => count('startVideoCapturing') != 1, 'a native start after the targeted cleanup');
          expect(count('stopVideoRecording'), 1);
          expect(service.clips, hasLength(1));
          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted', reason: 'and this is why it did not start');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.14 — what did not change', () {
    test(
      'X227 — a rotation whose stop meets the deadline is not a late settlement: no degraded state, no late decision',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 150), stopVideoRecordingTimeout: const Duration(seconds: 2));
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'session-A');
        var sawOverdue = false;
        var sawUnavailable = false;
        final watch = Timer.periodic(const Duration(milliseconds: 2), (_) {
          sawOverdue = sawOverdue || service.rotationStopOverdue;
          sawUnavailable = sawUnavailable || service.cameraKnownUnavailable;
        });
        try {
          await waitUntil(() => count('startVideoCapturing') >= 3, 'two ordinary rotations');
          expect(sawOverdue, isFalse);
          expect(sawUnavailable, isFalse);
          expect(service.lateRotationSettlementCountForTest, 0);
          expect(service.lastLateRotationDecisionForTest, isNull);
        } finally {
          watch.cancel();
        }
      },
    );

    test(
      'X228 — an EXPLICIT stop that outlives the deadline keeps the pre-existing meaning: the camera stays marked unavailable '
      'after the late success (nothing resumes after a stop), and it is never a rotation overrun',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: const Duration(milliseconds: 60));
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'session-A');
        final gate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = gate;
        try {
          await service.stopLoopRecording();
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.rotationStopOverdue, isFalse);
          gate.complete();
          await waitUntil(() => !service.hasPendingNativeStop, 'the explicit stop settling');
          expect(service.clips, hasLength(1));
          expect(service.cameraKnownUnavailable, isTrue, reason: 'unchanged: only a fresh initialize clears it after an explicit stop\'s overrun');
          expect(service.lateRotationSettlementCountForTest, 0);
          expect(count('startVideoCapturing'), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X229 — a TEARDOWN whose stop outlives the deadline (releaseIdleCamera during recording) is unchanged too, and the camera '
      'is released once the stop settles',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: const Duration(milliseconds: 60));
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'session-A');
        final gate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = gate;
        try {
          await service.releaseIdleCamera();
          expect(service.hasPendingNativeStop, isTrue);
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.rotationStopOverdue, isFalse);
          expect(count('dispose'), 0, reason: 'the controller is not disposed over a stop still in flight');
          gate.complete();
          await waitUntil(() => service.previewController == null, 'the camera being released after the stop settled');
          expect(service.clips, hasLength(1));
          expect(service.lateRotationSettlementCountForTest, 0);
          expect(count('startVideoCapturing'), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );
  });
}
