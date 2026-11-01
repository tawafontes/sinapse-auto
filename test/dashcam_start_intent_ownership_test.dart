// Fase 16.2-R4.3-R2.6.16 — START intent ownership / stale START suppression, at
// the DashcamService level (the service's own public API is the authority: none
// of this relies on what DashcamSessionController happens to call, or in which
// order).
//
// The independent review of R2.6.15 (P2-START-QUEUE) reproduced this through
// the public API, on every version back to R2.6.13: START A waits in the queue
// behind a native stop still in flight; A is stopped (that stop adopts the one
// in flight, so nothing of its own is queued behind A); START B is accepted; A
// reaches the front of the queue, finds B's intent set, and emits the native
// START as A. B then fails against a camera already recording, the service
// reports "not recording" over an active Recording, and the next
// stopLoopRecording() does not stop it — not even after one more START.
//
// The contract pinned here:
//  * a START carries the identity it was admitted with — its START epoch and
//    its controller — and acts for that intent only. Once superseded it emits
//    nothing: no native START, no Recording, no segment timer, no clip, no flag
//    of a later START touched; its Future still resolves without error;
//  * a START that ends up inert does not leave its own intent published
//    either: the service does not go on saying "recording" on its behalf;
//  * a START superseded only after its native call was issued cannot be undone,
//    but the Recording it produced always has exactly one owner: the queued
//    stop/teardown that withdrew it, or — when nothing queued can reach it —
//    the START itself, which finalizes that one Recording and nothing else;
//  * joining a START already wanted (the same intent) is still not a new
//    intent.
//
// How the tests place a START in each window:
//  * WAITING in the queue: recording 0 is being stopped and the test holds its
//    native stop on a Completer, so everything requested next waits behind it;
//  * IN FLIGHT: the test holds the native START itself on a Completer;
//  * AT ITS LAST CHECKPOINT: `semanticStillValid` is the last caller code the
//    service runs before the native START (X268).
//
// Waits are by cause (a call observed, a Future settled), never by elapsed
// time alone. Assertions come in the same order every time: what the camera
// and the queue did first, the name of the service's own decision last.
//
// Changed by R2.6.17 (five tests; the other 25 are as R2.6.16 left them). The
// independent review of R2.6.16 found two P2s which X276–X279 and X289 had
// pinned as given: a cleanup aimed at the previous Recording withdrawing an
// in-flight START (P2-A), and a START past its own deadline leaving its late
// Recording running (P2-B). Both are fixed, so:
//  * X276–X279 keep their purpose — the Recording nobody in the queue can
//    reach is finalized by the START that created it — with the one trigger
//    that still exists for it, the START's own deadline;
//  * X289 keeps its sequence and now expects the late Recording to be stopped.
// The new contracts themselves are in dashcam_start_attempt_settlement_test.dart.
//
// Changed by R2.6.18 (one test). X280 pinned that a cleanup naming ONLY the
// camera withdraws the START in flight — the sequence the review of R2.6.17
// reported as R1 (a camera names no START; such a cleanup now does nothing).
// X280 keeps its purpose and every assertion; its cleanup now names A's own
// START. The new contracts are in dashcam_cleanup_ownership_test.dart.
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

  /// The held native stop of recording 0, and the stop call it belongs to
  /// ([holdStopOfRecording0]).
  late Completer<void> stop0Gate;
  late Future<void> stop0;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  /// Long enough that the real segment timer never fires within a test.
  const manualTicksOnly = Duration(minutes: 10);
  const patience = Duration(seconds: 3);

  DashcamConfig config() => DashcamConfig(
    cameraSelection: CameraSelection.rear,
    storageQuotaMb: 1024,
    audioEnabled: false,
    resolution: VideoResolution.hd720,
    frameRate: 30,
    enabled: true,
  );

  /// A `null` [startDeadline] keeps the product's own default (5 s).
  DashcamService build({Duration segment = manualTicksOnly, Duration? startDeadline}) {
    final built = startDeadline == null
        ? DashcamService(config: config(), segmentDuration: segment)
        : DashcamService(config: config(), segmentDuration: segment, startVideoRecordingTimeout: startDeadline);
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
      '(isRecording=${service.isRecording}, pendingStop=${service.hasPendingNativeStop}, unavailable=${service.cameraKnownUnavailable}, '
      'startFates=${service.startFatesForTest}, calls=${fakePlatform.calls.join(',')})',
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

  /// What every scenario must end in, stated once: the service does not say it
  /// records, the camera does not record, no stop is in flight and no segment
  /// timer is armed.
  void expectNothingRecording() {
    expect(service.isRecording, isFalse, reason: 'the service does not claim to record');
    expect(service.previewController?.value.isRecordingVideo ?? false, isFalse, reason: 'zero physical recordings left');
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

  /// Recording 0 ('producer-0') is being stopped and its native stop is held on
  /// [stop0Gate]: whatever is requested from here on WAITS in the queue behind
  /// it.
  Future<void> holdStopOfRecording0({Duration segment = manualTicksOnly}) async {
    service = build(segment: segment);
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'producer-0');
    stop0Gate = Completer<void>();
    fakePlatform.pendingStopVideoRecording = stop0Gate;
    stop0 = service.stopLoopRecording();
    await waitUntil(() => service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'the stop of recording 0 being issued and held');
  }

  /// Recording 0 came and went on an initialized service; the native START(s)
  /// to come are held on the returned gate.
  Future<Completer<void>> afterRecording0HoldNextStart({Duration? startDeadline}) async {
    service = build(startDeadline: startDeadline);
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'producer-0');
    await service.stopLoopRecording();
    await waitUntil(() => !service.hasPendingNativeStop && count('stopVideoRecording') == 1, 'recording 0 being stopped');
    final gate = Completer<void>();
    fakePlatform.pendingStartVideoCapturing = gate;
    return gate;
  }

  /// An initialized service that never recorded; the native START(s) to come
  /// are held on the returned gate.
  Future<Completer<void>> holdNextStart({Duration? startDeadline}) async {
    service = build(startDeadline: startDeadline);
    await service.initialize();
    final gate = Completer<void>();
    fakePlatform.pendingStartVideoCapturing = gate;
    return gate;
  }

  /// Releases the held native START; any START after it goes straight through.
  void releaseStart(Completer<void> gate) {
    fakePlatform.pendingStartVideoCapturing = null;
    gate.complete();
  }

  setUp(() {
    timerTicks = [];
    dir = Directory.systemTemp.createTempSync('dashcam_start_intent_ownership_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    // Last-resort barrier, as in dashcam_rotation_tick_ownership_test.dart:
    // every test releases its own gates in a `finally`.
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

  group('Fase 16.2-R4.3-R2.6.16 — a START that was superseded while it waited emits nothing', () {
    test(
      'X261 — the independent review\'s own sequence, through the public API: START A waits behind a native stop in flight, '
      'A is stopped, START B is accepted, the stop returns. A emits nothing; B is the only START after recording 0, records '
      'as B, and the next stop really stops it',
      () async {
        await holdStopOfRecording0();
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final owner = DashcamService.processOwnerCurrentForTest;
          final recording0 = service.activeRecordingId!;

          final a = start('producer-A');
          expect(service.isRecording, isTrue, reason: 'test setup: A was accepted, and waits behind the held stop');
          final stoppingA = service.stopLoopRecording();
          expect(service.isRecording, isFalse, reason: 'test setup: the stop withdrew A');
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted, behind A');
          expect(count('startVideoCapturing'), 1);
          expect(count('stopVideoRecording'), 1);

          stop0Gate.complete();
          await Future.wait([stop0, stoppingA, a.done, b.done]).timeout(patience);

          // The reviewer's oracle.
          expect(b.error, isNull, reason: 'an accepted START B must not find the camera taken by the superseded START A');
          expect(a.error, isNull, reason: 'a superseded START resolves quietly, as it always did');
          expect(count('startVideoCapturing'), 2, reason: 'recording 0, then B — A emitted nothing');
          expect(count('stopVideoRecording'), 1);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(service.activeRecordingId, recording0 + 1, reason: 'exactly one Recording was created since recording 0');
          expect(timerTicks, hasLength(2), reason: 'one segment timer per Recording that started: recording 0\'s and B\'s');
          expect(service.hasActiveSegmentTimerForTest, isTrue);
          expect(producers(), ['producer-0']);
          expect(service.cameraKnownUnavailable, isFalse);

          // The following stop reaches B's Recording, and nothing is left recording.
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-B']);
          expect(service.previewController, same(controller), reason: 'same camera throughout');
          expect(DashcamService.processOwnerCurrentForTest, same(owner));
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0, reason: 'no teardown was needed to get here');
          expect(errors, isEmpty);

          // Why A did nothing: named last, after everything it did not do.
          expect(service.startFatesForTest, startFates(beforeEmission: 1));
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      'X262 — the review\'s variant with one more attempt: after that sequence B is stopped and START C is requested. C '
      'starts, records as C, and stopping it leaves zero recordings — no dispose is needed to get the camera back',
      () async {
        await holdStopOfRecording0();
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          final stoppingA = service.stopLoopRecording();
          final b = start('producer-B');
          stop0Gate.complete();
          await Future.wait([stop0, stoppingA, a.done, b.done]).timeout(patience);
          expect(b.error, isNull);

          await stopAndExpectItWas('producer-B');
          final c = start('producer-C');
          await c.done.timeout(patience);

          expect(c.error, isNull);
          expect(count('startVideoCapturing'), 3, reason: 'recording 0, B, C — one native START per START that was still wanted');
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          await stopAndExpectItWas('producer-C');
          expect(producers(), ['producer-0', 'producer-B', 'producer-C']);
          expect(count('stopVideoRecording'), 3);
          expect(service.previewController, same(controller));
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0, reason: 'consistency never depended on a dispose');

          expect(service.startFatesForTest, startFates(beforeEmission: 1));
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X263 — the same sequence with the REAL segment timer running: B rotates on its own timer and every clip after '
      'recording 0 is B\'s; once B is stopped nothing fires any more — no tick, no native call',
      () async {
        const segment = Duration(milliseconds: 150);
        await holdStopOfRecording0(segment: segment);
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          final stoppingA = service.stopLoopRecording();
          final b = start('producer-B');
          stop0Gate.complete();
          await Future.wait([stop0, stoppingA, a.done, b.done]).timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2);

          // By cause: two rotations of B's own timer have come and gone.
          await waitUntil(
            () => count('startVideoCapturing') >= 4 && service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop,
            'B rotating twice on its own timer',
          );
          expect(producers().first, 'producer-0');
          expect(producers().skip(1), everyElement('producer-B'), reason: 'every segment after recording 0 was recorded by B');
          expect(count('startVideoCapturing'), count('stopVideoRecording') + 1, reason: 'one Recording at a time: each start but the live one was stopped');
          expect(controller.value.isRecordingVideo, isTrue);

          final stop = service.beginStopLoopRecording();
          await stop.presentation.timeout(patience);
          await waitUntil(() => !service.hasPendingNativeStop && service.queuedRotationCountForTest == 0, 'the stop of B settling');
          expectNothingRecording();
          expect(count('startVideoCapturing'), count('stopVideoRecording'), reason: 'every Recording that started was stopped');
          expect(producers(), isNot(contains('producer-A')));

          final callsAtStop = fakePlatform.calls.length;
          final ticksAtStop = service.rotationTicksFiredForTest;
          await neverDuring(
            segment * 3,
            () => fakePlatform.calls.length != callsAtStop || service.rotationTicksFiredForTest != ticksAtStop,
            'a native call or a timer tick after B was stopped',
          );
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(beforeEmission: 1));
          expect(service.rotationTickFatesForTest['staleAtAdmission'], 0, reason: 'no timer of another run was left ticking');
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X264 — A, STOP, B, STOP, all while the stop ahead is in flight: nothing at all starts, both STARTs resolve quietly, '
      'and the service needs nothing to be usable again — the next START records',
      () async {
        await holdStopOfRecording0();
        try {
          final a = start('producer-A');
          final stoppingA = service.stopLoopRecording();
          final b = start('producer-B');
          final stoppingB = service.stopLoopRecording();
          expect(service.isRecording, isFalse);
          stop0Gate.complete();
          await Future.wait([stop0, stoppingA, stoppingB, a.done, b.done]).timeout(patience);
          await waitUntil(() => !service.hasPendingNativeStop, 'the stop of recording 0 settling');

          expect(a.error, isNull);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 1, reason: 'nothing started after recording 0');
          expect(count('stopVideoRecording'), 1);
          expectNothingRecording();
          expect(timerTicks, hasLength(1), reason: 'recording 0\'s only');
          expect(producers(), ['producer-0']);

          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull);
          expect(count('startVideoCapturing'), 2);
          await stopAndExpectItWas('producer-D');
          expect(producers(), ['producer-0', 'producer-D']);
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X265 — A, STOP, B, STOP, C, all while the stop ahead is in flight: only C — the latest START — starts, and what records '
      'is C\'s',
      () async {
        await holdStopOfRecording0();
        try {
          final recording0 = service.activeRecordingId!;
          final a = start('producer-A');
          final stoppingA = service.stopLoopRecording();
          final b = start('producer-B');
          final stoppingB = service.stopLoopRecording();
          final c = start('producer-C');
          stop0Gate.complete();
          await Future.wait([stop0, stoppingA, stoppingB, a.done, b.done, c.done]).timeout(patience);

          expect([a.error, b.error, c.error], everyElement(isNull));
          expect(count('startVideoCapturing'), 2, reason: 'recording 0, then C');
          expect(count('stopVideoRecording'), 1);
          expect(service.activeRecordingId, recording0 + 1);
          expect(service.isRecording, isTrue);
          expect(timerTicks, hasLength(2));
          await stopAndExpectItWas('producer-C');
          expect(producers(), ['producer-0', 'producer-C']);

          expect(service.startFatesForTest, startFates(beforeEmission: 2));
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X266 — many rapid attempts: ten START/STOP pairs and then START K, all while the stop ahead is in flight. Exactly one '
      'native START follows — K\'s; none of the eleven STARTs fails',
      () async {
        await holdStopOfRecording0();
        try {
          final attempts = <_Tracked>[];
          final stops = <Future<void>>[];
          for (var i = 1; i <= 10; i++) {
            attempts.add(start('producer-$i'));
            stops.add(service.stopLoopRecording());
          }
          final k = start('producer-K');
          stop0Gate.complete();
          await Future.wait([stop0, ...stops, ...attempts.map((t) => t.done), k.done]).timeout(patience);

          expect(attempts.map((t) => t.error), everyElement(isNull));
          expect(k.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'recording 0, then K — not the first of the ten');
          expect(count('stopVideoRecording'), 1);
          expect(service.isRecording, isTrue);
          expect(timerTicks, hasLength(2));
          await stopAndExpectItWas('producer-K');
          expect(producers(), ['producer-0', 'producer-K']);

          expect(service.startFatesForTest, startFates(beforeEmission: 10));
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X267 — superseded before the queue ever moved: START A, STOP and START B requested in one turn on an idle service. '
      'A emits nothing — the stop finds nothing to stop, and no clip of A ever exists',
      () async {
        service = build();
        await service.initialize();
        final a = start('producer-A');
        final stopOfA = service.beginStopLoopRecording();
        final b = start('producer-B');
        await Future.wait([a.done, b.done, stopOfA.presentation]).timeout(patience);

        expect(a.error, isNull);
        expect(b.error, isNull);
        expect(await stopOfA.handle.timeout(patience), isNull, reason: 'A never started: its stop had nothing to stop');
        expect(count('startVideoCapturing'), 1, reason: 'B only');
        expect(count('stopVideoRecording'), 0);
        expect(service.isRecording, isTrue);
        expect(timerTicks, hasLength(1));
        await stopAndExpectItWas('producer-B');
        expect(producers(), ['producer-B'], reason: 'nothing was ever recorded as A');

        expect(service.startFatesForTest, startFates(beforeEmission: 1));
      },
    );

    test(
      'X268 — superseded at its very last checkpoint: A is stopped and B requested from inside A\'s own semanticStillValid, '
      'the last caller code that runs before the native START. A still emits nothing',
      () async {
        service = build();
        await service.initialize();
        var consulted = 0;
        DashcamStopOutcome? stopOfA;
        _Tracked? b;
        final a = _Tracked(
          service.startLoopRecording(
            clipOwnerToken: 'producer-A',
            semanticStillValid: () {
              if (consulted++ == 0) {
                stopOfA = service.beginStopLoopRecording();
                b = start('producer-B');
              }
              return true;
            },
          ),
        );
        await a.done.timeout(patience);
        await b!.done.timeout(patience);
        await stopOfA!.presentation.timeout(patience);

        expect(a.error, isNull);
        expect(b!.error, isNull);
        expect(count('startVideoCapturing'), 1, reason: 'B only — A was superseded between its context check and its native call');
        expect(await stopOfA!.handle.timeout(patience), isNull, reason: 'A never started');
        expect(count('stopVideoRecording'), 0);
        expect(consulted, 1, reason: 'A got no further than that one checkpoint');
        expect(service.isRecording, isTrue);
        await stopAndExpectItWas('producer-B');
        expect(producers(), ['producer-B']);

        expect(service.startFatesForTest, startFates(beforeEmission: 1));
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.16 — the same when what the START waits behind is a slow rotation stop (R2.6.14, R2.6.15)', () {
    test(
      'X291 — recording 0\'s own rotation stop is slow and past its deadline; recording 0 is stopped, START A, STOP, START B, '
      'and only then that stop returns. The rotation does not restart, A emits nothing, and B is the one START that follows',
      () async {
        service = DashcamService(config: config(), segmentDuration: manualTicksOnly, stopVideoRecordingTimeout: const Duration(milliseconds: 40));
        service.segmentTimerArmedHookForTest = timerTicks.add;
        await service.initialize();
        await service.startLoopRecording(clipOwnerToken: 'producer-0');
        final gate = Completer<void>();
        fakePlatform.pendingStopVideoRecording = gate;
        try {
          final controller = service.previewController!;
          final recording0 = service.activeRecordingId!;
          timerTicks.single();
          await waitUntil(() => count('stopVideoRecording') == 1 && service.hasPendingNativeStop, 'the rotation stop being issued and held');
          await waitUntil(() => service.rotationStopOverdue, 'the rotation stop passing its deadline');

          final stopping0 = service.stopLoopRecording();
          final a = start('producer-A');
          final stoppingA = service.stopLoopRecording();
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted while the rotation stop is still in flight');
          expect(count('startVideoCapturing'), 1);
          gate.complete();
          await Future.wait([stopping0, stoppingA, a.done, b.done]).timeout(patience);
          await waitUntil(() => service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop, 'the rotation leaving the queue');

          expect(a.error, isNull);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'recording 0, then B — neither the rotation nor A started anything');
          expect(count('stopVideoRecording'), 1);
          expect(service.activeRecordingId, recording0 + 1);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(producers(), ['producer-0']);
          expect(timerTicks, hasLength(2), reason: 'recording 0\'s and B\'s');
          expect(service.cameraKnownUnavailable, isFalse, reason: 'a rotation stop that was merely slow leaves the camera usable (R2.6.14)');
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-B']);
          expect(count('dispose'), 0);

          expect(service.lastLateRotationDecisionForTest, 'supersededByNewerStart', reason: 'why the rotation did not restart');
          expect(service.startFatesForTest, startFates(beforeEmission: 1), reason: 'why A did not start');
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.16 — a START made inert while it waited leaves nothing behind', () {
    test(
      'X269 — stopped while it waited, and nothing else: no native START, the Future resolves, and the service does not say '
      'it records. (The rule that already did this before this round, still doing it)',
      () async {
        await holdStopOfRecording0();
        try {
          final a = start('producer-A');
          final stoppingA = service.stopLoopRecording();
          stop0Gate.complete();
          await Future.wait([stop0, stoppingA, a.done]).timeout(patience);
          await waitUntil(() => !service.hasPendingNativeStop, 'the stop of recording 0 settling');

          expect(a.error, isNull);
          expect(count('startVideoCapturing'), 1);
          expect(count('stopVideoRecording'), 1);
          expectNothingRecording();
          expect(producers(), ['producer-0']);

          expect(service.startFatesForTest, startFates(), reason: 'none of this round\'s rules was needed');
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X270 — dispose while START A waits: A emits nothing, its Future resolves, the camera and the process owner are '
      'released, and the service stays terminal',
      () async {
        await holdStopOfRecording0();
        try {
          final a = start('producer-A');
          final disposing = service.dispose();
          stop0Gate.complete();
          await Future.wait([stop0, a.done, disposing]).timeout(patience);
          await waitUntil(
            () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
            'dispose releasing the camera and the process owner',
          );

          expect(a.error, isNull);
          expect(count('startVideoCapturing'), 1, reason: 'recording 0 only');
          expect(count('stopVideoRecording'), 1);
          expect(count('dispose'), 1);
          expect(service.isRecording, isFalse);
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(producers(), ['producer-0']);
          expect(() => service.startLoopRecording(clipOwnerToken: 'producer-B'), throwsStateError);

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X271 — waiting behind the teardown of its own camera: releaseIdleCamera() is queued, START A is accepted for the '
      'camera that is still there, the camera is released. A emits nothing and does not leave "recording" standing over a '
      'camera that no longer exists; a fresh camera and START B record as B',
      () async {
        await holdStopOfRecording0();
        try {
          final oldController = service.previewController!;
          final releasing = service.releaseIdleCamera();
          final a = start('producer-A');
          expect(service.isRecording, isTrue, reason: 'test setup: A was accepted — its camera is still held, the release is queued');
          stop0Gate.complete();
          await Future.wait([stop0, releasing, a.done]).timeout(patience);
          await waitUntil(() => service.previewController == null, 'the camera being released');

          expect(a.error, isNull);
          expect(count('startVideoCapturing'), 1, reason: 'A emitted nothing');
          expect(count('stopVideoRecording'), 1);
          expect(count('dispose'), 1);
          expect(oldController.value.isRecordingVideo, isFalse);
          expect(service.isRecording, isFalse, reason: 'A took its own intent down with it');
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(DashcamService.processOwnerCurrentForTest, isNull);

          await service.initialize();
          final newController = service.previewController!;
          final b = start('producer-B');
          await b.done.timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2);
          expect(newController.value.isRecordingVideo, isTrue);
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-B']);

          expect(service.startFatesForTest, startFates(retracted: 1));
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X272 — waiting while the camera is re-initialized: initialize() is queued, START A is accepted for the old camera, '
      'the camera is replaced. A emits nothing on either camera, and the START that follows on the new camera is a real '
      'one — not absorbed by an intent A left behind',
      () async {
        await holdStopOfRecording0();
        try {
          final oldController = service.previewController!;
          final reinitializing = service.initialize();
          final a = start('producer-A');
          expect(service.isRecording, isTrue, reason: 'test setup: A was accepted for the camera that is still held');
          expect(count('createCameraWithSettings'), 1, reason: 'test setup: the re-initialize has not run yet');
          stop0Gate.complete();
          await Future.wait([stop0, reinitializing, a.done]).timeout(patience);

          final newController = service.previewController!;
          expect(newController, isNot(same(oldController)), reason: 'test setup: the camera was replaced');
          expect(a.error, isNull);
          expect(count('startVideoCapturing'), 1, reason: 'A emitted nothing: not on the camera it was admitted for, not on the new one');
          expect(newController.value.isRecordingVideo, isFalse);
          expect(timerTicks, hasLength(1), reason: 'recording 0\'s only');
          final claimedToRecordAfterA = service.isRecording;

          final b = start('producer-B');
          await b.done.timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'B really started');
          expect(newController.value.isRecordingVideo, isTrue);
          expect(service.isRecording, isTrue);
          expect(claimedToRecordAfterA, isFalse, reason: 'A had taken its own intent down with it');
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-B']);
          expect(count('createCameraWithSettings'), 2);

          expect(service.startFatesForTest, startFates(retracted: 1));
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X273 — its caller\'s context moved on while it waited (semanticStillValid says no at its turn; nothing told the '
      'service): A emits nothing, does not leave "recording" standing, and the next START is a real one',
      () async {
        await holdStopOfRecording0();
        try {
          final controller = service.previewController!;
          var contextOfACurrent = true;
          final a = _Tracked(service.startLoopRecording(clipOwnerToken: 'producer-A', semanticStillValid: () => contextOfACurrent));
          contextOfACurrent = false;
          stop0Gate.complete();
          await Future.wait([stop0, a.done]).timeout(patience);
          await waitUntil(() => !service.hasPendingNativeStop, 'the stop of recording 0 settling');

          expect(a.error, isNull);
          expect(count('startVideoCapturing'), 1, reason: 'A emitted nothing');
          expect(controller.value.isRecordingVideo, isFalse);
          expect(timerTicks, hasLength(1));
          final claimedToRecordAfterA = service.isRecording;

          final b = start('producer-B');
          await b.done.timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'B really started');
          expect(controller.value.isRecordingVideo, isTrue);
          expect(claimedToRecordAfterA, isFalse, reason: 'A had taken its own intent down with it');
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-B']);

          expect(service.startFatesForTest, startFates(retracted: 1));
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X286 — its caller\'s context moved on AND it was superseded (A, STOP, START B; then A\'s semanticStillValid says no): '
      'the intent standing at A\'s turn is B\'s, and A leaves it alone — B starts',
      () async {
        await holdStopOfRecording0();
        try {
          final controller = service.previewController!;
          var contextOfACurrent = true;
          final a = _Tracked(service.startLoopRecording(clipOwnerToken: 'producer-A', semanticStillValid: () => contextOfACurrent));
          final stoppingA = service.stopLoopRecording();
          final b = start('producer-B');
          contextOfACurrent = false;
          stop0Gate.complete();
          await Future.wait([stop0, stoppingA, a.done, b.done]).timeout(patience);

          expect(a.error, isNull);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'recording 0, then B — B was not turned into a no-op by A');
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(timerTicks, hasLength(2));
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-B']);

          expect(service.startFatesForTest['ownIntentRetracted'], 0, reason: 'the intent A found standing was not its own to take down');
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.16 — a START superseded while its native call is in flight', () {
    test(
      'X274 — A in flight, STOP, START B, and A\'s native START succeeds: the stop that withdrew A stops A\'s Recording, '
      'once; A arms no segment timer; B records, and the one timer armed is B\'s',
      () async {
        final startGate = await holdNextStart();
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final stopOfA = service.beginStopLoopRecording();
          expect(service.isRecording, isFalse);
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted while the native START of A is in flight');
          releaseStart(startGate);
          await Future.wait([a.done, b.done, stopOfA.presentation]).timeout(patience);
          final handleOfA = await stopOfA.handle.timeout(patience);

          expect(a.error, isNull);
          expect(b.error, isNull);
          expect(handleOfA, isNotNull, reason: 'the stop that withdrew A is the one that stopped A\'s Recording');
          expect(handleOfA!.producerToken, 'producer-A');
          await handleOfA.settlement.timeout(patience);
          expect(count('startVideoCapturing'), 2, reason: 'A, then B');
          expect(count('stopVideoRecording'), 1, reason: 'A\'s Recording was stopped once — not a second time by A itself');
          expect(producers(), ['producer-A']);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(timerTicks, hasLength(1), reason: 'one segment timer armed in all: A armed none');

          // That one timer is B's: its tick rotates B.
          timerTicks.single();
          await waitUntil(
            () => count('startVideoCapturing') == 3 && service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop,
            'the tick rotating B',
          );
          expect(producers(), ['producer-A', 'producer-B']);
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-A', 'producer-B', 'producer-B']);

          expect(service.startFatesForTest, startFates(afterEmission: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X275 — A in flight, STOP, START B, and A\'s native START FAILS: A\'s own caller learns it, and B is untouched — it '
      'starts and records (A\'s failure used to clear B\'s intent, and B "succeeded" without recording)',
      () async {
        final startGate = await holdNextStart();
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final stoppingA = service.stopLoopRecording();
          final b = start('producer-B');
          fakePlatform.pendingStartVideoCapturing = null;
          startGate.completeError(CameraException('start_failed', 'the native START of A failed'));
          await Future.wait([a.done, b.done, stoppingA]).timeout(patience);

          expect(a.error, isA<CameraException>(), reason: 'A\'s own caller is told that A failed, as before');
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'A (failed) and B — B was not turned into a no-op');
          expect(count('stopVideoRecording'), 0);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(timerTicks, hasLength(1));
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-B']);
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      // R2.6.17: until then the request that withdrew A here was a cleanup aimed
      // at the previous Recording. The independent review of R2.6.16 (P2-A)
      // showed that such a cleanup must not withdraw a START it does not name,
      // and it no longer does (dashcam_start_attempt_settlement_test.dart).
      // What is left that withdraws an in-flight START and queues nothing able
      // to reach its Recording is that START's own deadline — which R2.6.16
      // had left out. Same purpose, that trigger.
      'X276 — A in flight when its own START deadline elapses, then START B, then A\'s native START succeeds: nothing in the '
      'queue can reach A\'s late Recording. A finalizes the one Recording it created; B finds the camera free and records as B',
      () async {
        final startGate = await afterRecording0HoldNextStart(startDeadline: const Duration(milliseconds: 60));
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final recording0 = service.activeRecordingId!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          // By cause: A's Future resolves at A's own deadline — the native call is still held.
          await a.done.timeout(patience);
          expect(service.isRecording, isFalse, reason: 'test setup: A\'s deadline took A\'s own intent down');
          final b = start('producer-B');
          expect(service.isRecording, isTrue, reason: 'test setup: B was accepted while the native START of A is in flight');
          releaseStart(startGate);
          await b.done.timeout(patience);

          expect(a.error, isNull);
          expect(b.error, isNull, reason: 'B found the camera free');
          expect(count('startVideoCapturing'), 3, reason: 'recording 0, A, B');
          expect(count('stopVideoRecording'), 2, reason: 'recording 0, and A\'s Recording — stopped by A itself, once');
          expect(producers(), ['producer-0', 'producer-A']);
          expect(service.clips.last.recordingId, recording0 + 1, reason: 'the clip is the Recording A created');
          expect(service.activeRecordingId, recording0 + 2);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(timerTicks, hasLength(2), reason: 'recording 0\'s and B\'s — A armed none');
          expect(errors, isEmpty);

          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-0', 'producer-A', 'producer-B']);
          expect(count('createCameraWithSettings'), 1);
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          await errorsSub.cancel();
        }
      },
    );

    test(
      // R2.6.17: same change of trigger as X276 (the START's own deadline).
      'X277 — the same and NO new START, with a stop requested between the deadline and the late result: that stop finds '
      'nothing to reach yet and queues nothing, so A\'s late Recording still has no owner in the queue and A finalizes it. '
      'Nothing is left recording — no second stop is needed — the next stop has nothing to do, and the next START records',
      () async {
        final startGate = await afterRecording0HoldNextStart(startDeadline: const Duration(milliseconds: 60));
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          // By cause: A's Future resolves at A's own deadline — the native call is still held.
          await a.done.timeout(patience);
          expect(service.isRecording, isFalse, reason: 'test setup: A\'s deadline took A\'s own intent down');
          final stopBeforeTheLateResult = service.beginStopLoopRecording();
          await stopBeforeTheLateResult.presentation.timeout(patience);
          expect(await stopBeforeTheLateResult.handle.timeout(patience), isNull, reason: 'test setup: nothing records yet — that stop queued nothing');
          releaseStart(startGate);
          // By cause: the attempt has finished, whatever it did with what it created.
          await waitUntil(() => !service.startAttemptSettling && !service.hasPendingNativeStop, 'the START attempt of A finishing');

          expect(a.error, isNull);
          expect(count('stopVideoRecording'), 2, reason: 'recording 0, and A\'s late Recording — stopped by A itself');
          expect(count('startVideoCapturing'), 2);
          expectNothingRecording();
          expect(producers(), ['producer-0', 'producer-A']);
          expect(timerTicks, hasLength(1), reason: 'recording 0\'s only');

          final stop = service.beginStopLoopRecording();
          await stop.presentation.timeout(patience);
          expect(await stop.handle.timeout(patience), isNull, reason: 'nothing was left for a stop to find');
          expect(count('stopVideoRecording'), 2);

          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull);
          expect(count('startVideoCapturing'), 3);
          expect(controller.value.isRecordingVideo, isTrue);
          await stopAndExpectItWas('producer-D');
          expect(count('dispose'), 0);

          expect(service.startFatesForTest, startFates(ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      // R2.6.17: same change of trigger as X276 (the START's own deadline).
      'X278 — B is not touched by A\'s cleanup: while A\'s own stop is in flight B is still wanted and has started nothing; '
      'that stop concerns A\'s Recording alone; when it returns B starts and records as B',
      () async {
        final startGate = await afterRecording0HoldNextStart(startDeadline: const Duration(milliseconds: 60));
        final stopGate = Completer<void>();
        try {
          final controller = service.previewController!;
          final recording0 = service.activeRecordingId!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          // By cause: A's Future resolves at A's own deadline — the native call is still held.
          await a.done.timeout(patience);
          final b = start('producer-B');
          fakePlatform.pendingStopVideoRecording = stopGate;
          releaseStart(startGate);
          // By cause: A's native START returned and A went on to what it owes — or B settled, if A owed nothing.
          await waitUntil(() => service.hasPendingNativeStop || b.settled, 'A\'s own stop being issued and held');
          expect(count('stopVideoRecording'), 2, reason: 'A stops the Recording it created');

          // While A cleans up after itself.
          expect(service.pendingStopHandle!.recordingId, recording0 + 1, reason: 'the stop in flight is for the Recording A created');
          expect(service.pendingStopHandle!.controller, same(controller));
          expect(service.isRecording, isTrue, reason: 'B\'s intent stands');
          expect(b.settled, isFalse, reason: 'B waits its turn behind A\'s cleanup');
          expect(count('startVideoCapturing'), 2, reason: 'B has started nothing yet');
          expect(service.activeRecordingId, recording0 + 1);

          stopGate.complete();
          await b.done.timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 3);
          expect(count('stopVideoRecording'), 2, reason: 'A\'s cleanup stopped one Recording — its own');
          expect(producers(), ['producer-0', 'producer-A']);
          expect(service.activeRecordingId, recording0 + 2);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(timerTicks, hasLength(2));
          await stopAndExpectItWas('producer-B');

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          if (!stopGate.isCompleted) stopGate.complete();
        }
      },
    );

    test(
      // R2.6.17: same change of trigger as X276 (the START's own deadline).
      'X279 — A\'s cleanup itself fails: reported once, B is refused loudly (the camera is still taken by the Recording A '
      'could not stop) instead of "succeeding" without recording, and nothing claims to record',
      () async {
        final startGate = await afterRecording0HoldNextStart(startDeadline: const Duration(milliseconds: 60));
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 2, 'the native START of A being issued and held');
          // By cause: A's Future resolves at A's own deadline — the native call is still held.
          await a.done.timeout(patience);
          final b = start('producer-B');
          fakePlatform.failStopVideoRecordingWith = CameraException('stop_failed', 'the native stop of A failed');
          releaseStart(startGate);
          await b.done.timeout(patience);

          expect(a.error, isNull);
          expect(b.error, isA<CameraException>(), reason: 'B is told it did not start');
          expect(count('startVideoCapturing'), 2, reason: 'B never reached the platform: the camera still held A\'s Recording');
          expect(count('stopVideoRecording'), 2, reason: 'one attempt to stop A\'s Recording, never retried');
          expect(service.isRecording, isFalse, reason: 'nothing claims to record');
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(service.cameraKnownUnavailable, isTrue, reason: 'a failed stop leaves the camera untrusted, as for any other stop');
          expect(errors, hasLength(1), reason: 'the failure is reported once');
          expect(errors.single, contains('stop_failed'));

          // The established way out of a failed stop: a fresh camera.
          fakePlatform.failStopVideoRecordingWith = null;
          await service.initialize();
          final d = start('producer-D');
          await d.done.timeout(patience);
          expect(d.error, isNull);
          expect(service.previewController, isNot(same(controller)));
          expect(service.previewController!.value.isRecordingVideo, isTrue);
          await stopAndExpectItWas('producer-D');

          expect(service.startFatesForTest, startFates(afterEmission: 1, ownRecordingFinalized: 1));
        } finally {
          fakePlatform.failStopVideoRecordingWith = null;
          if (!startGate.isCompleted) startGate.complete();
          await errorsSub.cancel();
        }
      },
    );

    // R2.6.18: until that round this cleanup named ONLY the camera
    // (`expectedController`), and the test pinned that such a call withdraws
    // the START in flight — the very sequence the review of R2.6.17 reported as
    // R1 (its R1c), with A in the place of B. A camera names no START, so that
    // form now stops and withdraws nothing. The purpose of this test is
    // unchanged — a cleanup that CAN reach A's Recording keeps it — and so is
    // every assertion; what changed is how the cleanup says whose Recording it
    // means: by the identity of A's own START.
    test(
      'X280 — a targeted cleanup that CAN reach A\'s Recording (it names A\'s own START) keeps it: A does not finalize, the '
      'cleanup stops A\'s Recording itself and gets its handle, and B records',
      () async {
        final startGate = await holdNextStart();
        try {
          final controller = service.previewController!;
          final startOfA = service.beginStartLoopRecording(clipOwnerToken: 'producer-A');
          final a = _Tracked(startOfA.presentation);
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final cleanup = service.beginStopLoopRecording(startAttempt: startOfA.attempt);
          final b = start('producer-B');
          releaseStart(startGate);
          await Future.wait([a.done, b.done, cleanup.presentation]).timeout(patience);
          final handle = await cleanup.handle.timeout(patience);

          expect(a.error, isNull);
          expect(b.error, isNull);
          expect(handle, isNotNull, reason: 'the cleanup stopped A\'s Recording itself, and knows it');
          expect(handle!.producerToken, 'producer-A');
          await handle.settlement.timeout(patience);
          expect(count('stopVideoRecording'), 1, reason: 'stopped once');
          expect(count('startVideoCapturing'), 2);
          expect(producers(), ['producer-A']);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(timerTicks, hasLength(1));
          await stopAndExpectItWas('producer-B');

          expect(service.startFatesForTest, startFates(afterEmission: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X287 — A in flight, STOP, START B, and A\'s own START deadline elapses with the native call still in flight: the '
      'deadline is A\'s and takes down nothing of B. When the native call returns, the stop that withdrew A stops A\'s '
      'Recording and B starts',
      () async {
        final startGate = await holdNextStart(startDeadline: const Duration(milliseconds: 60));
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final stopOfA = service.beginStopLoopRecording();
          final b = start('producer-B');
          // By cause: A's Future resolves at A's deadline — the native call is still held.
          await a.done.timeout(patience);
          expect(a.error, isNull);
          expect(count('startVideoCapturing'), 1, reason: 'test setup: the native START of A has not returned');
          expect(b.settled, isFalse, reason: 'test setup: B waits behind A');
          final wantedAtTheDeadlineOfA = service.isRecording;

          releaseStart(startGate);
          await Future.wait([b.done, stopOfA.presentation]).timeout(patience);
          final handleOfA = await stopOfA.handle.timeout(patience);
          expect(handleOfA, isNotNull, reason: 'the stop that withdrew A stopped A\'s late Recording');
          expect(handleOfA!.producerToken, 'producer-A');
          await handleOfA.settlement.timeout(patience);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'B really started');
          expect(count('stopVideoRecording'), 1);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(timerTicks, hasLength(1), reason: 'B\'s — A armed none');
          expect(wantedAtTheDeadlineOfA, isTrue, reason: 'B\'s intent stood: the deadline that elapsed was A\'s');
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-A', 'producer-B']);

          expect(service.startFatesForTest, startFates(afterEmission: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X288 — the same, and A\'s native START then FAILS, late: reported once as A\'s failure, nothing of B is taken down, '
      'and B starts on the camera A never got',
      () async {
        final startGate = await holdNextStart(startDeadline: const Duration(milliseconds: 60));
        final errors = <String>[];
        final errorsSub = service.errors.listen(errors.add);
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final stopOfA = service.beginStopLoopRecording();
          final b = start('producer-B');
          await a.done.timeout(patience);
          expect(a.error, isNull, reason: 'a START that outlives its deadline resolves quietly, as before');
          final wantedAtTheDeadlineOfA = service.isRecording;

          fakePlatform.pendingStartVideoCapturing = null;
          startGate.completeError(CameraException('start_failed', 'the native START of A failed, late'));
          await Future.wait([b.done, stopOfA.presentation]).timeout(patience);

          expect(await stopOfA.handle.timeout(patience), isNull, reason: 'A never recorded: its stop had nothing to stop');
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'A (failed) and B — B was not turned into a no-op');
          expect(count('stopVideoRecording'), 0);
          expect(service.isRecording, isTrue);
          expect(controller.value.isRecordingVideo, isTrue);
          expect(wantedAtTheDeadlineOfA, isTrue, reason: 'B\'s intent stood');
          expect(errors, hasLength(1), reason: 'A\'s late failure, reported once');
          expect(errors.single, contains('start_failed'));
          await stopAndExpectItWas('producer-B');
          expect(producers(), ['producer-B']);
        } finally {
          if (!startGate.isCompleted) startGate.complete();
          await errorsSub.cancel();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.16 — stop, release and dispose while the native START is in flight keep owning what it starts', () {
    test(
      'X281 — STOP while A is in flight, nothing else: the stop stops A\'s Recording itself, once, and gets its handle; A '
      'does not finalize anything on its own',
      () async {
        final startGate = await holdNextStart();
        try {
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final stop = service.beginStopLoopRecording();
          releaseStart(startGate);
          await Future.wait([a.done, stop.presentation]).timeout(patience);
          final handle = await stop.handle.timeout(patience);

          expect(a.error, isNull);
          expect(handle, isNotNull);
          expect(handle!.producerToken, 'producer-A');
          await handle.settlement.timeout(patience);
          expect(count('stopVideoRecording'), 1, reason: 'stopped once, by the stop that was asked to');
          expect(producers(), ['producer-A']);
          expectNothingRecording();
          expect(timerTicks, isEmpty, reason: 'A armed no timer');

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X282 — releaseIdleCamera() while A is in flight: the release finalizes A\'s Recording, once, and then lets the camera '
      'go; A does not finalize anything on its own',
      () async {
        final startGate = await holdNextStart();
        try {
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final releasing = service.releaseIdleCamera();
          releaseStart(startGate);
          await Future.wait([a.done, releasing]).timeout(patience);
          await waitUntil(() => service.previewController == null, 'the camera being released');

          expect(a.error, isNull);
          expect(count('stopVideoRecording'), 1, reason: 'stopped once, by the release');
          expect(count('dispose'), 1);
          expect(producers(), ['producer-A'], reason: 'the clip was kept, as A\'s');
          expect(service.isRecording, isFalse);
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(DashcamService.processOwnerCurrentForTest, isNull);
          expect(timerTicks, isEmpty);

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );

    test(
      'X283 — dispose() while A is in flight: the teardown finalizes A\'s Recording, once, and releases the camera and the '
      'process owner; A does not finalize anything on its own',
      () async {
        final startGate = await holdNextStart();
        try {
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          final disposing = service.dispose();
          releaseStart(startGate);
          await Future.wait([a.done, disposing]).timeout(patience);
          await waitUntil(
            () => service.previewController == null && DashcamService.processOwnerCurrentForTest == null,
            'dispose releasing the camera and the process owner',
          );

          expect(a.error, isNull);
          expect(count('stopVideoRecording'), 1, reason: 'stopped once, by the teardown');
          expect(count('dispose'), 1);
          expect(producers(), ['producer-A']);
          expect(timerTicks, isEmpty, reason: 'A armed no timer on a service being disposed');
          expect(service.hasActiveSegmentTimerForTest, isFalse);
          expect(service.isRecording, isFalse);

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );
  });

  // R2.6.17: in R2.6.16 this group was "...is left as it was", and X289 pinned
  // that the late Recording "stays tracked and running — A does not stop it —
  // and the next teardown collects it", saying in so many words that the
  // START-deadline policy was not that round's to change. It is this round's:
  // the independent review of R2.6.16 classified exactly that end state as a
  // P2 (P2-B: camera recording, `isRecording == false`, no stop able to reach
  // it). Same sequence; the expectation is the new contract.
  group('Fase 16.2-R4.3-R2.6.16 — what a START that outlives its own deadline leaves behind (contract changed by R2.6.17)', () {
    test(
      'X289 — nothing else is requested: A\'s START deadline elapses, then its native START succeeds. The late Recording is '
      'not left running: the attempt that created it stops it, once, and its clip is kept as A\'s. Nothing records, no '
      'timer is armed, the camera stays held and idle, and a teardown afterwards has nothing left to collect',
      () async {
        final startGate = await holdNextStart(startDeadline: const Duration(milliseconds: 60));
        try {
          final controller = service.previewController!;
          final a = start('producer-A');
          await waitUntil(() => count('startVideoCapturing') == 1, 'the native START of A being issued and held');
          // By cause: A's Future resolves at A's deadline — the native call is still held.
          await a.done.timeout(patience);
          expect(a.error, isNull);
          expect(service.isRecording, isFalse, reason: 'as before: at its own deadline a START withdraws its own intent');
          expect(service.startAttemptSettling, isTrue, reason: 'the attempt itself is not over: its native call is still in flight');
          expect(count('stopVideoRecording'), 0);

          releaseStart(startGate);
          // By cause: the attempt has finished, whatever it did with what it created.
          await waitUntil(() => !service.startAttemptSettling && !service.hasPendingNativeStop, 'the START attempt of A finishing');
          expect(count('stopVideoRecording'), 1, reason: 'A stopped its own late Recording');
          expect(controller.value.isRecordingVideo, isFalse, reason: 'nothing is left recording');
          expect(service.isRecording, isFalse);
          expect(producers(), ['producer-A'], reason: 'the late clip is kept, as A\'s');
          expect(timerTicks, isEmpty, reason: 'no timer was armed for it');
          expect(service.previewController, same(controller), reason: 'the camera is still held, idle');
          expect(count('dispose'), 0);

          await service.releaseIdleCamera().timeout(patience);
          await waitUntil(() => service.previewController == null, 'the camera being released');
          expect(count('stopVideoRecording'), 1, reason: 'the teardown had nothing left to stop');
          expect(producers(), ['producer-A']);

          expect(service.startFatesForTest, startFates(ownRecordingFinalized: 1));
        } finally {
          if (!startGate.isCompleted) startGate.complete();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6.16 — joining a START that is already wanted is still not a new intent', () {
    test(
      'X284 — START A requested twice while it waits: the second call resolves at once, one native START serves both, and '
      'the first is not superseded by it',
      () async {
        await holdStopOfRecording0();
        try {
          final first = start('producer-A');
          final second = start('producer-A');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(second.settled, isTrue, reason: 'it joined the START already in the queue');
          expect(second.error, isNull);
          expect(first.settled, isFalse, reason: 'test setup: that START is still waiting behind the held stop');
          stop0Gate.complete();
          await Future.wait([stop0, first.done]).timeout(patience);

          expect(first.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'recording 0, then A — once');
          expect(service.isRecording, isTrue);
          expect(timerTicks, hasLength(2));
          await stopAndExpectItWas('producer-A');

          expect(service.startFatesForTest, startFates());
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );

    test(
      'X285 — START B requested while A waits, with NO stop in between: B\'s call is absorbed by the intent already in the '
      'queue (the rule this round leaves alone) and supersedes nothing — A still starts, once',
      () async {
        await holdStopOfRecording0();
        try {
          final a = start('producer-A');
          final b = start('producer-B');
          stop0Gate.complete();
          await Future.wait([stop0, a.done, b.done]).timeout(patience);

          expect(a.error, isNull);
          expect(b.error, isNull);
          expect(count('startVideoCapturing'), 2, reason: 'recording 0, then one START for the one intent');
          expect(service.isRecording, isTrue);
          expect(timerTicks, hasLength(2));
          await stopAndExpectItWas('producer-A');

          expect(service.startFatesForTest, startFates(), reason: 'an absorbed call is not a later START: A was not superseded');
        } finally {
          if (!stop0Gate.isCompleted) stop0Gate.complete();
        }
      },
    );
  });
}
