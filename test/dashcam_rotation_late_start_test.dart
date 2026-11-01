// Fase 16.2-R4.3-R2.6.20 — late rotation START settlement / automatic rearm
// (N2), at the DashcamService level.
//
// The defect (independent review of R2.6.17, N2; traced in this round with the
// product's own numbers): a segment rotation stops its segment, the native
// START of the next one outlives the 5 s startVideoRecordingTimeout and then
// SUCCEEDS. The deadline had marked the camera unavailable for good, so the
// late Recording went on as one endless segment: every later tick found the
// mark and neither stopped nor restarted anything, and the published state
// stayed "camera unavailable" until something re-initialized the camera.
//
// The contract pinned here — the START-side counterpart of R2.6.14: for the
// restart of a rotation the deadline is a liveness and diagnostic signal only.
// The raw native START stays the physical authority; when it settles, the
// rotation decides from the state as it is THEN:
//  * nothing changed — the Recording is the run's next segment, the published
//    state is healthy again, and the run's timer counts the next period from
//    that settlement;
//  * something changed (a stop, a dispose, a new generation, a newer START, a
//    background) — the Recording is NOT the run's: whoever is queued to stop it
//    does, or, when nobody is, the rotation stops it itself before it lets go
//    of the queue;
//  * the START failed — nothing was recorded, and the run ends there instead of
//    staying "wanted" with nothing recording.
// A START of startLoopRecording() that outlives its deadline is a different
// event and is unchanged (X377).
//
// How the tests wait and what they assert first: by cause, and by what the
// camera and the PUBLISHED state do. The fake camera's START is held on a
// Completer the test releases only after it has observed the service publish
// the camera as unavailable — which, with that START the only thing in flight,
// only its deadline can produce — so "the START returned after the deadline" is
// a fact of the run, never an assumption about elapsed time. The tests with the
// product's own numbers (5 s; 5.1 / 6.95 / 7 / 10 s) additionally hold the START
// until the stated real time has passed. What the service itself SAYS about a
// late restart (rotationRestartOverdue, the decision it took) is asserted last
// in each test, after the behaviour it explains. Rotation ticks are delivered by
// hand (segmentTimerArmedHookForTest) unless a test is about the timer's own
// real cadence, and then it says so.
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

  /// One closure per segment timer the service armed, in order: calling it
  /// delivers one tick of THAT timer.
  final timerTicks = <void Function()>[];

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  /// Long enough that the real segment timer never fires within a test.
  const manualTicksOnly = Duration(minutes: 10);

  /// A START deadline short enough to elapse within a test. It only ever
  /// elapses over a native START the test holds on a gate, so it cannot fire by
  /// accident.
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
  List<Object?> producers() => service.clips.map((c) => c.producerToken).toList();
  List<int?> recordingIds() => service.clips.map((c) => c.recordingId).toList();

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

  String state() =>
      'unavailable=${service.cameraKnownUnavailable}, isRecording=${service.isRecording}, cameraRecording=${cameraRecording()}, '
      'activeRecording=${service.activeRecordingId}, timer=${service.hasActiveSegmentTimerForTest}, timersArmed=${timerTicks.length}, '
      'rotationsQueued=${service.queuedRotationCountForTest}, pendingStop=${service.hasPendingNativeStop}, '
      'restartOverdue=${service.rotationRestartOverdue}, lateRestarts=${service.lateRestartSettlementCountForTest}, '
      'lateDecision=${service.lastLateRestartDecisionForTest}, calls=${fakePlatform.calls.join(',')}';

  /// Waits for [condition] and fails the test, naming [what], if it never holds.
  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail('never happened within ${within.inMilliseconds} ms: $what (${state()})');
  }

  /// Observes [window] of real time and fails if [condition] ever holds — for
  /// facts that must stay false ("no native stop yet").
  Future<void> neverDuring(Duration window, bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      if (condition()) fail('must not happen, but did after ${clock.elapsedMilliseconds} ms: $what (${state()})');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) fail('must not happen, but did by the end of ${window.inMilliseconds} ms: $what (${state()})');
  }

  /// Everything the service had queued has run: no rotation waiting or
  /// running, no native stop in flight, no START attempt settling.
  Future<void> waitForTheQueueToDrain() =>
      waitUntil(() => service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop && !service.startAttemptSettling, 'the service\'s queue draining');

  /// A service recording its first segment as 'session-A'. Ticks are delivered
  /// by hand unless [segment] is given; the START deadline is the product's own
  /// (5 s) unless [startDeadline] is given.
  Future<void> record({Duration segment = manualTicksOnly, Duration? startDeadline, Duration? stopDeadline, Duration? initializeDeadline}) async {
    service = DashcamService(
      config: config(),
      segmentDuration: segment,
      startVideoRecordingTimeout: startDeadline ?? const Duration(seconds: 5),
      stopVideoRecordingTimeout: stopDeadline ?? const Duration(seconds: 5),
      initializeCameraTimeout: initializeDeadline ?? const Duration(seconds: 10),
    );
    service.segmentTimerArmedHookForTest = timerTicks.add;
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'session-A');
    expect(timerTicks, hasLength(1), reason: 'test setup: the run armed its one timer');
    expect(cameraRecording(), isTrue);
  }

  /// A rotation of the current run: its tick is delivered, it stops the segment
  /// (within the stop deadline) and its restart START is issued and HELD on the
  /// returned gate. Only that START is held.
  Future<Completer<void>> rotateAndHoldTheRestart() async {
    final startsBefore = count('startVideoCapturing');
    final stopsBefore = count('stopVideoRecording');
    final gate = Completer<void>();
    fakePlatform.pendingStartVideoCapturing = gate;
    timerTicks.last();
    await waitUntil(
      () => count('stopVideoRecording') == stopsBefore + 1 && !service.hasPendingNativeStop && count('startVideoCapturing') == startsBefore + 1,
      'the rotation stopping its segment and issuing the restart START',
      within: const Duration(seconds: 8),
    );
    fakePlatform.pendingStartVideoCapturing = null;
    expect(cameraRecording(), isFalse, reason: 'test setup: the old segment is over and the new one has not started');
    return gate;
  }

  /// The restart START of the rotation is past its deadline and still in
  /// flight. Waited for by the state the service PUBLISHES — the camera
  /// reported unavailable — which, with the held START the only thing in
  /// flight, only its deadline can produce.
  Future<void> waitForTheRestartToPassItsDeadline({Duration within = const Duration(seconds: 5)}) => waitUntil(
    () => service.cameraKnownUnavailable,
    'the camera being reported unavailable while the restart START is in flight (its deadline)',
    within: within,
  );

  /// The held START has returned and the rotation that issued it has run to
  /// its end — along with any tick that was waiting behind it.
  Future<void> waitForTheRotationToEnd() => waitUntil(() => service.queuedRotationCountForTest == 0, 'the rotation ending after its native START returned');

  /// What the service itself says about the late restart: decided exactly
  /// [times] time(s), and why. Asserted LAST, after the behaviour it explains.
  void expectTheServiceDecided(String decision, {int times = 1}) {
    expect(service.lateRestartSettlementCountForTest, times, reason: 'a late restart is decided exactly once (${state()})');
    expect(service.lastLateRestartDecisionForTest, decision, reason: 'and this is why');
    expect(service.rotationRestartOverdue, isFalse, reason: '"overdue" ends when the native call returns');
  }

  /// One ordinary rotation, delivered through the timer armed LAST: one stop,
  /// one start, both within their deadlines, and a new Recording.
  Future<void> expectOneNormalRotation(String which) async {
    final startsBefore = count('startVideoCapturing');
    final stopsBefore = count('stopVideoRecording');
    final clipsBefore = service.clips.length;
    final recordingBefore = service.activeRecordingId;
    final lateBefore = service.lateRestartSettlementCountForTest;
    final timersBefore = timerTicks.length;
    timerTicks.last();
    await waitUntil(
      () => count('startVideoCapturing') == startsBefore + 1 && cameraRecording() && service.queuedRotationCountForTest == 0,
      'the $which rotation after the late restart completing',
    );
    expect(count('stopVideoRecording'), stopsBefore + 1, reason: 'the $which rotation ended exactly one segment');
    expect(service.clips, hasLength(clipsBefore + 1), reason: 'and collected its clip');
    expect(service.activeRecordingId, isNot(recordingBefore), reason: 'a new Recording, with its own identity');
    expect(service.isRecording, isTrue);
    expect(service.cameraKnownUnavailable, isFalse);
    expect(timerTicks, hasLength(timersBefore), reason: 'and it arms no timer: the run keeps the one it has');
    expect(service.hasActiveSegmentTimerForTest, isTrue);
    expect(service.lateRestartSettlementCountForTest, lateBefore, reason: 'an ordinary rotation: nothing late about it');
  }

  /// The run ended: nothing is wanted, nothing records, no timer.
  void expectTheRunEnded() {
    expect(service.isRecording, isFalse, reason: 'the run is over (${state()})');
    expect(service.hasActiveSegmentTimerForTest, isFalse, reason: 'and its timer with it');
    expect(cameraRecording(), isFalse, reason: 'nothing is recording');
  }

  setUp(() {
    timerTicks.clear();
    dir = Directory.systemTemp.createTempSync('dashcam_rotation_late_start_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    // Last-resort barrier: every test below releases its own gates in a
    // `finally`; this only releases an idle controller and proves the
    // process-wide owner is free for the next test.
    for (final gate in [fakePlatform.pendingStartVideoCapturing, fakePlatform.pendingStopVideoRecording, fakePlatform.pendingInitializeCamera]) {
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

  group('Fase 16.2-R4.3-R2.6.20 — a rotation whose restart START outlives the deadline and then succeeds', () {
    test(
      'X361 — the deadline only marks the restart as slow; when the raw START returns, the Recording it produced is the run\'s '
      'next segment, the service is healthy again by itself, the run\'s timer is re-armed at that settlement, and the next TWO '
      'rotations complete normally on the SAME controller',
      () async {
        await record(startDeadline: shortDeadline);
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        final controller = service.previewController!;
        final firstRecording = service.activeRecordingId!;
        final epoch = service.startIntentEpochForTest;
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();

          // Past the deadline, START still in flight: degraded, nothing ended, nothing new issued.
          expect(cameraRecording(), isFalse, reason: 'no video is being captured, and the published state says so');
          expect(service.isRecording, isTrue, reason: 'the intent to keep recording is not abandoned at the deadline');
          expect(service.hasActiveSegmentTimerForTest, isTrue, reason: 'nor is the run\'s timer');
          expect(timerTicks, hasLength(1), reason: 'and nothing is armed AT the deadline');
          expect(service.activeRecordingId, firstRecording, reason: 'no Recording exists yet');
          expect(count('startVideoCapturing'), 2, reason: 'the one restart START: no retry');
          expect(count('createCameraWithSettings'), 1, reason: 'no other camera');
          expect(service.startAttemptSettling, isFalse, reason: 'this is not a START of startLoopRecording()');
          expect(errors, isEmpty, reason: 'a slow START is not an error');
          final overdueWhileItWaited = service.rotationRestartOverdue;
          final decidedWhileItWaited = service.lateRestartSettlementCountForTest;

          gate.complete();
          await waitForTheRotationToEnd();

          expect(cameraRecording(), isTrue, reason: 'the late Recording is recording');
          expect(service.cameraKnownUnavailable, isFalse, reason: 'slow is not lost: nothing keeps the camera marked unavailable');
          expect(service.isRecording, isTrue);
          expect(service.previewController, same(controller), reason: 'same controller: no re-initialization, no second camera');
          expect(service.activeRecordingId, isNot(firstRecording), reason: 'the segment that really started has its own identity');
          expect(service.activeRecordingStartEpochForTest, epoch, reason: 'under the run\'s own START epoch');
          expect(service.startIntentEpochForTest, epoch, reason: 'no new START intent was created');
          expect(timerTicks, hasLength(2), reason: 'the run\'s timer was re-armed, once, at the settlement');
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(count('startVideoCapturing'), 2, reason: 'no second START');
          expect(count('stopVideoRecording'), 1, reason: 'and nothing stopped the late Recording');
          expect(count('createCameraWithSettings'), 1);
          expect(errors, isEmpty, reason: 'a slow START that succeeds is not an error, at the deadline or afterwards');

          await expectOneNormalRotation('first');
          await expectOneNormalRotation('second');

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop && !cameraRecording(), 'the final stop settling');
          expect(service.clips, hasLength(4), reason: 'the first segment, the late one, and the two after it');
          expect(producers(), everyElement('session-A'), reason: 'every segment keeps the producer of the Recording chain');
          expect(recordingIds().toSet(), hasLength(4), reason: 'four Recordings, four identities: no clip is attributed twice');
          expect(maxCamerasOpenAtOnce(), 1);
          expect(errors, isEmpty);

          expect(overdueWhileItWaited, isTrue, reason: 'while it waited the service said why it was degraded: its restart START was overdue');
          expect(decidedWhileItWaited, 0, reason: 'and nothing was decided at the deadline');
          expectTheServiceDecided('adopted');
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
    );

    // The product's own numbers: startVideoRecordingTimeout = 5 s (the default),
    // and a restart START that takes 5.1 s, 6.95 s, 7 s and 10 s. 6.95 s is what
    // the phone took for the STOP of a rotation in the R2.6.13 campaign.
    for (final (id, hold) in [
      ('X362', Duration(milliseconds: 5100)),
      ('X363', Duration(milliseconds: 6950)),
      ('X364', Duration(seconds: 7)),
      ('X365', Duration(seconds: 10)),
    ]) {
      test(
        '$id — production deadline (5 s): a restart START that takes ${hold.inMilliseconds / 1000} s converges; the late Recording is '
        'adopted, the timer is re-armed and the next rotation is an ordinary one',
        () async {
          await record();
          expect(service.startVideoRecordingTimeout, const Duration(seconds: 5), reason: 'this test is about the product\'s own default');
          final controller = service.previewController!;
          final firstRecording = service.activeRecordingId!;
          final held = Stopwatch()..start();
          final gate = await rotateAndHoldTheRestart();
          try {
            await neverDuring(const Duration(milliseconds: 4500), () => service.cameraKnownUnavailable, 'the camera reported unavailable before the 5 s deadline');
            await waitForTheRestartToPassItsDeadline(within: const Duration(seconds: 2));
            expect(held.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4900)), reason: 'the deadline is the product\'s 5 s');
            final remaining = hold - held.elapsed;
            if (!remaining.isNegative) await Future<void>.delayed(remaining);
            expect(service.cameraKnownUnavailable, isTrue, reason: 'still in flight, still reported (${held.elapsedMilliseconds} ms)');
            expect(cameraRecording(), isFalse);
            expect(count('startVideoCapturing'), 2, reason: 'no retry while it waits');

            gate.complete();
            await waitForTheRotationToEnd();
            expect(cameraRecording(), isTrue);
            expect(service.cameraKnownUnavailable, isFalse, reason: 'healthy again by itself');
            expect(service.isRecording, isTrue);
            expect(service.previewController, same(controller));
            expect(service.activeRecordingId, isNot(firstRecording));
            expect(timerTicks, hasLength(2), reason: 'timer re-armed at the settlement');
            expect(count('createCameraWithSettings'), 1);

            await expectOneNormalRotation('next');
            await service.stopLoopRecording();
            await waitUntil(() => !service.hasPendingNativeStop && !cameraRecording(), 'the final stop settling');
            expect(service.clips, hasLength(3));
            expect(producers(), everyElement('session-A'));
            expect(maxCamerasOpenAtOnce(), 1);
            expectTheServiceDecided('adopted');
          } finally {
            if (!gate.isCompleted) gate.complete();
          }
        },
        timeout: const Timeout(Duration(seconds: 40)),
      );
    }

    test(
      'X366 — the re-armed timer counts from the SETTLEMENT of the late START (real timer, period 1200 ms): the late segment is not '
      'rotated on the old cadence nor on a period counted from the deadline — it gets a whole period — and afterwards there is ONE '
      'timer: one rotation per period',
      () async {
        const period = Duration(milliseconds: 1200);
        await record(segment: period, startDeadline: const Duration(milliseconds: 300));
        final gate = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = gate;
        try {
          // The first real tick: one stop, then the restart START, held.
          await waitUntil(
            () => count('stopVideoRecording') == 1 && !service.hasPendingNativeStop && count('startVideoCapturing') == 2,
            'the first real tick rotating and its restart START being held',
            within: period + const Duration(seconds: 3),
          );
          fakePlatform.pendingStartVideoCapturing = null;
          await waitForTheRestartToPassItsDeadline();
          // Well past the deadline (300 ms): about 700 ms after the START was issued.
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(count('stopVideoRecording'), 1, reason: 'test setup: the next tick of the old cadence has not fired yet');

          gate.complete();
          await waitUntil(() => cameraRecording() && !service.cameraKnownUnavailable, 'the late Recording recording, with nothing reported unavailable');
          final sinceSettlement = Stopwatch()..start();

          // The old cadence would rotate about 500 ms from here, a period counted
          // from the deadline about 800 ms from here. Neither happens.
          await neverDuring(
            const Duration(milliseconds: 1000),
            () => count('stopVideoRecording') != 1,
            'a rotation of the late segment before a whole period has passed since it started',
          );
          await waitUntil(() => count('stopVideoRecording') == 2 && count('startVideoCapturing') == 3 && cameraRecording(), 'the rotation one period after the settlement');
          expect(sinceSettlement.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 1150)), reason: 'a whole period after the late START settled');

          // One timer: over the next 2.5 periods, exactly two more rotations.
          final stopsAfterFirst = count('stopVideoRecording');
          await Future<void>.delayed(Duration(milliseconds: (period.inMilliseconds * 2.5).round()));
          expect(count('stopVideoRecording') - stopsAfterFirst, 2, reason: 'one rotation per period: there is one timer, not two (${state()})');
          expect(timerTicks, hasLength(2), reason: 'armed by the START, re-armed by the late settlement, and never again');
          expectTheServiceDecided('adopted');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'X367 — ticks of the run that fire while the restart is in flight: one waits, the others add nothing, and after the late '
      'success the one that waited does NOT rotate the segment that has only just begun',
      () async {
        await record(startDeadline: shortDeadline);
        final gate = await rotateAndHoldTheRestart();
        try {
          final fatesBefore = service.rotationTickFatesForTest;
          timerTicks.last();
          expect(service.queuedRotationCountForTest, 2, reason: 'the rotation that is running, and one tick that waits');
          timerTicks.last();
          timerTicks.last();
          expect(service.queuedRotationCountForTest, 2, reason: 'never more than one waiting');
          expect(service.rotationTickFatesForTest['coalesced'], fatesBefore['coalesced']! + 2);
          await waitForTheRestartToPassItsDeadline();
          timerTicks.last();
          expect(service.queuedRotationCountForTest, 2);

          gate.complete();
          await waitForTheQueueToDrain();
          await neverDuring(
            const Duration(milliseconds: 250),
            () => count('stopVideoRecording') != 1 || count('startVideoCapturing') != 2,
            'a stop or a start right after the late success',
          );
          expect(cameraRecording(), isTrue, reason: 'the late segment goes on recording');
          expect(service.isRecording, isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.rotationTickFatesForTest['absorbed'], fatesBefore['absorbed']! + 1, reason: 'the tick that waited was for the segment already replaced');
          expect(timerTicks, hasLength(2));
          await expectOneNormalRotation('next');
          expectTheServiceDecided('adopted');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X368 — the boundary that did not move: a rotation whose restart START returns WITHIN the deadline is an ordinary rotation — '
      'nothing is reported unavailable, and the run keeps the timer it had (the cadence is untouched)',
      () async {
        await record(startDeadline: const Duration(seconds: 2));
        final firstRecording = service.activeRecordingId!;
        final gate = await rotateAndHoldTheRestart();
        try {
          await neverDuring(const Duration(milliseconds: 100), () => service.cameraKnownUnavailable, 'the camera reported unavailable inside the deadline');
          final overdueInsideTheDeadline = service.rotationRestartOverdue;
          gate.complete();
          await waitUntil(() => cameraRecording() && service.queuedRotationCountForTest == 0, 'the restart completing within its deadline');
          expect(timerTicks, hasLength(1), reason: 'the timer is NOT re-armed by an ordinary rotation');
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(service.activeRecordingId, isNot(firstRecording));
          expect(service.isRecording, isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(overdueInsideTheDeadline, isFalse);
          expect(service.lateRestartSettlementCountForTest, 0, reason: 'nothing late: no decision was taken');
          expect(service.lastLateRestartDecisionForTest, isNull);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X369 — slow STOP AND slow START, production deadlines: the rotation\'s stop takes 6.95 s and succeeds, its restart START then '
      'takes 6.95 s and succeeds. Both are only slow: the Recording is adopted, the timer is re-armed, the next rotation is an '
      'ordinary one, and nothing is left marked unavailable',
      () async {
        await record();
        expect(service.stopVideoRecordingTimeout, const Duration(seconds: 5));
        expect(service.startVideoRecordingTimeout, const Duration(seconds: 5));
        final controller = service.previewController!;
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        final stopGate = Completer<void>();
        final startGate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGate;
        fakePlatform.pendingStartVideoCapturing = startGate;
        try {
          final stopHeld = Stopwatch()..start();
          timerTicks.last();
          await waitUntil(() => count('stopVideoRecording') == 1, 'the rotation issuing its native stop');
          fakePlatform.pendingStopVideoRecording = null;
          await waitUntil(() => service.rotationStopOverdue, 'the rotation stop being reported as overdue', within: const Duration(seconds: 7));
          final stopRemaining = const Duration(milliseconds: 6950) - stopHeld.elapsed;
          if (!stopRemaining.isNegative) await Future<void>.delayed(stopRemaining);
          expect(count('startVideoCapturing'), 1, reason: 'no restart while the stop is in flight');

          final startHeld = Stopwatch()..start();
          stopGate.complete();
          await waitUntil(() => count('startVideoCapturing') == 2, 'the restart START being issued after the late stop');
          fakePlatform.pendingStartVideoCapturing = null;
          expect(service.cameraKnownUnavailable, isFalse, reason: 'between the two: the stop is settled and the START is within its deadline');
          await waitForTheRestartToPassItsDeadline(within: const Duration(seconds: 7));
          expect(startHeld.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4900)));
          final startRemaining = const Duration(milliseconds: 6950) - startHeld.elapsed;
          if (!startRemaining.isNegative) await Future<void>.delayed(startRemaining);
          expect(service.cameraKnownUnavailable, isTrue);

          startGate.complete();
          await waitForTheRotationToEnd();
          expect(cameraRecording(), isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.previewController, same(controller));
          expect(timerTicks, hasLength(2));
          expect(errors, isEmpty);

          await expectOneNormalRotation('next');
          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop && !cameraRecording(), 'the final stop settling');
          expect(service.clips, hasLength(3));
          expect(producers(), everyElement('session-A'));
          expect(count('createCameraWithSettings'), 1);
          expect(maxCamerasOpenAtOnce(), 1);

          expect(service.lastLateRotationDecisionForTest, 'resume', reason: 'the late stop resumed (R2.6.14)');
          expect(service.lateRotationSettlementCountForTest, 1);
          expect(service.rotationStopOverdue, isFalse);
          expectTheServiceDecided('adopted');
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
          if (!startGate.isCompleted) startGate.complete();
          await errorsSub.cancel();
        }
      },
      timeout: const Timeout(Duration(seconds: 50)),
    );

    test(
      'X370 — a cleanup naming the segment the rotation has just ended, issued while the restart is overdue (R2.6.18, N1): it '
      'withdraws nothing, the late Recording is adopted, and when the cleanup\'s own turn comes a successor exists — nothing to do',
      () async {
        await record(startDeadline: shortDeadline);
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final cleanup = service.beginStopLoopRecording(expectedRecordingId: segment1, expectedController: camera);
          expect(service.isRecording, isTrue, reason: 'with the restart in flight the run is not withdrawn');
          expect(service.hasActiveSegmentTimerForTest, isTrue);

          gate.complete();
          await cleanup.presentation.timeout(patience);
          await waitForTheQueueToDrain();
          expect(await cleanup.handle.timeout(patience), isNull, reason: 'segment 1 was already stopped, by the rotation');
          expect(count('stopVideoRecording'), 1, reason: 'the cleanup stopped nothing: not the late Recording either');
          expect(cameraRecording(), isTrue);
          expect(service.isRecording, isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(timerTicks, hasLength(2));
          await expectOneNormalRotation('next');
          expectTheServiceDecided('adopted');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.20 — a late restart that must NOT be adopted', () {
    test(
      'X371 — the recording is stopped while the restart is overdue: the late Recording is not adopted. The stop that was queued '
      'stops it — exactly one native stop, with its handle and its clip — no timer is armed, and nothing is left recording',
      () async {
        await record(startDeadline: shortDeadline);
        final segment1 = service.activeRecordingId!;
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final stop = service.beginStopLoopRecording();
          expect(service.isRecording, isFalse);
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(count('stopVideoRecording'), 1, reason: 'nothing can be stopped yet: the START is still in flight');

          gate.complete();
          await stop.presentation.timeout(patience);
          final handle = await stop.handle.timeout(patience);
          await waitForTheQueueToDrain();

          expect(count('stopVideoRecording'), 2, reason: 'segment 1 by the rotation, the late Recording by the queued stop: one stop each');
          expect(count('startVideoCapturing'), 2, reason: 'no START after the stop');
          expect(handle, isNotNull, reason: 'the stop that was asked for is the one that stopped the late Recording');
          expect(handle!.recordingId, isNot(segment1));
          expect(handle.recordingId, service.activeRecordingId);
          expect(service.clips, hasLength(2));
          expect(producers(), ['session-A', 'session-A'], reason: 'the late clip belongs to the run that started it');
          expect(timerTicks, hasLength(1), reason: 'no timer was armed for a Recording nobody wanted');
          expectTheRunEnded();
          expect(service.cameraKnownUnavailable, isFalse, reason: 'nothing failed: the camera is not left marked unavailable');
          expect(count('dispose'), 0);
          expectTheServiceDecided('recordingNoLongerWanted');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X372 — dispose() while the restart is overdue: the late Recording is not adopted; the teardown that was queued stops it and '
      'disposes the camera — zero cameras at the end, the process owner released',
      () async {
        await record(startDeadline: shortDeadline);
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final disposing = service.dispose();
          expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'the owner is not let go while the START is in flight');
          await neverDuring(const Duration(milliseconds: 150), () => count('dispose') != 0, 'the camera disposed while the native START is in flight');

          gate.complete();
          await disposing.timeout(patience);
          await waitUntil(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown completing');
          expect(count('stopVideoRecording'), 2, reason: 'the teardown stopped the late Recording before disposing');
          final calls = fakePlatform.calls;
          expect(calls.lastIndexOf('stopVideoRecording'), lessThan(calls.indexOf('dispose')));
          expect(service.clips, hasLength(2));
          expect(producers(), ['session-A', 'session-A']);
          expect(fakePlatform.disposedCameraIds, hasLength(1));
          expect(timerTicks, hasLength(1), reason: 'no timer for the late Recording');
          expect(service.isRecording, isFalse);
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
          expectTheServiceDecided('recordingNoLongerWanted');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X373 — a new generation is asked for while the restart is overdue (initialize(), as a recovery does): nothing of it runs '
      'before the START settles — no camera, no dispose. The late Recording is not adopted; the re-initialization stops it and '
      'disposes the old camera BEFORE the new one opens; the START that follows records under its own epoch and timer',
      () async {
        await record(startDeadline: shortDeadline);
        final oldCamera = service.previewController!;
        final epoch = service.startIntentEpochForTest;
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final initializing = service.initialize();
          unawaited(initializing.catchError((_) {}));
          expect(service.isRecording, isFalse, reason: 'test setup: a re-initialize withdraws the run when it is asked for');
          await neverDuring(
            const Duration(milliseconds: 200),
            () => count('createCameraWithSettings') != 1 || count('dispose') != 0 || count('stopVideoRecording') != 1,
            'a camera, a dispose or a stop while the native START is in flight',
          );

          final callsAtRelease = fakePlatform.calls.length;
          gate.complete();
          await initializing.timeout(patience);
          final after = fakePlatform.calls.skip(callsAtRelease).toList();
          expect(after.indexOf('stopVideoRecording'), isNonNegative, reason: 'the late Recording was stopped');
          expect(after.indexOf('stopVideoRecording'), lessThan(after.indexOf('dispose')), reason: 'stopped before its camera was disposed');
          expect(after.indexOf('dispose'), lessThan(after.indexOf('createCameraWithSettings')), reason: 'old camera released before the new one opens');
          expect(maxCamerasOpenAtOnce(), 1);
          expect(service.previewController, isNot(same(oldCamera)));
          expect(service.clips, hasLength(2));
          expect(producers(), ['session-A', 'session-A']);
          expect(timerTicks, hasLength(1), reason: 'no timer for the late Recording');
          expect(service.cameraKnownUnavailable, isFalse);

          await service.startLoopRecording(clipOwnerToken: 'session-A');
          expect(cameraRecording(), isTrue);
          expect(service.startIntentEpochForTest, epoch + 1, reason: 'a new run, with its own identity');
          expect(service.activeRecordingStartEpochForTest, epoch + 1);
          expect(timerTicks, hasLength(2), reason: 'and its own timer');
          expectTheServiceDecided('recordingNoLongerWanted');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X374 — the run is stopped and a NEW run is started while the restart of the old one is overdue: the late Recording is the old '
      'run\'s — stopped by the old run\'s stop, its clip under the old producer — and is never taken for the new run\'s, which '
      'starts afterwards on the same camera with its own START, epoch and timer. A tick of the old run is still refused',
      () async {
        await record(startDeadline: shortDeadline);
        final camera = service.previewController!;
        final epochA = service.startIntentEpochForTest;
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final stopOfA = service.beginStopLoopRecording();
          final b = service.beginStartLoopRecording(clipOwnerToken: 'session-B');
          expect(b.attempt, isNotNull, reason: 'test setup: A was stopped, so B is a START of its own');
          expect(count('startVideoCapturing'), 2, reason: 'B waits behind the restart still in flight');

          gate.complete();
          await Future.wait([stopOfA.presentation, b.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(count('stopVideoRecording'), 2, reason: 'segment 1, and the late Recording of A — stopped before B started');
          expect(count('startVideoCapturing'), 3, reason: 'A, the late restart of A, and B');
          final calls = fakePlatform.calls;
          expect(calls.lastIndexOf('stopVideoRecording'), lessThan(calls.lastIndexOf('startVideoCapturing')), reason: 'B started on a camera that was free');
          expect(producers(), ['session-A', 'session-A'], reason: 'the late clip is A\'s, not B\'s');
          expect(await stopOfA.handle.timeout(patience), isNotNull, reason: 'A\'s stop got the late Recording');
          expect(cameraRecording(), isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.previewController, same(camera));
          expect(service.startIntentEpochForTest, epochA + 1);
          expect(service.activeRecordingStartEpochForTest, epochA + 1, reason: 'the active Recording is B\'s own');
          expect(timerTicks, hasLength(2), reason: 'A\'s timer and B\'s: the late success re-armed nothing');
          expect(service.cameraKnownUnavailable, isFalse);

          // A tick of A's timer, were one ever delivered now, does nothing.
          final staleBefore = service.rotationTickFatesForTest['staleAtAdmission']!;
          final callsBefore = fakePlatform.calls.length;
          timerTicks.first();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(service.rotationTickFatesForTest['staleAtAdmission'], staleBefore + 1, reason: 'a tick of the old run is dropped');
          expect(fakePlatform.calls, hasLength(callsBefore), reason: 'and touches nothing of B');

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop && !cameraRecording(), 'B\'s stop settling');
          expect(producers(), ['session-A', 'session-A', 'session-B']);
          expectTheServiceDecided('supersededByNewerStart');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X375 — the old run is cleaned up BY ITS START ATTEMPT and a new run is started, while the restart of the old one is overdue: '
      'the late Recording belongs to the old attempt — its cleanup stops it, under the old producer — and is never bound to the '
      'START that came later, which then starts on a camera that is free',
      () async {
        service = DashcamService(config: config(), segmentDuration: manualTicksOnly, startVideoRecordingTimeout: shortDeadline);
        service.segmentTimerArmedHookForTest = timerTicks.add;
        await service.initialize();
        final a = service.beginStartLoopRecording(clipOwnerToken: 'session-A');
        await a.presentation.timeout(patience);
        final camera = service.previewController!;
        final epochA = service.startIntentEpochForTest;
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          expect(service.isRecording, isFalse, reason: 'test setup: A is still the latest START, so its cleanup withdraws the run');
          final b = service.beginStartLoopRecording(clipOwnerToken: 'session-B');
          expect(b.attempt, isNotNull, reason: 'test setup: B is a START of its own');

          gate.complete();
          await Future.wait([cleanupOfA.presentation, b.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(await cleanupOfA.handle.timeout(patience), isNotNull, reason: 'the cleanup of A\'s START got the late Recording: it is A\'s');
          expect(count('stopVideoRecording'), 2, reason: 'segment 1, and the late Recording — stopped before B started');
          expect(count('startVideoCapturing'), 3, reason: 'A, the late restart of A, and B');
          expect(producers(), ['session-A', 'session-A'], reason: 'the late clip is A\'s, not B\'s');
          expect(cameraRecording(), isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.previewController, same(camera));
          expect(service.activeRecordingStartEpochForTest, epochA + 1, reason: 'the active Recording is B\'s own');
          expect(timerTicks, hasLength(2), reason: 'A\'s timer and B\'s');

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop && !cameraRecording(), 'B\'s stop settling');
          expect(producers(), ['session-A', 'session-A', 'session-B']);
          expectTheServiceDecided('supersededByNewerStart');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X376 — the app goes to the background while the restart is overdue and the START returns there: the camera generation is no '
      'longer trusted, so the late Recording is NOT adopted. Nobody is queued to stop it, so the rotation stops it itself before '
      'letting go of the queue, and ends the run: no timer, nothing recording, the camera still marked unavailable for the next '
      'foreground recovery — which then opens ONE camera after the old one is released',
      () async {
        await record(startDeadline: shortDeadline);
        final oldCamera = service.previewController!;
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          service.notifyAppBackgrounded();
          expect(service.isRecording, isTrue, reason: 'test setup: a background transition withdraws nothing and queues nothing');
          expect(service.liveStopIntentCountForTest, 0);

          gate.complete();
          await waitForTheQueueToDrain();
          expect(count('stopVideoRecording'), 2, reason: 'the rotation stopped the Recording it had just created');
          expect(count('startVideoCapturing'), 2);
          expect(service.clips, hasLength(2));
          expect(producers(), ['session-A', 'session-A']);
          expectTheRunEnded();
          expect(timerTicks, hasLength(1), reason: 'nothing was armed');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'the background transition\'s own mark stays: recovery is the next foreground\'s');
          expect(service.previewController, same(oldCamera), reason: 'the camera itself is left for that recovery: no dispose in the background');
          expect(count('dispose'), 0);
          expect(errors, isEmpty, reason: 'nothing failed');
          expectTheServiceDecided('cameraUnavailable');

          // The next foreground: a fresh camera, one at a time.
          await service.initialize();
          expect(service.cameraKnownUnavailable, isFalse);
          expect(maxCamerasOpenAtOnce(), 1, reason: 'the new camera opened only after the old one was disposed');
          expect(count('stopVideoRecording'), 2, reason: 'nothing was left to stop');
          await service.startLoopRecording(clipOwnerToken: 'session-A');
          expect(cameraRecording(), isTrue);
          expect(timerTicks, hasLength(2), reason: 'the new run\'s own timer');
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X377 — the event that did not change: a START of startLoopRecording() that outlives the deadline and then succeeds is NOT '
      'turned into a recording. Its caller was told at the deadline, its intent came down there, the camera is marked unavailable, '
      'and the attempt stops the late Recording itself — none of the rotation\'s late-restart rules apply to it',
      () async {
        service = DashcamService(config: config(), segmentDuration: manualTicksOnly, startVideoRecordingTimeout: shortDeadline);
        service.segmentTimerArmedHookForTest = timerTicks.add;
        await service.initialize();
        final gate = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = gate;
        try {
          await service.startLoopRecording(clipOwnerToken: 'session-A').timeout(patience);
          fakePlatform.pendingStartVideoCapturing = null;
          expect(service.isRecording, isFalse, reason: 'the caller was told at the deadline: this START did not make it');
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.startAttemptSettling, isTrue, reason: 'the physical attempt is still in flight');
          final overdueWhileItWaited = service.rotationRestartOverdue;

          gate.complete();
          await waitUntil(() => !service.startAttemptSettling, 'the attempt settling');
          expect(count('stopVideoRecording'), 1, reason: 'the attempt stopped the Recording its own late START created');
          expect(cameraRecording(), isFalse);
          expect(service.isRecording, isFalse, reason: 'a late success is not turned into a recording');
          expect(timerTicks, isEmpty, reason: 'no timer');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'and the camera stays marked unavailable until a new initialize()');
          await service.initialize();
          expect(service.cameraKnownUnavailable, isFalse, reason: '...which clears the mark, as it always did');
          expect(service.startFatesForTest['ownRecordingFinalized'], 1);
          expect(overdueWhileItWaited, isFalse, reason: 'this is not the restart of a rotation');
          expect(service.lateRestartSettlementCountForTest, 0, reason: 'no late-restart decision exists for it');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.20 — a restart that fails, and one that never returns', () {
    test(
      'X378 — late FAILURE: the restart START outlives the deadline and then fails. It is reported once, as a camera error of this '
      'generation; nothing was recorded; the camera is not trusted any more; and the run ENDS there — it is not left "wanted" with '
      'nothing recording, so the next START is a START of its own and records',
      () async {
        await record(startDeadline: shortDeadline);
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        final errors = <String>[];
        final originated = <DashcamServiceError>[];
        final errorsSub = service.errors.listen(errors.add);
        final originatedSub = service.originatedErrors.listen(originated.add);
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          expect(service.isRecording, isTrue, reason: 'the deadline alone ends nothing');
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(errors, isEmpty);

          gate.completeError(CameraException('start_failed', 'the restart START of the rotation failed, late'));
          await waitForTheQueueToDrain();
          await Future<void>.delayed(Duration.zero);

          expect(errors, hasLength(1), reason: 'reported exactly once');
          expect(errors.single, contains('falhou após o prazo de resposta'));
          expect(originated.single.scope, DashcamServiceErrorScope.lifecycleCamera);
          expect(originated.single.origin, same(camera), reason: 'about THIS camera');
          expectTheRunEnded();
          expect(service.cameraKnownUnavailable, isTrue, reason: 'a START that ended in an error leaves the generation untrusted');
          expect(service.activeRecordingId, segment1, reason: 'no Recording was created');
          expect(count('startVideoCapturing'), 2, reason: 'no retry');
          expect(count('stopVideoRecording'), 1, reason: 'nothing to stop');
          expect(count('createCameraWithSettings'), 1);
          expect(timerTicks, hasLength(1));

          // No dead run: the next START is not absorbed.
          final next = service.beginStartLoopRecording(clipOwnerToken: 'session-D');
          expect(next.attempt, isNotNull, reason: 'a START of its own, not a call absorbed by a run with nothing recording');
          await next.presentation.timeout(patience);
          expect(cameraRecording(), isTrue, reason: 'and it records');
          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop && !cameraRecording(), 'its stop settling');
          expect(producers(), ['session-A', 'session-D']);
          expectTheServiceDecided('startFailed');

          // The recovery path stays usable: a fresh camera clears the mark.
          await service.initialize();
          expect(service.cameraKnownUnavailable, isFalse);
          expect(maxCamerasOpenAtOnce(), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
          await originatedSub.cancel();
        }
      },
    );

    test(
      'X379 — the same physical event inside the deadline: the restart START fails at once. Reported once, camera not trusted, and '
      'the run ends there too — the outcome does not depend on which side of the deadline the failure arrived',
      () async {
        await record();
        final segment1 = service.activeRecordingId!;
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        fakePlatform.failStartVideoCapturingWith = CameraException('start_failed', 'the restart START of the rotation failed');
        try {
          timerTicks.last();
          await waitUntil(
            () => count('stopVideoRecording') == 1 && !service.hasPendingNativeStop && count('startVideoCapturing') == 2 && service.queuedRotationCountForTest == 0,
            'the rotation stopping segment 1, its restart failing and the rotation ending',
          );
          fakePlatform.failStartVideoCapturingWith = null;
          await Future<void>.delayed(Duration.zero);
          expect(errors, hasLength(1));
          expect(errors.single, contains('Falha ao reiniciar gravação durante rotação de segmento'));
          expectTheRunEnded();
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.activeRecordingId, segment1);

          final next = service.beginStartLoopRecording(clipOwnerToken: 'session-D');
          expect(next.attempt, isNotNull, reason: 'a START of its own, not a call absorbed by a run with nothing recording');
          await next.presentation.timeout(patience);
          expect(cameraRecording(), isTrue);
          expect(service.lateRestartSettlementCountForTest, 0, reason: 'nothing late about it');
        } finally {
          fakePlatform.failStartVideoCapturingWith = null;
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X380 — late FAILURE with a cleanup of the ended segment waiting (R2.6.18, N1): while the restart is in flight the cleanup '
      'withdraws nothing; the failure ends the run; the cleanup finds nothing to do; the next START is a START of its own',
      () async {
        await record(startDeadline: shortDeadline);
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final cleanup = service.beginStopLoopRecording(expectedRecordingId: segment1, expectedController: camera);
          expect(service.isRecording, isTrue, reason: 'with the restart in flight the run is not withdrawn');

          gate.completeError(CameraException('start_failed', 'the restart START of the rotation failed, late'));
          await cleanup.presentation.timeout(patience);
          await waitForTheQueueToDrain();
          expect(await cleanup.handle.timeout(patience), isNull);
          expect(count('stopVideoRecording'), 1);
          expectTheRunEnded();

          final next = service.beginStartLoopRecording(clipOwnerToken: 'session-D');
          expect(next.attempt, isNotNull);
          await next.presentation.timeout(patience);
          expect(cameraRecording(), isTrue);
          expectTheServiceDecided('startFailed');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X381 — the restart START NEVER returns: fail-closed. The state stays degraded, the queue stays held — no second START, no '
      'second camera, the process owner kept — ticks do not pile up, a stop still returns to its caller, and nothing is decided '
      'until the native call settles',
      () async {
        await record(startDeadline: shortDeadline, stopDeadline: const Duration(milliseconds: 200), initializeDeadline: const Duration(milliseconds: 300));
        final gate = await rotateAndHoldTheRestart();
        late final bool overdueWhileItWaited;
        late final int decidedWhileItWaited;
        try {
          await waitForTheRestartToPassItsDeadline();
          for (var i = 0; i < 5; i++) {
            timerTicks.last();
          }
          expect(service.queuedRotationCountForTest, 2, reason: 'the rotation that is waiting on its START, and ONE tick behind it');
          await neverDuring(
            const Duration(milliseconds: 400),
            () => !service.cameraKnownUnavailable || cameraRecording() || count('startVideoCapturing') != 2 || count('stopVideoRecording') != 1,
            'the state changing, or another native call, while the START has not returned',
          );
          expect(service.isRecording, isTrue, reason: 'the deadline alone ends nothing');
          expect(service.hasActiveSegmentTimerForTest, isTrue);

          // A new generation cannot get a camera: its own deadline tells its caller.
          await expectLater(service.initialize(), throwsA(isA<StateError>()));
          expect(count('createCameraWithSettings'), 1, reason: 'no second camera');
          expect(count('dispose'), 0);
          expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'the physical authority is not let go');
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse);

          // A stop still returns to its caller, at its own deadline.
          await service.stopLoopRecording().timeout(patience);
          expect(service.isRecording, isFalse);
          expect(service.cameraKnownUnavailable, isTrue, reason: 'the native call is still in flight');
          expect(count('stopVideoRecording'), 1);
          overdueWhileItWaited = service.rotationRestartOverdue;
          decidedWhileItWaited = service.lateRestartSettlementCountForTest;
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
        // Released for the teardown: what the START finally produced is stopped
        // by what was queued behind it.
        await waitUntil(() => count('stopVideoRecording') == 2 && !cameraRecording() && !service.hasPendingNativeStop, 'the late Recording being stopped by the queue');
        await waitForTheRotationToEnd();
        expect(timerTicks, hasLength(1), reason: 'nothing was armed for a Recording nobody wanted any more');
        expect(service.hasActiveSegmentTimerForTest, isFalse);
        expect(service.isRecording, isFalse);
        expect(overdueWhileItWaited, isTrue, reason: 'for as long as it waited the service said its restart START was overdue');
        expect(decidedWhileItWaited, 0, reason: 'and decided nothing before the settlement');
        expectTheServiceDecided('recordingNoLongerWanted');
      },
    );

    test(
      'X392 — the barrier holds for a failure too: a new generation is asked for while the restart is overdue, and the START then '
      'FAILS. Nothing of the re-initialization runs before that settlement — no camera, no dispose; afterwards it proceeds by '
      'itself: the old camera is released before the new one opens, nothing was ever recorded by the late START, and the failure is '
      'reported once',
      () async {
        await record(startDeadline: shortDeadline);
        final oldCamera = service.previewController!;
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        final gate = await rotateAndHoldTheRestart();
        try {
          await waitForTheRestartToPassItsDeadline();
          final initializing = service.initialize();
          unawaited(initializing.catchError((_) {}));
          await neverDuring(
            const Duration(milliseconds: 200),
            () => count('createCameraWithSettings') != 1 || count('dispose') != 0,
            'a camera or a dispose while the native START is in flight',
          );

          final callsAtRelease = fakePlatform.calls.length;
          gate.completeError(CameraException('start_failed', 'the restart START of the rotation failed, late'));
          await initializing.timeout(patience);
          await Future<void>.delayed(Duration.zero);
          final after = fakePlatform.calls.skip(callsAtRelease).toList();
          expect(after, isNot(contains('stopVideoRecording')), reason: 'nothing was recording: nothing to stop');
          expect(after.indexOf('dispose'), isNonNegative);
          expect(after.indexOf('dispose'), lessThan(after.indexOf('createCameraWithSettings')), reason: 'old camera released before the new one opens');
          expect(maxCamerasOpenAtOnce(), 1);
          expect(service.previewController, isNot(same(oldCamera)));
          expect(service.cameraKnownUnavailable, isFalse, reason: 'the fresh camera is trusted');
          expect(errors, hasLength(1), reason: 'the failure of the late START, once');
          expect(service.clips, hasLength(1));
          expect(service.isRecording, isFalse);
          expect(timerTicks, hasLength(1));
          expectTheServiceDecided('startFailed');
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
    );
  });
}
