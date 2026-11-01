// Fase 16.2-R4.3-R2.6.17 — START attempt settlement authority / targeted
// cleanup, at the DashcamService level (the service's own public API is the
// authority: none of this relies on what DashcamSessionController happens to
// call, or in which order).
//
// The independent review of R2.6.16 left two P2s of the public API, both older
// than that round:
//
//  P2-A — a stale cleanup withdraws a newer START. A cleanup that NAMES a
//         Recording took the recording intent down whenever its target matched,
//         and its target matched a Recording that was over (the id is never
//         reset) or one whose stop was pending — while the intent already
//         belonged to a START accepted later. That START then resolved without
//         error and never recorded.
//  P2-B — a START past its 5 s deadline. The caller is told at the deadline;
//         the native call is not cancelled. When it then succeeded, the late
//         Recording stayed on the camera with `isRecording == false`: a START
//         queued behind it failed, no stop could reach it, only a teardown.
//
// The contract pinned here:
//  * a cleanup that names a Recording acts for that Recording only: it takes
//    the recording intent down only while that Recording is the one the latest
//    START stands for. It still adopts the stop pending for the Recording it
//    names; it never withdraws, stops or disturbs a START accepted later;
//  * a START attempt owns everything it starts until it has really finished:
//    the caller's Future ending (at the deadline) ends neither the attempt nor
//    the barrier. A later START waits behind it. A late success is not turned
//    into a recording — the attempt stops the Recording it created, and only
//    then lets go of the queue. A late failure leaves nothing behind;
//  * a START that reports success has recorded.
//
// How the tests place things: a native call is "in flight" when the test holds
// it on a Completer; a START deadline "elapsed" when the START's own Future
// has resolved while its native call is still held (60 ms here; the three
// tests of the last group use the product's own 5 s, in real time).
//
// Waits are by cause (a call observed, a Future settled, the attempt reported
// as finished), never by elapsed time alone. The only fixed stretches of time
// are the windows in which something must NOT happen ([neverDuring]): a slow
// host can make such a window miss a defect, never report one that is not
// there. Assertions come in the same order every time: what the camera and the
// queue did first, the name of the service's own decision last.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/services/dashcam_service.dart';

import 'support/fake_camera_platform.dart';

/// A call whose outcome the test reads later: [error] stays `null` when it
/// resolved normally.
class _Tracked {
  _Tracked(Future<void> future) {
    done = future.then(
      (_) {
        settled = true;
      },
      onError: (Object e) {
        settled = true;
        error = e;
      },
    );
  }

  late final Future<void> done;
  bool settled = false;
  Object? error;
}

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
  const patience = Duration(seconds: 3);

  /// A START deadline short enough to elapse within a test. It only ever
  /// elapses over a native START the test holds on a gate, so it cannot fire by
  /// accident. The STOP deadline is never shortened here: it also covers the
  /// real file I/O of a clip, and a short one would make a slow disk look like
  /// a defect.
  const shortDeadline = Duration(milliseconds: 60);

  /// How long a teardown requested under a native START still in flight is
  /// watched for letting go of the camera too early ([neverDuring]).
  const teardownWindow = Duration(milliseconds: 150);

  DashcamConfig config() => DashcamConfig(
    cameraSelection: CameraSelection.rear,
    storageQuotaMb: 1024,
    audioEnabled: false,
    resolution: VideoResolution.hd720,
    frameRate: 30,
    enabled: true,
  );

  /// `false` keeps the product's own default deadline (5 s).
  DashcamService build({bool shortStartDeadline = false}) {
    final built = shortStartDeadline
        ? DashcamService(config: config(), segmentDuration: manualTicksOnly, startVideoRecordingTimeout: shortDeadline)
        : DashcamService(config: config(), segmentDuration: manualTicksOnly);
    built.segmentTimerArmedHookForTest = timerTicks.add;
    return built;
  }

  int count(String call) => fakePlatform.calls.where((c) => c == call).length;
  List<Object?> producers() => service.clips.map((c) => c.producerToken).toList();
  _Tracked start(String producer) => _Tracked(service.startLoopRecording(clipOwnerToken: producer));

  /// The service's own account of what it did to the STARTs that did not end up
  /// recording — always asserted last.
  Map<String, int> startFates({int retracted = 0, int beforeEmission = 0, int afterEmission = 0, int ownRecordingFinalized = 0}) => {
    'ownIntentRetracted': retracted,
    'supersededBeforeEmission': beforeEmission,
    'supersededAfterEmission': afterEmission,
    'ownRecordingFinalized': ownRecordingFinalized,
  };

  Future<void> waitUntil(bool Function() condition, String what, {Duration within = const Duration(seconds: 5)}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail(
      'never happened within ${within.inMilliseconds} ms: $what '
      '(isRecording=${service.isRecording}, attemptSettling=${service.startAttemptSettling}, pendingStop=${service.hasPendingNativeStop}, '
      'unavailable=${service.cameraKnownUnavailable}, startFates=${service.startFatesForTest}, calls=${fakePlatform.calls.join(',')})',
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

  /// The START attempt in the queue has finished everything it owed — whatever
  /// that was — and no stop is in flight. A wait that does not presuppose what
  /// the attempt did.
  Future<void> waitForTheAttemptToFinish() {
    return waitUntil(() => !service.startAttemptSettling && !service.hasPendingNativeStop, 'the START attempt finishing');
  }

  /// What every scenario must end in, stated once: the service does not say it
  /// records, the camera does not record, no START attempt and no stop is in
  /// flight, and no segment timer is armed.
  void expectNothingRecording() {
    expect(service.isRecording, isFalse, reason: 'the service does not claim to record');
    expect(service.previewController?.value.isRecordingVideo ?? false, isFalse, reason: 'zero physical recordings left');
    expect(service.startAttemptSettling, isFalse, reason: 'no START attempt left settling');
    expect(service.hasPendingNativeStop, isFalse);
    expect(service.hasActiveSegmentTimerForTest, isFalse, reason: 'no segment timer left armed');
  }

  /// One plain stop of whatever is recording now: it must find a Recording made
  /// by [producer], really stop it, and leave nothing recording.
  Future<void> stopAndExpectItWas(String producer) async {
    final stopsBefore = count('stopVideoRecording');
    final recording = service.activeRecordingId;
    final stop = service.beginStopLoopRecording();
    final handle = await stop.handle.timeout(patience);
    await stop.presentation.timeout(patience);
    expect(handle, isNotNull, reason: 'the stop found something to stop');
    expect(handle!.recordingId, recording);
    expect(handle.producerToken, producer, reason: 'and what it stopped was recorded by $producer');
    await handle.settlement.timeout(patience);
    expect(count('stopVideoRecording'), stopsBefore + 1);
    expect(service.clips.last.producerToken, producer);
    expectNothingRecording();
  }

  /// Recording 0 ('producer-0') recorded on a freshly built service.
  Future<void> recordRecording0() async {
    service = build();
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'producer-0');
  }

  /// An initialized service; the native START(s) to come are held on the
  /// returned gate. With [afterRecording0], recording 0 came and went first.
  Future<Completer<void>> holdNextStart({bool afterRecording0 = false, bool shortStartDeadline = false}) async {
    service = build(shortStartDeadline: shortStartDeadline);
    await service.initialize();
    if (afterRecording0) {
      await service.startLoopRecording(clipOwnerToken: 'producer-0');
      await service.stopLoopRecording();
      await waitUntil(() => !service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'recording 0 being stopped');
    }
    final gate = Completer<void>();
    fakePlatform.pendingStartVideoCapturing = gate;
    return gate;
  }

  /// START A is requested, its native call is issued and held, and its own
  /// (short) START deadline elapses: A's Future has resolved, the native call
  /// has not returned.
  Future<_Tracked> startAAndLetItsDeadlineElapse({int nativeStartsSoFar = 0}) async {
    final a = start('producer-A');
    await waitUntil(() => count('startVideoCapturing') == nativeStartsSoFar + 1, 'the native START of A being issued and held');
    // By cause: the Future of A resolves at A's own deadline, not before.
    await a.done.timeout(patience);
    expect(a.error, isNull, reason: 'test setup: a START past its deadline resolves quietly, as it always did');
    expect(count('startVideoCapturing'), nativeStartsSoFar + 1, reason: 'test setup: the native START of A has not returned');
    return a;
  }

  /// Releases the held native START; any START after it goes straight through.
  void releaseStart(Completer<void> gate) {
    fakePlatform.pendingStartVideoCapturing = null;
    gate.complete();
  }

  setUp(() {
    timerTicks = [];
    dir = Directory.systemTemp.createTempSync('dashcam_start_attempt_settlement_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    // Last-resort barrier: every test releases its own gates in a `finally`.
    fakePlatform.failStopVideoRecordingWith = null;
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

  group('Fase 16.2-R4.3-R2.6.17 — a cleanup that names a Recording does not withdraw a START accepted after it (P2-A)', () {
    test(
      'X292 — the independent review\'s first sequence: recording 0 is being stopped (native stop in flight), START B is '
      'accepted behind it, and a cleanup aimed at recording 0 arrives. The cleanup adopts the stop of recording 0 — and '
      'gets its handle — but B\'s intent is not its to take down: B starts, records as B, and the next stop stops B',
      () async {
        await recordRecording0();
        final stopGate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGate;
        try {
          final controller = service.previewController!;
          final owner = DashcamService.processOwnerCurrentForTest;
          final recording0 = service.activeRecordingId!;
          final stop0 = service.stopLoopRecording();
          await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'the stop of recording 0 being issued and held');
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted, behind the stop in flight');

          final cleanup = service.beginStopLoopRecording(expectedRecordingId: recording0, expectedController: controller);
          final wantedRightAfterTheCleanup = service.isRecording;
          stopGate.complete();
          await Future.wait([stop0, b.done, cleanup.presentation]).timeout(patience);
          final handle = await cleanup.handle.timeout(patience);

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'B really started — a START that reports success has recorded');
          expect(count('stopVideoRecording'), 1, reason: 'recording 0 only');
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(service.activeRecordingId, recording0 + 1);
          expect(timerTicks, hasLength(2), reason: 'recording 0\'s and B\'s');
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(producers(), ['producer-0']);
          expect(handle, isNotNull, reason: 'the cleanup still reached what it named: the stop of recording 0');
          expect(handle!.recordingId, recording0);
          expect(handle.producerToken, 'producer-0');
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'the cleanup named recording 0: B\'s intent was never taken down');

          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-B']);
          expect(service.previewController, same(controller));
          expect(DashcamService.processOwnerCurrentForTest, same(owner));
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X293 — its second sequence: recording 0 is over, the native START of B is in flight, and a cleanup still aimed at '
      'recording 0 arrives. It withdraws nothing and stops nothing: B keeps its intent, records with its own timer — which '
      'still rotates B — and the next stop stops B',
      () async {
        final startGate = await holdNextStart(afterRecording0: true);
        try {
          final controller = service.previewController!;
          final recording0 = service.activeRecordingId!;
          final b = start('producer-B');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of B being issued and held');

          final cleanup = service.beginStopLoopRecording(expectedRecordingId: recording0, expectedController: controller);
          final wantedRightAfterTheCleanup = service.isRecording;
          releaseStart(startGate);
          await Future.wait([b.done, cleanup.presentation]).timeout(patience);
          await waitForTheAttemptToFinish();

          expect(b.error, isNull);
          expect(count('stopVideoRecording'), 1, reason: 'recording 0 only — nothing of B was stopped');
          expect(count('startVideoCapturing'), 2);
          expect(controller.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.activeRecordingId, recording0 + 1);
          expect(timerTicks, hasLength(2), reason: 'recording 0\'s and B\'s');
          expect(service.hasActiveSegmentTimerForTest, isTrue, reason: 'B\'s timer was not cancelled');
          expect(producers(), ['producer-0']);
          expect(await cleanup.handle.timeout(patience), isNull, reason: 'the cleanup named recording 0, which was over: it stopped nothing');
          expect(wantedRightAfterTheCleanup, isTrue);

          // B's own timer still rotates B.
          timerTicks.last();
          await waitUntil(
            () => count('startVideoCapturing') == 3 && service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop,
            'the tick rotating B',
          );
          expect(producers(), ['producer-0', 'producer-B']);
          await stopAndExpectItWas('producer-B');
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(), reason: 'B was never withdrawn: it had nothing to clean up');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X294 — its third: A in flight, A is stopped, START B is accepted, and when A\'s START returns the caller of A cleans '
      'up A\'s Recording — by name. That cleanup is about A: B is not withdrawn. A\'s Recording is stopped once, by the stop '
      'that withdrew A; B starts and records as B',
      () async {
        final startGate = await holdNextStart(afterRecording0: true);
        try {
          final controller = service.previewController!;
          final recording0 = service.activeRecordingId!;
          DashcamStopOutcome? cleanupOfA;
          bool? wantedRightAfterTheCleanupOfA;
          final a = _Tracked(
            service.startLoopRecording(clipOwnerToken: 'producer-A').then((_) {
              // What DashcamSessionController does right after a START that
              // returned for an attempt that is no longer the current one.
              cleanupOfA = service.beginStopLoopRecording(expectedRecordingId: service.activeRecordingId, expectedController: controller);
              wantedRightAfterTheCleanupOfA = service.isRecording;
            }),
          );
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          final stopOfA = service.beginStopLoopRecording();
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted while the native START of A is in flight');
          releaseStart(startGate);
          await Future.wait([a.done, b.done, stopOfA.presentation]).timeout(patience);
          await cleanupOfA!.presentation.timeout(patience);
          final handleOfTheStop = await stopOfA.handle.timeout(patience);

          expect(a.error, isNull);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 3, reason: 'recording 0, A, B — B really started');
          expect(count('stopVideoRecording'), 2, reason: 'recording 0, and A\'s Recording — once');
          expect(handleOfTheStop, isNotNull, reason: 'the stop that withdrew A stopped A\'s Recording');
          expect(handleOfTheStop!.recordingId, recording0 + 1);
          expect(handleOfTheStop.producerToken, 'producer-A');
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(service.activeRecordingId, recording0 + 2);
          expect(timerTicks, hasLength(2), reason: 'recording 0\'s and B\'s');
          expect(producers(), ['producer-0', 'producer-A']);
          expect(wantedRightAfterTheCleanupOfA, isTrue, reason: 'the cleanup of A did not take B\'s intent down');

          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-A', 'producer-B']);

          expect(service.startFatesForTest, startFates(afterEmission: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X295 — a cleanup of A arriving after B is already recording: no native call, B\'s Recording, intent and timer are '
      'intact, B\'s timer still rotates B, and the next stop stops B',
      () async {
        await recordRecording0();
        final controller = service.previewController!;
        final recordingA = service.activeRecordingId!;
        await service.stopLoopRecording();
        await waitUntil(() => !service.hasPendingNativeStop, 'recording 0 being stopped');
        final b = start('producer-B');
        await b.done.timeout(patience);
        final recordingB = service.activeRecordingId;
        final callsBefore = fakePlatform.calls.length;

        final cleanup = service.beginStopLoopRecording(expectedRecordingId: recordingA, expectedController: controller);
        await cleanup.presentation.timeout(patience);

        expect(fakePlatform.calls.length, callsBefore, reason: 'the cleanup of the old Recording emitted nothing');
        expect(await cleanup.handle.timeout(patience), isNull);
        expect(controller.value.isRecordingVideo, isTrue);
        expect(service.isRecording, isTrue);
        expect(service.activeRecordingId, recordingB);
        expect(service.hasActiveSegmentTimerForTest, isTrue);

        timerTicks.last();
        await waitUntil(
          () => count('startVideoCapturing') == 3 && service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop,
          'the tick rotating B',
        );
        expect(producers(), ['producer-0', 'producer-B']);
        await stopAndExpectItWas('producer-B');
      },
    );

    test(
      'X296 — what did NOT change: a cleanup that names the Recording of the latest START is that START\'s own cleanup. It '
      'takes the intent down at once, stops that Recording, and gets its handle',
      () async {
        service = build();
        await service.initialize();
        final controller = service.previewController!;
        final a = start('producer-A');
        await a.done.timeout(patience);
        final recordingA = service.activeRecordingId!;
        expect(service.hasActiveSegmentTimerForTest, isTrue);

        final cleanup = service.beginStopLoopRecording(expectedRecordingId: recordingA, expectedController: controller);
        expect(service.isRecording, isFalse, reason: 'the intent is the named Recording\'s own: taken down at once');
        expect(service.hasActiveSegmentTimerForTest, isFalse);
        final handle = await cleanup.handle.timeout(patience);
        await cleanup.presentation.timeout(patience);

        expect(handle, isNotNull);
        expect(handle!.recordingId, recordingA);
        expect(handle.producerToken, 'producer-A');
        await handle.settlement.timeout(patience);
        expect(count('stopVideoRecording'), 1);
        expect(producers(), ['producer-A']);
        expectNothingRecording();
      },
    );

    test(
      'X297 — a cleanup of an old camera does not let go of the new one. A release naming the old camera is accepted while '
      'that camera is still the current one, and waits behind the re-initialize that replaces it: when its turn comes it '
      'disposes nothing and leaves the process owner where it is. Then, with B recording on the new camera, a release and a '
      'stop that name the old one emit nothing',
      () async {
        service = build();
        await service.initialize();
        final oldController = service.previewController!;
        final owner = DashcamService.processOwnerCurrentForTest;
        final reinitializing = service.initialize();
        final staleRelease = service.releaseIdleCamera(expectedController: oldController);
        await Future.wait([reinitializing, staleRelease]).timeout(patience);
        expect(service.previewController, isNotNull, reason: 'the stale release did not take the new camera away');
        final newController = service.previewController!;
        expect(newController, isNot(same(oldController)), reason: 'test setup: the camera was replaced');
        expect(count('dispose'), 1, reason: 'the old camera, disposed by the re-initialize — and nothing else');
        expect(DashcamService.processOwnerCurrentForTest, isNotNull, reason: 'the process owner of the new camera was not released');
        expect(DashcamService.processOwnerCurrentForTest, same(owner));
        final b = start('producer-B');
        await b.done.timeout(patience);
        final callsBefore = fakePlatform.calls.length;

        await service.releaseIdleCamera(expectedController: oldController).timeout(patience);
        final stop = service.beginStopLoopRecording(expectedController: oldController);
        await stop.presentation.timeout(patience);

        expect(fakePlatform.calls.length, callsBefore, reason: 'neither call emitted anything');
        expect(await stop.handle.timeout(patience), isNull);
        expect(service.previewController, same(newController));
        expect(DashcamService.processOwnerCurrentForTest, same(owner), reason: 'the process owner was not released');
        expect(newController.value.isRecordingVideo, isTrue);
        expect(service.isRecording, isTrue);
        expect(service.hasActiveSegmentTimerForTest, isTrue);
        await stopAndExpectItWas('producer-B');
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.17 — a START attempt owns what it starts until it has really finished (P2-B)', () {
    test(
      'X298 — the independent review\'s sequence: A\'s START deadline elapses, START B is accepted, and A\'s native START '
      'then succeeds. B waits behind A — no second native START while A\'s is in flight; A stops the Recording it created; '
      'only then B starts, and records as B. The next stop stops B',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final owner = DashcamService.processOwnerCurrentForTest;
          final a = await startAAndLetItsDeadlineElapse();
          final wantedAtTheDeadline = service.isRecording;
          final settlingAtTheDeadline = service.startAttemptSettling;

          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted after A\'s deadline');
          await neverDuring(
            const Duration(milliseconds: 150),
            () => count('startVideoCapturing') != 1 || b.settled,
            'B starting, or its Future settling, while the native START of A is still in flight',
          );
          expect(service.startAttemptSettling, isTrue, reason: 'A\'s attempt is still the one holding the queue');

          releaseStart(startGate);
          await b.done.timeout(patience);

          expect(b.error, isNull, reason: 'B found the camera free');
          expect(count('startVideoCapturing'), 2, reason: 'A, then B — one at a time');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped by A');
          expect(producers(), ['producer-A'], reason: 'the late clip is kept, as A\'s');
          expect(controller.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.startAttemptSettling, isFalse);
          expect(timerTicks, hasLength(1), reason: 'B\'s — A armed none');
          expect(a.error, isNull);
          expect(wantedAtTheDeadline, isFalse, reason: 'as before: at its own deadline a START takes its own intent down');
          expect(settlingAtTheDeadline, isTrue, reason: 'and yet its attempt was still settling');
          expect(errors, isEmpty);

          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-A', 'producer-B']);
          expect(service.previewController, same(controller));
          expect(DashcamService.processOwnerCurrentForTest, same(owner));
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0, reason: 'no teardown was needed to get here');

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X299 — the deadline elapses, START B is accepted, and A\'s native START then FAILS: reported once as A\'s late '
      'failure, nothing was started so nothing is stopped, the barrier is released and B starts and records',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          await startAAndLetItsDeadlineElapse();
          final b = start('producer-B');
          fakePlatform.pendingStartVideoCapturing = null;
          startGate.completeError(CameraException('start_failed', 'the native START of A failed, late'));
          await b.done.timeout(patience);

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'A (failed) and B — B really started');
          expect(count('stopVideoRecording'), 0, reason: 'A never recorded: there was nothing to stop');
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(service.startAttemptSettling, isFalse);
          expect(timerTicks, hasLength(1));
          expect(errors, hasLength(1), reason: 'A\'s late failure, reported once');
          expect(errors.single, contains('start_failed'));
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-B']);

          expect(service.startFatesForTest, startFates(), reason: 'A created nothing: it had nothing to clean up');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X300 — the deadline elapses and A\'s native START then fails, with nothing else requested: reported once, zero '
      'recordings, zero stops, the attempt is over and the next START records',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          await startAAndLetItsDeadlineElapse();
          fakePlatform.pendingStartVideoCapturing = null;
          startGate.completeError(CameraException('start_failed', 'the native START of A failed, late'));
          await waitForTheAttemptToFinish();

          expect(count('stopVideoRecording'), 0);
          expect(count('startVideoCapturing'), 1);
          expectNothingRecording();
          expect(service.clips, isEmpty);
          expect(errors, hasLength(1));
          expect(errors.single, contains('start_failed'));

          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull);
          expect(controller.value.isRecordingVideo, isTrue);
          await stopAndExpectItWas('producer-D');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X301 — the deadline elapses, a stop is requested (it finds nothing to reach yet), START B is accepted, and A\'s '
      'native START then succeeds: A stops its own late Recording, B starts and records as B',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final controller = service.previewController!;
          await startAAndLetItsDeadlineElapse();
          final stopBeforeTheLateResult = service.beginStopLoopRecording();
          await stopBeforeTheLateResult.presentation.timeout(patience);
          final b = start('producer-B');
          releaseStart(startGate);
          await b.done.timeout(patience);

          expect(b.error, isNull);
          expect(await stopBeforeTheLateResult.handle.timeout(patience), isNull, reason: 'that stop found nothing recording and queued nothing');
          expect(count('startVideoCapturing'), 2);
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped by A');
          expect(producers(), ['producer-A']);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(timerTicks, hasLength(1));
          await stopAndExpectItWas('producer-B');

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X302 — the deadline elapses, then B, STOP, C are requested while A\'s native START is still in flight, and it then '
      'succeeds: only the latest intent survives. A\'s late Recording is stopped once — by the stop that is queued, so A '
      'leaves it to that stop; B emits nothing; C starts and records as C',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final controller = service.previewController!;
          final a = await startAAndLetItsDeadlineElapse();
          final b = start('producer-B');
          final stopOfB = service.beginStopLoopRecording();
          final c = start('producer-C');
          expect(count('startVideoCapturing'), 1, reason: 'test setup: all of it while the native START of A is in flight');
          releaseStart(startGate);
          await Future.wait([b.done, c.done, stopOfB.presentation]).timeout(patience);
          final handleOfTheStop = await stopOfB.handle.timeout(patience);

          expect([a.error, b.error, c.error], everyElement(isNull));
          expect(count('startVideoCapturing'), 2, reason: 'A, then C — B emitted nothing');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, once');
          expect(handleOfTheStop, isNotNull, reason: 'the queued stop is the one that stopped it');
          expect(handleOfTheStop!.producerToken, 'producer-A');
          expect(producers(), ['producer-A']);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(timerTicks, hasLength(1), reason: 'C\'s only');
          await stopAndExpectItWas('producer-C');
          expect(producers(), ['producer-A', 'producer-C']);

          expect(service.startFatesForTest, startFates(beforeEmission: 1, afterEmission: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X315 — the deadline elapses, START B is accepted, A\'s native START succeeds late, B records — and then C. A START '
      'requested while B records is absorbed, as it always was: no native call, B goes on as B. Once B is stopped, START C '
      'records as C. Nothing of A reaches either of them',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final controller = service.previewController!;
          await startAAndLetItsDeadlineElapse();
          final b = start('producer-B');
          releaseStart(startGate);
          await b.done.timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'test setup: A, then B');
          expect(count('stopVideoRecording'), 1, reason: 'test setup: A\'s late Recording, stopped by A');
          final recordingB = service.activeRecordingId;

          final absorbed = start('producer-C');
          await absorbed.done.timeout(patience);
          expect(absorbed.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'a START while a recording is wanted is absorbed: no native call');
          expect(service.activeRecordingId, recordingB);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          await stopAndExpectItWas('producer-B');

          final c = start('producer-C');
          await c.done.timeout(patience);
          expect(c.error, isNull);
          expect(count('startVideoCapturing'), 3, reason: 'A, B, C — one each');
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(timerTicks, hasLength(2), reason: 'B\'s and C\'s — A armed none');
          await stopAndExpectItWas('producer-C');
          expect(producers(), ['producer-A', 'producer-B', 'producer-C']);
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0, reason: 'no teardown was needed to get here');

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X303 — dispose while A\'s native START is in flight past its deadline: the camera and the process owner are NOT '
      'let go while the native call can still produce a Recording. When it returns, the teardown stops A\'s late '
      'Recording — once — and only then releases everything; nothing records after dispose',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final controller = service.previewController!;
          final owner = DashcamService.processOwnerCurrentForTest;
          await startAAndLetItsDeadlineElapse();

          final disposing = service.dispose();
          // A window of real time that does not depend on what the service does:
          // a teardown that did not wait for the native START would let go of
          // the camera well within it.
          await neverDuring(
            teardownWindow,
            () => count('dispose') > 0 || !identical(service.previewController, controller) || !identical(DashcamService.processOwnerCurrentForTest, owner),
            'the camera or the process owner being let go under a native START still in flight',
          );
          expect(service.startAttemptSettling, isTrue);
          expect(count('stopVideoRecording'), 0);

          releaseStart(startGate);
          await disposing.timeout(patience);
          await waitUntil(
            () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
            'the teardown releasing the camera and the process owner',
          );
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped once');
          expect(count('dispose'), 1);
          expect(producers(), ['producer-A'], reason: 'the late clip is kept, as A\'s');
          expect(service.isRecording, isFalse);
          expect(service.startAttemptSettling, isFalse);
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(() => service.startLoopRecording(clipOwnerToken: 'producer-B'), throwsStateError);

          expect(service.startFatesForTest, startFates(), reason: 'the teardown owned the late Recording; A left it to the teardown');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X304 — releaseIdleCamera while A\'s native START is in flight past its deadline: same barrier, and the service stays '
      'usable — after the late Recording is stopped and the camera released, a fresh camera and START B record as B',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final controller = service.previewController!;
          final owner = DashcamService.processOwnerCurrentForTest;
          await startAAndLetItsDeadlineElapse();

          final releasing = service.releaseIdleCamera();
          await neverDuring(
            teardownWindow,
            () => count('dispose') > 0 || !identical(service.previewController, controller) || !identical(DashcamService.processOwnerCurrentForTest, owner),
            'the camera or the process owner being let go under a native START still in flight',
          );
          expect(service.startAttemptSettling, isTrue);
          expect(count('stopVideoRecording'), 0);

          releaseStart(startGate);
          await releasing.timeout(patience);
          await waitUntil(
            () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
            'the release letting go of the camera and the process owner',
          );
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped once');
          expect(count('dispose'), 1);
          expect(producers(), ['producer-A']);
          expect(service.isRecording, isFalse);

          await service.initialize();
          final b = start('producer-B');
          await b.done.timeout(patience);
          expect(b.error, isNull);
          expect(service.previewController!.value.isRecordingVideo, isTrue);
          expect(service.cameraKnownUnavailable, isFalse, reason: 'a fresh camera starts clean');
          await stopAndExpectItWas('producer-B');

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X305 — dispose while A is stopping its own late Recording: the teardown waits for that stop, the Recording is stopped '
      'once, its clip is kept, and everything is released',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        final stopGate = Completer<void>();
        try {
          await startAAndLetItsDeadlineElapse();
          fakePlatform.pendingStopVideoRecording = stopGate;
          releaseStart(startGate);
          // By cause: A's native START returned and A went on to what it owes — or finished, if it owed nothing.
          await waitUntil(() => service.hasPendingNativeStop || !service.startAttemptSettling, 'A\'s own stop being issued and held');
          expect(count('stopVideoRecording'), 1, reason: 'A stops the Recording it created');
          expect(service.startAttemptSettling, isTrue, reason: 'the attempt is not over until that stop settles');

          final disposing = service.dispose();
          expect(count('dispose'), 0, reason: 'the camera is not disposed under a stop still in flight');
          stopGate.complete();
          await disposing.timeout(patience);
          await waitUntil(
            () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
            'dispose releasing the camera and the process owner',
          );

          expect(count('stopVideoRecording'), 1, reason: 'stopped once');
          expect(count('dispose'), 1);
          expect(producers(), ['producer-A']);
          expect(service.isRecording, isFalse);
          expect(service.startAttemptSettling, isFalse);

          expect(service.startFatesForTest, startFates(ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X314 — dispose with A past its deadline AND START B waiting behind it: when A\'s native START succeeds late, the '
      'teardown stops that Recording — once — and B never reaches the camera. Nothing old starts a recording after dispose',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          await startAAndLetItsDeadlineElapse();
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted after A\'s deadline');

          final disposing = service.dispose();
          final wantedRightAfterDispose = service.isRecording;
          releaseStart(startGate);
          await Future.wait([disposing, b.done]).timeout(patience);
          await waitUntil(
            () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
            'the teardown releasing the camera and the process owner',
          );

          expect(b.error, isNull, reason: 'a START withdrawn while it waited completes quietly, as it always did');
          expect(count('startVideoCapturing'), 1, reason: 'A only: B never reached the camera');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped once');
          expect(count('dispose'), 1);
          expect(producers(), ['producer-A']);
          expect(service.isRecording, isFalse);
          expect(service.startAttemptSettling, isFalse);
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(wantedRightAfterDispose, isFalse, reason: 'dispose took the intent down — B\'s included');

          expect(service.startFatesForTest, startFates(afterEmission: 1), reason: 'the teardown owned the late Recording; B was withdrawn, not superseded');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.17 — the two together: an old attempt never erases the new one', () {
    test(
      'X306 — A past its deadline, START B accepted, A\'s native START succeeds, and while A is stopping its own late '
      'Recording the caller of A also cleans it up, by name. That cleanup adopts A\'s stop and gets its handle; B — which '
      'has started nothing yet — keeps its intent, then starts and records as B',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        final stopGate = Completer<void>();
        try {
          final controller = service.previewController!;
          await startAAndLetItsDeadlineElapse();
          final b = start('producer-B');
          fakePlatform.pendingStopVideoRecording = stopGate;
          releaseStart(startGate);
          await waitUntil(() => service.hasPendingNativeStop || b.settled, 'A\'s own stop being issued and held');
          expect(count('stopVideoRecording'), 1, reason: 'A stops the Recording it created');
          final recordingA = service.activeRecordingId!;

          final cleanupOfA = service.beginStopLoopRecording(expectedRecordingId: recordingA, expectedController: controller);
          final wantedRightAfterTheCleanupOfA = service.isRecording;
          expect(b.settled, isFalse, reason: 'B waits its turn behind A\'s cleanup');
          expect(count('startVideoCapturing'), 1, reason: 'B has started nothing yet');
          stopGate.complete();
          await Future.wait([b.done, cleanupOfA.presentation]).timeout(patience);
          final handle = await cleanupOfA.handle.timeout(patience);

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'B really started');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording — once');
          expect(handle, isNotNull, reason: 'the cleanup of A reached what it named');
          expect(handle!.recordingId, recordingA);
          expect(producers(), ['producer-A']);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(service.activeRecordingId, recordingA + 1);
          expect(timerTicks, hasLength(1));
          expect(wantedRightAfterTheCleanupOfA, isTrue, reason: 'the cleanup of A did not take B\'s intent down');
          await stopAndExpectItWas('producer-B');

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X313 — a stale cleanup waiting in the queue is not an owner. A in flight; a cleanup naming the previous Recording '
      'arrives (it withdraws nothing and waits its turn); A\'s deadline elapses; START B is accepted; A\'s native START '
      'then succeeds. A still stops its own late Recording — that cleanup could never reach it — and B records as B',
      () async {
        final startGate = await holdNextStart(afterRecording0: true, shortStartDeadline: true);
        try {
          final controller = service.previewController!;
          final recording0 = service.activeRecordingId!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          final staleCleanup = service.beginStopLoopRecording(expectedRecordingId: recording0, expectedController: controller);
          final wantedRightAfterTheCleanup = service.isRecording;
          // By cause: the Future of A resolves at A's own deadline, not before.
          await a.done.timeout(patience);
          final b = start('producer-B');
          releaseStart(startGate);
          await Future.wait([b.done, staleCleanup.presentation]).timeout(patience);

          expect(b.error, isNull, reason: 'B found the camera free');
          expect(count('startVideoCapturing'), 3, reason: 'recording 0, A, B');
          expect(count('stopVideoRecording'), 2, reason: 'recording 0, and A\'s late Recording — stopped by A');
          expect(producers(), ['producer-0', 'producer-A']);
          expect(await staleCleanup.handle.timeout(patience), isNull, reason: 'the stale cleanup named recording 0, and stopped nothing');
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(service.activeRecordingId, recording0 + 2);
          expect(timerTicks, hasLength(2), reason: 'recording 0\'s and B\'s');
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'the stale cleanup had not withdrawn A either');
          await stopAndExpectItWas('producer-B');

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X307 — A past its deadline, STOP, START B, A\'s native START succeeds late, B records; then a cleanup of A arrives '
      'late, B is stopped, and START C is requested: the late cleanup touches nothing of B, and C records as C',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final controller = service.previewController!;
          await startAAndLetItsDeadlineElapse();
          final stopBeforeTheLateResult = service.beginStopLoopRecording();
          await stopBeforeTheLateResult.presentation.timeout(patience);
          final b = start('producer-B');
          releaseStart(startGate);
          await b.done.timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'test setup: A, then B');
          final recordingB = service.activeRecordingId!;
          final recordingA = recordingB - 1;
          final callsBefore = fakePlatform.calls.length;

          final lateCleanupOfA = service.beginStopLoopRecording(expectedRecordingId: recordingA, expectedController: controller);
          await lateCleanupOfA.presentation.timeout(patience);
          expect(fakePlatform.calls.length, callsBefore, reason: 'the late cleanup of A emitted nothing');
          expect(await lateCleanupOfA.handle.timeout(patience), isNull);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(service.activeRecordingId, recordingB);
          expect(service.hasActiveSegmentTimerForTest, isTrue);

          await stopAndExpectItWas('producer-B');
          final c = start('producer-C');
          await c.done.timeout(patience);
          expect(c.error, isNull);
          expect(count('startVideoCapturing'), 3, reason: 'C really started');
          expect(controller.value.isRecordingVideo, isTrue);
          await stopAndExpectItWas('producer-C');
          expect(producers(), ['producer-A', 'producer-B', 'producer-C']);
          expect(count('dispose'), 0);
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.17 — the same with the product\'s own 5 s START deadline, in real time', () {
    /// The product's deadlines, nothing injected. [hold] is how long the native
    /// START of A stays in flight, counted from the instant it was issued.
    Future<(_Tracked, Completer<void>, Stopwatch)> startAWithTheProductDeadline() async {
      service = build();
      expect(service.startVideoRecordingTimeout, const Duration(seconds: 5), reason: 'test setup: the product\'s own deadline');
      await service.initialize();
      final gate = Completer<void>();
      fakePlatform.pendingStartVideoCapturing = gate;
      final a = start('producer-A');
      await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
      final sinceTheNativeCall = Stopwatch()..start();
      await a.done.timeout(const Duration(seconds: 8));
      expect(a.error, isNull);
      expect(sinceTheNativeCall.elapsedMilliseconds, greaterThanOrEqualTo(4900), reason: 'the Future of A resolved at the 5 s deadline, not before');
      expect(sinceTheNativeCall.elapsedMilliseconds, lessThan(5900));
      expect(count('startVideoCapturing'), 1, reason: 'test setup: the native START of A has not returned');
      expect(service.isRecording, isFalse);
      expect(service.startAttemptSettling, isTrue);
      return (a, gate, sinceTheNativeCall);
    }

    Future<void> holdUntil(Stopwatch sinceTheNativeCall, Duration hold) async {
      final remaining = hold - sinceTheNativeCall.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    }

    test(
      'X308 — 5.1 s: START B is accepted after the deadline and waits; A\'s native START succeeds at 5.1 s; A stops its late '
      'Recording, B starts and records as B',
      () async {
        final (_, gate, sinceTheNativeCall) = await startAWithTheProductDeadline();
        try {
          final controller = service.previewController!;
          final b = start('producer-B');
          await holdUntil(sinceTheNativeCall, const Duration(milliseconds: 5100));
          expect(count('startVideoCapturing'), 1, reason: 'B did not start while the native START of A was in flight');
          expect(b.settled, isFalse);
          releaseStart(gate);
          await b.done.timeout(patience);

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2);
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped by A');
          expect(producers(), ['producer-A']);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          await stopAndExpectItWas('producer-B');
          expect(count('dispose'), 0);
          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'X309 — 7 s: nothing else is requested; A\'s native START succeeds at 7 s; the late Recording is stopped by A and '
      'nothing is left recording; a stop afterwards has nothing to do',
      () async {
        final (_, gate, sinceTheNativeCall) = await startAWithTheProductDeadline();
        try {
          final controller = service.previewController!;
          await holdUntil(sinceTheNativeCall, const Duration(seconds: 7));
          expect(count('stopVideoRecording'), 0);
          releaseStart(gate);
          await waitForTheAttemptToFinish();

          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped by A');
          expect(count('startVideoCapturing'), 1);
          expect(producers(), ['producer-A']);
          expectNothingRecording();
          expect(service.previewController, same(controller), reason: 'the camera stays held, idle');
          final stop = service.beginStopLoopRecording();
          await stop.presentation.timeout(patience);
          expect(await stop.handle.timeout(patience), isNull, reason: 'nothing was left for a stop to find');
          expect(count('stopVideoRecording'), 1);
          expect(count('dispose'), 0);
          expect(service.startFatesForTest, startFates(ownRecordingFinalized: 1));
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'X310 — 10 s: a stop and then START B are requested after the deadline; A\'s native START FAILS at 10 s; it is '
      'reported once, nothing is stopped, and B starts and records',
      () async {
        final (_, gate, sinceTheNativeCall) = await startAWithTheProductDeadline();
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final stopBeforeTheLateResult = service.beginStopLoopRecording();
          await stopBeforeTheLateResult.presentation.timeout(patience);
          final b = start('producer-B');
          await holdUntil(sinceTheNativeCall, const Duration(seconds: 10));
          expect(count('startVideoCapturing'), 1, reason: 'B did not start while the native START of A was in flight');
          expect(b.settled, isFalse);
          fakePlatform.pendingStartVideoCapturing = null;
          gate.completeError(CameraException('start_failed', 'the native START of A failed at 10 s'));
          await b.done.timeout(patience);

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2);
          expect(count('stopVideoRecording'), 0);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(errors, hasLength(1));
          expect(errors.single, contains('start_failed'));
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-B']);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await errorsSub.cancel();
        }
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });
}
