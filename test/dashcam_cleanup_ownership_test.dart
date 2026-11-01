// Fase 16.2-R4.3-R2.6.18 — cleanup ownership / restart attempt identity, at the
// DashcamService level (the service's own public API is the authority: none of
// this relies on what DashcamSessionController happens to call, or in which
// order).
//
// The substitute independent review of R2.6.17 left two P2s of the public API,
// both older than that round:
//
//  R1 — a cleanup that names ONLY the camera. `stopLoopRecording(
//       expectedController: c)` carried no START and no Recording, and was
//       taken to speak for whatever START stood at that instant. Issued by the
//       caller of an older attempt, it withdrew a newer START, which then
//       resolved without error and never recorded.
//  N1 — a cleanup that names the segment a rotation is replacing, issued while
//       the rotation's restart START is in flight. Its prefix withdrew the
//       recording intent (that segment was the latest START's); its turn in the
//       queue then compared ids, found the successor, and stopped nothing: the
//       camera went on recording with nobody owning it.
//
// The contract pinned here — stopping an old physical resource and changing the
// CURRENT logical state are different things, and what a cleanup may do depends
// on what it can prove by what it names:
//  * only the camera: nothing. It stops nothing and withdraws nothing;
//  * a START attempt (the identity `beginStartLoopRecording` hands out when the
//    START is accepted): what THAT START did. It takes the intent down only
//    while that START is still the latest one; it stops, adopts or owns only a
//    Recording of that attempt — its current segment, whatever id a rotation has
//    given it — and never anything a later START recorded;
//  * a Recording: that ONE segment, and only while it is still alive. A segment
//    a rotation has already ended is over: the cleanup has nothing left to
//    clean and the run goes on. Whether a successor really comes is not known
//    while the restart START is in flight, so such a cleanup decides when its
//    own turn in the queue comes: if none was created (the restart failed) the
//    segment it named was the run's last one, and the dead run's intent comes
//    down — the same outcome as when the cleanup arrives after the failure;
//  * a Recording keeps the START epoch of the attempt that created it, through
//    segment rotations and through STARTs accepted later;
//  * a START that reports success has recorded, and the next plain stop always
//    finds the Recording that is current — no dispose is needed to converge.
//
// How the tests place things: a native call is "in flight" when the test holds
// it on a Completer; a segment rotation is delivered by calling the tick of the
// run's own timer; "the restart is in flight" means the rotation has stopped
// the segment and its restart START is held.
//
// Waits are by cause (a call observed, a Future settled, the attempt reported
// as finished), never by elapsed time alone. Assertions come in the same order
// every time: what the camera and the queue did first, the name of the
// service's own decision last.
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

/// A START together with the identity the service gave it.
class _Started {
  _Started(DashcamStartOutcome outcome) : attempt = outcome.attempt, tracked = _Tracked(outcome.presentation);

  final DashcamStartAttempt? attempt;
  final _Tracked tracked;

  Future<void> get done => tracked.done;
  Object? get error => tracked.error;
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
  /// accident. The STOP deadline is never shortened here.
  const shortDeadline = Duration(milliseconds: 60);

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
  _Started start(String producer) => _Started(service.beginStartLoopRecording(clipOwnerToken: producer));

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
      '(isRecording=${service.isRecording}, cameraRecording=${service.previewController?.value.isRecordingVideo}, attemptSettling=${service.startAttemptSettling}, '
      'pendingStop=${service.hasPendingNativeStop}, activeRecordingId=${service.activeRecordingId}, unavailable=${service.cameraKnownUnavailable}, '
      'startFates=${service.startFatesForTest}, calls=${fakePlatform.calls.join(',')})',
    );
  }

  /// Every operation the service had to run has run: no START attempt, no stop
  /// and no rotation left in the queue. A wait that does not presuppose what
  /// any of them did.
  Future<void> waitForTheQueueToDrain() {
    return waitUntil(
      () => !service.startAttemptSettling && !service.hasPendingNativeStop && service.queuedRotationCountForTest == 0,
      'the queue draining',
    );
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

  /// The final STOP of every scenario — one plain stop of whatever is recording
  /// now: it must find the Recording that is current, made by [producer], emit
  /// exactly one native stop, and leave nothing recording, on the same camera
  /// and under the same process owner.
  Future<void> stopAndExpectItWas(String producer) async {
    final stopsBefore = count('stopVideoRecording');
    final recording = service.activeRecordingId;
    final camera = service.previewController;
    final owner = DashcamService.processOwnerCurrentForTest;
    final stop = service.beginStopLoopRecording();
    final handle = await stop.handle.timeout(patience);
    await stop.presentation.timeout(patience);
    expect(handle, isNotNull, reason: 'the stop found something to stop');
    expect(handle!.recordingId, recording, reason: 'and it was the Recording that was current');
    expect(handle.producerToken, producer, reason: 'recorded by $producer');
    await handle.settlement.timeout(patience);
    expect(count('stopVideoRecording'), stopsBefore + 1, reason: 'exactly one native stop');
    expect(service.clips.last.producerToken, producer);
    expectNothingRecording();
    expect(service.previewController, same(camera), reason: 'no teardown was needed to get here');
    expect(DashcamService.processOwnerCurrentForTest, same(owner));
  }

  /// A plain stop that must find nothing to stop.
  Future<void> expectAPlainStopFindsNothing() async {
    final stopsBefore = count('stopVideoRecording');
    final stop = service.beginStopLoopRecording();
    await stop.presentation.timeout(patience);
    expect(await stop.handle.timeout(patience), isNull, reason: 'nothing was left for a stop to find');
    expect(count('stopVideoRecording'), stopsBefore);
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

  /// Releases the held native START; any START after it goes straight through.
  void releaseStart(Completer<void> gate) {
    fakePlatform.pendingStartVideoCapturing = null;
    gate.complete();
  }

  /// START A is recording on a freshly built service.
  Future<_Started> recordA() async {
    service = build();
    await service.initialize();
    final a = start('producer-A');
    await a.done.timeout(patience);
    expect(a.error, isNull, reason: 'test setup: A records');
    expect(service.previewController!.value.isRecordingVideo, isTrue, reason: 'test setup: A records');
    return a;
  }

  /// A tick of the run's own timer has stopped the current segment and the
  /// rotation's restart START is held on the returned gate: the camera is not
  /// recording, the recording is still wanted, and `activeRecordingId` still
  /// names the segment that has just ended.
  Future<Completer<void>> rotateAndHoldTheRestart() async {
    final stopsBefore = count('stopVideoRecording');
    final startsBefore = count('startVideoCapturing');
    final gate = Completer<void>();
    fakePlatform.pendingStartVideoCapturing = gate;
    timerTicks.last();
    await waitUntil(
      () => count('stopVideoRecording') == stopsBefore + 1 && count('startVideoCapturing') == startsBefore + 1 && !service.hasPendingNativeStop,
      'the rotation stopping the segment and issuing its restart START',
    );
    expect(service.previewController!.value.isRecordingVideo, isFalse, reason: 'test setup: the restart has not returned');
    expect(service.isRecording, isTrue, reason: 'test setup: the run is still wanted');
    return gate;
  }

  /// A tick of the run's own timer rotates the segment: the next one records.
  Future<void> rotateOnce() async {
    final startsBefore = count('startVideoCapturing');
    final segmentBefore = service.activeRecordingId;
    timerTicks.last();
    await waitUntil(
      () => count('startVideoCapturing') == startsBefore + 1 && service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop && service.activeRecordingId != segmentBefore,
      'the tick rotating the segment',
    );
    expect(service.previewController!.value.isRecordingVideo, isTrue);
  }

  setUp(() {
    timerTicks = [];
    dir = Directory.systemTemp.createTempSync('dashcam_cleanup_ownership_test');
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

  group('Fase 16.2-R4.3-R2.6.18 — a cleanup that names ONLY the camera names no START: it stops and withdraws nothing (R1)', () {
    test(
      'X316 — the review\'s R1a: recording 0 is being stopped (native stop in flight), START B is accepted behind it, and a '
      'cleanup naming only the camera arrives. It adopts nothing and withdraws nothing: B starts, records as B, and the '
      'next stop stops B',
      () async {
        service = build();
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-0');
        final camera = service.previewController!;
        final stopGate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGate;
        try {
          final stop0 = service.stopLoopRecording();
          await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'the native stop of recording 0 being issued and held');
          fakePlatform.pendingStopVideoRecording = null;
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted');

          final cleanup = service.beginStopLoopRecording(expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          stopGate.complete();
          await Future.wait([stop0, b.done, cleanup.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'B really started — a START that reports success has recorded');
          expect(count('stopVideoRecording'), 1, reason: 'recording 0 only');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.hasActiveSegmentTimerForTest, isTrue, reason: 'B\'s timer is armed');
          expect(await cleanup.handle.timeout(patience), isNull, reason: 'the camera names no Recording: the stop of recording 0 was not its to adopt');
          expect(producers(), ['producer-0']);
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'the cleanup did not take B\'s intent down');
          await stopAndExpectItWas('producer-B');
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(), reason: 'B was never withdrawn');
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X317 — the review\'s R1b: nothing was ever recorded, A\'s START deadline elapses, START B is accepted, and the caller '
      'of A cleans up with what it can read — `activeRecordingId` is null, so it names only the camera. B is not '
      'withdrawn: A stops its own late Recording, then B starts and records as B',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final camera = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          // By cause: the Future of A resolves at A's own deadline — the native call is still held.
          await a.done.timeout(patience);
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted after A\'s deadline');
          expect(service.activeRecordingId, isNull, reason: 'test setup: no Recording has ever existed');

          final cleanup = service.beginStopLoopRecording(expectedController: camera, expectedRecordingId: service.activeRecordingId);
          final wantedRightAfterTheCleanup = service.isRecording;
          releaseStart(startGate);
          await Future.wait([b.done, cleanup.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'A, then B — B really started');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped by A itself');
          expect(producers(), ['producer-A']);
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(await cleanup.handle.timeout(patience), isNull);
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'the cleanup did not take B\'s intent down');
          await stopAndExpectItWas('producer-B');
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X318 — the review\'s R1c: recording 0 is over, the native START of B is in flight, and a cleanup naming only the '
      'camera arrives. B keeps its intent, records with its own timer — which still rotates B — and the next stop stops B',
      () async {
        final startGate = await holdNextStart(afterRecording0: true);
        try {
          final camera = service.previewController!;
          final b = start('producer-B');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of B being issued and held');

          final cleanup = service.beginStopLoopRecording(expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          releaseStart(startGate);
          await Future.wait([b.done, cleanup.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('stopVideoRecording'), 1, reason: 'recording 0 only — nothing of B was stopped');
          expect(count('startVideoCapturing'), 2);
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.hasActiveSegmentTimerForTest, isTrue, reason: 'B\'s timer was not cancelled');
          expect(await cleanup.handle.timeout(patience), isNull);
          expect(wantedRightAfterTheCleanup, isTrue);

          await rotateOnce();
          expect(producers(), ['producer-0', 'producer-B'], reason: 'B\'s own timer rotated B');
          await stopAndExpectItWas('producer-B');
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(), reason: 'B was never withdrawn: it had nothing to clean up');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X319 — the review\'s R1d: B is already recording when a cleanup naming only the camera arrives. No native call, and '
      'B\'s Recording, intent and timer are intact; B\'s timer still rotates B, and the next stop stops B',
      () async {
        service = build();
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-0');
        await service.stopLoopRecording();
        await waitUntil(() => !service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'recording 0 being stopped');
        final camera = service.previewController!;
        final b = start('producer-B');
        await b.done.timeout(patience);
        expect(b.error, isNull);
        final recordingB = service.activeRecordingId;
        final callsBefore = fakePlatform.calls.length;

        final cleanup = service.beginStopLoopRecording(expectedController: camera);
        await cleanup.presentation.timeout(patience);
        await waitForTheQueueToDrain();

        expect(fakePlatform.calls.length, callsBefore, reason: 'the cleanup emitted nothing');
        expect(await cleanup.handle.timeout(patience), isNull);
        expect(camera.value.isRecordingVideo, isTrue);
        expect(service.isRecording, isTrue);
        expect(service.activeRecordingId, recordingB);
        expect(service.hasActiveSegmentTimerForTest, isTrue);
        expect(service.cameraKnownUnavailable, isFalse);

        await rotateOnce();
        await stopAndExpectItWas('producer-B');
        expect(count('dispose'), 0);
      },
    );

    test(
      'X320 — what that form no longer does: with A\'s native START in flight and A still the latest START, a cleanup '
      'naming only the camera does not cancel A. A records as A; to cancel a START, a caller names that START',
      () async {
        final startGate = await holdNextStart();
        try {
          final camera = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');

          final cleanup = service.beginStopLoopRecording(expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          releaseStart(startGate);
          await Future.wait([a.done, cleanup.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(a.error, isNull);
          expect(count('stopVideoRecording'), 0, reason: 'nothing of A was stopped');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'A is recording');
          expect(service.isRecording, isTrue);
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(await cleanup.handle.timeout(patience), isNull);
          expect(wantedRightAfterTheCleanup, isTrue);
          await stopAndExpectItWas('producer-A');

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.18 — a cleanup that names its START acts for that START, and for nothing a later START did', () {
    test(
      'X321 — every accepted START gets an identity of its own; a call absorbed by a recording already wanted gets none. A '
      'cleanup naming the latest START, issued with its native call in flight, cancels it: that START does not finalize, '
      'the cleanup stops its Recording itself, gets its handle, and nothing is left recording',
      () async {
        final startGate = await holdNextStart();
        try {
          final camera = service.previewController!;
          final a = start('producer-A');
          final absorbed = start('producer-X');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          expect(a.attempt, isNotNull, reason: 'an accepted START has an identity');
          expect(absorbed.attempt, isNull, reason: 'an absorbed call is no START of its own');
          expect(a.attempt!.startEpochForTest, service.startIntentEpochForTest);

          final cleanup = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedRightAfterTheCleanup = service.isRecording;
          releaseStart(startGate);
          await Future.wait([a.done, absorbed.done, cleanup.presentation]).timeout(patience);
          final handle = await cleanup.handle.timeout(patience);
          await waitForTheQueueToDrain();

          expect(a.error, isNull);
          expect(absorbed.error, isNull);
          expect(count('startVideoCapturing'), 1);
          expect(handle, isNotNull, reason: 'the cleanup stopped A\'s Recording itself, and knows it');
          expect(handle!.producerToken, 'producer-A');
          await handle.settlement.timeout(patience);
          expect(count('stopVideoRecording'), 1, reason: 'stopped once');
          expect(producers(), ['producer-A']);
          expect(wantedRightAfterTheCleanup, isFalse, reason: 'A was the latest START: its own cleanup takes its intent down at once');
          expectNothingRecording();
          expect(service.previewController, same(camera));
          await expectAPlainStopFindsNothing();

          expect(service.startFatesForTest, startFates(), reason: 'the queued cleanup owned A\'s Recording: A did not finalize it');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X322 — the cleanup of the latest START while it records: the intent goes down at once, that Recording is stopped, '
      'the cleanup gets its handle. A second cleanup of the same START finds nothing',
      () async {
        final a = await recordA();
        final recordingA = service.activeRecordingId;

        final cleanup = service.beginStopLoopRecording(startAttempt: a.attempt);
        final wantedRightAfterTheCleanup = service.isRecording;
        final handle = await cleanup.handle.timeout(patience);
        await cleanup.presentation.timeout(patience);

        expect(handle, isNotNull);
        expect(handle!.recordingId, recordingA);
        expect(handle.producerToken, 'producer-A');
        await handle.settlement.timeout(patience);
        expect(count('stopVideoRecording'), 1);
        expect(wantedRightAfterTheCleanup, isFalse);
        expectNothingRecording();

        final callsBefore = fakePlatform.calls.length;
        final again = service.beginStopLoopRecording(startAttempt: a.attempt);
        await again.presentation.timeout(patience);
        expect(await again.handle.timeout(patience), isNull);
        expect(fakePlatform.calls.length, callsBefore, reason: 'nothing of A was left');
      },
    );

    test(
      'X323 — the review\'s R1b again, with the caller of A naming A\'s own START instead of the camera: the cleanup is '
      'about A, B is not withdrawn. Queued behind B, it is not what stops A\'s late Recording — A does, before B needs '
      'the camera — and B records as B',
      () async {
        final startGate = await holdNextStart(shortStartDeadline: true);
        try {
          final camera = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          await a.done.timeout(patience);
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted after A\'s deadline');

          final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedRightAfterTheCleanup = service.isRecording;
          releaseStart(startGate);
          await Future.wait([b.done, cleanupOfA.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'A, then B — B really started');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s late Recording, stopped once');
          expect(producers(), ['producer-A']);
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(await cleanupOfA.handle.timeout(patience), isNull, reason: 'by its turn nothing of A was left on the camera');
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'the cleanup of A did not take B\'s intent down');
          await stopAndExpectItWas('producer-B');
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1), reason: 'A stopped its own late Recording');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X324 — the physical cleanup of A is not dropped because A is no longer the latest START: A\'s Recording is being '
      'stopped (native stop in flight), START B is accepted behind it, and the caller of A names A\'s START. The cleanup '
      'adopts that stop — and gets its handle — without withdrawing B, which starts and records as B',
      () async {
        final a = await recordA();
        final camera = service.previewController!;
        final recordingA = service.activeRecordingId;
        final stopGate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGate;
        try {
          final stopOfA = service.stopLoopRecording();
          await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'the native stop of A\'s Recording being issued and held');
          fakePlatform.pendingStopVideoRecording = null;
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted');

          final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedRightAfterTheCleanup = service.isRecording;
          stopGate.complete();
          await Future.wait([stopOfA, b.done, cleanupOfA.presentation]).timeout(patience);
          final handle = await cleanupOfA.handle.timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'B really started');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s Recording, once');
          expect(handle, isNotNull, reason: 'the stop of A\'s Recording is what this cleanup asked for');
          expect(handle!.recordingId, recordingA);
          expect(handle.producerToken, 'producer-A');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'the cleanup of A did not take B\'s intent down');
          await stopAndExpectItWas('producer-B');

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X325 — a cleanup of A arriving after B is already recording on the same camera: no native call, and B\'s Recording, '
      'intent, timer and process owner are intact; B\'s timer still rotates B, and the next stop stops B',
      () async {
        final a = await recordA();
        await service.stopLoopRecording();
        await waitUntil(() => !service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'A\'s Recording being stopped');
        final camera = service.previewController!;
        final owner = DashcamService.processOwnerCurrentForTest;
        final b = start('producer-B');
        await b.done.timeout(patience);
        expect(b.error, isNull);
        final recordingB = service.activeRecordingId;
        final callsBefore = fakePlatform.calls.length;

        final lateCleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
        await lateCleanupOfA.presentation.timeout(patience);
        await waitForTheQueueToDrain();

        expect(fakePlatform.calls.length, callsBefore, reason: 'the late cleanup of A emitted nothing');
        expect(await lateCleanupOfA.handle.timeout(patience), isNull);
        expect(camera.value.isRecordingVideo, isTrue);
        expect(service.isRecording, isTrue);
        expect(service.activeRecordingId, recordingB);
        expect(service.hasActiveSegmentTimerForTest, isTrue);
        expect(service.cameraKnownUnavailable, isFalse, reason: 'B\'s camera status is untouched');
        expect(service.previewController, same(camera));
        expect(DashcamService.processOwnerCurrentForTest, same(owner), reason: 'B\'s process owner is untouched');

        await rotateOnce();
        await stopAndExpectItWas('producer-B');
        expect(count('dispose'), 0);
      },
    );

    test(
      'X326 — the cleanup of a START reaches what that START is recording NOW, whatever id a rotation has given it. A '
      'records; a rotation has stopped its segment and the restart START is in flight; the caller of A names A\'s START. '
      'A\'s intent goes down, and when the restart returns the cleanup stops the new segment: nothing is left recording',
      () async {
        final a = await recordA();
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        final restartGate = await rotateAndHoldTheRestart();
        try {
          final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedRightAfterTheCleanup = service.isRecording;
          releaseStart(restartGate);
          await cleanupOfA.presentation.timeout(patience);
          final handle = await cleanupOfA.handle.timeout(patience);
          await waitForTheQueueToDrain();

          expect(count('startVideoCapturing'), 2, reason: 'A, and the restart of A\'s rotation');
          expect(count('stopVideoRecording'), 2, reason: 'segment 1 by the rotation, the restarted segment by the cleanup');
          expect(handle, isNotNull, reason: 'the cleanup stopped the restarted segment itself');
          expect(handle!.recordingId, segment1 + 1);
          expect(handle.producerToken, 'producer-A');
          await handle.settlement.timeout(patience);
          expect(producers(), ['producer-A', 'producer-A']);
          expect(wantedRightAfterTheCleanup, isFalse, reason: 'A was the latest START');
          expectNothingRecording();
          expect(service.previewController, same(camera));
          await expectAPlainStopFindsNothing();

          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull, reason: 'the camera was left free');
          await stopAndExpectItWas('producer-D');
          expect(count('dispose'), 0);
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
        }
      },
    );

    test(
      'X327 — the same once the rotation is over: A\'s current segment has a new id, a cleanup naming A\'s first segment '
      'finds nothing of its own and changes nothing, and the cleanup naming A\'s START stops the current segment',
      () async {
        final a = await recordA();
        final segment1 = service.activeRecordingId!;
        await rotateOnce();
        final camera = service.previewController!;
        expect(service.activeRecordingId, segment1 + 1);
        final callsBefore = fakePlatform.calls.length;

        final staleSegment = service.beginStopLoopRecording(expectedRecordingId: segment1, expectedController: camera);
        await staleSegment.presentation.timeout(patience);
        expect(await staleSegment.handle.timeout(patience), isNull);
        expect(fakePlatform.calls.length, callsBefore, reason: 'segment 1 is over: nothing to stop');
        expect(service.isRecording, isTrue);
        expect(camera.value.isRecordingVideo, isTrue);
        expect(service.hasActiveSegmentTimerForTest, isTrue);

        final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
        final handle = await cleanupOfA.handle.timeout(patience);
        await cleanupOfA.presentation.timeout(patience);
        expect(handle, isNotNull);
        expect(handle!.recordingId, segment1 + 1);
        await handle.settlement.timeout(patience);
        expect(count('stopVideoRecording'), 2, reason: 'the rotation\'s, then the cleanup\'s');
        expectNothingRecording();
      },
    );

    test(
      'X328 — A, B, C on one camera: A is stopped while in flight, B is accepted, A\'s Recording is being stopped when the '
      'caller of A names A\'s START; B is stopped, C is accepted, the caller of A names A\'s START again; only then does '
      'A\'s stop return. Nothing of B or C is touched: C starts, records as C with its own timer, and the next stop stops C',
      () async {
        final startGate = await holdNextStart(afterRecording0: true);
        final stopGate = Completer<void>();
        try {
          final camera = service.previewController!;
          final owner = DashcamService.processOwnerCurrentForTest;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          final stopOfA = service.beginStopLoopRecording();
          final b = start('producer-B');
          fakePlatform.pendingStopVideoRecording = stopGate;
          releaseStart(startGate);
          await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 2, 'the stop of A\'s Recording being issued and held');
          fakePlatform.pendingStopVideoRecording = null;

          final firstCleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedAfterTheFirstCleanup = service.isRecording;
          final stopOfB = service.beginStopLoopRecording();
          final c = start('producer-C');
          final secondCleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedAfterTheSecondCleanup = service.isRecording;
          expect(count('startVideoCapturing'), 2, reason: 'nothing of B or C reached the camera while A\'s stop is in flight');

          stopGate.complete();
          await Future.wait([a.done, b.done, c.done, stopOfA.presentation, stopOfB.presentation, firstCleanupOfA.presentation, secondCleanupOfA.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect([a.error, b.error, c.error], everyElement(isNull));
          expect(count('startVideoCapturing'), 3, reason: 'recording 0, A, C — B emitted nothing');
          expect(count('stopVideoRecording'), 2, reason: 'recording 0 and A\'s Recording: nothing of C was stopped');
          expect((await firstCleanupOfA.handle.timeout(patience))?.producerToken, 'producer-A');
          expect((await secondCleanupOfA.handle.timeout(patience))?.producerToken, 'producer-A');
          expect((await stopOfB.handle.timeout(patience))?.producerToken, 'producer-A', reason: 'a plain stop adopts the stop in flight, as it always did: B had recorded nothing');
          expect(producers(), ['producer-0', 'producer-A']);
          expect(camera.value.isRecordingVideo, isTrue, reason: 'C is recording');
          expect(service.isRecording, isTrue);
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.previewController, same(camera));
          expect(DashcamService.processOwnerCurrentForTest, same(owner));
          expect(wantedAfterTheFirstCleanup, isTrue, reason: 'the first cleanup of A did not take B\'s intent down');
          expect(wantedAfterTheSecondCleanup, isTrue, reason: 'the second cleanup of A did not take C\'s intent down');

          await rotateOnce();
          expect(producers(), ['producer-0', 'producer-A', 'producer-C'], reason: 'C\'s own timer rotated C');
          await stopAndExpectItWas('producer-C');
          expect(count('dispose'), 0);
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X329 — a different camera: A recorded on the first camera; the service is re-initialized and B records on the new '
      'one. A cleanup naming A\'s START emits nothing and leaves B\'s Recording, intent, timer, camera and process owner alone',
      () async {
        final a = await recordA();
        final firstCamera = service.previewController!;
        await service.initialize();
        final secondCamera = service.previewController!;
        expect(secondCamera, isNot(same(firstCamera)), reason: 'test setup: a new camera');
        final owner = DashcamService.processOwnerCurrentForTest;
        final b = start('producer-B');
        await b.done.timeout(patience);
        expect(b.error, isNull);
        final recordingB = service.activeRecordingId;
        final callsBefore = fakePlatform.calls.length;

        final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
        await cleanupOfA.presentation.timeout(patience);
        await waitForTheQueueToDrain();

        expect(fakePlatform.calls.length, callsBefore, reason: 'the cleanup of A emitted nothing');
        expect(await cleanupOfA.handle.timeout(patience), isNull);
        expect(secondCamera.value.isRecordingVideo, isTrue);
        expect(service.isRecording, isTrue);
        expect(service.activeRecordingId, recordingB);
        expect(service.hasActiveSegmentTimerForTest, isTrue);
        expect(service.previewController, same(secondCamera));
        expect(DashcamService.processOwnerCurrentForTest, same(owner));
        expect(producers(), ['producer-A'], reason: 'the re-initialize stopped A\'s Recording, once');
        await stopAndExpectItWas('producer-B');
      },
    );

    test(
      'X335 — the cleanup of A never receives what belongs to B. A is over; B\'s native START is in flight; B is stopped '
      '(that stop waits for B) and then the caller of A names A\'s START, right behind it in the queue. The stop of B '
      'stops B\'s Recording and gets its handle; the cleanup of A gets none — B\'s stop is not A\'s to adopt',
      () async {
        final a = await recordA();
        await service.stopLoopRecording();
        await waitUntil(() => !service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'A\'s Recording being stopped');
        final startGate = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = startGate;
        try {
          final b = start('producer-B');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of B being issued and held');
          final stopOfB = service.beginStopLoopRecording();
          final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          releaseStart(startGate);
          await Future.wait([b.done, stopOfB.presentation, cleanupOfA.presentation]).timeout(patience);
          final handleOfTheStopOfB = await stopOfB.handle.timeout(patience);
          final handleOfTheCleanupOfA = await cleanupOfA.handle.timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('stopVideoRecording'), 2, reason: 'A\'s Recording earlier, B\'s now — once each');
          expect(handleOfTheStopOfB, isNotNull);
          expect(handleOfTheStopOfB!.producerToken, 'producer-B');
          expect(handleOfTheCleanupOfA, isNull, reason: 'B\'s stop is not A\'s to receive');
          expect(producers(), ['producer-A', 'producer-B']);
          expectNothingRecording();
          expect(cleanupOfA.intentId, isNot(stopOfB.intentId));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X336 — two cleanups for two different STARTs are never one request. Z is over; A\'s native START is in flight; the '
      'caller of A names A\'s START, then the caller of Z names Z\'s. A\'s cleanup stops A\'s Recording and gets its '
      'handle; Z\'s is a request of its own and gets none',
      () async {
        service = build();
        await service.initialize();
        final z = start('producer-Z');
        await z.done.timeout(patience);
        await service.stopLoopRecording();
        await waitUntil(() => !service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'Z\'s Recording being stopped');
        final startGate = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = startGate;
        try {
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          final cleanupOfZ = service.beginStopLoopRecording(startAttempt: z.attempt);
          releaseStart(startGate);
          await Future.wait([a.done, cleanupOfA.presentation, cleanupOfZ.presentation]).timeout(patience);
          final handleOfA = await cleanupOfA.handle.timeout(patience);
          final handleOfZ = await cleanupOfZ.handle.timeout(patience);
          await waitForTheQueueToDrain();

          expect(a.error, isNull);
          expect(count('stopVideoRecording'), 2, reason: 'Z\'s Recording earlier, A\'s now — once each');
          expect(handleOfA, isNotNull);
          expect(handleOfA!.producerToken, 'producer-A');
          expect(handleOfZ, isNull, reason: 'the stop of A\'s Recording is not Z\'s to receive');
          expect(cleanupOfZ.intentId, isNot(cleanupOfA.intentId), reason: 'two STARTs, two requests');
          expectNothingRecording();

          expect(service.startFatesForTest, startFates(), reason: 'A\'s own cleanup, queued ahead of everything else, owned A\'s Recording');
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X337 — cancelling a START that has not reached the camera yet: recording 0 is being stopped (native stop in '
      'flight), START A waits behind it, and the caller of A names A\'s START. A is withdrawn and never emits; the stop in '
      'flight is recording 0\'s, not A\'s, so the cleanup does not adopt it. The next START records',
      () async {
        service = build();
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-0');
        final camera = service.previewController!;
        final stopGate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGate;
        try {
          final stop0 = service.stopLoopRecording();
          await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'the native stop of recording 0 being issued and held');
          fakePlatform.pendingStopVideoRecording = null;
          final a = start('producer-A');
          expect(service.isRecording, isTrue, reason: 'test setup: A was accepted');

          final cleanupOfA = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedRightAfterTheCleanup = service.isRecording;
          stopGate.complete();
          await Future.wait([stop0, a.done, cleanupOfA.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(a.error, isNull, reason: 'a START withdrawn while it waited completes quietly, as it always did');
          expect(count('startVideoCapturing'), 1, reason: 'recording 0 only: A never reached the camera');
          expect(count('stopVideoRecording'), 1);
          expect(await cleanupOfA.handle.timeout(patience), isNull, reason: 'the stop in flight was recording 0\'s, not A\'s');
          expect(producers(), ['producer-0']);
          expect(wantedRightAfterTheCleanup, isFalse, reason: 'A was the latest START: its own cleanup withdraws it');
          expectNothingRecording();
          expect(service.previewController, same(camera));

          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull);
          await stopAndExpectItWas('producer-D');
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.18 — a cleanup that names a segment a rotation has replaced does not touch the run (N1)', () {
    test(
      'X330 — the review\'s N1: A records; a rotation has stopped segment 1 and its restart START is in flight; a cleanup '
      'names the id `activeRecordingId` returns at that instant — segment 1, which is over. The run is not withdrawn: the '
      'restart returns, the new segment records with its owner, its timer and its status, the timer still rotates it, and '
      'the next stop stops it',
      () async {
        await recordA();
        final camera = service.previewController!;
        final owner = DashcamService.processOwnerCurrentForTest;
        final segment1 = service.activeRecordingId!;
        final restartGate = await rotateAndHoldTheRestart();
        try {
          expect(service.activeRecordingId, segment1, reason: 'test setup: the id still names the segment that has just ended');
          final cleanup = service.beginStopLoopRecording(expectedRecordingId: service.activeRecordingId, expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          final timerRightAfterTheCleanup = service.hasActiveSegmentTimerForTest;
          releaseStart(restartGate);
          await cleanup.presentation.timeout(patience);
          await waitForTheQueueToDrain();

          expect(count('startVideoCapturing'), 2, reason: 'A, and the restart');
          expect(count('stopVideoRecording'), 1, reason: 'segment 1 by the rotation — the restarted segment was not stopped');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'the restarted segment is recording');
          expect(service.isRecording, isTrue, reason: 'and it is wanted: it has an owner');
          expect(service.activeRecordingId, segment1 + 1);
          expect(service.hasActiveSegmentTimerForTest, isTrue, reason: 'the run\'s timer was not cancelled');
          expect(service.cameraKnownUnavailable, isFalse, reason: 'the run\'s camera status is untouched');
          expect(service.previewController, same(camera));
          expect(DashcamService.processOwnerCurrentForTest, same(owner));
          expect(await cleanup.handle.timeout(patience), isNull, reason: 'segment 1 was already stopped: the cleanup had nothing to stop');
          expect(producers(), ['producer-A']);
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'a cleanup of a segment that is over does not withdraw the run');
          expect(timerRightAfterTheCleanup, isTrue);

          await rotateOnce();
          expect(producers(), ['producer-A', 'producer-A'], reason: 'the run\'s own timer still rotates it');
          await stopAndExpectItWas('producer-A');
          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull, reason: 'the next START is not refused');
          await stopAndExpectItWas('producer-D');
          expect(count('dispose'), 0);
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
        }
      },
    );

    test(
      'X331 — the boundary that did not move: the same cleanup while the rotation\'s stop of that segment is still in '
      'flight. The segment is not over yet: the cleanup adopts its stop, gets its handle and withdraws the run — the '
      'rotation does not restart',
      () async {
        await recordA();
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        final stopGate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopGate;
        try {
          timerTicks.last();
          await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'the rotation\'s stop of segment 1 being issued and held');
          fakePlatform.pendingStopVideoRecording = null;

          final cleanup = service.beginStopLoopRecording(expectedRecordingId: segment1, expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          stopGate.complete();
          await cleanup.presentation.timeout(patience);
          final handle = await cleanup.handle.timeout(patience);
          await waitForTheQueueToDrain();

          expect(count('startVideoCapturing'), 1, reason: 'the rotation did not restart');
          expect(count('stopVideoRecording'), 1);
          expect(handle, isNotNull);
          expect(handle!.recordingId, segment1);
          expect(wantedRightAfterTheCleanup, isFalse);
          expectNothingRecording();
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      'X341 — the corner: a rotation stops segment 1 and its restart START FAILS. Nothing records and no successor is on '
      'its way. (Adapted in Fase 16.2-R4.3-R2.6.20: until then the run was left wanted, and it took the cleanup naming '
      'segment 1 to bring the intent down; the rotation now ends the run itself when its restart fails.) The cleanup '
      'naming segment 1 finds nothing left to do, and the next START is accepted and records, instead of being absorbed '
      'by a dead run',
      () async {
        await recordA();
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        fakePlatform.failStartVideoCapturingWith = CameraException('start_failed', 'the restart START of the rotation failed');
        try {
          timerTicks.last();
          await waitUntil(
            () => count('stopVideoRecording') == 1 && !service.hasPendingNativeStop && service.cameraKnownUnavailable && service.queuedRotationCountForTest == 0,
            'the rotation stopping segment 1, its restart failing and the rotation ending',
          );
          fakePlatform.failStartVideoCapturingWith = null;
          expect(service.isRecording, isFalse, reason: 'test setup (R2.6.20): the rotation ended the run itself when its restart failed');
          expect(camera.value.isRecordingVideo, isFalse, reason: 'test setup: and nothing records');
          expect(service.activeRecordingId, segment1);

          final cleanup = service.beginStopLoopRecording(expectedRecordingId: segment1, expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          await cleanup.presentation.timeout(patience);
          expect(await cleanup.handle.timeout(patience), isNull, reason: 'segment 1 was already stopped');
          expect(count('stopVideoRecording'), 1);
          expect(wantedRightAfterTheCleanup, isFalse, reason: 'nothing was on its way and nothing is wanted: the run is over');
          expectNothingRecording();

          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull);
          expect(d.attempt, isNotNull, reason: 'the next START is a START of its own, not a call absorbed by the dead run');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'and it records');
          await stopAndExpectItWas('producer-D');
        } finally {
          fakePlatform.failStartVideoCapturingWith = null;
        }
      },
    );

    test(
      'X342 — the same failure seen from inside the window: the cleanup naming segment 1 arrives with the restart START '
      'in flight, and the restart fails afterwards. While the restart is in flight the run is left alone; when the '
      'cleanup\'s own turn comes no successor exists, so it takes the dead run\'s intent down. The next START is a '
      'START of its own and records — the outcome does not depend on which side of the failure the cleanup arrived',
      () async {
        await recordA();
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        final restartGate = await rotateAndHoldTheRestart();
        try {
          final cleanup = service.beginStopLoopRecording(expectedRecordingId: segment1, expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          final timerRightAfterTheCleanup = service.hasActiveSegmentTimerForTest;
          fakePlatform.pendingStartVideoCapturing = null;
          restartGate.completeError(CameraException('start_failed', 'the restart START of the rotation failed'));
          await cleanup.presentation.timeout(patience);
          await waitForTheQueueToDrain();

          expect(count('startVideoCapturing'), 2, reason: 'A, and the restart that failed');
          expect(count('stopVideoRecording'), 1, reason: 'segment 1, by the rotation');
          expect(await cleanup.handle.timeout(patience), isNull, reason: 'segment 1 was already stopped');
          expect(service.activeRecordingId, segment1, reason: 'no successor was created');
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'with the restart in flight the run is not withdrawn');
          expect(timerRightAfterTheCleanup, isTrue);
          expectNothingRecording();

          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull);
          expect(d.attempt, isNotNull, reason: 'the next START is a START of its own, not a call absorbed by the dead run');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'and it records');
          await stopAndExpectItWas('producer-D');
          expect(count('dispose'), 0);
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
        }
      },
    );

    test(
      'X343 — what the cleanup decides at its turn is about the run it was issued for: in the same window the run is '
      'stopped and START B is accepted, and then the restart fails. When the cleanup\'s turn comes the intent standing '
      'is B\'s: it is left alone, and B starts and records as B with its own timer',
      () async {
        await recordA();
        final camera = service.previewController!;
        final segment1 = service.activeRecordingId!;
        final restartGate = await rotateAndHoldTheRestart();
        try {
          final cleanup = service.beginStopLoopRecording(expectedRecordingId: segment1, expectedController: camera);
          final stopOfA = service.beginStopLoopRecording();
          final b = start('producer-B');
          expect(b.attempt, isNotNull, reason: 'test setup: A was stopped, so B is a START of its own');
          fakePlatform.pendingStartVideoCapturing = null;
          restartGate.completeError(CameraException('start_failed', 'the restart START of the rotation failed'));
          await Future.wait([cleanup.presentation, stopOfA.presentation, b.done]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 3, reason: 'A, the restart that failed, and B');
          expect(count('stopVideoRecording'), 1, reason: 'segment 1, by the rotation');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue, reason: 'and it is wanted: the cleanup of A\'s segment did not take B\'s intent down');
          expect(service.hasActiveSegmentTimerForTest, isTrue, reason: 'with B\'s own timer');
          expect(service.activeRecordingStartEpochForTest, b.attempt!.startEpochForTest);
          expect(await cleanup.handle.timeout(patience), isNull);
          expect(await stopOfA.handle.timeout(patience), isNull, reason: 'A\'s segment had already been stopped by the rotation');
          expect(producers(), ['producer-A']);
          await stopAndExpectItWas('producer-B');
          expect(service.startFatesForTest, startFates());
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
        }
      },
    );

    test(
      'X332 — a restart under a NEWER authority: A is over, B records, and a rotation of B has stopped B\'s segment with '
      'its restart START in flight. A cleanup naming A\'s START and one naming A\'s old Recording arrive. Neither retires '
      'B\'s run, zeroes its owner, changes its status or leaves its new segment without an owner',
      () async {
        final a = await recordA();
        final camera = service.previewController!;
        final owner = DashcamService.processOwnerCurrentForTest;
        final recordingA = service.activeRecordingId!;
        await service.stopLoopRecording();
        await waitUntil(() => !service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'A\'s Recording being stopped');
        final b = start('producer-B');
        await b.done.timeout(patience);
        expect(b.error, isNull);
        final segmentB1 = service.activeRecordingId!;
        final restartGate = await rotateAndHoldTheRestart();
        try {
          final callsBefore = fakePlatform.calls.length;
          final byStart = service.beginStopLoopRecording(startAttempt: a.attempt);
          final wantedAfterTheCleanupByStart = service.isRecording;
          final byRecording = service.beginStopLoopRecording(expectedRecordingId: recordingA, expectedController: camera);
          final wantedAfterTheCleanupByRecording = service.isRecording;
          expect(fakePlatform.calls.length, callsBefore);
          releaseStart(restartGate);
          await Future.wait([byStart.presentation, byRecording.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(count('startVideoCapturing'), 3, reason: 'A, B, and the restart of B\'s rotation');
          expect(count('stopVideoRecording'), 2, reason: 'A\'s Recording and B\'s first segment — the restarted one was not stopped');
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B\'s restarted segment is recording');
          expect(service.isRecording, isTrue, reason: 'and it has its owner');
          expect(service.activeRecordingId, segmentB1 + 1);
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(service.cameraKnownUnavailable, isFalse);
          expect(service.previewController, same(camera));
          expect(DashcamService.processOwnerCurrentForTest, same(owner));
          expect(await byStart.handle.timeout(patience), isNull);
          expect(await byRecording.handle.timeout(patience), isNull);
          expect(wantedAfterTheCleanupByStart, isTrue);
          expect(wantedAfterTheCleanupByRecording, isTrue);

          await rotateOnce();
          await stopAndExpectItWas('producer-B');
          expect(count('dispose'), 0);
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.18 — a Recording keeps the START epoch of the attempt that created it', () {
    test(
      'X333 — through a rotation: the segments of one run all carry the epoch of the START that began it; a later START '
      'gets a later epoch, and so does the Recording it creates',
      () async {
        final a = await recordA();
        final epochA = a.attempt!.startEpochForTest;
        expect(service.activeRecordingStartEpochForTest, epochA, reason: 'the Recording A created is bound to A');

        await rotateOnce();
        expect(service.activeRecordingStartEpochForTest, epochA, reason: 'the rotation\'s restart is A\'s run: it does not rebind the Recording');
        expect(service.startIntentEpochForTest, epochA, reason: 'and a rotation is no START');
        await rotateOnce();
        expect(service.activeRecordingStartEpochForTest, epochA);

        await stopAndExpectItWas('producer-A');
        expect(service.activeRecordingStartEpochForTest, epochA, reason: 'a stop does not change whose Recording that was');
        final b = start('producer-B');
        await b.done.timeout(patience);
        final epochB = b.attempt!.startEpochForTest;
        expect(epochB, greaterThan(epochA));
        expect(service.activeRecordingStartEpochForTest, epochB);
        await stopAndExpectItWas('producer-B');
      },
    );

    test(
      'X334 — against a later START: A\'s rotation restart is in flight when A is stopped and START B is accepted. The '
      'segment that restart creates is still A\'s — bound to A\'s epoch with B\'s already current — so a cleanup naming '
      'it is a cleanup of A: it adopts its stop without withdrawing B, and B records under its own epoch',
      () async {
        final a = await recordA();
        final camera = service.previewController!;
        final epochA = a.attempt!.startEpochForTest;
        final segment1 = service.activeRecordingId!;
        final restartGate = await rotateAndHoldTheRestart();
        final stopGate = Completer<void>();
        try {
          final stopOfA = service.beginStopLoopRecording();
          final b = start('producer-B');
          final epochB = b.attempt!.startEpochForTest;
          expect(epochB, greaterThan(epochA));
          fakePlatform.pendingStopVideoRecording = stopGate;
          releaseStart(restartGate);
          await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 2, 'the stop of A\'s restarted segment being issued and held');
          fakePlatform.pendingStopVideoRecording = null;

          expect(service.activeRecordingId, segment1 + 1, reason: 'the restart created A\'s second segment');
          expect(service.startIntentEpochForTest, epochB, reason: 'with B already the latest START');
          expect(service.activeRecordingStartEpochForTest, epochA, reason: 'and that segment is bound to A, not to B');

          final cleanupOfTheSegment = service.beginStopLoopRecording(expectedRecordingId: segment1 + 1, expectedController: camera);
          final wantedRightAfterTheCleanup = service.isRecording;
          stopGate.complete();
          await Future.wait([stopOfA.presentation, b.done, cleanupOfTheSegment.presentation]).timeout(patience);
          await waitForTheQueueToDrain();

          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 3, reason: 'A, A\'s restart, B');
          expect(count('stopVideoRecording'), 2);
          expect((await cleanupOfTheSegment.handle.timeout(patience))?.recordingId, segment1 + 1);
          expect(camera.value.isRecordingVideo, isTrue, reason: 'B is recording');
          expect(service.isRecording, isTrue);
          expect(service.activeRecordingStartEpochForTest, epochB, reason: 'B\'s Recording is bound to B');
          expect(wantedRightAfterTheCleanup, isTrue, reason: 'a cleanup of A\'s segment does not withdraw B');
          await stopAndExpectItWas('producer-B');
        } finally {
          if (!restartGate.isCompleted) restartGate.complete();
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );
  });
}
