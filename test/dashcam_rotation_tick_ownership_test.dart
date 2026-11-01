// Fase 16.2-R4.3-R2.6.15 — rotation tick ownership / stale tick suppression, at
// the DashcamService level (the service's own public API is the authority: none
// of this relies on what DashcamSessionController happens to call, or in which
// order).
//
// The independent review of R2.6.14 (P2-01) reproduced this through the public
// API: rotation ticks of run A accumulated behind a slow rotation stop; A was
// stopped and B started before that stop returned; the accumulated ticks then
// ran, found the camera idle and B's intent set, and started Recordings
// labelled A. B's own START failed against a camera already recording, the
// service reported "not recording" over an active Recording, and the next
// stopLoopRecording() did not stop it.
//
// The contract pinned here:
//  * a rotation tick belongs to the run that armed its timer — the START epoch
//    and the controller — and acts for that run only: once the run has been
//    superseded it starts nothing, stops nothing, and leaves no trace;
//  * a run never has more than one tick waiting behind the rotation in flight,
//    and a tick that waited does not rotate a segment that has just begun;
//  * a slow rotation stop that still belongs to its run keeps resuming by
//    itself (R2.6.14), exactly once.
//
// How the tests drive ticks. Two ways, on purpose:
//  * the real segment timer (X240, X249, X257) — the reviewer's own
//    counter-proof used it, and so do the tests that restate it;
//  * `segmentTimerArmedHookForTest` — the service hands over a closure that
//    delivers one tick of a given timer, exactly what that timer calls. With a
//    segment of ten minutes the real timer never fires during a test, so every
//    tick is delivered at a known instant and the counts asserted are exact,
//    not "at least". It is also the only way to deliver a tick of a run that
//    has already ended: a Dart Timer does not fire after cancel().
//
// Waits are by cause: a stop is held on a Completer and released only after
// the state under test was OBSERVED (stop issued, deadline reported, N ticks
// fired). Assertions come in the same order every time: what the camera and
// the queue did first, the name of the service's own decision last.
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

  /// One deliverer per segment timer the service armed, in arming order:
  /// calling one delivers a tick of THAT timer.
  late List<void Function()> timerTicks;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  /// Long enough that the real segment timer never fires within a test.
  const manualTicksOnly = Duration(minutes: 10);

  DashcamConfig config() => DashcamConfig(
    cameraSelection: CameraSelection.rear,
    storageQuotaMb: 1024,
    audioEnabled: false,
    resolution: VideoResolution.hd720,
    frameRate: 30,
    enabled: true,
  );

  /// A `null` [stopDeadline] keeps the product's own default (5 s).
  DashcamService build({Duration segment = manualTicksOnly, Duration? stopDeadline}) {
    final built = stopDeadline == null
        ? DashcamService(config: config(), segmentDuration: segment)
        : DashcamService(config: config(), segmentDuration: segment, stopVideoRecordingTimeout: stopDeadline);
    built.segmentTimerArmedHookForTest = timerTicks.add;
    return built;
  }

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;
  int fate(String name) => service.rotationTickFatesForTest[name]!;

  /// Ticks the segment timers delivered so far, whatever became of them.
  int ticksFired() => service.rotationTicksFiredForTest;
  List<Object?> producers() => service.clips.map((c) => c.producerToken).toList();

  /// The largest number of cameras that were open at the same time, from the
  /// fake platform's own call order.
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

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail(
      'never happened within ${within.inMilliseconds} ms: $what '
      '(isRecording=${service.isRecording}, pendingStop=${service.hasPendingNativeStop}, overdue=${service.rotationStopOverdue}, '
      'unavailable=${service.cameraKnownUnavailable}, queuedRotations=${service.queuedRotationCountForTest}, fates=${service.rotationTickFatesForTest}, '
      'lateDecision=${service.lastLateRotationDecisionForTest}, calls=${fakePlatform.calls.join(',')})',
    );
  }

  /// Observes [window] of real time and fails if [condition] ever holds.
  Future<void> neverDuring(Duration window, bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      if (condition()) fail('must not happen, but did after ${clock.elapsedMilliseconds} ms: $what (calls=${fakePlatform.calls.join(',')})');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// The rotation in flight and every tick behind it have left the queue, and
  /// no native stop is pending.
  Future<void> waitForRotationsToDrain() {
    return waitUntil(() => service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop, 'the rotation queue draining');
  }

  /// Run A recording on a freshly built service; the native stop(s) to come are
  /// held on the returned gate.
  Future<Completer<void>> recordAWithHeldStops({Duration segment = manualTicksOnly, Duration? stopDeadline}) async {
    service = build(segment: segment, stopDeadline: stopDeadline);
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'producer-A');
    final gate = Completer<void>();
    fakePlatform.pendingStopVideoRecording = gate;
    return gate;
  }

  /// A rotation tick of run A issued its native stop, and the call is in flight.
  Future<void> waitForHeldRotationStop({int stopsSoFar = 1}) {
    return waitUntil(() => count('stopVideoRecording') == stopsSoFar && service.hasPendingNativeStop, 'the rotation stop being issued and held');
  }

  setUp(() {
    timerTicks = [];
    dir = Directory.systemTemp.createTempSync('dashcam_rotation_tick_ownership_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    // Last-resort barrier, as in dashcam_rotation_late_stop_test.dart: every
    // test releases its own gates in a `finally`.
    for (final gate in [fakePlatform.pendingStopVideoRecording, fakePlatform.pendingStartVideoCapturing]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
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

  group('Fase 16.2-R4.3-R2.6.15 — ticks of run A must not act once run B was requested', () {
    test(
      'X240 — the independent review\'s own sequence, through the public API and the real segment timer: ticks of A pile up '
      'behind a slow rotation stop, A is stopped and B started before that stop returns. Only B\'s START starts anything, B '
      'records as B, and the next stop really stops it',
      () async {
        // Same ordering as the product and as the reviewer's probe: the stop
        // deadline is shorter than the segment period.
        final gate = await recordAWithHeldStops(segment: const Duration(milliseconds: 120), stopDeadline: const Duration(milliseconds: 20));
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final owner = DashcamService.processOwnerCurrentForTest;
          final recordingA = service.activeRecordingId;
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          // By cause, not by elapsed time: four more ticks of the real timer
          // fired while the stop is held.
          await waitUntil(() => ticksFired() >= 5, 'four more ticks firing while the stop is held');
          expect(service.queuedRotationCountForTest, 2, reason: 'the rotation in flight and ONE tick behind it, however many fired');
          expect(count('startVideoCapturing'), 1);
          expect(count('stopVideoRecording'), 1);

          await service.stopLoopRecording();
          expect(service.isRecording, isFalse);
          expect(service.hasPendingNativeStop, isTrue, reason: 'test setup: the logical stop adopted the stop still in flight');
          Object? startError;
          final startingB = service.startLoopRecording(clipOwnerToken: 'producer-B').catchError((Object e) {
            startError = e;
          });
          expect(service.isRecording, isTrue, reason: 'test setup: B was requested while A\'s raw stop is still held');
          gate.complete();
          await startingB.timeout(const Duration(seconds: 3));

          // The reviewer's oracle.
          expect(startError, isNull, reason: 'an accepted START B must not meet a Recording restarted by ticks of A');
          expect(count('startVideoCapturing'), 2, reason: 'A, then B — no tick of A started anything');
          expect(count('stopVideoRecording'), 1, reason: 'and none stopped anything');
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(producers(), ['producer-A'], reason: 'the slow stop\'s own clip, collected once, as A\'s');
          expect(service.activeRecordingId, isNot(recordingA));
          expect(service.hasActiveSegmentTimerForTest, isTrue, reason: 'B\'s own timer');
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.queuedRotationCountForTest, 0);

          // The following stop reaches B's Recording, and nothing is left recording.
          final recordingB = service.activeRecordingId;
          final stop = service.beginStopLoopRecording();
          final handle = await stop.handle.timeout(const Duration(seconds: 3));
          await stop.presentation.timeout(const Duration(seconds: 3));
          expect(handle, isNotNull, reason: 'the stop found something to stop');
          expect(handle!.recordingId, recordingB);
          expect(handle.producerToken, 'producer-B');
          expect(handle.controller, same(controller));
          await handle.settlement.timeout(const Duration(seconds: 3));
          expect(count('stopVideoRecording'), 2);
          expect(controller.value.isRecordingVideo, isFalse, reason: 'zero physical recordings left');
          expect(service.isRecording, isFalse);
          expect(producers(), ['producer-A', 'producer-B']);
          expect(service.previewController, same(controller), reason: 'same camera throughout');
          expect(DashcamService.processOwnerCurrentForTest, same(owner));
          expect(count('createCameraWithSettings'), 1);
          expect(errors, isEmpty);

          // Why nothing of A ran: named last, after everything it did not do.
          expect(service.lastLateRotationDecisionForTest, 'supersededByNewerStart', reason: 'the rotation that was in flight');
          expect(fate('staleAtExecution'), 1, reason: 'the tick that waited behind it');
          expect(fate('coalesced'), greaterThanOrEqualTo(3), reason: 'the other ticks never entered the queue');
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X241 — no deadline involved at all: the rotation stop is merely in flight (production deadline, 5 s) when A is stopped '
      'and B started. The rotation does not restart A under B\'s intent, B starts, and the next stop stops B',
      () async {
        final gate = await recordAWithHeldStops();
        try {
          final controller = service.previewController!;
          timerTicks.single();
          await waitForHeldRotationStop();
          expect(service.rotationStopOverdue, isFalse, reason: 'test setup: the stop is within its deadline');

          final stopping = service.stopLoopRecording();
          Object? startError;
          final startingB = service.startLoopRecording(clipOwnerToken: 'producer-B').catchError((Object e) {
            startError = e;
          });
          gate.complete();
          await stopping.timeout(const Duration(seconds: 3));
          await startingB.timeout(const Duration(seconds: 3));

          expect(startError, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'A, then B');
          expect(count('stopVideoRecording'), 1);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(producers(), ['producer-A']);

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop, 'B\'s stop settling');
          expect(count('stopVideoRecording'), 2);
          expect(controller.value.isRecordingVideo, isFalse);
          expect(producers(), ['producer-A', 'producer-B']);
          expect(count('createCameraWithSettings'), 1);

          expect(service.lateRotationSettlementCountForTest, 0, reason: 'the stop met its deadline: this is not the late-settlement path');
          expect(fate('staleAfterStop'), 1, reason: 'the rotation found its run superseded when its own stop returned');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X242 — the same within the deadline, with ticks behind it: three more ticks fire while the stop is in flight (one '
      'waits, two are coalesced), then A is stopped and B started. Neither the rotation in flight nor the tick that waited '
      'acts for B',
      () async {
        final gate = await recordAWithHeldStops();
        try {
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          tickA();
          tickA();
          tickA();
          expect(service.queuedRotationCountForTest, 2, reason: 'the rotation in flight and one tick behind it');

          final stopping = service.stopLoopRecording();
          Object? startError;
          final startingB = service.startLoopRecording(clipOwnerToken: 'producer-B').catchError((Object e) {
            startError = e;
          });
          gate.complete();
          await stopping.timeout(const Duration(seconds: 3));
          await startingB.timeout(const Duration(seconds: 3));

          expect(startError, isNull);
          expect(count('startVideoCapturing'), 2);
          expect(count('stopVideoRecording'), 1);
          expect(service.queuedRotationCountForTest, 0);
          expect(producers(), ['producer-A']);

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop, 'B\'s stop settling');
          expect(producers(), ['producer-A', 'producer-B']);
          expect(service.previewController!.value.isRecordingVideo, isFalse);

          expect(fate('staleAfterStop'), 1, reason: 'the rotation in flight');
          expect(fate('staleAtExecution'), 1, reason: 'the tick that waited');
          expect(fate('coalesced'), 2, reason: 'the two ticks that never entered the queue');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X243 — a superseded tick leaves nothing behind: its stop intent resolves to "no stop", no status changes, no timer is '
      'touched — and B\'s own rotation afterwards is B\'s, start to finish',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        service.trackStopIntentsForTest = true;
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          timerTicks.single();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          timerTicks.single();
          timerTicks.single();
          final waiting = service.stopIntentsForTest.where((i) => i.purpose == 'rotation' && !i.resolved).single;

          await service.stopLoopRecording();
          final startingB = service.startLoopRecording(clipOwnerToken: 'producer-B');
          gate.complete();
          await startingB.timeout(const Duration(seconds: 3));

          final settledWaiting = service.stopIntentsForTest.firstWhere((i) => i.id == waiting.id);
          expect(settledWaiting.resolved, isTrue, reason: 'nobody is left waiting on the tick that did nothing');
          expect(settledWaiting.resolvedPhysicalStopId, isNull, reason: 'it resolved to "no stop": it issued none');
          expect(service.liveStopIntentCountForTest, 0);
          expect(service.stopIntentAncestryEntriesForTest, 0);
          expect(service.queuedRotationCountForTest, 0);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.rotationStopOverdue, isFalse);
          expect(timerTicks, hasLength(2), reason: 'A\'s timer and B\'s: no tick of A armed one');
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(count('startVideoCapturing'), 2);
          expect(count('stopVideoRecording'), 1);
          final recordingB = service.activeRecordingId;

          // B's own rotation.
          timerTicks[1]();
          await waitUntil(() => count('startVideoCapturing') == 3, 'B\'s rotation restarting');
          await waitForRotationsToDrain();
          expect(count('stopVideoRecording'), 2);
          expect(producers(), ['producer-A', 'producer-B']);
          expect(service.clips.last.recordingId, recordingB);

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop, 'B\'s stop settling');
          expect(producers(), ['producer-A', 'producer-B', 'producer-B']);
          expect(service.previewController!.value.isRecordingVideo, isFalse);
          expect(errors, isEmpty);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X256 — a tick waiting behind a rotation whose RESTART is in flight, then A is stopped and B started: the tick, now '
      'superseded, stops nothing. The explicit stop itself stops the Recording that restart produced, and B starts',
      () async {
        service = build();
        service.trackStopIntentsForTest = true;
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-A');
        final restartGate = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = restartGate;
        try {
          final controller = service.previewController!;
          timerTicks.single();
          await waitUntil(() => count('startVideoCapturing') == 2 && !service.hasPendingNativeStop, 'rotation 1 stopping Recording #1 and holding its restart');
          timerTicks.single();
          final waiting = service.stopIntentsForTest.where((i) => i.purpose == 'rotation' && !i.resolved).single;
          expect(service.queuedRotationCountForTest, 2);

          final explicit = service.beginStopLoopRecording();
          Object? startError;
          final startingB = service.startLoopRecording(clipOwnerToken: 'producer-B').catchError((Object e) {
            startError = e;
          });
          restartGate.complete();
          final handle = await explicit.handle.timeout(const Duration(seconds: 3));
          await explicit.presentation.timeout(const Duration(seconds: 3));
          await startingB.timeout(const Duration(seconds: 3));

          expect(startError, isNull);
          expect(handle, isNotNull, reason: 'the Recording the restart produced was stopped');
          expect(handle!.producerIntentId, explicit.intentId, reason: 'by the explicit stop itself — not by the superseded tick ahead of it');
          expect(handle.producerIntentId, isNot(waiting.id));
          expect(handle.producerToken, 'producer-A');
          expect(service.stopIntentsForTest.firstWhere((i) => i.id == waiting.id).resolvedPhysicalStopId, isNull);
          await handle.settlement.timeout(const Duration(seconds: 3));
          expect(count('stopVideoRecording'), 2, reason: 'Recording #1 (rotation 1) and Recording #2 (the explicit stop)');
          expect(count('startVideoCapturing'), 3, reason: 'A, A\'s restart, B');
          expect(producers(), ['producer-A', 'producer-A']);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);

          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop, 'B\'s stop settling');
          expect(producers(), ['producer-A', 'producer-A', 'producer-B']);
          expect(controller.value.isRecordingVideo, isFalse);

          expect(fate('staleAtExecution'), 1, reason: 'the tick that waited behind the restart');
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
          fakePlatform.pendingStartVideoCapturing = null;
        }
      },
    );

    test(
      'X260 — the same waiting tick, and B is stopped again before its START ever runs (so no intent to record is left '
      'when the tick\'s turn comes): the Recording the restart produced is still stopped by A\'s own explicit stop, never '
      'by the superseded tick ahead of it, and nothing of B starts',
      () async {
        service = build();
        service.trackStopIntentsForTest = true;
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-A');
        final restartGate = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = restartGate;
        try {
          final controller = service.previewController!;
          timerTicks.single();
          await waitUntil(() => count('startVideoCapturing') == 2 && !service.hasPendingNativeStop, 'rotation 1 stopping Recording #1 and holding its restart');
          timerTicks.single();
          final waiting = service.stopIntentsForTest.where((i) => i.purpose == 'rotation' && !i.resolved).single;

          final stopOfA = service.beginStopLoopRecording();
          Object? startError;
          final startingB = service.startLoopRecording(clipOwnerToken: 'producer-B').catchError((Object e) {
            startError = e;
          });
          final stopOfB = service.beginStopLoopRecording();
          restartGate.complete();
          final handleA = await stopOfA.handle.timeout(const Duration(seconds: 3));
          final handleB = await stopOfB.handle.timeout(const Duration(seconds: 3));
          await stopOfA.presentation.timeout(const Duration(seconds: 3));
          await stopOfB.presentation.timeout(const Duration(seconds: 3));
          await startingB.timeout(const Duration(seconds: 3));

          expect(startError, isNull);
          expect(handleA, isNotNull, reason: 'the Recording the restart produced was stopped');
          await handleA!.settlement.timeout(const Duration(seconds: 3));
          expect(handleA.producerIntentId, stopOfA.intentId, reason: 'by A\'s explicit stop itself — the superseded tick ahead of it issued no stop');
          expect(handleA.producerIntentId, isNot(waiting.id));
          expect(handleA.producerToken, 'producer-A');
          expect(handleB, isNull, reason: 'B never started: there was nothing of B to stop');
          expect(count('startVideoCapturing'), 2, reason: 'A and A\'s restart; B\'s own stop superseded B\'s START');
          expect(count('stopVideoRecording'), 2, reason: 'Recording #1 (rotation 1) and Recording #2 (A\'s explicit stop)');
          expect(producers(), ['producer-A', 'producer-A']);
          expect(service.isRecording, isFalse);
          expect(controller.value.isRecordingVideo, isFalse);
          expect(service.stopIntentsForTest.firstWhere((i) => i.id == waiting.id).resolvedPhysicalStopId, isNull);
          expect(service.liveStopIntentCountForTest, 0);

          expect(fate('staleAtExecution'), 1, reason: 'the tick that waited behind the restart');
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
          fakePlatform.pendingStartVideoCapturing = null;
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.15 — a tick delivered for a run that has ended', () {
    test(
      'X244 — one tick of A arrives while B is recording: it is refused before it claims or queues anything, B is untouched, '
      'and B\'s own tick still rotates B',
      () async {
        service = build();
        service.trackStopIntentsForTest = true;
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-A');
        await service.stopLoopRecording();
        await service.startLoopRecording(clipOwnerToken: 'producer-B');
        final controller = service.previewController!;
        final recordingB = service.activeRecordingId;
        final callsBefore = fakePlatform.calls.length;
        final intentsBefore = service.stopIntentsForTest.length;

        timerTicks[0]();
        // What the tick left behind the instant it returned — read now, asserted
        // after the camera has had time to show whether anything ran.
        final queuedRightAfter = service.queuedRotationCountForTest;
        final intentsRightAfter = service.stopIntentsForTest.length;
        final liveIntentsRightAfter = service.liveStopIntentCountForTest;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(fakePlatform.calls, hasLength(callsBefore), reason: 'no native call of any kind: a tick of A neither stops nor restarts B');
        expect(service.isRecording, isTrue);
        expect(controller.value.isRecordingVideo, isTrue);
        expect(service.activeRecordingId, recordingB);
        expect(service.hasActiveSegmentTimerForTest, isTrue);
        expect(service.cameraKnownUnavailable, isFalse);
        expect(producers(), ['producer-A']);
        expect(queuedRightAfter, 0, reason: 'nothing was queued');
        expect(intentsRightAfter, intentsBefore, reason: 'no stop intent was created');
        expect(liveIntentsRightAfter, 0);

        timerTicks[1]();
        await waitUntil(() => count('startVideoCapturing') == 3, 'B\'s own rotation restarting');
        await waitForRotationsToDrain();
        expect(producers(), ['producer-A', 'producer-B']);
        await service.stopLoopRecording();
        await waitUntil(() => !service.hasPendingNativeStop, 'B\'s stop settling');
        expect(producers(), ['producer-A', 'producer-B', 'producer-B']);
        expect(controller.value.isRecordingVideo, isFalse);

        expect(fate('staleAtAdmission'), 1, reason: 'the tick of A was refused the instant it arrived');
      },
    );

    test(
      'X245 — several ticks of A arrive while B\'s own rotation is in flight: none of them is queued, and none takes the '
      'place of B\'s own waiting tick',
      () async {
        service = build();
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-A');
        await service.stopLoopRecording();
        await service.startLoopRecording(clipOwnerToken: 'producer-B');
        final gate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = gate;
        try {
          timerTicks[1]();
          await waitForHeldRotationStop(stopsSoFar: 2);

          for (var i = 0; i < 5; i++) {
            timerTicks[0]();
          }
          expect(service.queuedRotationCountForTest, 1, reason: 'only B\'s own rotation: no tick of A was queued');

          timerTicks[1]();
          expect(service.queuedRotationCountForTest, 2, reason: 'B\'s own second tick is the one that waits — its place was not taken');

          gate.complete();
          await waitForRotationsToDrain();
          expect(count('startVideoCapturing'), 3, reason: 'A, B, and B\'s rotation restart');
          expect(count('stopVideoRecording'), 2, reason: 'A\'s explicit stop and B\'s rotation stop');
          expect(producers(), ['producer-A', 'producer-B']);
          expect(service.isRecording, isTrue);

          expect(fate('staleAtAdmission'), 5);
          expect(fate('coalesced'), 0, reason: 'a tick of A is not "one more tick of B"');
          expect(fate('absorbed'), 1, reason: 'B\'s waiting tick, behind B\'s own rotation');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X246 — the camera generation changed: a tick of the run that recorded on the old controller is refused, before and '
      'after a new START',
      () async {
        service = build();
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-A');
        final oldController = service.previewController!;
        await service.initialize();
        expect(service.previewController, isNot(same(oldController)), reason: 'test setup: a new generation');
        expect(producers(), ['producer-A'], reason: 'test setup: the release finalized A\'s Recording');
        var callsBefore = fakePlatform.calls.length;

        // No new START yet: the START epoch has not moved, only the controller did.
        timerTicks[0]();
        expect(service.queuedRotationCountForTest, 0, reason: 'nothing was queued');
        expect(service.liveStopIntentCountForTest, 0, reason: 'nothing was claimed');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(fakePlatform.calls, hasLength(callsBefore));
        expect(fate('staleAtAdmission'), 1);

        await service.startLoopRecording(clipOwnerToken: 'producer-B');
        callsBefore = fakePlatform.calls.length;
        timerTicks[0]();
        expect(service.queuedRotationCountForTest, 0);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(fakePlatform.calls, hasLength(callsBefore));
        expect(service.previewController!.value.isRecordingVideo, isTrue);
        expect(count('startVideoCapturing'), 2);
        expect(count('stopVideoRecording'), 1);
        expect(maxCamerasOpenAtOnce(), 1);
        expect(fate('staleAtAdmission'), 2);
      },
    );

    test(
      'X247 — the user stopped A and nothing was started since: a late tick of A finds nothing to do — no native call, no '
      'restart, no status change',
      () async {
        service = build();
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-A');
        await service.stopLoopRecording();
        final controller = service.previewController!;
        final callsBefore = fakePlatform.calls.length;

        timerTicks.single();
        await waitUntil(() => service.queuedRotationCountForTest == 0, 'the late tick leaving the queue');
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(fakePlatform.calls, hasLength(callsBefore), reason: 'no native call');
        expect(service.isRecording, isFalse);
        expect(controller.value.isRecordingVideo, isFalse);
        expect(service.hasActiveSegmentTimerForTest, isFalse);
        expect(service.cameraKnownUnavailable, isFalse);
        expect(service.liveStopIntentCountForTest, 0);
        expect(producers(), ['producer-A']);
      },
    );

    test(
      'X248 — dispose: ticks of A delivered between dispose() and its teardown, and after it, start nothing and stop '
      'nothing; the teardown runs once, after the raw stop',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        try {
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');

          final disposing = service.dispose();
          tickA();
          tickA();
          expect(service.queuedRotationCountForTest, 2, reason: 'one waits behind the teardown, the other was coalesced');
          expect(count('dispose'), 0, reason: 'the teardown waits for the raw stop');

          gate.complete();
          await disposing.timeout(const Duration(seconds: 3));
          await waitUntil(() => DashcamService.processOwnerCurrentForTest == null, 'the teardown releasing the camera');
          await waitUntil(() => service.queuedRotationCountForTest == 0, 'the late tick leaving the queue');

          expect(count('startVideoCapturing'), 1, reason: 'nothing restarted');
          expect(count('stopVideoRecording'), 1, reason: 'the rotation\'s own stop, and nothing else to stop');
          expect(count('dispose'), 1);
          expect(producers(), ['producer-A']);

          final callsBefore = fakePlatform.calls.length;
          tickA();
          expect(service.queuedRotationCountForTest, 0, reason: 'after the teardown a tick is not even queued');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(fakePlatform.calls, hasLength(callsBefore));

          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted');
          expect(fate('coalesced'), 1);
          expect(fate('staleAtExecution'), 1, reason: 'the tick that waited ran after the teardown: its controller is gone');
          expect(fate('staleAtAdmission'), 1, reason: 'the tick delivered after the teardown');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.15 — one rotation in flight, any number of ticks', () {
    test(
      'X249 — same run, real segment timer: three more ticks fire while the rotation stop is slow. When it returns the next '
      'segment starts ONCE and is not rotated again until the next regular tick',
      () async {
        final gate = await recordAWithHeldStops(segment: const Duration(milliseconds: 400), stopDeadline: const Duration(milliseconds: 40));
        try {
          final controller = service.previewController!;
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          // Released right after a tick was observed, so the next regular tick
          // is almost a full period (400 ms) away.
          await waitUntil(() => ticksFired() >= 4, 'three more ticks firing while the stop is held');
          expect(service.queuedRotationCountForTest, 2, reason: 'the rotation in flight and one tick behind it');
          expect(count('startVideoCapturing'), 1);
          expect(count('stopVideoRecording'), 1);

          gate.complete();
          await waitForRotationsToDrain();
          expect(count('startVideoCapturing'), 2, reason: 'exactly one restart');
          expect(count('stopVideoRecording'), 1, reason: 'and no rotation of the segment that has only just begun');
          expect(service.clips, hasLength(1));
          expect(service.cameraKnownUnavailable, isFalse);
          await neverDuring(
            const Duration(milliseconds: 150),
            () => count('startVideoCapturing') != 2 || count('stopVideoRecording') != 1,
            'a rotation right after the late restart',
          );
          expect(service.lastLateRotationDecisionForTest, 'resume');
          expect(service.lateRotationSettlementCountForTest, 1);
          expect(fate('absorbed'), 1, reason: 'the tick that waited found its segment already replaced');

          // The next regular tick rotates as usual.
          await waitUntil(() => count('stopVideoRecording') == 2 && count('startVideoCapturing') == 3, 'the next regular rotation', within: const Duration(seconds: 3));
          await service.stopLoopRecording();
          await waitUntil(() => !service.hasPendingNativeStop, 'the final stop settling');
          expect(service.clips.every((c) => c.producerToken == 'producer-A'), isTrue);
          expect(controller.value.isRecordingVideo, isFalse);
          expect(maxCamerasOpenAtOnce(), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X250 — same run, exact counts: ten ticks delivered while the rotation stop is slow. The queue never holds more than '
      'two rotations, the stop returns to exactly one restart, and the next tick rotates normally',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        try {
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          for (var i = 0; i < 10; i++) {
            tickA();
            expect(service.queuedRotationCountForTest, 2, reason: 'after tick ${i + 1}: the rotation in flight plus one');
          }
          expect(service.liveStopIntentCountForTest, 1, reason: 'one unresolved rotation intent, not ten');
          expect(count('startVideoCapturing'), 1);
          expect(count('stopVideoRecording'), 1);

          gate.complete();
          await waitForRotationsToDrain();
          expect(count('startVideoCapturing'), 2, reason: 'zero duplicate START');
          expect(count('stopVideoRecording'), 1, reason: 'zero duplicate STOP');
          expect(service.liveStopIntentCountForTest, 0);
          expect(service.isRecording, isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(count('startVideoCapturing'), 2);
          expect(count('stopVideoRecording'), 1);

          tickA();
          await waitUntil(() => count('startVideoCapturing') == 3, 'the next rotation restarting');
          await waitForRotationsToDrain();
          expect(count('stopVideoRecording'), 2);
          expect(producers(), ['producer-A', 'producer-A']);

          expect(service.lastLateRotationDecisionForTest, 'resume');
          expect(fate('coalesced'), 9);
          expect(fate('absorbed'), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X251 — the stop never returns: fifty ticks later the queue still holds two rotations, nothing started, no second '
      'camera, and a START B requested meanwhile stays behind the stop. Once it does return, only B starts',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        try {
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          for (var i = 0; i < 50; i++) {
            tickA();
          }
          expect(service.queuedRotationCountForTest, 2, reason: 'fifty ticks, still two rotations in the queue');
          expect(service.liveStopIntentCountForTest, 1);
          expect(service.isRecording, isTrue, reason: 'the intent is kept, as before');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'degraded for as long as the stop is in flight');

          await service.stopLoopRecording();
          Object? startError;
          var bSettled = false;
          final startingB = service
              .startLoopRecording(clipOwnerToken: 'producer-B')
              .catchError((Object e) {
                startError = e;
              })
              .whenComplete(() => bSettled = true);
          await neverDuring(
            const Duration(milliseconds: 200),
            () => bSettled || count('startVideoCapturing') != 1 || count('createCameraWithSettings') != 1 || count('stopVideoRecording') != 1,
            'anything starting, stopping or opening while the stop never returns',
          );
          expect(service.hasPendingNativeStop, isTrue, reason: 'fail-closed: the raw stop still owns the camera');

          // Releasing it is this test's cleanup — and shows no backlog was waiting to run.
          gate.complete();
          await startingB.timeout(const Duration(seconds: 3));
          expect(startError, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'A, then B: fifty ticks left nothing to run');
          expect(count('stopVideoRecording'), 1);
          expect(producers(), ['producer-A']);
          expect(count('createCameraWithSettings'), 1);
          expect(fate('coalesced'), 49);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X252 — ticks pile up behind a stop that does not return, then a NEW GENERATION is requested: nothing of A runs '
      'against it — the old camera is released first, B records on the new one, and A\'s ticks are refused',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        try {
          final oldController = service.previewController!;
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          for (var i = 0; i < 5; i++) {
            tickA();
          }
          expect(service.queuedRotationCountForTest, 2);

          final initializing = service.initialize();
          await neverDuring(
            const Duration(milliseconds: 150),
            () => count('createCameraWithSettings') != 1 || count('startVideoCapturing') != 1,
            'a camera or a start while A\'s stop is still in flight',
          );
          final callsAtRelease = fakePlatform.calls.length;
          gate.complete();
          await initializing.timeout(const Duration(seconds: 5));
          final afterRelease = fakePlatform.calls.skip(callsAtRelease).toList();
          expect(afterRelease.indexOf('dispose'), lessThan(afterRelease.indexOf('createCameraWithSettings')), reason: 'the old camera released before the new one opens');
          expect(service.previewController, isNot(same(oldController)));
          expect(service.queuedRotationCountForTest, 0);
          expect(count('startVideoCapturing'), 1, reason: 'no tick of A started anything, on either camera');
          expect(count('stopVideoRecording'), 1);

          await service.startLoopRecording(clipOwnerToken: 'producer-B');
          final callsBefore = fakePlatform.calls.length;
          tickA();
          tickA();
          expect(service.queuedRotationCountForTest, 0, reason: 'a tick of A is not queued against the new generation');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(fakePlatform.calls, hasLength(callsBefore));
          expect(count('startVideoCapturing'), 2);
          expect(producers(), ['producer-A']);
          expect(service.previewController!.value.isRecordingVideo, isTrue);
          expect(maxCamerasOpenAtOnce(), 1);

          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted');
          expect(fate('staleAtAdmission'), 2);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X253 — the slow stop ends in an ERROR with ticks behind it: no restart, one error, and the tick that waited does not '
      'issue a second stop for the Recording whose stop failed',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          tickA();
          tickA();
          tickA();

          gate.completeError(CameraException('stop_failed', 'forced late failure for this test'));
          await waitUntil(() => service.lateRotationSettlementCountForTest == 1 && service.queuedRotationCountForTest == 0, 'the failed stop and the tick behind it settling');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(count('startVideoCapturing'), 1, reason: 'no restart after a failed stop');
          expect(count('stopVideoRecording'), 1, reason: 'a terminally failed stop is never retried');
          expect(errors, hasLength(1));
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.clips, isEmpty);
          expect(service.lastLateRotationDecisionForTest, 'stopFailed');
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X254 — the user stops A while the rotation stop is slow and ticks are behind it (no new START): nothing restarts, and '
      'the tick that waited finds nothing to stop',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        try {
          final controller = service.previewController!;
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          tickA();
          tickA();
          tickA();

          await service.stopLoopRecording();
          gate.complete();
          await waitForRotationsToDrain();
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(count('startVideoCapturing'), 1, reason: 'no restart of the run the user stopped');
          expect(count('stopVideoRecording'), 1, reason: 'one stop for one Recording');
          expect(service.isRecording, isFalse);
          expect(controller.value.isRecordingVideo, isFalse);
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.liveStopIntentCountForTest, 0);
          expect(producers(), ['producer-A']);
          expect(service.lastLateRotationDecisionForTest, 'recordingNoLongerWanted');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X255 — the app goes to the background while the rotation stop is slow and ticks are behind it: nothing restarts and '
      'the tick that waited issues no stop; the foreground recovery opens one camera, after the old one is released',
      () async {
        final gate = await recordAWithHeldStops(stopDeadline: const Duration(milliseconds: 30));
        try {
          final oldController = service.previewController!;
          final tickA = timerTicks.single;
          tickA();
          await waitForHeldRotationStop();
          await waitUntil(() => service.rotationStopOverdue, 'the stop deadline being reported');
          tickA();
          tickA();
          tickA();

          service.notifyAppBackgrounded();
          gate.complete();
          await waitForRotationsToDrain();
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(count('startVideoCapturing'), 1, reason: 'no restart while backgrounded');
          expect(count('stopVideoRecording'), 1);
          expect(service.isRecording, isTrue, reason: 'the intent survives for the foreground recovery, as for any background loss');
          expect(service.cameraKnownUnavailable, isTrue);
          expect(producers(), ['producer-A']);
          expect(service.lastLateRotationDecisionForTest, 'cameraUnavailable');

          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'producer-A');
          expect(service.previewController, isNot(same(oldController)));
          expect(count('startVideoCapturing'), 2);
          expect(count('createCameraWithSettings'), 2);
          expect(maxCamerasOpenAtOnce(), 1);
          final callsBefore = fakePlatform.calls.length;
          tickA();
          expect(service.queuedRotationCountForTest, 0, reason: 'a tick of the run that ended with the old camera is not queued');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(fakePlatform.calls, hasLength(callsBefore));
          expect(fate('staleAtAdmission'), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );

    test(
      'X257 — the product\'s own deadline (5 s) and the stop the phone produced (6.95 s), across three segment periods: the '
      'late settlement is still valid for its own run — one restart, by itself, and no rotation on its heels',
      () async {
        final gate = await recordAWithHeldStops(segment: const Duration(seconds: 2));
        try {
          expect(service.stopVideoRecordingTimeout, const Duration(seconds: 5), reason: 'this test is about the product\'s own default');
          final controller = service.previewController!;
          await waitUntil(() => count('stopVideoRecording') == 1 && service.hasPendingNativeStop, 'the rotation stop being issued and held', within: const Duration(seconds: 6));
          final sinceStop = Stopwatch()..start();
          await waitUntil(() => service.rotationStopOverdue, 'the 5 s deadline being reported', within: const Duration(seconds: 8));
          final remaining = const Duration(milliseconds: 6950) - sinceStop.elapsed;
          if (remaining > Duration.zero) await Future<void>.delayed(remaining);

          // Ticks were due 2 s, 4 s and 6 s into the stop.
          expect(ticksFired(), greaterThanOrEqualTo(3), reason: 'test setup: the stop outlived at least two more segment periods');
          expect(service.queuedRotationCountForTest, 2, reason: 'the rotation in flight and one tick behind it');
          expect(count('startVideoCapturing'), 1, reason: 'nothing starts while the stop is in flight');
          expect(count('createCameraWithSettings'), 1);
          gate.complete();

          await waitForRotationsToDrain();
          expect(count('startVideoCapturing'), 2, reason: 'the next segment started by itself, once');
          expect(count('stopVideoRecording'), 1);
          expect(service.previewController, same(controller));
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.clips, hasLength(1));
          expect(service.lastLateRotationDecisionForTest, 'resume');
          expect(fate('absorbed'), 1);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
