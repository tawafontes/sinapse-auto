import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraController;
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/services/dashcam_service.dart';

import 'support/fake_camera_platform.dart';
import 'support/held_deadlines.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeCameraPlatform fakePlatform;
  late DashcamService service;

  // DashcamService._clipsDirectory() calls path_provider's
  // getApplicationDocumentsDirectory(), a real platform channel — mocked
  // here to point at this test's own temp dir, the same way a real device
  // would resolve it, without touching any actual platform.
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  DashcamConfig config({
    CameraSelection cameraSelection = CameraSelection.rear,
    int storageQuotaMb = 1024,
    bool audioEnabled = false,
    VideoResolution resolution = VideoResolution.hd720,
    int frameRate = 30,
    bool enabled = true,
  }) {
    return DashcamConfig(
      cameraSelection: cameraSelection,
      storageQuotaMb: storageQuotaMb,
      audioEnabled: audioEnabled,
      resolution: resolution,
      frameRate: frameRate,
      enabled: enabled,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dashcam_service_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  /// Fase 16.2-R4.2A-R2 (review §19): after resolving a `Completer` a test
  /// controls, waits until `service.hasPendingNativeStop` clears — real
  /// evidence that the pending STOP/finalize operation's own processing (a
  /// real `File.copy()`, see `_finalizeSegmentResult`'s own doc, when it
  /// succeeded) has finished — instead of a single fixed sleep, whose
  /// duration can be insufficient under system load (observed directly: a
  /// 20ms fixed sleep intermittently left `service.clips` still empty when
  /// the very next line asserted on it).
  ///
  /// Fase 16.2-R4.2A-R3 (review §16/§17): this proves ONLY that
  /// `hasPendingNativeStop` cleared — i.e. that the finalize operation
  /// itself concluded — NOT that any SEPARATE teardown (`controller
  /// .dispose()`, closing `errors`) has also run: `releaseIdleCamera()`/
  /// `dispose()`'s own real teardown is a distinct, later step of
  /// `_queueTail` that this deliberately does not wait for (use
  /// [waitForCallCount] against concrete evidence — e.g. a `dispose` call —
  /// for that). Also fails the test EXPLICITLY on timeout (via `fail()`)
  /// instead of silently returning: a caller relying on this as proof of
  /// something it does not actually establish should see a clear failure,
  /// not a false pass.
  Future<void> waitForPendingStopToClear({int maxIterations = 50, Duration step = const Duration(milliseconds: 10)}) async {
    for (var i = 0; i < maxIterations; i++) {
      if (!service.hasPendingNativeStop) return;
      await Future<void>.delayed(step);
    }
    fail('waitForPendingStopToClear: hasPendingNativeStop was still true after ${maxIterations * step.inMilliseconds}ms');
  }

  /// Fase 16.2-R4.4-R1-T-Rm: polls [condition] until it holds, failing the test
  /// (never returning silently) after a finite bound.
  Future<void> waitForCondition(bool Function() condition, String label, {int maxIterations = 300}) async {
    for (var i = 0; i < maxIterations; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('waitForCondition: "$label" never held after ${maxIterations * 10}ms (calls: ${fakePlatform.calls.join(',')})');
  }

  /// Fase 16.2-R4.4-R1-T-Rm: a PREPARATION stop that must settle normally (the
  /// clip the rest of the test builds on). With a short
  /// `stopVideoRecordingTimeout` (the scenario needs it for a LATER stop), the
  /// clip's processing — its promotion is real file I/O since R4.4-R1 — could
  /// outlast the deadline under load: the stop returned before the clip existed
  /// and the camera generation was marked untrusted (reproduced by delaying
  /// only the promotion's rename, T-Rm 02_directed/screen_rename). Its
  /// deadlines are held ([HeldDeadlines]) for this one call: it returns once the
  /// stop really completed, and nothing may still be held afterwards.
  Future<void> stopNormally(DashcamService target, Future<void> Function() stop) async {
    final held = HeldDeadlines.upTo(target.stopVideoRecordingTimeout);
    await held.run(stop);
    expect(held.pending, 0, reason: 'test setup check: the preparation stop completed before any of its deadlines had to elapse');
  }

  /// Fase 16.2-R4.2A-R3 (review §18): waits for concrete evidence of real
  /// teardown — an expected number of occurrences of [call] in
  /// `fakePlatform.calls` (e.g. `'dispose'`) — rather than treating
  /// [waitForPendingStopToClear]'s own, narrower guarantee as a stand-in for
  /// it. Bounded and fails the test explicitly (via `fail()`) if the count
  /// is never reached, rather than a silent, potentially-false pass.
  Future<void> waitForCallCount(
    String call,
    int expectedCount, {
    int maxIterations = 50,
    Duration step = const Duration(milliseconds: 10),
  }) async {
    for (var i = 0; i < maxIterations; i++) {
      if (fakePlatform.calls.where((c) => c == call).length >= expectedCount) return;
      await Future<void>.delayed(step);
    }
    fail(
      'waitForCallCount: "$call" never reached $expectedCount occurrence(s) after '
      '${maxIterations * step.inMilliseconds}ms (currently '
      '${fakePlatform.calls.where((c) => c == call).length})',
    );
  }

  /// Fase 16.2-R4.2A-R6 (§23): polls [DashcamService.discoveryUncertainCountForTest]
  /// until it reaches [expected] — real evidence a specific caller's own
  /// discovery-uncertainty contribution has been paired with its own
  /// decrement (see [DashcamService._armDiscoveryUncertainty]'s own doc),
  /// not merely that SOME caller's did. Fails the test explicitly on
  /// timeout, matching [waitForCallCount]/[waitForPendingStopToClear]'s own
  /// established contract.
  Future<void> waitForDiscoveryUncertainCount(
    int expected, {
    int maxIterations = 50,
    Duration step = const Duration(milliseconds: 10),
  }) async {
    for (var i = 0; i < maxIterations; i++) {
      if (service.discoveryUncertainCountForTest == expected) return;
      await Future<void>.delayed(step);
    }
    fail(
      'waitForDiscoveryUncertainCount: never reached $expected after '
      '${maxIterations * step.inMilliseconds}ms (currently '
      '${service.discoveryUncertainCountForTest})',
    );
  }

  /// Fase 16.2-R4.2A-R7 (§5/§18): polls [DashcamService.previewController]
  /// until it is `null` — real evidence a REAL `controller.dispose()` call
  /// has actually resolved (`_controller` is only ever nulled, inside
  /// `_doReleaseController`, synchronously AFTER that `await` returns — see
  /// its own doc), not merely that some `dispose()`/`releaseIdleCamera()`
  /// call has visibly returned to its own caller (which this file's own
  /// docs elsewhere establish is not the same thing — a `dispose()` this
  /// test itself stalled via `fakePlatform.pendingDispose`, for instance,
  /// can be "returned from" by its own caller well before this). Deliberately
  /// small and explicit, not folded into [waitForCallCount] — that helper
  /// only ever proves a call was *issued* (logged synchronously, at
  /// invocation), never that it *finished*.
  Future<void> waitForControllerReleased({
    int maxIterations = 50,
    Duration step = const Duration(milliseconds: 10),
  }) async {
    for (var i = 0; i < maxIterations; i++) {
      if (service.previewController == null) return;
      await Future<void>.delayed(step);
    }
    fail('waitForControllerReleased: previewController was still non-null after ${maxIterations * step.inMilliseconds}ms');
  }

  /// Fase 16.2-R4.2B-R1: polls [DashcamService.processOwnerCurrentForTest]
  /// until it [identical]s [expected] — real evidence of the process-wide
  /// coordinator's own current owner, not an assumption about timing.
  /// Fails the test explicitly on timeout, matching every other helper in
  /// this file.
  Future<void> waitForProcessOwner(
    Object? expected, {
    int maxIterations = 50,
    Duration step = const Duration(milliseconds: 10),
  }) async {
    for (var i = 0; i < maxIterations; i++) {
      if (identical(DashcamService.processOwnerCurrentForTest, expected)) return;
      await Future<void>.delayed(step);
    }
    fail(
      'waitForProcessOwner: owner never matched the expected token after '
      '${maxIterations * step.inMilliseconds}ms (currently ${DashcamService.processOwnerCurrentForTest})',
    );
  }

  /// Fase 16.2-R4.2B-R4 (intervention — test determinism correction): polls
  /// [DashcamService.pendingInitializeSettlement] until it is `null` — real
  /// evidence that a specific RAW initialize() operation has genuinely
  /// settled AND self-cleared (via its own `.whenComplete()`, the exact
  /// mechanism `DashcamSessionController`'s own barrier-wait relies on),
  /// rather than presuming a fixed real-time margin was "enough" for that
  /// to already have happened. A caller that wants to observe a SPECIFIC
  /// raw operation's own settlement should first `await` that captured
  /// [Future] directly (with `.catchError`, since it may fail) — this
  /// helper only confirms the bookkeeping field itself cleared afterward,
  /// matching the self-clearing pattern, not listener-registration
  /// ordering. Fails the test explicitly on timeout, matching every other
  /// helper in this file.
  Future<void> waitForPendingInitializeSettlementToClear({
    int maxIterations = 50,
    Duration step = const Duration(milliseconds: 10),
  }) async {
    for (var i = 0; i < maxIterations; i++) {
      if (service.pendingInitializeSettlement == null) return;
      await Future<void>.delayed(step);
    }
    fail(
      'waitForPendingInitializeSettlementToClear: pendingInitializeSettlement was still non-null after '
      '${maxIterations * step.inMilliseconds}ms',
    );
  }

  tearDown(() async {
    // Let any still-pending fire-and-forget rotation/finalize work (a stray
    // Timer.periodic tick from a short segmentDuration test) settle before
    // the next test's setUp swaps CameraPlatform.instance out from under it.
    await Future<void>.delayed(Duration.zero);

    // Fase 16.2-R4.2A-R10 (§2/§3/§9 — independent review, confirmed
    // contraprova): a shared, LAST-RESORT terminal barrier — every test in
    // this file assigns `service` exactly once, as its own first statement
    // (verified for all 73 tests in this file as of this round), so this
    // is safe to call unconditionally. It does NOT replace a test's own
    // `finally` block: those remain solely responsible for releasing
    // gates/pending native operations that would otherwise deadlock this
    // very call (R9 already eliminated every known case of a test ending
    // with such an operation still deliberately blocked). This barrier
    // only catches a test that forgot to release an otherwise-idle
    // controller — `service.dispose()` is idempotent (safe to call again
    // even if the test's own code already disposed it, or never
    // initialized a controller at all — see `_doReleaseController`'s own
    // doc) and `waitForControllerReleased()` fails the test EXPLICITLY
    // (not silently) if a controller genuinely never releases, exactly
    // like every other helper in this file.
    await service.dispose().catchError((_) {});
    await waitForControllerReleased();

    // Fase 16.2-R4.2B-R2 (§23, independent review — "reset atual pode
    // apagar ownership ativo"): the process-wide ownership coordinator is
    // static — it survives across every test in this process. A NORMAL
    // test's own `service.dispose()` above already, naturally, releases it
    // (see `_doReleaseControllerAndOwnership`'s own doc) — so this only
    // VERIFIES that natural release happened, rather than force-clearing
    // it: a test that leaves the coordinator genuinely occupied here (e.g.
    // a deliberate dispose-failure test that forgot its own local
    // `DashcamService.simulateProcessRestartForTest` cleanup) must fail
    // loudly, not be silently masked by this shared barrier — masking is
    // exactly what an earlier version of this barrier did by calling that
    // reset unconditionally.
    await waitForProcessOwner(null);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    // Fase 16.2-R4.2A-R2 (wording corrected per R4.2A-R3 review §21: this is
    // NOT asserted as fact to be exclusively Windows handle-release timing —
    // only described as what is observed): a handful of this file's own
    // tests deliberately let a pending native stop resolve LATE, which
    // writes a real file via File.copy() moments before this tearDown runs.
    // Deleting the containing directory immediately afterward intermittently
    // raises a FileSystemException/PathAccessException here ("file in use" /
    // "directory not empty") on Windows, unrelated to any test's own
    // assertions (all of which already ran and settled by this point). This
    // is limited tolerance for a transient FileSystemException during test
    // teardown on Windows, not a substitute for deterministic cleanup
    // elsewhere in this file (see [waitForPendingStopToClear]/
    // [waitForCallCount]) — it only ever retries deleting this same,
    // already-torn-down temp directory, never re-runs any test logic, and
    // still rethrows (failing the test) if the condition does not clear.
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

  test(
    'recordedAt is stamped at segment START, not at finalize (Fase 15 — regression for a '
    'real, ~segmentDuration-off-by bug: the original code used DateTime.now() inside '
    '_finalizeCurrentSegment, up to segmentDuration late)',
    () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      await service.initialize();

      final beforeStart = DateTime.now();
      await service.startLoopRecording();
      // A real, measurable gap between segment start and segment stop —
      // large enough that "stamped at finalize" vs. "stamped at start"
      // produce clearly distinguishable recordedAt values.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await service.stopLoopRecording();
      final afterStop = DateTime.now();

      final clip = service.clips.single;
      expect(clip.recordedAt.difference(beforeStart).inMilliseconds, lessThan(50));
      expect(afterStop.difference(clip.recordedAt).inMilliseconds, greaterThanOrEqualTo(60));
    },
  );

  test(
    'startLoopRecording requests non-persistent video capture (Fase 16.2-R4.1A: '
    'DashcamService now asks the platform for enablePersistentRecording: false, the flag '
    'physically confirmed in Fase 16.2 R3-C to make a background-lost recording '
    'auto-finalize natively instead of surviving as a stale handle, Fase 16.2 R2/R3-A. '
    'This test only proves the request reaches VideoCaptureOptions — it makes no claim '
    'about native CameraX lifecycle behavior itself, which is exercised on real hardware, '
    'not here)',
    () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        await service.startLoopRecording();

        expect(fakePlatform.lastStartVideoCapturingOptions?.enablePersistentRecording, isFalse);
      } finally {
        await service.dispose();
      }
    },
  );

  test(
    'durationSeconds is stamped at segment STOP-REQUEST time, not after '
    'stopVideoRecording()\'s own finalize latency and the disk copy of the whole video file '
    '(Fase 15 — regression for a real bug found via physical hardware testing: the original code '
    'used a fresh DateTime.now() at the very end of _finalizeCurrentSegment, after both '
    'stopVideoRecording() and _moveToClipsDirectory()\'s file copy had already elapsed, so every '
    'clip\'s stored durationSeconds silently included that finalize+copy overhead — confirmed '
    'on-device as a consistent ~2s overstatement versus the same file\'s own actual playable '
    'length)',
    () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      await service.initialize();
      await service.startLoopRecording();

      // A short, real "recording" period...
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // ...followed by a stopVideoRecording() call that (exactly like real
      // hardware finalizing a several-MB file, see this fake field's own
      // doc) takes noticeably longer than the recording itself. This delay
      // sits entirely *after* the point durationSeconds must now be stamped
      // at — if it leaks into durationSeconds at all, the fix has regressed.
      fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 1200);
      await service.stopLoopRecording();

      // ~30ms of real recording, truncated to whole seconds, must read 0 —
      // the old code would have summed the 30ms recording *plus* the
      // 1200ms stop delay (~1230ms total) and reported 1.
      final clip = service.clips.single;
      expect(
        clip.durationSeconds,
        0,
        reason:
            'stopVideoRecording()\'s own 1200ms finalize latency must NOT be counted as part of '
            'the recorded segment\'s duration',
      );
    },
  );

  test(
    'markClipAsProtected protects the segment currently being recorded, not just the last '
    'already-finalized one (Fase 15 — regression for a real bug: the original code only '
    'marked clips.last, which is empty/irrelevant for an event during the very first segment)',
    () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      // Fase 16.2-R4.2A-R9 (§7/§41 audit): an assert between
      // startLoopRecording() and stopLoopRecording() below could otherwise
      // skip the call that cancels this test's own segment timer.
      try {
        await service.initialize();
        await service.startLoopRecording();

        // No finalized clip exists yet — this is exactly the case the fixed
        // bug covers: an event fires while the first segment is still
        // recording, before anything has landed in `clips`.
        expect(service.clips, isEmpty);
        await service.markClipAsProtected();

        await service.stopLoopRecording();

        expect(service.clips, hasLength(1));
        expect(service.clips.single.isProtected, isTrue);
      } finally {
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    },
  );

  test('frameRate from DashcamConfig is passed through to the camera platform', () async {
    service = DashcamService(config: config(frameRate: 24), segmentDuration: const Duration(minutes: 10));
    await service.initialize();

    expect(fakePlatform.lastMediaSettings?.fps, 24);
  });

  test('initialize() is re-entrant-safe: a second concurrent call does not create a second camera', () async {
    service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));

    final first = service.initialize();
    final second = service.initialize();
    await Future.wait([first, second]);

    expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));
  });

  test(
    'initialize() disposes the previous CameraController before creating a new one for a second, '
    'SEQUENTIAL call (Fase 15 — regression for a real leak found via physical hardware testing: '
    'DashcamService is long-lived and initialize() is called once per driving session, not once '
    'per app run, but the original code only guarded the concurrent-call case, so every session '
    'after the first constructed a brand new CameraController without ever disposing the '
    'previous one — leaking its native camera session and leaving its _onControllerValueChanged '
    'listener attached forever)',
    () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));

      await service.initialize();
      expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));
      expect(fakePlatform.disposedCameraIds, isEmpty);

      // A second session starting later — fully sequential, the first call
      // already completed (unlike the concurrent case above).
      await service.initialize();

      expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(2));
      expect(
        fakePlatform.disposedCameraIds,
        equals([0]),
        reason: 'the first camera (id 0) must be disposed before/while the second (id 1) is created',
      );
    },
  );

  // Fase 16.2-R4.4-R2 — ADAPTED (owner decision O4; D0 RK2).
  // BEFORE: with a 0 MB quota the service itself evicted every unprotected
  //   clip, inside its camera FIFO, right after each promotion — only the
  //   protected first segment was left in `clips`.
  // WHY superseded: the quota is physical now and runs in the index FIFO over
  //   the disk (dashcam_storage_quota.dart); the camera FIFO enforces none (D0
  //   §12: a quota deletion there consumed the STOP's budget and its failure
  //   stopped the recording). These clips have unknown provenance (no producer
  //   token → legacy names), which the quota never manages anyway.
  // AFTER: with the same 0 MB quota, the service deletes NOTHING: one clip per
  //   segment started, every file still on disk, the protection on the first.
  //   "Oldest unprotected first, protected kept" is proven where eviction now
  //   lives: X490/X492 (module) and X511 (controller).
  // NEGATIVE CONTROL: the old in-FIFO quota put back in
  //   `_finalizeSegmentResult` (mutant M9) evicts here → this test fails.
  test('quota enforcement deletes the oldest unprotected clip first, keeps a protected one', () async {
    service = DashcamService(
      config: config(storageQuotaMb: 0), // 0 MB *1024*1024 == 0 bytes quota — any clip triggers eviction
      segmentDuration: const Duration(milliseconds: 20),
    );
    await service.initialize();
    await service.startLoopRecording();
    await service.markClipAsProtected(); // protects the first segment once it finalizes
    await Future<void>.delayed(const Duration(milliseconds: 40)); // let one rotation happen
    await service.stopLoopRecording();

    final segmentsStarted = fakePlatform.calls.where((c) => c == 'startVideoCapturing').length;
    expect(segmentsStarted, greaterThanOrEqualTo(1));
    expect(service.clips, hasLength(segmentsStarted), reason: 'the camera FIFO evicts nothing: one clip per segment started');
    expect(service.clips.first.isProtected, isTrue, reason: 'the protection still lands on the segment that was recording');
    expect(service.clips.every((clip) => clip.file.existsSync()), isTrue, reason: 'every file is still on disk');
  });

  test('dispose() best-effort finalizes an in-flight segment instead of discarding it', () async {
    service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
    // Fase 16.2-R4.2A-R9 (§7/§41 audit): the expect() below could otherwise
    // throw before dispose() (this test's own cancelling call) ever ran.
    try {
      await service.initialize();
      await service.startLoopRecording();

      expect(service.clips, isEmpty);
      await service.dispose();

      expect(fakePlatform.calls, contains('stopVideoRecording'));
    } finally {
      await service.dispose().catchError((_) {});
      await waitForControllerReleased();
    }
  });

  test('errors stream reports an asynchronous camera-lost error, not a normal method failure', () async {
    service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
    final errors = <String>[];
    service.errors.listen(errors.add);

    // A normal initialize() failure throws — it must NOT also appear on
    // errors (see DashcamService.errors' own doc for why).
    fakePlatform.failCreateCameraWith = CameraException('no_camera', 'forced failure');
    await expectLater(service.initialize(), throwsA(isA<CameraException>()));
    expect(errors, isEmpty);
  });

  group('Fase 16.2 — background camera loss vs. segment rotation', () {
    test(
      'segment rotation is skipped while the camera is known-unavailable, and does not call '
      'stopVideoRecording against a camera Android may have already revoked (§16 regression test '
      'for the confirmed root cause of a real crash reproduced on a Samsung SM-A326B: RECORDING → '
      'app backgrounded → camera silently revoked by Android, with no Dart-visible signal → '
      '3-minute rotation timer fires → stopVideoRecording() against the gone camera → native '
      'Recorder stuck in STOPPING → later resume reconfiguration collides with it → AssertionError '
      'in Recorder.onConfigured(), Recorder.java:1476, fatal process death)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        // Fase 16.2-R4.2A-R9 (§8 — independent review): even though this
        // test's own point is that the rotation tick's callback returns
        // before ever touching the camera once `cameraKnownUnavailable` is
        // true, the underlying `Timer.periodic` itself is not cancelled by
        // that — it still wakes the isolate and runs Dart every 20ms unless
        // explicitly cancelled via stopLoopRecording()/releaseIdleCamera()/
        // dispose(), none of which this test used to call at all.
        try {
          await service.initialize();
          await service.startLoopRecording();
          final callsBeforeBackground = fakePlatform.calls.length;

          service.notifyAppBackgrounded();
          expect(service.cameraKnownUnavailable, isTrue);

          // Long enough for the real Timer.periodic to fire at least once,
          // exactly like it would while genuinely backgrounded.
          await Future<void>.delayed(const Duration(milliseconds: 60));

          expect(
            fakePlatform.calls.skip(callsBeforeBackground),
            isNot(contains('stopVideoRecording')),
            reason: 'the rotation timer must not call stopVideoRecording() once the camera is known-unavailable',
          );
          expect(
            fakePlatform.calls.skip(callsBeforeBackground),
            isNot(contains('startVideoCapturing')),
            reason: 'nor may it attempt to start a new segment on a known-lost camera',
          );
          expect(service.clips, isEmpty, reason: 'nothing was finalized — the camera was never stopped, so there is nothing to save');
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'normal foreground segment rotation is unaffected — still produces successive clips when the '
      'camera stays available (proves the Fase 16.2 guard only engages when actually backgrounded)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        await service.initialize();
        await service.startLoopRecording();

        // Harness T5: waits for the rotations themselves instead of a fixed
        // 70 ms ("several rotation periods"). No stop deadline is configured
        // here (production default): what that fixed window bounded was the
        // first rotation's finalize — a REAL File.copy of the clip — which had
        // to end within ~50 ms (70 ms minus the first tick at 20 ms) for a
        // second Recording to exist when the stop arrived. A slower copy left
        // a single clip and failed a property that still held. The third
        // startVideoCapturing is only issued once two rotations have been
        // finalized and restarted: the "successive clips" this test is about.
        // Bounded; fails explicitly.
        await waitForCallCount('startVideoCapturing', 3, maxIterations: 200);

        await service.stopLoopRecording();

        expect(service.clips.length, greaterThanOrEqualTo(2));
        expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording').length, service.clips.length);
      },
    );

    test(
      'stopLoopRecording() while the camera is known-unavailable still calls stopVideoRecording and '
      'still collects the clip, and clears isRecording (e.g. the user returns to the app and taps '
      'stop before any automatic recovery has had a chance to run). Fase 16.2-R4.2A-R4 (§4/§5/§7 — '
      'independent review, dynamically reproduced P1): an EXPLICIT, user-initiated stop is not a "start '
      'a NEW recording" decision (the thing _cameraKnownUnavailable must still gate — see '
      '_FinalizeReason.rotation\'s own doc) — it is the exact "collect an EXISTING owned Recording" '
      'obligation this class exists to fulfill. The R1-era version of this test asserted the opposite '
      '(no stop, no clip), which is precisely the silent-data-loss behavior an independent review '
      'found and this subfase fixes',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        // Fase 16.2-R4.2A-R8 (§4/§19 — independent review, confirmed bug):
        // this test had no try/finally and no dispose() at all — the
        // controller leaked into whatever test ran next even on the happy
        // path.
        try {
          await service.initialize();
          await service.startLoopRecording();

          service.notifyAppBackgrounded();
          final callsBefore = fakePlatform.calls.length;

          await service.stopLoopRecording();

          expect(fakePlatform.calls.skip(callsBefore), contains('stopVideoRecording'));
          expect(service.isRecording, isFalse);
          expect(service.clips, hasLength(1), reason: 'the segment that was actually recording must still be collected, not silently discarded');
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'dispose() while the camera is known-unavailable still collects the in-flight segment (exactly '
      'one stopVideoRecording call, one clip) before releasing the controller. Fase 16.2-R4.2A-R4 '
      '(§4/§5/§7/§8 — same reasoning as the stopLoopRecording() test above, _FinalizeReason.teardown): '
      'a teardown discards the controller regardless of what it decides, so skipping the stop here '
      'only ever loses a clip — an architectural fact about this class\'s own serialized, single-owner '
      'teardown path, not a hardware-validated safety claim (see this class\'s own doc, final paragraph) '
      '— the R1-era version of this test asserted the opposite (no stop attempted)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          await service.initialize();
          await service.startLoopRecording();

          service.notifyAppBackgrounded();
          final callsBefore = fakePlatform.calls.length;

          await service.dispose();

          expect(fakePlatform.calls.skip(callsBefore), contains('stopVideoRecording'));
          expect(fakePlatform.calls.skip(callsBefore), contains('dispose'));
          expect(service.clips, hasLength(1), reason: 'the segment that was actually recording must still be collected before the controller is disposed');
          final stopIndex = fakePlatform.calls.indexOf('stopVideoRecording');
          final disposeIndex = fakePlatform.calls.indexOf('dispose');
          expect(disposeIndex, greaterThan(stopIndex), reason: 'controller.dispose() must never precede collecting the Recording it still holds');
        } finally {
          // Fase 16.2-R4.2A-R8 (§16/§19): `dispose()` above already ran, but
          // its own bounded wait returning is not itself proof the queued
          // `_doReleaseController` work it triggered has actually finished
          // (see this file's own §5/§16 docs elsewhere) — a safety-net
          // dispose() call plus concrete release evidence closes that gap
          // regardless of where an assert above may have thrown.
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'a fresh initialize() after the camera was known-unavailable clears the flag, collects the '
      'segment that was abandoned while backgrounded, and a brand new recording then starts normally '
      '(the foreground-return recovery path: DashcamSessionController always calls initialize() again '
      'before startLoopRecording()). Fase 16.2-R4.2A-R4 (§4/§7/§8, R3-C/R3-D architecture): '
      'initialize()\'s own internal release of the prior controller (_FinalizeReason.teardown) is '
      'exactly the "background/source-inactive → unavailability → public stop of the ORIGINAL Recording '
      '→ its XFile → dispose → only THEN a new generation" flow — the segment is not lost, it is '
      'recovered here, one call later than before this fix',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        // Fase 16.2-R4.2A-R8 (§5/§19 — independent review, confirmed bug):
        // this test creates controller A, then (via the second initialize()
        // below) a fresh controller B, and had no try/finally/dispose() at
        // all — B leaked into whatever test ran next even on the happy
        // path. A failure at any expect leaves whichever generation is
        // current at that point open too.
        try {
          await service.initialize();
          await service.startLoopRecording();
          service.notifyAppBackgrounded();
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.clips, isEmpty, reason: 'not finalized YET — nothing has released the prior controller so far, that only happens once initialize() runs below');

          await service.initialize();
          expect(service.cameraKnownUnavailable, isFalse, reason: 'a fresh successful initialize() must clear the flag');
          expect(service.clips, hasLength(1), reason: 'the segment abandoned while backgrounded must be collected by initialize()\'s own internal teardown of the prior controller, not discarded');

          await service.startLoopRecording();
          expect(service.isRecording, isTrue);
          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing').length,
            2,
            reason: 'one from before backgrounding, one fresh after recovery',
          );

          // The post-recovery segment is a genuinely new, camera-available
          // recording — stopping it must finalize and save it like any other
          // segment, not silently drop it.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await service.stopLoopRecording();
          expect(
            service.clips,
            hasLength(2),
            reason: 'the recovered pre-background segment (1) plus the post-recovery segment (2) must both be finalized and saved',
          );
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'the segment timer is not duplicated across a background-loss → recovery re-initialize cycle: '
      'stopping after recovery finalizes exactly one segment, not two (§13 — only one Timer.periodic '
      'may be active after recovery, not one stacked on top of a leftover from before backgrounding)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 25));
        // Fase 16.2-R4.2A-R8 (§6/§19 — independent review, confirmed bug):
        // `segmentDuration: 25ms` means a live Timer.periodic is running
        // through most of this test — this test had no try/finally/
        // dispose() at all, so a failure at any expect (or even the happy
        // path) left that timer, and the second (recovery) controller it
        // drives, alive to fire into whatever test ran next.
        try {
          await service.initialize();
          await service.startLoopRecording();

          service.notifyAppBackgrounded();
          // Past several would-be rotation ticks, exactly like a real
          // multi-minute background stay crossing the rotation mark.
          await Future<void>.delayed(const Duration(milliseconds: 60));

          await service.initialize(); // recovery's fresh reinitialize
          await service.startLoopRecording();
          final callsAfterRecoveryStart = fakePlatform.calls.length;

          await service.stopLoopRecording();

          // If the pre-backgrounding timer had somehow survived alongside a
          // second, independent one from recovery, this single stop would
          // race two overlapping rotation/stop cycles instead of cleanly
          // finalizing exactly the one active segment.
          expect(fakePlatform.calls.skip(callsAfterRecoveryStart).where((c) => c == 'stopVideoRecording'), hasLength(1));
          // Fase 16.2-R4.2A-R4: 2, not 1 — the segment abandoned while
          // backgrounded is now also collected, by the recovery initialize()
          // call's own internal teardown of the prior controller (see the
          // dedicated recovery test above); this test's own concern (exactly
          // ONE segment/timer active post-recovery, not two overlapping ones)
          // is still what the stopVideoRecording count above proves.
          expect(service.clips, hasLength(2));
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test('notifyAppBackgrounded() is a no-op when nothing is recording', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      await service.initialize();

      service.notifyAppBackgrounded();

      expect(service.cameraKnownUnavailable, isFalse);
    });

    test('calling startLoopRecording() twice in a row is a no-op the second time (double start)', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      // Fase 16.2-R4.2A-R9 (§12 — independent review): this test never
      // called stopLoopRecording()/releaseIdleCamera()/dispose() at all —
      // its own 10-minute segment timer stayed active (uncancelled) past
      // the test's own end. Unlikely to fire during a short suite run, but
      // still a genuinely active, undrained resource per this round's own
      // closure standard (§8) — not conditioned on how likely it is to
      // actually tick.
      try {
        await service.initialize();

        await service.startLoopRecording();
        await service.startLoopRecording();

        expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1));
      } finally {
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('calling stopLoopRecording() twice in a row is a no-op the second time (double stop)', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      await service.initialize();
      await service.startLoopRecording();

      await service.stopLoopRecording();
      await service.stopLoopRecording();

      expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
    });

    test(
      'a segment rotation racing an explicit stopLoopRecording() call finalizes the segment exactly '
      'once, not twice ("rotate during stop": the real camera package only flips '
      'CameraValue.isRecordingVideo to false AFTER stopVideoRecording()\'s platform call resolves — '
      'verified against camera-0.12.0+2 source — so without deduplication both the rotation\'s own '
      'finalize and an explicit stop landing at the same moment would each independently call '
      'stopVideoRecording())',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        await service.initialize();
        await service.startLoopRecording();

        fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 80);
        // Let the segment timer fire and get partway into its own in-flight finalize.
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Races the in-flight rotation's own finalize.
        await service.stopLoopRecording();

        expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
        expect(service.clips, hasLength(1));
        expect(service.isRecording, isFalse);
      },
    );

    test(
      'dispose() called while a segment rotation is already mid-flight finalizes exactly once and '
      'still releases the camera hardware ("dispose during rotation" — the same in-flight-Future '
      'deduplication that protects rotate-during-stop also protects this, since _releaseController '
      'goes through the same _finalizeCurrentSegment)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        await service.initialize();
        await service.startLoopRecording();

        fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 80);
        await Future<void>.delayed(const Duration(milliseconds: 30)); // rotation's finalize now in flight

        await service.dispose();

        expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
        expect(fakePlatform.calls, contains('dispose'));
        expect(service.clips, hasLength(1));
      },
    );

    test(
      'a segment rotation racing a concurrent initialize() call (e.g. a manual camera retry, or '
      'DashcamSessionController\'s own recovery restart) does not restart a recording on the '
      'controller initialize() just replaced ("rotate during initialization" — initialize() releases '
      'the previous controller through the same _releaseController as dispose(), so the same fix '
      'that closes "dispose during rotation" applies here too)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        await service.initialize();
        await service.startLoopRecording();

        fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 80);
        await Future<void>.delayed(const Duration(milliseconds: 30)); // rotation's finalize now in flight

        await service.initialize(); // races the in-flight rotation exactly like dispose() does above

        expect(
          fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
          hasLength(1),
          reason:
              'only the original startLoopRecording() call may have started a recording — the '
              'racing rotation must not restart one on the controller initialize() just replaced',
        );
        expect(service.isRecording, isFalse);
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(2));
      },
    );

    test(
      'dispose() is terminal: an initialize() call issued right after (without awaiting dispose '
      'first) throws immediately instead of racing it (Fase 16.2-R1, independent review §12 '
      '"dispose+initialize": a service that stays ambiguously reusable after dispose() is exactly '
      'what the review asked to be resolved one way or the other — this class chose "terminal", '
      'checked synchronously so a call issued the instant after dispose() sees it immediately, not '
      'only once dispose()\'s own queued teardown eventually completes). dispose() itself still '
      'completes normally and releases the camera hardware regardless.',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        await service.initialize();
        await service.startLoopRecording();

        final disposeFuture = service.dispose();
        expect(() => service.initialize(), throwsA(isA<StateError>()));

        await disposeFuture;
        expect(fakePlatform.calls, contains('dispose'));
      },
    );

    test(
      'stopVideoRecording() hanging past the configured timeout abandons the segment instead of '
      'blocking forever, and marks the camera known-unavailable (physical-device finding on a '
      'Samsung SM-A326B: a completely normal, foreground, user-initiated stop — no backgrounding '
      'involved — can hang at the exact same native chokepoint as the original Fase 16.1 crash, '
      '`Recorder: The source didn\'t become non-streaming before timeout`, after CameraX\'s own '
      'reconnection-after-loss behavior left the Recorder in an unstable state with no Dart-visible '
      'signal)',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§13/§14/§15/§26 — independent review, confirmed
        // bug): this test used to set `fakePlatform.stopVideoRecordingDelay
        // = const Duration(seconds: 2)` — a REAL Dart `Future.delayed`
        // running on the real clock, well past this test's own end (this
        // whole suite runs in well under 2 seconds). By the time it fired,
        // this test's own temp dir had already been deleted by `tearDown`,
        // and the resulting filesystem access could surface as an
        // unhandled async error while a LATER, unrelated test was running.
        // Replaced with the same deterministic `pendingStopVideoRecording`
        // Completer this file already uses elsewhere (TESTE C/D/I) for
        // "late-resolving stop" scenarios — `DashcamService`'s own timeout
        // mechanism only cares that the underlying Future hasn't resolved
        // yet, not why, so this is behaviorally identical to the real
        // reviewer-observed timing without ever depending on the real
        // clock.
        final stopCompleter = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter; // deterministically "hangs" past the 50ms timeout
          await service.stopLoopRecording();

          expect(service.clips, isEmpty, reason: 'nothing was reliably captured — the segment must be abandoned, not saved');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'a hung stop must be treated the same as a known-lost camera going forward');
          expect(service.isRecording, isFalse);
        } finally {
          // Let the late-resolving native stop genuinely conclude, inside
          // this test's own lifetime, before its temp dir is torn down —
          // proving the delay does not resume later, not merely that the
          // test itself reports green.
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'a stopVideoRecording() that resolves comfortably within the timeout is unaffected — normal '
      'finalize still succeeds and produces a clip',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(seconds: 2),
        );
        await service.initialize();
        await service.startLoopRecording();

        fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 50); // well under the 2s timeout
        await service.stopLoopRecording();

        expect(service.clips, hasLength(1));
        expect(service.cameraKnownUnavailable, isFalse);
      },
    );

    test(
      'a segment rotation whose own stopVideoRecording() hangs past the timeout does not restart a '
      'new recording on the now-known-unhealthy controller',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 20),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§13/§14/§15/§26, independent review, confirmed
        // bug): same class of issue as the test above — a real 2-second
        // `Future.delayed` outliving this test, PLUS this test never called
        // stopLoopRecording()/releaseIdleCamera()/dispose() at all, leaving
        // its own live 20ms rotation Timer.periodic uncancelled too.
        // Replaced the real delay with the deterministic
        // `pendingStopVideoRecording` gate and added failure-safe cleanup.
        final stopCompleter = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter; // deterministically "hangs" past the 50ms timeout
          // Let the segment timer fire and time out.
          await Future<void>.delayed(const Duration(milliseconds: 120));

          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(1),
            reason: 'only the original startLoopRecording() call — the rotation must not restart on a controller whose stop just hung',
          );
          expect(service.cameraKnownUnavailable, isTrue);
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R1 — post-review hardening (ownership, serialization, native-operation safety)', () {
    test(
      '§18-A (superseded by Fase 16.2-R4.2A): a native stopVideoRecording() that resolves AFTER the '
      'UI-visible deadline does not throw an uncaught error, and its XFile is preserved and processed '
      'exactly once once the real result is known — the R1-era version of this test asserted the '
      'opposite (a late completion must NOT retroactively add a clip), which was exactly the "XFile '
      'tardio descartado" P1 that R4.2A exists to fix; see DashcamService._doFinalizeCurrentSegment\'s '
      'own doc',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;

        // Returns at the UI deadline, not when the native call actually
        // resolves — see stopLoopRecording()'s own doc.
        await service.stopLoopRecording();
        expect(service.cameraKnownUnavailable, isTrue);
        expect(service.clips, isEmpty, reason: 'the real native result has not arrived yet');
        expect(service.hasPendingNativeStop, isTrue);

        // The native call finally "completes" well after the timeout — a
        // real device confirmed this can happen. Must not throw anywhere
        // uncaught/unhandled, AND the resulting clip must not be discarded.
        stopCompleter.complete();
        await waitForPendingStopToClear();

        expect(service.clips, hasLength(1), reason: 'the late completion\'s XFile must be preserved, not discarded');
        expect(service.hasPendingNativeStop, isFalse, reason: 'the barrier must release once processing is done');
      },
    );

    test(
      '§18-B (superseded by Fase 16.2-R4.2A): a still-pending native stopVideoRecording() blocks a '
      'later initialize() from opening a new camera generation until the real result is known — the '
      'R1-era version of this test asserted the opposite (initialize() proceeds after a short '
      '"quarantine" even though the old stop is still pending), which was exactly the ownership gap '
      'R4.2A closes',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();
        final oldController = service.previewController;

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording();
        expect(service.cameraKnownUnavailable, isTrue);
        expect(service.hasPendingNativeStop, isTrue);

        // Recovery attempt: kicked off but deliberately NOT awaited yet —
        // it must not be able to proceed while the old stop is still
        // pending.
        var initializeCompleted = false;
        final recovery = service.initialize().whenComplete(() => initializeCompleted = true);

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(initializeCompleted, isFalse, reason: 'initialize() must not cross a still-pending native stop');
        expect(service.previewController, same(oldController), reason: 'no new controller may have been created yet');
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));

        // NOW the old native stop finally resolves — only then may recovery
        // proceed.
        stopCompleter.complete();
        await recovery;

        expect(initializeCompleted, isTrue);
        expect(service.cameraKnownUnavailable, isFalse);
        expect(service.clips, hasLength(1), reason: 'the old stop\'s XFile must still have been preserved');
        expect(
          fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
          hasLength(2),
          reason: 'exactly one new camera generation was opened, only after the old stop resolved',
        );
      },
    );

    test(
      'physical-validation finding (Samsung SM-A326B), updated for Fase 16.2-R4.2A: after a '
      'ROTATION-triggered native stop timeout (not an explicit stopLoopRecording(), which clears '
      'intent itself) leaves isRecording=true (intent survives, see its own doc) and '
      'cameraKnownUnavailable=true, recovery (initialize() then startLoopRecording(), exactly '
      '_attemptRecoveryRestart\'s own sequence) must NOT open a new camera generation while that '
      'rotation\'s own native stop is still unresolved (Fase 16.2-R4.2A\'s own ownership barrier — the '
      'R1-era version of this test let recovery proceed immediately, which is exactly the same gap '
      'that historically let a real device silently reopen the camera without ever reissuing '
      'startVideoRecording(): confirmed via CameraGraph state reaching OPEN but no native '
      'startVideoRecording() issued for ~19 minutes, no new Muxer.setOutput, no new raw temp file, '
      'while status kept reporting "recording"). Once the old stop genuinely resolves, recovery must '
      'still issue a REAL native start on the fresh controller.',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R8 (§19 — self-discovered during the full-file
        // audit mandated by the independent review): the comment that used
        // to sit right before this test's own final `dispose()` call
        // already named the exact danger a live 30ms segment timer poses if
        // left running past this test (real rotations firing against this
        // test's own, about-to-be-deleted temp dir and fakePlatform,
        // corrupting later tests) — but only handled it on the happy path.
        // Six `expect()` calls run between creating `stopCompleter` and that
        // original, unconditional `dispose()` call; camera availability is
        // restored (recovery succeeds) partway through, so a failure late
        // in this test left a genuinely active, camera-available,
        // un-cancelled timer behind, not merely an inert one.
        final stopCompleter = Completer<void>();
        Future<void>? recoveryInitialize;
        try {
          await service.initialize();
          await service.startLoopRecording();

          // The segment timer's own rotation tick will call stopVideoRecording()
          // — make that hang past the timeout, exactly _doRotateSegment's real
          // native-stop-timeout path (unlike stopLoopRecording(), this does NOT
          // touch isRecording).
          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await Future<void>.delayed(const Duration(milliseconds: 150));

          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.isRecording, isTrue, reason: 'intent must survive a rotation-triggered camera-loss timeout, see _isRecording\'s own doc');
          expect(service.hasPendingNativeStop, isTrue, reason: 'the rotation\'s own stop is still unresolved');

          // Recovery's own exact sequence: initialize() then startLoopRecording()
          // — kicked off but NOT awaited yet, per Fase 16.2-R4.2A: it must not
          // be able to open a new camera generation while the old stop above is
          // still pending.
          final oldController = service.previewController;
          final callsBeforeRecovery = fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length;
          var recoveryInitializeDone = false;
          recoveryInitialize = service.initialize().whenComplete(() => recoveryInitializeDone = true);

          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(recoveryInitializeDone, isFalse, reason: 'recovery must not cross the rotation\'s own still-pending native stop');
          expect(service.previewController, same(oldController));
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings').length,
            callsBeforeRecovery,
            reason: 'no new camera generation may have been opened yet',
          );

          // NOW the rotation's own stop genuinely resolves — only then may
          // recovery proceed.
          stopCompleter.complete();
          await recoveryInitialize;
          expect(service.cameraKnownUnavailable, isFalse);

          final callsBefore = fakePlatform.calls.length;
          await service.startLoopRecording();
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(
            fakePlatform.calls.skip(callsBefore),
            contains('startVideoCapturing'),
            reason: 'a native startVideoCapturing() call must actually be issued on the fresh controller',
          );
          expect(service.previewController!.value.isRecordingVideo, isTrue);
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          if (recoveryInitialize != null) await recoveryInitialize.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§18-C: the platform rejecting startVideoCapturing() (simulating "a recording is already '
      'active elsewhere") is a normal startLoopRecording() failure, not a crash, and does not leave '
      'isRecording stuck true',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        await service.initialize();

        fakePlatform.failStartVideoCapturingWith = CameraException('video_recording_failed', 'A recording is already in progress.');

        await expectLater(service.startLoopRecording(), throwsA(isA<CameraException>()));
        expect(service.isRecording, isFalse, reason: 'a failed native start must not leave isRecording stuck true');
      },
    );

    test(
      '§18-D: a native startVideoRecording() that completes AFTER an explicit stop already flipped '
      'intent does not resurrect isRecording — and (Fase 16.2-R4.2B-R1, corrected: see below) the '
      'late-succeeding, now-orphaned recording IS still collected by stopLoopRecording()\'s own '
      'already-queued obligation once it finally gets its turn, no longer silently left recording '
      'forever the way the pre-R4.2B-R1 detach-and-forget behavior did (P1-4)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        await service.initialize();

        final startCompleter = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = startCompleter;
        final startFuture = service.startLoopRecording(); // stuck mid-flight
        await Future<void>.delayed(Duration.zero); // let it actually reach the stuck native call

        await service.stopLoopRecording(); // flips _isRecording=false while start is still stuck

        startCompleter.complete(); // the native start finally "succeeds"
        await startFuture;

        expect(service.isRecording, isFalse, reason: 'stop won — this must not resurrect isRecording');

        // Fase 16.2-R4.2B-R1: the native start is now RETAINED (this
        // class's own doc, §3/§4) rather than detached-and-forgotten —
        // _queueTail stayed occupied by it the whole time, so
        // stopLoopRecording()'s own already-queued obligation could not
        // even check isRecordingVideo until this genuinely, late,
        // resolved. Once it does, that obligation correctly finds
        // isRecordingVideo == true and collects it — an earlier version
        // of this test asserted the opposite (silence, via the old
        // detach-and-forget path), which meant a REAL, physical recording
        // was left running with nothing ever left to stop it — a more
        // serious bug than the "orphaned Timer" framing this test's own
        // original name suggested.
        await waitForCallCount('stopVideoRecording', 1);
        await waitForPendingStopToClear();
        expect(service.clips, hasLength(1), reason: 'the late-succeeding, orphaned recording must be collected, not silently left running');

        // Still no orphaned Timer either way — no segment rotation was
        // ever created for the superseded start (see
        // _doStartLoopRecording's own doc).
        final callsBefore = fakePlatform.calls.length;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(fakePlatform.calls.skip(callsBefore), isEmpty);
      },
    );

    test(
      '§18-E: a native startVideoRecording() that completes AFTER dispose() already tore the '
      'controller down does not resurrect it or leave an orphaned timer (P1-4)',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 20),
          stopVideoRecordingTimeout: const Duration(seconds: 2),
          startVideoRecordingTimeout: const Duration(seconds: 2),
        );
        await service.initialize();

        final startCompleter = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = startCompleter;
        final startFuture = service.startLoopRecording();
        await Future<void>.delayed(Duration.zero);

        final disposeFuture = service.dispose();
        startCompleter.complete();
        await Future.wait([startFuture, disposeFuture]);

        expect(service.isRecording, isFalse);
        expect(service.previewController, isNull);
        final callsBefore = fakePlatform.calls.length;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(fakePlatform.calls.skip(callsBefore), isEmpty, reason: 'no orphaned timer must fire after dispose()');
      },
    );

    test(
      '§18-F: dispose() called after initialize()\'s own native call has genuinely already been emitted '
      '(not merely requested) leaves no camera behind — the slow initialize()\'s own controller is '
      'safely disposed once it finally arrives, never becomes the active controller (P1-3). Fase '
      '16.2-R4.2B-R2 (§10, independent review — retimed with a clear causal diagnosis, not silently): a '
      'dispose() landing SYNCHRONOUSLY, with no `await` at all, immediately after initialize() is now '
      'correctly caught by DashcamService._doInitializeController\'s own pre-native-call revalidation '
      '(§10 of that round\'s report) and never even reaches `controller.initialize()` at all — see this '
      'file\'s own new "P2 — pre-admission dispose" test for that scenario, and DashcamService\'s own '
      'doc for why `CameraController.dispose()` on a controller whose own `initialize()` was never '
      'called is a pure local no-op (verified against `camera-0.12.0+2` source: it never touches the '
      'platform without a prior `_initializeFuture`). This test now waits for the native '
      '`initializeCamera` call to genuinely start FIRST, so it continues to exercise the true '
      'POST-emission race it was originally written for, where retention (not pre-admission '
      'abandonment) is the applicable rule.',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));

        final initCompleter = Completer<void>();
        fakePlatform.pendingInitializeCamera = initCompleter;
        final initializeFuture = service.initialize();
        await waitForCallCount('initializeCamera', 1); // genuinely mid-flight now, past the pre-native-call revalidation checkpoint

        final disposeFuture = service.dispose();

        initCompleter.complete(); // the slow initialize() finally finishes natively
        await Future.wait([initializeFuture, disposeFuture]);

        expect(service.previewController, isNull, reason: 'dispose() must win — no camera left active');
        expect(fakePlatform.disposedCameraIds, isNotEmpty, reason: 'the controller the doomed initialize() opened must still be disposed, not leaked');
      },
    );

    test(
      '§18-L: a segment rotation\'s own restart (startVideoRecording after finalize) timing out in '
      'a completely normal, foreground scenario is handled the same safe way as any other native '
      'timeout — camera marked unavailable, no crash, no further rotation attempts',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 20),
          startVideoRecordingTimeout: const Duration(milliseconds: 30),
        );
        // Fase 16.2-R4.2A-R9 (§9/§20 — independent review, confirmed bug):
        // named `restartCompleter` (was an anonymous, unreferenced
        // `Completer<void>()`) so the finally block below can still
        // complete it — this test's own comment already says its 20ms
        // rotation Timer.periodic "keeps ticking on schedule regardless"
        // even once every tick becomes a no-op; §20 of this round's own
        // review explicitly says a live periodic timer plus a still-stuck
        // native op must NOT be treated as inert.
        final restartCompleter = Completer<void>();
        try {
          await service.initialize();
          // The very first start (startLoopRecording's own) must succeed
          // normally so the timer actually gets created — only rotations'
          // own restarts, from here on, should hang.
          await service.startLoopRecording();
          fakePlatform.pendingStartVideoCapturing = restartCompleter; // never completes on this path

          // Let a rotation's restart hang and time out. Harness T3: waited for
          // by the state asserted below instead of a fixed 100 ms real wait.
          // Measured in T3: the flag flips 61-69 ms into that wait, so the fixed
          // wait had only 33-41 ms of slack, and it failed when the rotation
          // finalize's real clip I/O (File.copy) spiked: 55 and 103 ms in the
          // two instrumented failures, against a 9 ms median. CPU load alone
          // did not trigger it. The clip is recorded before the restart
          // begins, and the timed-out restart is retained on the service's
          // serial queue, so later ticks only enqueue behind it until the
          // finally below: a longer wait observed nothing more. Bounded; fails
          // explicitly.
          for (var iter = 0; !service.cameraKnownUnavailable; iter++) {
            if (iter == 200) fail('§18-L: cameraKnownUnavailable still false after 200 x 10 ms: the rotation restart never timed out');
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(service.cameraKnownUnavailable, isTrue);
          expect(
            service.clips,
            hasLength(1),
            reason: 'exactly one rotation\'s finalize happened before its own restart hung; the timer keeps '
                'ticking on schedule regardless, but every later tick now no-ops on cameraKnownUnavailable',
          );
        } finally {
          if (!restartCompleter.isCompleted) restartCompleter.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§18-O: a protect-current-clip intent for a segment that becomes known-unavailable while still '
      'recording correctly attaches to THAT segment once stopLoopRecording() collects it (Fase '
      '16.2-R4.2A-R4, _FinalizeReason.explicitStop — see this file\'s own R4.2A-R4 group for why it is '
      'no longer abandoned), and does not migrate onto a later, unrelated clip (P2)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        // Fase 16.2-R4.2A-R8 (§12/§19 — independent review, confirmed bug):
        // this test had no try/finally and no dispose() at all — segment
        // B's controller leaked into whatever test ran next even on the
        // happy path.
        try {
          await service.initialize();
          await service.startLoopRecording();
          await service.markClipAsProtected(); // intent: protect the segment currently recording

          service.notifyAppBackgrounded(); // marked unavailable, but still genuinely recording
          await service.stopLoopRecording(); // Fase 16.2-R4.2A-R4: still collects it for real now
          expect(service.clips, hasLength(1), reason: 'the segment that was actually recording must still be collected');
          expect(service.clips.single.isProtected, isTrue, reason: 'the protect intent belonged to exactly this segment');

          // A second, completely unrelated recording.
          await service.initialize();
          await service.startLoopRecording();
          await service.stopLoopRecording();

          expect(service.clips, hasLength(2));
          expect(
            service.clips.last.isProtected,
            isFalse,
            reason: 'the earlier protect intent must not leak onto this later, unrelated clip',
          );
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.2A — native-stop exclusivity / pending-stop protocol', () {
    test(
      'TESTE A — stop normal: resolves within the deadline, produces exactly one clip, camera stays '
      'available, no pending stop left behind',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        await service.initialize();
        await service.startLoopRecording();

        await service.stopLoopRecording();

        expect(service.clips, hasLength(1));
        expect(service.cameraKnownUnavailable, isFalse);
        expect(service.hasPendingNativeStop, isFalse);
        expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
      },
    );

    test(
      'TESTE B — a stop exceeding the UI deadline returns control to the caller with the camera '
      'already marked unavailable and the raw native call still running, and a startLoopRecording() '
      'issued while it is still pending does not issue a new native start until it resolves',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;

        // Fase 16.2-R4.2A-R3 (review §19): declared outside the try so the
        // finally block below can observe it even if an earlier expect()
        // threw before this test's own `await startFuture;` was reached.
        Future<void>? startFuture;
        try {
          await service.stopLoopRecording();
          expect(service.cameraKnownUnavailable, isTrue, reason: 'must already be true by the time the caller regains control');
          expect(service.hasPendingNativeStop, isTrue);

          var startDone = false;
          startFuture = service.startLoopRecording().whenComplete(() => startDone = true);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(startDone, isFalse, reason: 'startLoopRecording() must not cross a still-pending native stop');
          expect(
            fakePlatform.calls.where((c) => c == 'startVideoCapturing'),
            hasLength(1),
            reason: 'no new native start issued yet — only the original one',
          );

          stopCompleter.complete();
          await startFuture;
          expect(startDone, isTrue);
        } finally {
          // Fase 16.2-R4.2A-R2 (review §18/§22): if an expect above failed
          // before stopCompleter.complete() was reached, resolve it here so
          // dispose() below is not itself waiting on an operation this test
          // never let conclude — startFuture also leaves a live
          // Timer.periodic (segmentDuration: 10 minutes) and
          // CameraController either way, which dispose() releases rather
          // than leaking into later tests.
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          // Fase 16.2-R4.2A-R3 (review §19): explicitly observe startFuture
          // here too, in case the try body threw before its own `await
          // startFuture;` was reached — nothing derived from it may be left
          // orphaned/unawaited. The ORIGINAL failure (if any) is what
          // should surface from this test, not a secondary one from this
          // safety net, hence swallowed here.
          if (startFuture != null) {
            try {
              await startFuture;
            } catch (_) {}
          }
          // Fase 16.2-R4.2A-R6 (§25, independent review — confirmed still
          // broken): if the FIRST expect() above (right after
          // stopLoopRecording() itself, before startFuture is ever
          // assigned) is what failed, stopCompleter.complete() just above
          // fires SYNCHRONOUSLY, with no await in between, right before
          // this dispose() call — meaning the pending stop's own
          // [_PendingNativeStop.state] is still exactly
          // [_NativeStopState.uiDeadlineExceededPending] at the instant
          // dispose() reads it (nothing has had a chance to actually
          // process the just-unblocked native result yet). [_awaitTeardown]
          // then correctly returns immediately per its own documented
          // contract — but that means THIS dispose() call, awaited right
          // here, can return VISIBLY while the real native
          // processing/teardown chain is still genuinely running in the
          // background, past this test's own end — exactly the
          // cross-test-contamination mechanism this file's own
          // R4.2A-R5/R6 tests found and fixed elsewhere (a live chain
          // later firing into whatever fakePlatform a SUBSEQUENT test's
          // setUp() has since installed). Waiting for concrete evidence —
          // a real dispose call actually landing in fakePlatform.calls —
          // proves the WHOLE chain settled, not merely that this method
          // returned.
          await service.dispose();
          await waitForCallCount('dispose', 1);
        }
      },
    );

    test(
      'TESTE C — a late-resolving stop\'s XFile is processed exactly once, and only once that '
      'processing is fully done does a subsequent initialize() proceed to open a new camera generation',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording();
        expect(service.clips, isEmpty);

        var initializeDone = false;
        final initializeFuture = service.initialize().whenComplete(() => initializeDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(initializeDone, isFalse);

        stopCompleter.complete();
        await initializeFuture;

        expect(initializeDone, isTrue);
        expect(service.clips, hasLength(1), reason: 'the late XFile must have been processed before recovery proceeded');
        expect(service.hasPendingNativeStop, isFalse);
        expect(
          fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
          hasLength(1),
          reason: 'exactly one native stop call, processed exactly once',
        );
      },
    );

    test(
      'TESTE D — a stop that never resolves keeps a later initialize() blocked indefinitely (no '
      'timed/quarantine release), never issues a second native stop, and never blocked the caller that '
      'originally requested the stop',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§19/§41 audit): named (was an anonymous,
        // unreferenced `Completer<void>()`) — this test's own point is that
        // NOTHING but the real native result can ever unblock the
        // initialize() call below (no quarantine/timer release exists), so
        // deliberately draining it here in finally, rather than leaving it
        // permanently suspended for the rest of the process.
        final stopCompleter = Completer<void>();
        Future<void>? initializeFuture;
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter;

          final callerStopwatch = Stopwatch()..start();
          await service.stopLoopRecording();
          callerStopwatch.stop();
          expect(callerStopwatch.elapsedMilliseconds, lessThan(500), reason: 'the original caller must not be blocked waiting for CameraX');

          var initializeDone = false;
          initializeFuture = service.initialize().whenComplete(() => initializeDone = true);

          // 1s — a full order of magnitude past this test's own 50ms
          // stopVideoRecordingTimeout — with initializeDone still false below.
          // This does not (and does not need to) exceed any specific historical
          // duration; it only needs to be long enough that a timed release, if
          // one existed, would already have fired by now. No such release
          // exists at all in this architecture (Fase 16.2-R4.2A removed the
          // R1-era "nativeQuarantine" mechanism entirely, not merely shortened
          // it) — only the real native result can unblock this.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(initializeDone, isFalse, reason: 'no quarantine/timer may release the barrier — only the real result can');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'no second native stop may ever be issued');
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          if (initializeFuture != null) await initializeFuture.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'TESTE E — releaseIdleCamera() while a native stop is pending does not dispose the controller '
      'concurrently with it, and itself returns without blocking indefinitely — the real dispose runs '
      'only once the pending stop resolves',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording();
        expect(service.hasPendingNativeStop, isTrue);

        final disposedBefore = fakePlatform.calls.where((c) => c == 'dispose').length;
        final releaseStopwatch = Stopwatch()..start();
        await service.releaseIdleCamera();
        releaseStopwatch.stop();

        expect(releaseStopwatch.elapsedMilliseconds, lessThan(500), reason: 'releaseIdleCamera() itself must not block indefinitely');
        expect(
          fakePlatform.calls.where((c) => c == 'dispose').length,
          disposedBefore,
          reason: 'the controller must not be disposed concurrently with the still-pending stop',
        );

        stopCompleter.complete();
        // Fase 16.2-R4.2A-R3 (review §16/§17/§18): waiting for
        // hasPendingNativeStop to clear only proves the finalize operation
        // itself concluded, not that this test's own SEPARATE, later
        // _doReleaseController (already enqueued behind it) has ALSO
        // finished disposing the controller — wait for that concrete
        // evidence directly instead.
        await waitForCallCount('dispose', disposedBefore + 1);
      },
    );

    test(
      'TESTE F — dispose() while a native stop is pending does not crash and does not block '
      'indefinitely; it is terminal immediately; the late result is still handled cleanly',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording();
        expect(service.hasPendingNativeStop, isTrue);

        final errors = <String>[];
        final sub = service.errors.listen(errors.add);

        final disposeStopwatch = Stopwatch()..start();
        await service.dispose();
        disposeStopwatch.stop();
        expect(disposeStopwatch.elapsedMilliseconds, lessThan(500));

        // Terminal immediately, regardless of the pending stop.
        expect(() => service.initialize(), throwsA(isA<StateError>()));

        stopCompleter.complete();
        // Fase 16.2-R4.2A-R3 (review §16/§17/§18): waitForPendingStopToClear
        // proves the finalize operation concluded, not that the SEPARATE,
        // later dispose()-triggered teardown has also run — wait for the
        // real evidence (a dispose call) directly.
        await waitForCallCount('dispose', 1);

        expect(errors, isEmpty, reason: 'the late XFile resolved successfully — no error should have been reported');

        await sub.cancel();
      },
    );

    test(
      'TESTE G — a protect-clip intent captured for segment A survives A resolving late, and does not '
      'leak onto segment B started only after A was already resolved',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          // Fase 16.2-R4.2A-R4: widened from 50ms — a test-fragility fix
          // (see the R4.2A-R2 §16 test's own doc for the full reasoning):
          // B's own, otherwise-ordinary stop below shares this budget, and
          // real (if fake) file I/O occasionally exceeded 50ms under system
          // load running this whole suite, unrelated to what this test
          // itself checks (protect-intent scoping, not timeout precision).
          stopVideoRecordingTimeout: const Duration(milliseconds: 200),
        );
        await service.initialize();
        await service.startLoopRecording();
        await service.markClipAsProtected(); // intent belongs to segment A

        // Fase 16.2-R4.2A-R8 (§13/§19 — independent review, confirmed bug):
        // this test had no try/finally and no dispose() at all — segment
        // B's controller (or A's, if a failure occurred before B ever
        // started) leaked into whatever test ran next even on the happy
        // path. `stopCompleter` declared here, before the try, so the
        // finally block can still complete it if an assert throws first.
        final stopCompleter = Completer<void>();
        try {
          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await service.stopLoopRecording(); // A's stop times out, still pending

          stopCompleter.complete();
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1));
          expect(service.clips.single.isProtected, isTrue, reason: 'A\'s own protect intent must survive its late resolution');

          // Segment B: a completely fresh, unrelated recording — must not
          // inherit A's protection (nobody calls markClipAsProtected() again).
          await service.initialize();
          await service.startLoopRecording();
          await service.stopLoopRecording();

          expect(service.clips, hasLength(2));
          expect(service.clips.last.isProtected, isFalse, reason: 'B must not inherit A\'s protect intent');
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    // TESTE H (timeout não descarta arquivo) and §27's own "bug real do
    // timeout" reproduction are both already exactly what the rewritten
    // §18-A test above proves — see its own doc — deliberately not
    // duplicated here.

    test(
      'TESTE I — a stop that times out, is redundantly "stopped" again while still pending (a no-op, '
      'like the existing double-stop test), and later resolves, then dispose() — issues exactly one '
      'native stop call and exactly one clip throughout (no double-stop)',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording();

        // A second stop attempt while the first is still pending — _isRecording
        // is already false, so this must be an immediate no-op (existing
        // double-stop guard, unaffected by R4.2A).
        await service.stopLoopRecording();

        stopCompleter.complete();
        await waitForPendingStopToClear();

        expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
        expect(service.clips, hasLength(1));

        await service.dispose();
        expect(
          fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
          hasLength(1),
          reason: 'dispose() must not issue a second stop once the first already resolved',
        );
      },
    );

    test(
      'TESTE J — a brand new session\'s initialize()+startLoopRecording() sequence, attempted while a '
      'previous session\'s own stop is still pending, does not cross it: no new camera is opened and no '
      'new native start is issued until the old stop resolves',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording(); // "session A" ends, stop still pending

        // Fase 16.2-R4.2A-R3 (review §19): declared outside the try so the
        // finally block below can observe it even if an earlier expect()
        // threw before this test's own `await sessionB;` was reached.
        Future<void>? sessionB;
        try {
          // "session B" starts immediately, unaware A is still finalizing.
          var sessionBReady = false;
          // Fase 16.2-R4.2A-R5 (§27, independent review): sessionB is
          // reassigned to its OWN .whenComplete()-wrapped Future, not left
          // as the original with a SEPARATE, unawaited derived Future
          // tracking readiness — a prior version did the latter
          // (`unawaited(sessionB.whenComplete(...))`), which meant a
          // failure in sessionB was observed twice: once through the
          // explicit `await sessionB` below, and once (unobserved, since
          // that derived Future itself was never awaited/caught) through
          // the orphaned wrapper. Reassigning here keeps exactly one Future
          // object, awaited exactly once, in every path (success path
          // below and the `finally` block's own safety net).
          sessionB = (() async {
            await service.initialize();
            await service.startLoopRecording();
          })().whenComplete(() => sessionBReady = true);

          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(sessionBReady, isFalse, reason: 'session B must not open a new camera generation while A is still pending');
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));

          stopCompleter.complete();
          await sessionB;

          expect(sessionBReady, isTrue);
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(2));
          expect(service.isRecording, isTrue);
        } finally {
          // Fase 16.2-R4.2A-R2 (review §18/§22): if an expect above failed
          // before stopCompleter.complete() was reached, resolve it here so
          // dispose() below is not itself waiting on an operation this test
          // never let conclude — session B also leaves a live
          // Timer.periodic (segmentDuration: 10 minutes) and
          // CameraController either way, which dispose() releases rather
          // than leaking into later tests.
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          // Fase 16.2-R4.2A-R3 (review §19): explicitly observe sessionB
          // here too, BEFORE calling dispose() below — and deliberately in
          // that order: session B's own startLoopRecording() call re-checks
          // `_disposed` at ITS OWN call time (unlike the initialize() call
          // ahead of it, already past that check before this test's
          // failure), so awaiting it here first, before dispose() sets
          // `_disposed=true`, lets it settle on its own normal outcome
          // instead of racing dispose() into an unexpected StateError. The
          // ORIGINAL test failure (if any) is what should surface, not a
          // secondary one from this safety net, hence swallowed here.
          if (sessionB != null) {
            try {
              await sessionB;
            } catch (_) {}
          }
          // Fase 16.2-R4.2A-R8 (§10/§16 — independent review): `dispose()`
          // itself is a bounded, presentation-only wait (same contract as
          // `stopLoopRecording()`) — it can return to this caller before
          // session B's OWN pending native stop/finalize (this test's
          // `stopVideoRecordingTimeout: 50ms`) has actually concluded and
          // the controller it holds is really released. Waiting for
          // concrete evidence of that release, not merely this call
          // returning, is what actually proves the second controller does
          // not leak into a later test.
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§30 — a stop that times out and later resolves with an ERROR (not an XFile) reports it via '
      'errors, does not persist a nonexistent clip, does not throw unhandled, and still releases the '
      'barrier so recovery can proceed',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording();
        expect(service.hasPendingNativeStop, isTrue);

        final errors = <String>[];
        final sub = service.errors.listen(errors.add);

        // The native call finally resolves — with a failure, not a file.
        stopCompleter.completeError(CameraException('native_error', 'simulated late native failure'));
        await waitForPendingStopToClear();

        expect(service.clips, isEmpty, reason: 'no nonexistent clip may be persisted for a failed stop');
        expect(errors, hasLength(1));
        expect(service.hasPendingNativeStop, isFalse, reason: 'the barrier must still release even on a late failure');

        await service.initialize();
        expect(service.cameraKnownUnavailable, isFalse);

        await sub.cancel();
      },
    );
  });

  group('Fase 16.2-R4.2A-R1 — local fixes post-review (P1-A, P2-B, P2-C, P2/P3-D, P3-E)', () {
    test(
      '§18 (P1-A reproduction, MANDATORY) — a stop already pending because a segment ROTATION issued '
      'it does not get a second, independent stop enqueued behind it when stopLoopRecording() is then '
      'called: the caller returns by the ALREADY-pending stop\'s own deadline (not after waiting behind '
      'it AND a fresh one), cameraKnownUnavailable is already true by then, exactly one native stop call '
      'is ever issued, the original stop is still pending afterward, and the queue is still blocked',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§10/§20 — independent review, confirmed bug):
        // named (was an anonymous, unreferenced `Completer<void>()`) so the
        // finally block can complete it. This test's own design
        // deliberately never completes it inside the try body —
        // `hasPendingNativeStop` must still read `true` at the end, by
        // design — but that leaves both the underlying native stop AND
        // (if an early expect throws before stopLoopRecording() is even
        // reached) the 30ms rotation timer genuinely active; §20 of this
        // round's own review says that combination must not be treated as
        // inert.
        final stopCompleter = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();

          // The segment timer's own rotation tick will issue the native stop
          // — make it hang via this gate, left deliberately incomplete for
          // the remainder of the try body.
          fakePlatform.pendingStopVideoRecording = stopCompleter;
          // Long enough for the 30ms rotation tick to fire and actually reach
          // controller.stopVideoRecording(), but comfortably before that
          // stop's own 50ms-from-issue deadline elapses.
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
          expect(service.hasPendingNativeStop, isTrue, reason: 'the rotation\'s own stop must already be tracked as pending');

          final callerStopwatch = Stopwatch()..start();
          await service.stopLoopRecording();
          callerStopwatch.stop();

          expect(
            callerStopwatch.elapsedMilliseconds,
            lessThan(400),
            reason:
                'must return by the ALREADY-pending stop\'s own remaining deadline — the R1-era bug '
                'enqueued a brand new _doFinalizeCurrentSegment behind the rotation\'s, whose own fresh '
                'uiSignal could then only complete once its turn in _queueTail arrived, which cannot '
                'happen before the existing pending stop\'s own queued operation first returns: an '
                'unbounded wait, since this test\'s stop never resolves',
          );
          expect(service.cameraKnownUnavailable, isTrue);
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'no second native stop call was ever issued',
          );
          expect(service.hasPendingNativeStop, isTrue, reason: 'the original rotation-triggered stop is still pending — the queue is still blocked');
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§19 — releaseIdleCamera() called while a ROTATION-triggered stop is still pending waits for '
      'THAT SAME operation\'s own remaining deadline (not a fresh, independent one on top of it), and '
      'only disposes the controller once the stop genuinely resolves',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§10 — independent review, confirmed bug):
        // `stopCompleter` moved to before the try so the finally block can
        // still complete it — an assert between here and `stopCompleter
        // .complete()` below used to leave the still-queued
        // `_doReleaseController` (behind this rotation-triggered stop)
        // permanently suspended, a genuinely active operation per §3 of
        // this round's own review, independent of the 30ms rotation timer
        // (already cancelled synchronously the moment releaseIdleCamera()
        // below is called, regardless of how its own await resolves).
        final stopCompleter = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
          expect(service.hasPendingNativeStop, isTrue);

          final disposedBefore = fakePlatform.calls.where((c) => c == 'dispose').length;
          final releaseStopwatch = Stopwatch()..start();
          await service.releaseIdleCamera();
          releaseStopwatch.stop();

          expect(
            releaseStopwatch.elapsedMilliseconds,
            lessThan(400),
            reason: 'must not wait a FRESH full stopVideoRecordingTimeout on top of the one already partly elapsed',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'dispose').length,
            disposedBefore,
            reason: 'no dispose concurrent with the still-pending stop',
          );

          stopCompleter.complete();
          // Fase 16.2-R4.2A-R3 (review §16/§17/§18): wait for the real
          // teardown evidence, not merely for the finalize operation to clear.
          await waitForCallCount('dispose', disposedBefore + 1);
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§20 — dispose() called while a ROTATION-triggered stop is still pending is terminal '
      'immediately, waits for THAT SAME operation\'s own remaining deadline, never disposes the '
      'controller concurrently with it, and the errors stream is not closed prematurely',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§10 — independent review, confirmed bug):
        // `stopCompleter` and `sub` both moved to before the try so the
        // finally block can still reach them regardless of where an assert
        // throws.
        final stopCompleter = Completer<void>();
        final errors = <String>[];
        StreamSubscription<String>? sub;
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));

          sub = service.errors.listen(errors.add);

          final disposeStopwatch = Stopwatch()..start();
          await service.dispose();
          disposeStopwatch.stop();

          expect(disposeStopwatch.elapsedMilliseconds, lessThan(400));
          expect(() => service.initialize(), throwsA(isA<StateError>()));

          stopCompleter.complete();
          // Fase 16.2-R4.2A-R3 (review §16/§17/§18): wait for the real
          // teardown evidence, not merely for the finalize operation to clear.
          await waitForCallCount('dispose', 1);

          expect(errors, isEmpty, reason: 'the late XFile resolved successfully — the stream must not have closed before it could report, nor did it need to');
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          await sub?.cancel();
        }
      },
    );

    test(
      '§17 (TESTE K, distinct from the existing "protects the segment currently being recorded" test '
      'and from TESTE G) — markClipAsProtected() called AFTER a stop has already started (during the '
      'gap before it resolves, with no segment currently capturing frames) does not retroactively '
      'protect that pending segment, and does not leak onto the next segment (B) either',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          // Fase 16.2-R4.2A-R7 (§16 audit — confirmed a real, intermittent
          // test-fragility, not a product defect: this file's own
          // R4.2A-R2 §16/TESTE G docs already establish the same class of
          // issue — a 50ms budget occasionally racing real, if fake, file
          // I/O in _moveToClipsDirectory under system load, which since
          // `stopLoopRecording()` never blocks past its own bounded
          // deadline (Fase 16.2-R4.2A-R5's own contract) can make
          // `await service.stopLoopRecording()` for segment B return
          // before B's own clip has actually been added — this test's own
          // 50ms had not yet been widened to match. Widened here for the
          // same reason: this test's own purpose (protection-during-gap
          // semantics for A, checked via the explicitly-controlled
          // stopCompleter below) does not depend on this specific value.
          stopVideoRecordingTimeout: const Duration(milliseconds: 200),
        );
        final stopCompleter = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();
          // No markClipAsProtected() call yet — segment A starts unprotected.

          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await service.stopLoopRecording(); // A's stop begins, still pending
          expect(service.hasPendingNativeStop, isTrue);

          // The mark arrives DURING the gap — the stop already started, and
          // no segment is currently capturing frames for it to belong to.
          await service.markClipAsProtected();

          stopCompleter.complete();
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1));
          expect(
            service.clips.single.isProtected,
            isFalse,
            reason: 'A\'s own protection snapshot was captured atomically with its native call, before the mark arrived — it must not change retroactively',
          );

          // Segment B: a fresh, unrelated recording — must not inherit the
          // mark made during the gap.
          await service.initialize();
          await service.startLoopRecording();
          await service.stopLoopRecording();
          await waitForPendingStopToClear();

          expect(service.clips, hasLength(2));
          expect(service.clips.last.isProtected, isFalse, reason: 'B must not inherit the mark made during the gap either');
        } finally {
          // Fase 16.2-R4.2A-R7 (§16 audit): no try/finally existed before —
          // safe/idempotent regardless of how far the try body got.
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§14 (TESTE L) — startLoopRecording() called after dispose() is rejected immediately with a '
      'StateError (matching initialize()\'s own existing terminal behavior), without touching '
      '_isRecording, without creating a Timer, without enqueueing any work, and without touching the '
      'CameraController',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        await service.initialize();
        await service.startLoopRecording();
        await service.stopLoopRecording();

        await service.dispose();

        final callsBefore = List<String>.from(fakePlatform.calls);
        expect(() => service.startLoopRecording(), throwsA(isA<StateError>()));
        expect(service.isRecording, isFalse);
        expect(fakePlatform.calls, callsBefore, reason: 'no native call, no timer, no controller touched');
      },
    );

    test(
      'R4.2A-R2 §17 (TESTE L, redone — the R1-era version above did not actually prove terminality '
      'while a stop was still pending, since by the time dispose() returned the controller had already '
      'been fully torn down) — startLoopRecording() called while dispose() has VISIBLY returned but the '
      'native stop it is bounded by is STILL pending is rejected immediately with a StateError, without '
      'touching _isRecording, without creating a Timer, without issuing any native call, and without '
      'enqueueing additional work',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;
        await service.stopLoopRecording(); // A's stop begins, exceeds its own deadline, still pending
        expect(service.hasPendingNativeStop, isTrue);

        await service.dispose(); // returns bounded by A's own remaining deadline (already elapsed)
        expect(service.hasPendingNativeStop, isTrue, reason: 'dispose() visibly returned, but A itself has not resolved yet');
        expect(fakePlatform.calls, isNot(contains('dispose')), reason: 'the controller is still retained for teardown once A resolves');

        final callsBefore = List<String>.from(fakePlatform.calls);
        expect(() => service.startLoopRecording(), throwsA(isA<StateError>()));
        expect(service.isRecording, isFalse);
        expect(fakePlatform.calls, callsBefore, reason: 'no native call, no timer, no additional queued work');

        // Cleanup: resolve A and confirm the real teardown eventually completes.
        stopCompleter.complete();
        // Fase 16.2-R4.2A-R3 (review §16/§17/§18): wait for the real
        // teardown evidence, not merely for the finalize operation to clear.
        await waitForCallCount('dispose', 1);
      },
    );

    test(
      'R4.2A-R2 §16 — markClipAsProtected() called during the RECOVERY GAP (A has fully resolved, '
      'pendingNativeStop is null, camera is still known-unavailable, B has not started/recovered yet) '
      'does not protect B — closes a second gap beyond R1\'s own fix, which only covered marks made '
      'while A was still pending (see TESTE K)',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          // Fase 16.2-R4.2A-R4: widened from the 50ms most other tests in
          // this file use, to a real test-fragility fix, not a product
          // change — A's own timeout below is driven deterministically by
          // its own never-resolved Completer regardless of this value, but
          // B's LATER, otherwise-normal stop still shares this same budget,
          // and real (if fake) file I/O — File.copy() in
          // _moveToClipsDirectory — was observed, under real system load
          // running this whole suite back-to-back, to occasionally exceed
          // 50ms on its own, spuriously tripping B's own timeout branch and
          // leaving it `uiDeadlineExceededPending` at the exact moment this
          // test's own assertions run. Not a race this test is meant to
          // exercise at all.
          stopVideoRecordingTimeout: const Duration(milliseconds: 200),
        );
        await service.initialize();
        await service.startLoopRecording();
        // No markClipAsProtected() call — segment A starts unprotected.

        // Fase 16.2-R4.2A-R8 (§9/§14/§25 — independent review, confirmed
        // bug): declared before the try below so the finally block can
        // still complete it if the FIRST expect() after
        // `stopLoopRecording()` (or any other before `stopCompleter
        // .complete()` was reached) throws — otherwise A's own native stop
        // never resolves, and the controller it holds leaks, uncleaned,
        // into whatever test runs next.
        final stopCompleter = Completer<void>();
        try {
          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await service.stopLoopRecording(); // times out, still pending
          expect(service.cameraKnownUnavailable, isTrue);

          // A fully resolves now.
          stopCompleter.complete();
          await waitForPendingStopToClear();
          expect(service.hasPendingNativeStop, isFalse, reason: 'A has fully resolved');
          expect(service.clips, hasLength(1));
          expect(service.cameraKnownUnavailable, isTrue, reason: 'still unavailable — B has not started/recovered yet');

          // The recovery gap: the mark arrives here, with no current segment
          // at all — neither pending nor actively recording.
          await service.markClipAsProtected();

          // Recovery: segment B starts, completely fresh and unrelated.
          await service.initialize();
          await service.startLoopRecording();
          await service.stopLoopRecording();

          expect(service.clips, hasLength(2));
          expect(service.clips.last.isProtected, isFalse, reason: 'B must not inherit the mark made during the recovery gap');
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'R4.2A-R2 §24 — releaseIdleCamera() that itself triggers a NEW native stop (none was already '
      'pending) returns by THAT stop\'s own deadline, cameraKnownUnavailable already true, the stop '
      'still pending, no dispose yet, and exactly one native stop call',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§19 audit): the anonymous, never-referenced
        // `Completer<void>()` this test used to install is, by §19's own
        // criteria, already demonstrably inert once created (this test's
        // 10-minute segment timer is cancelled synchronously the moment
        // releaseIdleCamera() below is called; nothing external could ever
        // complete it; nothing runs after it in the fake either way) — named
        // and drained below anyway, as a consistent, low-risk hygiene
        // improvement matching this file's other cleanup, not because
        // leaving it alone would have blocked this round's closure.
        final stopCompleter = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter;

          final disposedBefore = fakePlatform.calls.where((c) => c == 'dispose').length;
          final releaseStopwatch = Stopwatch()..start();
          await service.releaseIdleCamera();
          releaseStopwatch.stop();

          expect(
            releaseStopwatch.elapsedMilliseconds,
            lessThan(400),
            reason: 'must return by the deadline of the stop it itself triggered, not block indefinitely',
          );
          expect(service.cameraKnownUnavailable, isTrue);
          expect(service.hasPendingNativeStop, isTrue);
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
          expect(
            fakePlatform.calls.where((c) => c == 'dispose').length,
            disposedBefore,
            reason: 'no dispose yet — the stop it triggered is still pending',
          );
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'R4.2A-R2 §25 — dispose() that itself triggers a NEW native stop (none was already pending) is '
      'terminal immediately, returns by THAT stop\'s own deadline, unavailability already published '
      'before returning, no concurrent teardown, and once the stop resolves the real teardown '
      '(processing + controller dispose + errors cleanup) completes',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;

        final disposeStopwatch = Stopwatch()..start();
        await service.dispose();
        disposeStopwatch.stop();

        expect(disposeStopwatch.elapsedMilliseconds, lessThan(400));
        expect(() => service.initialize(), throwsA(isA<StateError>()));
        expect(service.cameraKnownUnavailable, isTrue, reason: 'unavailability must already be published before the caller regains control');
        expect(service.hasPendingNativeStop, isTrue);
        expect(fakePlatform.calls, isNot(contains('dispose')), reason: 'no dispose yet — concurrent with the stop it triggered');

        stopCompleter.complete();
        // hasPendingNativeStop clearing proves the finalize (XFile
        // processing) concluded — the SEPARATE, later controller.dispose()
        // teardown step needs its own, concrete evidence (Fase
        // 16.2-R4.2A-R3, review §16/§17/§18).
        await waitForPendingStopToClear();
        expect(service.clips, hasLength(1), reason: 'the real teardown processed the late XFile');

        await waitForCallCount('dispose', 1);
      },
    );

    test(
      'R4.2A-R2 §20/§21/§23 (rotation fast-failure) — a rotation-triggered native stop that fails FAST '
      '(not a timeout) is reported via errors exactly once, never escapes as an unhandled async error, '
      'and does not attempt a second stop or a same-generation restart afterward',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        // Fase 16.2-R4.2A-R9 (§11/§41 audit): `sub` moved to before the try
        // so the finally block can still cancel it, and the final dispose()
        // (which also cancels this test's own live 20ms rotation timer)
        // now always runs, even if one of the three expects below throws.
        StreamSubscription<String>? sub;
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.failStopVideoRecordingWith = CameraException('native_stop_failed', 'simulated fast rotation stop failure');

          final errors = <String>[];
          sub = service.errors.listen(errors.add);

          // Let the 20ms rotation tick fire and its own stop fail fast.
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(errors, hasLength(1), reason: 'the rotation-triggered failure must be reported exactly once');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'no second stop attempted');
          expect(service.cameraKnownUnavailable, isTrue);
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          await sub?.cancel();
        }
      },
    );

    test(
      'R4.2A-R2 §26/§27 — once a pending stop\'s own deadline has ALREADY elapsed, a LATER caller '
      '(releaseIdleCamera here) does not receive a fresh full stopVideoRecordingTimeout of its own — it '
      'returns almost immediately, proving the wait derives from the remaining time on the real, '
      'already-computed deadlineInstant, not a newly-started timer',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R9 (§7/§41 audit): named (was an anonymous,
        // unreferenced `Completer<void>()`) — this test's own design
        // deliberately never completes it in the try body
        // (hasPendingNativeStop must still read `true` at the end), but
        // the still-queued `_doReleaseController` behind it is a genuinely
        // active, suspended operation per §3 of this round's own review.
        final stopCompleter = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await service.stopLoopRecording(); // creates the pending stop; returns once ITS OWN 50ms deadline elapses
          expect(service.hasPendingNativeStop, isTrue);

          // Real time comfortably PAST the stop's own deadline before a later
          // caller arrives — if that caller started a fresh
          // stopVideoRecordingTimeout of its own, it would take ~50ms more;
          // deriving from the SAME already-elapsed deadlineInstant instead
          // means it returns almost immediately.
          await Future<void>.delayed(const Duration(milliseconds: 100));

          final releaseStopwatch = Stopwatch()..start();
          await service.releaseIdleCamera();
          releaseStopwatch.stop();

          expect(
            releaseStopwatch.elapsedMilliseconds,
            lessThan(30),
            reason: 'the pending stop\'s deadline already elapsed — no new stopVideoRecordingTimeout may be granted',
          );
          expect(service.hasPendingNativeStop, isTrue);
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          await waitForPendingStopToClear();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.2A-R3 — handshake discovery, full teardown observation, deterministic test sync', () {
    test(
      '§13 (MANDATORY) — a stop SCHEDULED by stopLoopRecording() but not yet PUBLISHED is discovered '
      'by releaseIdleCamera() called synchronously right after, with NO await in between (the exact '
      'race an independent review reproduced): exactly one native stop is issued, release does not '
      'start a second one, both callers observe A\'s own deadline/signal, cameraKnownUnavailable=true '
      'before either returns, the queue stays occupied, and resolving A allows processing + teardown '
      'to complete',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        await service.initialize();
        await service.startLoopRecording();

        final stopCompleter = Completer<void>();
        fakePlatform.pendingStopVideoRecording = stopCompleter;

        // The exact race, reproduced literally: no await between the two
        // calls, so stopLoopRecording()'s own finalize is enqueued but
        // _pendingNativeStop is still null when releaseIdleCamera() reads
        // it synchronously right after.
        final stopping = service.stopLoopRecording();
        final releasing = service.releaseIdleCamera();

        await stopping;
        await releasing;

        expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'exactly one native stop was issued — release did not start a second one');
        expect(service.cameraKnownUnavailable, isTrue, reason: 'must be true by the time BOTH callers regained control');
        expect(service.hasPendingNativeStop, isTrue, reason: 'A is still pending — the queue is still occupied');
        expect(fakePlatform.calls, isNot(contains('dispose')), reason: 'no dispose concurrent with A');

        stopCompleter.complete();
        await waitForPendingStopToClear();
        expect(service.clips, hasLength(1), reason: 'A\'s own late XFile was processed');

        await waitForCallCount('dispose', 1);
      },
    );

    test(
      '§14 — release\'s own discovery times out because PRIOR, unrelated queued work has not '
      'progressed far enough to even reveal whether a stop exists: the caller returns without '
      'blocking on that unrelated work either, cameraKnownUnavailable=true before it returns, no state '
      'claims teardown is complete, the queued work stays alive (observed), and the flow continues '
      'correctly once the queue eventually progresses. Fase 16.2-R4.2A-R4 (§23/§24 — independent review '
      'found this test used to pass even when the segment that becomes active while release waits was '
      'silently discarded, zero stopVideoRecording call, zero clip): once the stuck start genuinely '
      'completes (isRecordingVideo == true) and release\'s own queued teardown finally runs, it must '
      'still issue exactly one native stop and collect exactly one clip, strictly before disposing — '
      'cameraKnownUnavailable being true by then (from the unrelated discovery timeout above) must not '
      'suppress that',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        await service.initialize();

        // A slow/stuck native START (entirely unrelated to any STOP)
        // occupies the queue ahead of the releaseIdleCamera() call below.
        // Not awaited on purpose — deliberately left mid-flight.
        final pendingStart = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = pendingStart;
        final starting = service.startLoopRecording();
        Future<void>? releasing;
        try {
          // Let _doStartLoopRecording actually reach its own native call
          // (stuck on pendingStart) before requesting release — this test is
          // about QUEUE CONGESTION specifically, not the synchronous-
          // scheduling race §13's own dedicated test already covers (there,
          // release's prefix would otherwise win a bare back-to-back race
          // against _enqueue's own microtask scheduling and supersede the
          // start before it even reaches this point).
          await Future<void>.delayed(Duration.zero);
          expect(fakePlatform.calls, contains('startVideoCapturing'), reason: 'the stuck start must have actually been issued by now');

          // releaseIdleCamera() is requested while that unrelated work is
          // still stuck ahead of it in _queueTail — its own discovery cannot
          // possibly learn whether a stop exists within its own presentation
          // deadline, since the operation that would create (or rule out) one
          // has not even reached its turn yet.
          final releaseStopwatch = Stopwatch()..start();
          releasing = service.releaseIdleCamera();
          await releasing;
          releaseStopwatch.stop();

          expect(releaseStopwatch.elapsedMilliseconds, lessThan(400), reason: 'must not block on unrelated queued work either');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'must be marked unavailable before returning — this caller cannot know what is happening ahead of it in the queue');
          expect(fakePlatform.calls, isNot(contains('dispose')), reason: 'no teardown may be claimed complete — release\'s own queued work has not even started yet');

          // Let the stuck start finally settle — the queue now progresses,
          // and release's own queued teardown work (still alive, never
          // abandoned) gets its turn right after.
          pendingStart.complete();
          await starting;
          expect(
            service.previewController?.value.isRecordingVideo,
            isTrue,
            reason: 'the segment genuinely, natively started — this is the active recording at risk',
          );
          await waitForCallCount('dispose', 1);

          // Fase 16.2-R4.2A-R4 (§23/§24 MANDATORY strengthening): the earlier,
          // unrelated discovery timeout must not have suppressed collecting
          // this now-active segment.
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'the active segment must still be natively stopped exactly once, not silently abandoned',
          );
          expect(service.clips, hasLength(1), reason: 'the stopped segment\'s XFile must still be collected into clips, not discarded');
          final startIndex = fakePlatform.calls.indexOf('startVideoCapturing');
          final stopIndex = fakePlatform.calls.indexOf('stopVideoRecording');
          final disposeIndex = fakePlatform.calls.indexOf('dispose');
          expect(stopIndex, greaterThan(startIndex), reason: 'the stop must follow the start it is finalizing');
          expect(disposeIndex, greaterThan(stopIndex), reason: 'controller.dispose() must never precede collecting the Recording it still holds');
        } finally {
          // Fase 16.2-R4.2A-R6 (§26, independent review — confirmed this
          // test had no cleanup at all): guaranteed even if an assertion
          // above fails partway through, at any point — otherwise a still
          // -stuck `starting`/still-queued `releasing`/still-pending
          // teardown chain can settle only AFTER this test has already
          // ended, firing into whichever fakePlatform a LATER test's own
          // setUp() has since installed (the same cross-test contamination
          // mechanism this file's own R4.2A-R5 N1 test found and fixed for
          // an uncancelled Timer — here, an unresolved Completer chain
          // instead).
          if (!pendingStart.isCompleted) pendingStart.complete();
          await starting.catchError((_) {});
          if (releasing != null) await releasing.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForCallCount('dispose', 1);
        }
      },
    );

    test(
      '§12 (MANDATORY) — a LATE teardown failure (controller.dispose() itself throwing, once a '
      'pending stop it was queued behind finally resolves, well after dispose()\'s own caller already '
      'returned) is observed and reported exactly once via errors, never escapes as an unhandled async '
      'error, and does not leave the queue broken or trigger an unexpected second dispose attempt',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        // Fase 16.2-R4.2A-R10 (§22 — independent review): this test
        // deliberately leaves `controller.dispose()` failing
        // (`failDisposeWith`) and had no local cleanup at all —
        // `_doReleaseController` has no try/catch around that await, so
        // `_controller` is never nulled on that path (R3-era approved
        // behavior, same as this file's own §42-J test). Explicit local
        // cleanup added below, rather than relying solely on the shared
        // teardown's own fallback to happen to handle it correctly.
        final stopCompleter = Completer<void>();
        StreamSubscription<String>? sub;
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopCompleter;
          await service.stopLoopRecording(); // A's stop times out, still pending

          final errors = <String>[];
          sub = service.errors.listen(errors.add);

          final disposeStopwatch = Stopwatch()..start();
          await service.dispose(); // returns bounded by A's own deadline
          disposeStopwatch.stop();
          expect(disposeStopwatch.elapsedMilliseconds, lessThan(400));
          expect(fakePlatform.calls, isNot(contains('dispose')), reason: 'the real teardown has not run yet — A is still pending');

          // The controller.dispose() this pending teardown will eventually
          // attempt is set to fail, realistically (see FakeCameraPlatform
          // .failDisposeWith's own doc) — simulating the platform's own
          // unbindAll()-equivalent failing once teardown finally runs.
          fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated late teardown failure');

          // A resolves now — its own processing completes, releasing the
          // queue barrier, letting the queued teardown (dispose()'s own
          // _doReleaseController) finally run and hit the failure above.
          stopCompleter.complete();
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1), reason: 'A\'s own XFile must still be preserved regardless of the LATER, unrelated dispose failure');

          // The failure is asynchronous from here — give the queued
          // controller.dispose() attempt (and _observeTeardown's own error
          // report) a bounded chance to actually run.
          for (var i = 0; i < 50 && errors.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(errors, hasLength(1), reason: 'the late teardown failure must be reported exactly once via errors');
          expect(fakePlatform.calls.where((c) => c == 'dispose'), hasLength(1), reason: 'exactly one dispose attempt — no automatic retry');
          expect(service.hasPendingNativeStop, isFalse, reason: 'the queue barrier itself was properly released, not left stuck by the failure');
        } finally {
          if (!stopCompleter.isCompleted) stopCompleter.complete();
          // Clearing the failure and issuing a fresh dispose() is a local
          // no-op, not a retried native call — see this file's own §42-J
          // doc for why (`CameraController._isDisposed` is already `true`
          // from the first attempt) — but it is what lets
          // `_doReleaseController` finally reach its own `_controller =
          // null` line.
          fakePlatform.failDisposeWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          // Fase 16.2-R4.2B-R2 (§19/§23): the dispose failure above left
          // the process-wide coordinator `_uncertain` (fail-closed, by
          // design — see `_DashcamProcessOwner.markUncertain`'s own doc).
          // Local, explicit cleanup — not the shared tearDown's barrier,
          // which now only VERIFIES natural release (see its own doc) —
          // simulating the process having restarted, exactly like a real
          // recovery from this state would require.
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          await sub?.cancel();
        }
      },
    );
  });

  group('Fase 16.2-R4.2A-R4 — presentation unavailability vs. the obligation to collect an existing Recording', () {
    test(
      '§10/§11/§35 (MANDATORY) — a discovery timeout belonging to a completely unrelated caller must '
      'NOT suppress collecting an already-active recording once dispose() itself reaches the queue: '
      'START completed normally (isRecordingVideo == true), a discovery timeout marks '
      'cameraKnownUnavailable=true, and dispose() must still: stop exactly once, collect exactly one '
      'clip, and dispose the controller strictly AFTER that stop, in that order',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        await service.initialize();

        // Unrelated queue congestion ahead of dispose() — a slow/stuck
        // native START, never itself a stop-announcement participant (see
        // _doStartLoopRecording's own doc) — is the only deterministic way
        // this test infrastructure offers to make a LATER caller's own
        // discovery of a scheduled stop time out for real (see this file's
        // own §14 test, which this one mirrors using dispose() instead of
        // releaseIdleCamera(), per this class's own doc §15 audit of every
        // stop-capable call site).
        final pendingStart = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = pendingStart;
        final starting = service.startLoopRecording();
        Future<void>? disposing;
        try {
          await Future<void>.delayed(Duration.zero);
          expect(fakePlatform.calls, contains('startVideoCapturing'));

          final disposeStopwatch = Stopwatch()..start();
          disposing = service.dispose();
          await disposing;
          disposeStopwatch.stop();
          expect(disposeStopwatch.elapsedMilliseconds, lessThan(400), reason: 'must not block on unrelated queued work either');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'the discovery timeout is still a real, UI-visible presentation signal');
          expect(fakePlatform.calls, isNot(contains('dispose')), reason: 'the real teardown has not run yet — the stuck start is still ahead of it');

          pendingStart.complete();
          await starting;
          await waitForCallCount('dispose', 1);

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'the segment that became active while dispose() was waiting must still be natively stopped exactly once',
          );
          expect(service.clips, hasLength(1), reason: 'its XFile must still be collected, not silently discarded');
          final startIndex = fakePlatform.calls.indexOf('startVideoCapturing');
          final stopIndex = fakePlatform.calls.indexOf('stopVideoRecording');
          final disposeIndex = fakePlatform.calls.indexOf('dispose');
          expect(stopIndex, greaterThan(startIndex));
          expect(disposeIndex, greaterThan(stopIndex), reason: 'controller.dispose() must never precede collecting the Recording it still holds');
        } finally {
          // Fase 16.2-R4.2A-R5 (§28): guaranteed even if an assertion above
          // fails before pendingStart.complete() is reached — otherwise
          // `starting` (and whatever dispose()'s own queue work is stuck
          // behind it) is left live indefinitely.
          if (!pendingStart.isCompleted) pendingStart.complete();
          await starting.catchError((_) {});
          // Fase 16.2-R4.2A-R7 (§10, independent review — confirmed bug):
          // the very FIRST expect() above (right after the stuck start is
          // confirmed issued) runs BEFORE `disposing` is ever assigned — if
          // IT fails, an earlier version of this finally block's own
          // `if (disposing != null)` guard meant dispose() was never called
          // at all, leaking the controller. If nothing requested dispose()
          // yet, this does so now — otherwise this reuses the SAME Future
          // this test's own try body already started, rather than issuing
          // a second, redundant call.
          disposing ??= service.dispose();
          await disposing.catchError((_) {});
          // Fase 16.2-R4.2A-R6 (§26)/R7 (§5): `disposing` itself can (by
          // this test's own design) return VISIBLY before the real,
          // underlying teardown chain — still stuck behind `starting` at
          // that point — has settled. Concrete evidence (the controller
          // actually released) is what proves the chain finished, not
          // merely that some Future returned.
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§1-§9/§27 (doc/test-accuracy fix) — _discoveryUncertainCount (the presentation-only counter a '
      'discovery timeout now increments, instead of setting _cameraKnownUnavailable) returns to 0, and '
      'the public cameraKnownUnavailable getter correctly reads false, once the caller\'s own real, '
      'already-enqueued obligation (releaseIdleCamera()\'s own queued teardown here) actually concludes '
      '— NOT because any later initialize() call "clears" it, contrary to an earlier version of this '
      'test\'s own claim: a fresh initialize() afterward is checked only as a sanity confirmation that '
      'nothing about a new camera generation reintroduces staleness',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        await service.initialize();

        final pendingStart = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = pendingStart;
        final starting = service.startLoopRecording();
        Future<void>? releasing;
        // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): the obligation collected below
        // (the segment that starts once the gate opens) is stopped and its clip
        // promoted — real file I/O since R4.4-R1 — under the same 50 ms
        // deadline the discovery timeout needs. Under load that processing
        // outlasted it, the service marked the generation untrusted (correctly,
        // for a stop past its deadline) and the final getter read stayed true
        // for that OTHER reason (reproduced by delaying only the rename, T-Rm
        // 02_directed/screen_rename). The obligation's own deadlines are held
        // ([HeldDeadlines]) from the moment the discovery timeout has already
        // fired: it concludes normally, as this test's scenario requires.
        final obligationDeadlines = HeldDeadlines.upTo(service.stopVideoRecordingTimeout, holding: false);
        try {
          await Future<void>.delayed(Duration.zero);

          releasing = obligationDeadlines.run(() => service.releaseIdleCamera());
          await releasing;
          expect(service.cameraKnownUnavailable, isTrue, reason: 'the discovery timeout above set it');

          obligationDeadlines.holding = true;
          pendingStart.complete();
          await starting;
          await waitForCallCount('dispose', 1);
          // The obligation's own conclusion — what clears the uncertainty — is
          // awaited as the event it is (see the doc below), not inferred from a
          // polling step outlasting it.
          await waitForCondition(() => service.discoveryUncertainCountForTest == 0, 'the release obligation concluded');
          expect(obligationDeadlines.pending, 0, reason: 'test setup check: the obligation concluded before any of its deadlines had to elapse');
          // Fase 16.2-R4.2A-R7 (§27, doc/test-accuracy fix), corrected
          // Fase 16.2-R4.2A-R8 (§29, independent review — waitForCallCount
          // does not itself prove conclusion): the signal clears once
          // releaseIdleCamera()'s own queued _doReleaseController Future
          // actually completes — that completion (not the call-count log
          // above) is what _armDiscoveryUncertainty's own
          // queued.whenComplete() pairs with (see that method's own doc).
          // `waitForCallCount('dispose', 1)` only proves the native dispose
          // call was ISSUED (logged synchronously, at invocation) — the
          // queued operation's own resolution, and therefore the
          // uncertainty decrement, happens a few microtasks later; the
          // `expect()` below only observes it reliably because this
          // helper's own polling step (10ms) comfortably outlasts that gap,
          // not because reaching the call count is itself the completion
          // event. An earlier version of this test asserted the flag was
          // cleared by a LATER initialize() call instead, which was also
          // inaccurate.
          expect(service.cameraKnownUnavailable, isFalse, reason: 'cleared by the caller\'s own real obligation concluding, not by initialize()');

          // Fase 16.2-R4.2A-R7 (§6): baseline captured before opening this
          // SECOND controller — the finally block below must prove THIS
          // one (not the first, already-released one) actually gets
          // disposed too.
          final disposeBeforeSecondInitialize = fakePlatform.calls.where((c) => c == 'dispose').length;
          await service.initialize();
          expect(service.cameraKnownUnavailable, isFalse, reason: 'a fresh camera generation does not reintroduce staleness — sanity check only, not the clearing event itself');

          // Fase 16.2-R4.2A-R7 (§11, independent review — confirmed leak):
          // this test opens a SECOND controller (the whole point — proving
          // the signal clears on a fresh generation) but, previously,
          // never disposed it, in either the happy path or any earlier
          // failure. Disposing it here, still inside the try body once
          // this test's own real work is done, keeps the finally block
          // below simple (idempotent) for every other failure point.
          await service.dispose();
          await waitForCallCount('dispose', disposeBeforeSecondInitialize + 1);
        } finally {
          // Fase 16.2-R4.2A-R6 (§26)/R7 (§4): same guard as this file's
          // other discovery-timeout tests — see §14/N1's own doc for the
          // exact cross-test contamination this prevents. Safe/idempotent
          // regardless of whether the try body's own dispose() above
          // already ran: _doReleaseController no-ops once _controller is
          // already null.
          if (!pendingStart.isCompleted) pendingStart.complete();
          await starting.catchError((_) {});
          if (releasing != null) await releasing.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§9/§13/§14 — rotation, still correctly declining ITS OWN stop attempt when the camera is '
      'genuinely unavailable (_FinalizeReason.rotation, unchanged historical Fase 16.1 protection — '
      'see the dedicated "background camera loss vs. segment rotation" group above), still publishes '
      '`null` to the shared announcement it claims: a releaseIdleCamera() call afterward is not left '
      'waiting on it, and correctly still collects the segment rotation declined to touch, via its own '
      'teardown obligation (_FinalizeReason.teardown)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        try {
          await service.initialize();
          await service.startLoopRecording();
          expect(service.previewController?.value.isRecordingVideo, isTrue);

          service.notifyAppBackgrounded();
          expect(service.cameraKnownUnavailable, isTrue);

          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), isEmpty, reason: 'rotation itself must still decline to stop a known-unavailable camera');
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1), reason: 'and must not have attempted to restart either');

          final releaseStopwatch = Stopwatch()..start();
          await service.releaseIdleCamera();
          releaseStopwatch.stop();
          expect(releaseStopwatch.elapsedMilliseconds, lessThan(200), reason: 'must not hang waiting on an announcement rotation already published `null` to');

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'teardown must still collect the segment rotation correctly left untouched',
          );
          expect(service.clips, hasLength(1));
          await waitForCallCount('dispose', 1);
        } finally {
          // Fase 16.2-R4.2A-R7 (§16 audit — confirmed leak): this test has
          // a live 20ms Timer.periodic and previously no cleanup at all —
          // an assertion failing anywhere above left it running past this
          // test's own end.
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§17/§18(a) (MANDATORY) — a stop SCHEDULED by a rotation tick but not yet PUBLISHED (its own '
      '_doRotateSegment still queued behind an earlier, still-in-flight rotation restart attempt) is '
      'discovered deterministically by releaseIdleCamera() called while it is still unpublished — no '
      'sleep/probabilistic race: discovery genuinely waits on the shared announcement, then resolves '
      'once the queue actually progresses',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          stopVideoRecordingTimeout: const Duration(milliseconds: 500),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        // Stalls ONLY the restart half of the first rotation tick — segment
        // A's own finalize (stop + clip) resolves normally/fast, and the
        // tick's own _doRotateSegment then blocks trying to start segment
        // B, still occupying _queueTail.
        final pendingRestart = Completer<void>();
        Future<void>? releasing;
        try {
          await service.initialize();
          await service.startLoopRecording();
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1));

          fakePlatform.pendingStartVideoCapturing = pendingRestart;

          // The rotation timer has not ticked yet at all — wait for its own
          // native stop to actually be ISSUED first (real evidence rotation
          // ran), only then for the resulting pending stop to clear (real
          // evidence its processing finished) — waitForPendingStopToClear()
          // alone would return immediately, vacuously, before rotation ever
          // ticks, if called with nothing yet pending.
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1), reason: 'segment A was properly finalized by rotation itself');
          await waitForCallCount('startVideoCapturing', 2);

          // A second rotation tick fires (same short segmentDuration) while
          // the first tick's restart is still stuck ahead of it in
          // _queueTail — its own _onRotationTick() claims the shared
          // announcement synchronously; nothing has published to it yet,
          // since its own _doRotateSegment cannot even start running until
          // the first tick's restart resolves.
          await Future<void>.delayed(const Duration(milliseconds: 35));

          releasing = service.releaseIdleCamera();

          // Let the first tick's stuck restart resolve for real now — this is
          // what finally lets the second tick's own _doRotateSegment run,
          // decide whether segment B needs stopping, and publish that
          // decision to the SAME shared announcement releaseIdleCamera()
          // above is already waiting on.
          pendingRestart.complete();

          await releasing;

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(2),
            reason: 'segment B (started by the first tick\'s restart) was discovered via the announcement and properly stopped too — not silently abandoned, and not duplicated',
          );
          expect(service.clips, hasLength(2));
          await waitForCallCount('dispose', 1);
        } finally {
          // Fase 16.2-R4.2A-R7 (§16 audit — confirmed leak): this test has
          // a live 30ms Timer.periodic and a stuck native-start Completer —
          // previously no cleanup at all, so any assertion failing above
          // (in particular, before `pendingRestart.complete()` at the end
          // of the try body) left both alive past this test's own end.
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          if (releasing != null) await releasing.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.2A-R5 — announcement result vs. caller obligation', () {
    test(
      '§9/§34-N1 (MANDATORY) — the exact Codex repro: a rotation tick registers the shared '
      'announcement and, because the camera is known-unavailable, decides NOT to issue a STOP and '
      'publishes `null` — stopLoopRecording(), having discovered and reused THAT SAME announcement, '
      'must NOT accept that `null` as satisfying its own obligation: its own already-enqueued work '
      'still finds the Recording genuinely active and collects it for real',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        final pendingRestart = Completer<void>();
        Future<void>? stopping;
        try {
          await service.initialize();
          await service.startLoopRecording();
          expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing'), hasLength(1));

          // Segment A rotates normally (not yet backgrounded) into segment
          // B — but B's own restart is stalled, keeping rotation's own
          // overall _doRotateSegment operation (tick 1) occupying
          // _queueTail.
          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          // waitForPendingStopToClear() alone would return immediately,
          // vacuously, before rotation's first tick has even fired —
          // real evidence (the native call itself) must come first.
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1), reason: 'segment A was finalized normally by rotation\'s first tick');
          await waitForCallCount('startVideoCapturing', 2);

          // NOW the camera becomes known-unavailable — segment B has not
          // started yet (its restart is still stuck), but _isRecording is
          // still true (only startLoopRecording()/stopLoopRecording()
          // touch it, never _doRotateSegment directly), so this takes
          // effect.
          service.notifyAppBackgrounded();
          expect(service.cameraKnownUnavailable, isTrue);

          // A second rotation tick fires (same short segmentDuration)
          // while tick 1's restart is still stuck ahead of it in
          // _queueTail — its own _onRotationTick() claims the shared
          // announcement synchronously; nothing has published to it yet.
          await Future<void>.delayed(const Duration(milliseconds: 35));

          // stopLoopRecording() discovers and reuses THAT SAME
          // (tick 2's) announcement — the exact race this test proves
          // must not be accepted as sufficient.
          stopping = service.stopLoopRecording();

          // Let tick 1's stuck restart resolve for real now — segment B
          // genuinely, natively starts (controller.value.isRecordingVideo
          // becomes true for it), tick 1 returns, and tick 2's own
          // _doRotateSegment finally runs: sees B genuinely recording AND
          // cameraKnownUnavailable — _FinalizeReason.rotation's own
          // policy — and publishes `null` to the announcement
          // stopLoopRecording() above is already waiting on.
          pendingRestart.complete();

          await stopping;

          expect(
            service.isRecording,
            isFalse,
            reason: 'stopLoopRecording()\'s own synchronous intent prefix always clears this, regardless',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(2),
            reason: 'exactly two native stops total: segment A (rotation\'s own, normal finalize) and segment B '
                '(stopLoopRecording()\'s own obligation, after rotation explicitly declined to touch it) — B must '
                'not have been silently lost, and must not have been double-stopped either',
          );
          expect(service.clips, hasLength(2), reason: 'segment A (rotation) + segment B (explicitStop, after rotation\'s null) — not silently dropped');
        } finally {
          // Fase 16.2-R4.2A-R5 (§29): guaranteed even if an assertion above
          // fails partway through — an uncompleted pendingRestart would
          // otherwise leave this test's own Timer.periodic (30ms) alive
          // and ticking in the BACKGROUND past this test's own end, firing
          // into whichever fakePlatform a LATER test's own setUp() has
          // since installed as CameraPlatform.instance (confirmed directly:
          // this contaminated a sibling test with extra stopVideoRecording
          // calls before this fix).
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          if (stopping != null) await stopping.catchError((_) {});
          await service.dispose().catchError((_) {});
          // Fase 16.2-R4.2A-R7 (§16 audit): real evidence the controller
          // itself was released, not merely that dispose() returned.
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§10 — stopLoopRecording() discovers a scheduled-but-unpublished announcement but its own '
      'discovery times out (unrelated queue congestion) before learning the result: its own real '
      'obligation must remain enqueued and alive regardless, with no orphaned Future',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        await service.initialize();

        // A slow/stuck, unrelated native START occupies the queue ahead of
        // the stopLoopRecording() call below — this test is specifically
        // about discovery TIMING OUT, distinct from §9/N1's own scenario
        // (an announcement that DOES resolve, just to `null`).
        final pendingStart = Completer<void>();
        fakePlatform.pendingStartVideoCapturing = pendingStart;
        final starting = service.startLoopRecording();
        Future<void>? stopping;
        // Fase 16.2-R4.4-R1-T-Rm (R-m §10, test-only): the obligation that finally
        // collects the segment is stopped and its clip promoted — real file I/O
        // since R4.4-R1 — under the same 50 ms deadline the discovery timeout
        // needs. Under load that processing outlasted it, the service marked the
        // generation untrusted (correctly, for a stop past its deadline), and
        // the last getter read stayed true for that OTHER reason (this test's
        // natural R-m signature, reproduced by delaying only the rename, T-Rm
        // 02_directed/screen_rename). The obligation's own deadlines are held
        // ([HeldDeadlines]) once the discovery timeout has fired, and the
        // obligation's conclusion is awaited as the event it is.
        final obligationDeadlines = HeldDeadlines.upTo(service.stopVideoRecordingTimeout, holding: false);
        try {
          await Future<void>.delayed(Duration.zero);
          expect(fakePlatform.calls, contains('startVideoCapturing'));

          final stopStopwatch = Stopwatch()..start();
          stopping = obligationDeadlines.run(() => service.stopLoopRecording());
          await stopping;
          stopStopwatch.stop();

          expect(stopStopwatch.elapsedMilliseconds, lessThan(400), reason: 'must not block on unrelated queued work either');
          expect(service.cameraKnownUnavailable, isTrue, reason: 'discovery uncertainty must be visible while this caller\'s own obligation is still unresolved');

          // Let the stuck start settle — the segment genuinely, natively
          // starts, and stopLoopRecording()'s own already-enqueued obligation
          // (queued behind it) finally gets its turn and must still collect
          // it, since _isRecording was already flipped false synchronously.
          obligationDeadlines.holding = true;
          pendingStart.complete();
          await starting;
          await waitForPendingStopToClear();

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'the segment that became active while stopLoopRecording() was waiting must still be collected',
          );
          expect(service.clips, hasLength(1));
          await waitForCondition(() => service.discoveryUncertainCountForTest == 0, 'this caller\'s own obligation concluded');
          expect(obligationDeadlines.pending, 0, reason: 'test setup check: the obligation concluded before any of its deadlines had to elapse');
          expect(service.cameraKnownUnavailable, isFalse, reason: 'the discovery uncertainty must clear once this caller\'s own real obligation concludes');
        } finally {
          // Fase 16.2-R4.2A-R6 (§26, independent review — confirmed this
          // test also had no cleanup): see this file's own §14/N1 tests'
          // docs for the exact cross-test contamination this guards
          // against.
          if (!pendingStart.isCompleted) pendingStart.complete();
          await starting.catchError((_) {});
          if (stopping != null) await stopping.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§25 (MANDATORY) — a protect intent for a segment that becomes known-unavailable while still '
      'recording survives rotation declining to stop it (publishing `null`, per _FinalizeReason '
      '.rotation), and is still correctly applied once explicitStop/teardown actually collects that '
      'same segment later — with no leak onto a later, unrelated segment',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 20));
        try {
          await service.initialize();
          await service.startLoopRecording();
          await service.markClipAsProtected(); // intent: protect A, currently recording

          service.notifyAppBackgrounded(); // A is now known-unavailable, still genuinely recording
          expect(service.cameraKnownUnavailable, isTrue);

          // Let a real rotation tick run through its own null-publishing
          // policy for A — must NOT clear the protect intent.
          await Future<void>.delayed(const Duration(milliseconds: 40));
          expect(fakePlatform.calls, isNot(contains('stopVideoRecording')), reason: 'rotation itself must still decline to stop a known-unavailable camera');

          // explicitStop collects A for real — protection must have survived.
          await service.stopLoopRecording();
          expect(service.clips, hasLength(1));
          expect(service.clips.single.isProtected, isTrue, reason: 'the protect intent captured for A must survive rotation\'s own no-op decline');

          // A later, completely unrelated segment must not inherit it.
          await service.initialize();
          await service.startLoopRecording();
          await service.stopLoopRecording();
          expect(service.clips, hasLength(2));
          expect(service.clips.last.isProtected, isFalse, reason: 'the protect intent belonged to A only — it must not leak onto this later, unrelated clip');
        } finally {
          // Fase 16.2-R4.2A-R5 (§29): a live 20ms Timer.periodic must not
          // survive an assertion failure partway through this test — see
          // N1's own doc above for the cross-test contamination this
          // guards against.
          await service.dispose().catchError((_) {});
          // Fase 16.2-R4.2A-R7 (§16 audit): real evidence, not merely a
          // visible return — this test also opens a SECOND controller
          // (line 2608's own initialize()) that must be released too.
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§18/§35 — initialize()\'s own internal release of a prior, still-active controller participates '
      'in the shared announcement too: a dispose() called synchronously right after, with no await in '
      'between, discovers it instead of concluding nothing is pending',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          // Deliberately short: dispose()'s own queued teardown-closing
          // work is queued BEHIND this second initialize()'s own
          // _doInitializeController — which this test keeps deliberately
          // stuck (see pendingInit below) — so dispose() itself can only
          // ever resolve via _awaitTeardown's own defensive
          // `queued.timeout(stopVideoRecordingTimeout)` fallback. A short
          // value here keeps the test fast without weakening what it
          // actually proves (discovery of the announcement itself, and the
          // real collection of the prior segment, both settle well before
          // this).
          stopVideoRecordingTimeout: const Duration(milliseconds: 100),
        );
        // Fase 16.2-R4.2A-R7 (§16 audit — confirmed the gate and both
        // Futures below were previously declared INSIDE the try block,
        // making them inaccessible to `finally` — same class of bug as
        // R4.2A-R6's own §7/§8 fix for Test I's `pendingDispose`. All three
        // are declared here instead, and the whole test body (including
        // the FIRST initialize()/startLoopRecording() below, previously
        // outside any try at all) is now covered.
        final pendingInit = Completer<void>();
        Future<void>? initializing;
        Future<void>? disposing;
        try {
          await service.initialize();
          await service.startLoopRecording();
          expect(service.previewController?.value.isRecordingVideo, isTrue);

          // Stalls ONLY the second initialize()'s own native camera setup —
          // its internal release of the prior (still-recording) controller,
          // which happens first, is NOT stalled.
          fakePlatform.pendingInitializeCamera = pendingInit;

          // No await between these two calls — the exact race this test
          // proves: initialize()'s own claim (§18's own fix) must already
          // be in place by the time dispose() reads it, synchronously.
          initializing = service.initialize();
          disposing = service.dispose();

          // dispose() itself must still return (bounded defensively, per
          // _awaitTeardown's own doc) even though the second initialize()
          // it raced is still stuck — never blocked indefinitely by it.
          await disposing.timeout(const Duration(seconds: 2));

          // Fase 16.2-R4.4-R1-T-Rm (R-m §18/§35, test-only): dispose() returns
          // through _awaitTeardown's own bounded fallback (100 ms), which says
          // nothing about the prior segment's collection: that is the second
          // initialize()'s own release — the native stop, then the clip's
          // promotion (real file I/O since R4.4-R1). Under load it had not
          // settled yet when read (reproduced by delaying only the rename past
          // the fallback, T-Rm 02_directed/rename150). The collection is
          // awaited — no native stop left in flight — and only then counted:
          // "exactly once" is still checked, after it settled.
          await waitForCondition(
            () => fakePlatform.calls.contains('stopVideoRecording') && !service.hasPendingNativeStop,
            'the prior segment\'s native stop issued and settled',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'the segment active before this second initialize() must still be collected exactly once',
          );
          await waitForCondition(() => service.clips.isNotEmpty, 'the prior segment\'s clip published');
          expect(service.clips, hasLength(1));

          pendingInit.complete();
          await initializing.catchError((_) {});
        } finally {
          if (!pendingInit.isCompleted) pendingInit.complete();
          if (initializing != null) await initializing.catchError((_) {});
          if (disposing != null) await disposing.catchError((_) {});
          // service is already terminal by this point (dispose() above
          // always runs first in the happy path); a fresh, no-op-safe call
          // here only matters if an earlier assert failed before disposing
          // was even assigned. Once initializing has settled, _controller
          // is the FRESH controller that second initialize() built (this
          // test's own deliberate end-state — dispose() already released
          // the ORIGINAL one) — this call is what releases THAT one.
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.2A-R6 — terminal identity of a failed STOP attempt', () {
    test(
      '§16/§42-E (MANDATORY) — the exact Codex repro: a rotation-issued STOP for Recording A fails '
      'fast, and explicitStop, already queued behind it, must NOT retry that SAME Recording just '
      'because controller.value.isRecordingVideo stayed true (the plugin never flips it back after a '
      'failed stop) — exactly one attempt total for A, the original error reported exactly once, no '
      'fabricated clip',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        final pendingRestart = Completer<void>();
        Future<void>? stopping;
        StreamSubscription<String>? sub;
        try {
          await service.initialize();
          await service.startLoopRecording();

          // A preparatory segment rotates normally (real, successful stop —
          // counted separately below) into Recording A — but A's own
          // restart is stalled, keeping rotation's first tick's overall
          // _doRotateSegment operation occupying _queueTail, exactly like
          // this file's own R4.2A-R5 N1 test.
          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1), reason: 'the preparatory segment was finalized normally by rotation\'s first tick');
          await waitForCallCount('startVideoCapturing', 2);

          final errors = <String>[];
          sub = service.errors.listen(errors.add);

          // From here on, ANY stopVideoRecording() call fails fast — this
          // is Recording A's OWN, real, once-only attempt.
          fakePlatform.failStopVideoRecordingWith = CameraException('native_stop_failed', 'simulated fast native failure for Recording A');

          // A second rotation tick fires while tick 1's restart is still
          // stuck ahead of it — claims the shared announcement
          // synchronously; nothing has published to it yet.
          await Future<void>.delayed(const Duration(milliseconds: 35));

          // stopLoopRecording() discovers and reuses THAT SAME announcement
          // — its own obligation is enqueued behind tick 2 regardless.
          stopping = service.stopLoopRecording();

          // Let tick 1's stuck restart resolve for real now — Recording A
          // genuinely, natively starts, tick 1 returns, and tick 2's own
          // _doRotateSegment finally runs: attempts A's own real STOP,
          // which fails fast (configured above).
          pendingRestart.complete();

          await stopping;

          expect(service.isRecording, isFalse);
          expect(service.hasPendingNativeStop, isFalse, reason: 'the failed attempt is terminal, not pending');
          expect(service.previewController?.value.isRecordingVideo, isTrue, reason: 'the plugin never flips this back to false after a failed stop — the exact fact this whole fix exists to not be misled by');
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(2),
            reason: 'exactly two native stop calls total: the preparatory segment\'s own successful one, and Recording A\'s own single, failed attempt — explicitStop must not have issued a third, retrying the same Recording',
          );
          expect(service.clips, hasLength(1), reason: 'still only the preparatory clip — Recording A was never actually collected, and no fabricated clip was added for it');
          expect(errors, hasLength(1), reason: 'the original failure must be reported exactly once — explicitStop discovering the same terminal failure later must not re-report it');
        } finally {
          // Fase 16.2-R4.2A-R7 (§16 audit): this test's own segmentDuration
          // is 30ms (a live Timer.periodic) — dispose()'s synchronous
          // prefix always cancels it regardless of where a failure above
          // happened, but real evidence the controller itself was released
          // (not merely that dispose() visibly returned) is added here for
          // consistency with this file's other failure-marker tests.
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          if (stopping != null) await stopping.catchError((_) {});
          await sub?.cancel();
          fakePlatform.failStopVideoRecordingWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§17/§42-F (MANDATORY) — same failure, but discovered by releaseIdleCamera() instead of '
      'stopLoopRecording(): teardown must not retry the same, already-terminally-failed Recording '
      'either, and must still eventually dispose the controller',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        final pendingRestart = Completer<void>();
        Future<void>? releasing;
        StreamSubscription<String>? sub;
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1));
          await waitForCallCount('startVideoCapturing', 2);

          final errors = <String>[];
          sub = service.errors.listen(errors.add);

          fakePlatform.failStopVideoRecordingWith = CameraException('native_stop_failed', 'simulated fast native failure for Recording A');

          await Future<void>.delayed(const Duration(milliseconds: 35));

          releasing = service.releaseIdleCamera();

          pendingRestart.complete();
          await releasing;

          await waitForCallCount('dispose', 1);

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(2),
            reason: 'exactly two native stop calls total — release must not have retried Recording A a second time',
          );
          expect(service.clips, hasLength(1), reason: 'no fabricated clip for the failed Recording A');
          expect(errors, hasLength(1), reason: 'the original failure reported exactly once');
        } finally {
          // Fase 16.2-R4.2A-R7 (§16 audit): same reasoning as §16/§42-E's
          // own finally block above.
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          if (releasing != null) await releasing.catchError((_) {});
          await sub?.cancel();
          fakePlatform.failStopVideoRecordingWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§42-G — an explicit stopLoopRecording() whose own STOP fails fast leaves the Recording '
      'terminally failed: a release()/dispose() called afterward must not retry it either',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final errors = <String>[];
        StreamSubscription<String>? sub;
        try {
          await service.initialize();
          await service.startLoopRecording();
          sub = service.errors.listen(errors.add);

          fakePlatform.failStopVideoRecordingWith = CameraException('native_stop_failed', 'simulated explicit-stop failure');
          // Fase 16.2-R4.2A-R6 (§21): stopLoopRecording() never throws for a
          // native stop failure — the error is reported via [errors].
          await service.stopLoopRecording();

          expect(service.isRecording, isFalse);
          expect(service.previewController?.value.isRecordingVideo, isTrue);
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
          expect(errors, hasLength(1), reason: 'the failure must still be reported exactly once via errors, even though it does not throw');

          await service.dispose();
          await waitForCallCount('dispose', 1);

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'dispose() must not retry the same, already-failed Recording',
          );
          expect(service.clips, isEmpty);
        } finally {
          // Fase 16.2-R4.2A-R7 (§13, independent review — confirmed leak):
          // an earlier version of this finally block never disposed the
          // controller/service if any assert above (all of which run
          // BEFORE the try body's own dispose() call) failed. Safe/
          // idempotent regardless of whether that dispose() already ran.
          await sub?.cancel();
          fakePlatform.failStopVideoRecordingWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§15/§42-H — a failed attempt marker is scoped to the exact Recording it failed for, not to this '
      'DashcamService instance as a whole: on the SAME instance, once the failed controller is '
      'released (via a second initialize()\'s own internal teardown — itself correctly not retrying A '
      'either) and a fresh one takes over, a brand new, legitimate Recording B still receives its own, '
      'normal, single STOP — the marker does not leak forward and block it',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.failStopVideoRecordingWith = CameraException('native_stop_failed', 'Recording A fails');
          // Fase 16.2-R4.2A-R6 (§21): stopLoopRecording() never throws for a
          // native stop failure — the error is reported via [errors]
          // instead (not asserted on here; this test's own focus is the
          // failure marker's scoping, covered by the dedicated §42-G test).
          await service.stopLoopRecording();
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
          expect(service.previewController?.value.isRecordingVideo, isTrue, reason: 'A is still, misleadingly, "recording" per the plugin\'s own contract');

          // Recovery on the SAME service instance: a second initialize()'s
          // own internal release of the still-"recording" A must ALSO not
          // retry it (same guard, same _activeRecordingId) — it just
          // disposes the controller and builds a fresh one, exactly like
          // DashcamSessionController's own foreground-recovery path.
          fakePlatform.failStopVideoRecordingWith = null;
          await service.initialize();
          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(1),
            reason: 'this recovery initialize() must not have retried A a second time either',
          );

          // Recording B: brand new, on the fresh controller — its own
          // _activeRecordingId is different from A's, so A's failure
          // marker must not apply to it.
          await service.startLoopRecording();
          await service.stopLoopRecording();

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(2),
            reason: 'Recording A\'s own failed attempt (1) plus Recording B\'s own, brand new, successful stop (2) — B must not have been blocked by A\'s marker',
          );
          expect(service.clips, hasLength(1), reason: 'B\'s own clip, collected normally — A never produced one');
        } finally {
          // Fase 16.2-R4.2A-R7 (§14, independent review — confirmed leak):
          // an earlier version of this finally block only cleared the
          // failure configuration — it never disposed the service/whatever
          // controller (A's or B's, depending how far the try body got)
          // was still open. Safe/idempotent regardless of which one exists
          // at this point, or whether dispose() already ran.
          fakePlatform.failStopVideoRecordingWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§23/§42-I — _discoveryUncertainCount balances correctly across two INDEPENDENT, concurrent '
      'discovery timeouts: 0 → 1 (stopLoopRecording()\'s own) → 2 (releaseIdleCamera()\'s own, on the '
      'SAME still-unpublished announcement) → 1 (once the first caller\'s own real obligation '
      'resolves) → 0 (once the second\'s does too) — one contribution never clears the other\'s',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        final pendingRestart = Completer<void>();
        // Fase 16.2-R4.2A-R7 (§7/§8, independent review — confirmed bug):
        // declared HERE, at the same scope as the `finally` block below, not
        // inside the `try` — a Completer declared inside `try` is out of
        // scope in `finally`, so an earlier version of this test could only
        // ever null out `fakePlatform.pendingDispose` there, which has NO
        // effect on a `dispose()` call already in flight and already
        // captured its own local reference to this exact Completer (see
        // FakeCameraPlatform.dispose's own doc) — that in-flight call, and
        // whatever real teardown is queued behind it, would then never
        // resolve if any assert between creating this gate and completing it
        // normally were to fail.
        final disposeGate = Completer<void>();
        Future<void>? stopping;
        Future<void>? releasing;
        try {
          await service.initialize();
          await service.startLoopRecording();

          // Segment A rotates normally into segment B, whose own restart is
          // stalled — the SAME deterministic congestion construction used
          // throughout this file's own R4.2A-R5/R6 tests.
          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(1));
          await waitForCallCount('startVideoCapturing', 2);

          expect(service.discoveryUncertainCountForTest, 0, reason: 'nothing uncertain yet');

          // stopLoopRecording() claims a fresh announcement (nothing else
          // pending) and enqueues its own obligation behind the still-stuck
          // restart — its own discovery of THAT announcement times out.
          stopping = service.stopLoopRecording();
          await stopping;
          expect(service.discoveryUncertainCountForTest, 1, reason: 'stopLoopRecording()\'s own discovery timed out');

          // releaseIdleCamera() reuses the SAME still-unpublished
          // announcement (stopLoopRecording()'s own queued obligation
          // hasn't run yet either) — its own, INDEPENDENT discovery ALSO
          // times out.
          releasing = service.releaseIdleCamera();
          await releasing;
          expect(
            service.discoveryUncertainCountForTest,
            2,
            reason: 'a SECOND, independent caller\'s own discovery timing out must ADD to the first\'s contribution, not replace it',
          );
          expect(service.cameraKnownUnavailable, isTrue);

          // Stalls releaseIdleCamera()'s own eventual controller.dispose()
          // call deterministically — without this, both contributions
          // could resolve within the same ~10ms poll step below, making the
          // intermediate "1" unobservable rather than merely fast.
          fakePlatform.pendingDispose = disposeGate;

          // Let the stuck restart resolve for real — segment B genuinely
          // starts, then stopLoopRecording()'s own queued obligation runs
          // (stops B for real, decrementing its own contribution), then
          // releaseIdleCamera()'s own queued obligation runs (nothing left
          // to finalize) and reaches controller.dispose(), where it now
          // deterministically stalls.
          pendingRestart.complete();

          await waitForCallCount('stopVideoRecording', 2);
          await waitForCallCount('dispose', 1);
          expect(
            service.discoveryUncertainCountForTest,
            1,
            reason: 'stopLoopRecording()\'s own contribution resolved (segment B was stopped), but releaseIdleCamera()\'s own is still outstanding — its own controller.dispose() call has been issued but is deterministically stalled, not yet resolved',
          );

          disposeGate.complete();
          await waitForDiscoveryUncertainCount(0);
        } finally {
          // Fase 16.2-R4.2A-R8 (§6/§7 — independent review, confirmed bug):
          // the fallback `service.dispose()` call must be REQUESTED before
          // `waitForControllerReleased()` is ever awaited, not after. If an
          // assert above failed before `stopping`/`releasing` were assigned
          // (e.g. inside the try body, before line ~3025), NOTHING would
          // have asked the controller to release at all — an earlier version
          // of this finally block called `waitForControllerReleased()`
          // immediately after releasing the gates and awaiting `stopping`/
          // `releasing` (both still null in that scenario), with the
          // fallback `service.dispose()` call only reached AFTERWARD — so
          // the wait would itself time out and `fail()` before the one call
          // that could have satisfied it ever ran. Gates first, then any
          // already-started Futures, THEN the fallback teardown request,
          // and only THEN the wait for real evidence it concluded.
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          if (!disposeGate.isCompleted) disposeGate.complete();
          if (stopping != null) await stopping.catchError((_) {});
          if (releasing != null) await releasing.catchError((_) {});
          fakePlatform.pendingDispose = null;
          // _doReleaseController (via dispose()/releaseIdleCamera()) is
          // idempotent — a no-op if `_controller` is already null — so
          // issuing this unconditionally, even when `releasing` above
          // already tore the controller down for real, is always safe.
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      '§23/§42-J — a caller\'s own real obligation, once resolved, decrements its own discovery-'
      'uncertainty contribution exactly once even when that obligation itself terminates with an '
      'error (not merely on success) — a late controller.dispose() failure here',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          stopVideoRecordingTimeout: const Duration(milliseconds: 50),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        final pendingRestart = Completer<void>();
        Future<void>? disposing;
        final errors = <String>[];
        StreamSubscription<String>? sub;
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          await waitForCallCount('startVideoCapturing', 2);

          sub = service.errors.listen(errors.add);

          disposing = service.dispose();
          await disposing;
          expect(service.discoveryUncertainCountForTest, 1, reason: 'dispose()\'s own discovery timed out');

          // Fase 16.2-R4.2A-R7 (§28, doc-accuracy fix): completing
          // pendingRestart below lets the FIRST rotation tick's own
          // restart genuinely finish — segment B actually, natively
          // starts — before _queueTail can advance to dispose()'s own
          // queued _doReleaseController; an earlier version of this
          // comment claimed B "never actually started," which is not
          // what is actually guaranteed here. What IS guaranteed: by the
          // time _doReleaseController runs, B's own real stop attempt (not
          // configured to fail) succeeds and is collected normally, and
          // THEN controller.dispose() — configured to fail below — is what
          // this test's own assertions are actually about.
          fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated late teardown failure');

          pendingRestart.complete();

          await waitForCallCount('dispose', 1);
          await waitForDiscoveryUncertainCount(0);
          expect(
            service.discoveryUncertainCountForTest,
            0,
            reason: 'the contribution must still be decremented exactly once even though the underlying queued work failed, not succeeded',
          );

          for (var i = 0; i < 50 && errors.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(errors, hasLength(1), reason: 'the late dispose() failure must still be reported exactly once via errors');
        } finally {
          // Fase 16.2-R4.2A-R7 (§15, independent review — confirmed leak):
          // if a `waitFor*` helper above `fail()`s before `disposing` is
          // ever assigned, dispose() was never called at all — and since
          // this test's own 30ms Timer.periodic is only ever cancelled
          // (synchronously, in dispose()'s own prefix) by that same call,
          // an earlier version of this finally block left it alive
          // indefinitely (it never even attempted dispose() in that path).
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          // `disposing` itself (from the try body, if it ever ran) only
          // ever represents that FIRST, deliberately bounded call — its
          // own REAL underlying teardown is exactly what this test
          // configured to fail (failDisposeWith) and is therefore NOT
          // expected to have nulled `_controller` on its own, unlike every
          // other test in this file.
          //
          // Fase 16.2-R4.2A-R8 (§18/§28, independent review — doc-accuracy
          // fix): the fresh `service.dispose()` call below is NOT a "retry
          // of the native platform dispose" — verified directly against
          // `camera-0.12.0+2`'s own `CameraController.dispose()` source:
          // `_isDisposed` is set `true` BEFORE it awaits
          // `CameraPlatform.instance.dispose(_cameraId)`, so the FIRST
          // (failed) call above already left `_isDisposed == true` on this
          // exact controller object, and a `CameraController.dispose()`
          // call sees that and returns immediately (`if (_isDisposed)
          // return;`) WITHOUT calling the platform again at all. What
          // actually happens: `_doReleaseController`'s own
          // `await controller.dispose();` this second time hits that
          // already-`_isDisposed` no-op, does not throw (unlike the first
          // attempt), and only THEN does `_doReleaseController` reach its
          // own `_controller = null` line — this fresh call's only real
          // effect is letting DashcamService's own, LOCAL teardown reach
          // terminality; it proves nothing about a second native call
          // (`fakePlatform.calls` gets no additional `'dispose'` entry from
          // it).
          if (disposing != null) await disposing.catchError((_) {});
          fakePlatform.failDisposeWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          // Fase 16.2-R4.2B-R2 (§19/§23) — see the §12 dispose-failure
          // test's own identical comment above.
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          await sub?.cancel();
        }
      },
    );
  });

  group('Fase 16.2-R4.2B-R1 — process-wide ownership + native initialize/start retention', () {
    test('P1 — two DashcamService instances: B does not touch the platform while A is still process owner; B proceeds once A safely releases', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest));

        var bDone = false;
        final bFuture = b.initialize().whenComplete(() => bDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bDone, isFalse, reason: 'B must not proceed while A is still process owner');
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A ever touched the platform so far');

        await service.dispose();
        // Deliberately not asserting an intermediate `null` owner here: B
        // is EAGERLY waiting on the coordinator's own gate the instant A
        // releases it (a hot handoff, by design — no wasted idle time),
        // so there is no guaranteed OBSERVABLE window where the owner is
        // null from this test's own polling perspective. The real proof
        // this test cares about is the ordering below: B only ever
        // proceeds (and only ever touches the platform) AFTER this point.
        await bFuture;
        expect(bDone, isTrue);
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(2));
        expect(DashcamService.processOwnerCurrentForTest, same(b.processOwnerTokenForTest));
      } finally {
        await service.dispose().catchError((_) {});
        await b.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('P2 — initialize native pending: presentation deadline fires, but the raw Future/queue/owner are all retained until it genuinely resolves', () async {
      service = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        initializeCameraTimeout: const Duration(milliseconds: 50),
      );
      final initGate = Completer<void>();
      DashcamService? b;
      Future<void>? bFuture;
      try {
        fakePlatform.pendingInitializeCamera = initGate;
        final initFuture = service.initialize();

        await expectLater(initFuture, throwsA(isA<StateError>()), reason: 'the public presentation deadline still ends THIS caller\'s own wait');
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'ownership is retained past the presentation deadline');

        b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        var bDone = false;
        bFuture = b.initialize().whenComplete(() => bDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bDone, isFalse, reason: 'B must not touch the backend while the raw native initialize() is still pending');
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));

        initGate.complete();
        for (var i = 0; i < 50 && service.previewController == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(service.previewController, isNotNull, reason: 'the retained native initialize() must have genuinely completed');
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'still A — ownership only releases at a correct teardown point, not merely because the retained op finished');
      } finally {
        if (!initGate.isCompleted) initGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
        if (b != null) {
          await bFuture?.catchError((_) {});
          await b.dispose().catchError((_) {});
        }
      }
    });

    test('P3 — initialize native pending + dispose(): dispose() does not bypass it; teardown and owner release happen only after it resolves', () async {
      service = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        initializeCameraTimeout: const Duration(milliseconds: 50),
      );
      final initGate = Completer<void>();
      try {
        fakePlatform.pendingInitializeCamera = initGate;
        unawaited(service.initialize().catchError((_) {}));
        await Future<void>.delayed(Duration.zero);

        var disposeDone = false;
        unawaited(service.dispose().whenComplete(() => disposeDone = true));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(disposeDone, isFalse, reason: 'dispose() must not bypass the still-pending native initialize()');
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest));

        initGate.complete();
        // `previewController == null` proves nothing by itself here — it
        // starts null anyway, before this retained initialize() ever
        // assigns it — real evidence is the platform actually being asked
        // to dispose the controller this sequence built.
        await waitForCallCount('dispose', 1);
        expect(fakePlatform.disposedCameraIds, isNotEmpty, reason: 'the controller the doomed initialize() opened must still be disposed, not leaked');
        await waitForControllerReleased();
        await waitForProcessOwner(null, maxIterations: 200);
      } finally {
        if (!initGate.isCompleted) initGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('P4 — initialize native pending + B: zero native calls from B while A\'s initialize is still pending', () async {
      service = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        initializeCameraTimeout: const Duration(milliseconds: 50),
      );
      final initGate = Completer<void>();
      DashcamService? b;
      Future<void>? bFuture;
      try {
        fakePlatform.pendingInitializeCamera = initGate;
        unawaited(service.initialize().catchError((_) {}));
        await Future<void>.delayed(Duration.zero);

        b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        bFuture = b.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Exactly one of each — A's own (currently stalled inside
        // initializeCamera) — B must not have added a second of either.
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A\'s own createCameraWithSettings so far');
        expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1), reason: 'only A\'s own initializeCamera call — B must not have reached it at all');
      } finally {
        if (!initGate.isCompleted) initGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
        if (b != null) {
          await bFuture?.catchError((_) {});
          await b.dispose().catchError((_) {});
        }
      }
    });

    test('P5 — START native pending: presentation deadline fires, but owner/queue/raw Future stay retained; A\'s own teardown does not overtake START', () async {
      service = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        startVideoRecordingTimeout: const Duration(milliseconds: 50),
      );
      final startGate = Completer<void>();
      try {
        await service.initialize();
        fakePlatform.pendingStartVideoCapturing = startGate;
        final startFuture = service.startLoopRecording();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(service.isRecording, isFalse, reason: 'presentation deadline already elapsed — same public contract as before R4.2B-R1');
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'ownership retained past the START presentation deadline');

        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        var bDone = false;
        final bFuture = b.initialize().whenComplete(() => bDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bDone, isFalse, reason: 'B must not touch the backend while A\'s START is still pending');

        var disposeDone = false;
        final disposeFuture = service.dispose().whenComplete(() => disposeDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(disposeDone, isFalse, reason: 'A\'s own dispose() must not overtake its own still-pending START either');

        startGate.complete();
        await startFuture.catchError((_) {});
        await disposeFuture;
        await bFuture;

        expect(bDone, isTrue);
        expect(DashcamService.processOwnerCurrentForTest, same(b.processOwnerTokenForTest));
        await b.dispose().catchError((_) {});
      } finally {
        if (!startGate.isCompleted) startGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('P6 — START native pending + B: zero native calls from B until A reaches safe terminality', () async {
      service = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        startVideoRecordingTimeout: const Duration(milliseconds: 50),
      );
      final startGate = Completer<void>();
      DashcamService? b;
      Future<void>? bFuture;
      try {
        await service.initialize();
        fakePlatform.pendingStartVideoCapturing = startGate;
        unawaited(service.startLoopRecording());
        await Future<void>.delayed(const Duration(milliseconds: 100));

        b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        bFuture = b.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A\'s own controller so far — B has not touched the backend');
      } finally {
        if (!startGate.isCompleted) startGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
        if (b != null) {
          await bFuture?.catchError((_) {});
          await b.dispose().catchError((_) {});
        }
      }
    });

    test('P7 — START failure: A remains owner while its controller exists; B stays blocked until A\'s own safe teardown', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        fakePlatform.failStartVideoCapturingWith = CameraException('video_recording_failed', 'forced failure');
        await expectLater(service.startLoopRecording(), throwsA(isA<CameraException>()));
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'a START failure must not release ownership — the controller is still valid and still A\'s');

        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        var bDone = false;
        final bFuture = b.initialize().whenComplete(() => bDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bDone, isFalse, reason: 'B must remain blocked purely because a START attempt failed');

        await service.dispose();
        await bFuture;
        expect(bDone, isTrue, reason: 'B may proceed only once A\'s own safe teardown released ownership');
        await b.dispose().catchError((_) {});
      } finally {
        fakePlatform.failStartVideoCapturingWith = null;
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('P8 — initialize failure: cleanup succeeds, so ownership releases and B may proceed', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        fakePlatform.failCreateCameraWith = CameraException('no_camera', 'forced failure');
        await expectLater(service.initialize(), throwsA(isA<CameraException>()));
        expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'nothing (no controller, no pending op) is left to protect after a clean initialize() failure');

        fakePlatform.failCreateCameraWith = null;
        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        await b.initialize();
        expect(DashcamService.processOwnerCurrentForTest, same(b.processOwnerTokenForTest));
        await b.dispose().catchError((_) {});
      } finally {
        fakePlatform.failCreateCameraWith = null;
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test(
      'P9 — dispose native failure: fail-closed — B is rejected IMMEDIATELY (uncertain has precedence '
      'over waiting, Fase 16.2-R4.2B-R2 §14/§15/§16) even though the local controller reference is '
      'already gone',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final errors = <String>[];
        final sub = service.errors.listen(errors.add);
        DashcamService? b;
        try {
          await service.initialize();
          final ownerToken = service.processOwnerTokenForTest;
          fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated dispose failure');

          await service.dispose(); // does not throw — reported via errors (R6 contract)
          for (var i = 0; i < 50 && errors.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(errors, hasLength(1));
          expect(DashcamService.processOwnerIsUncertainForTest, isTrue, reason: 'a native dispose failure must fail-closed the coordinator');
          expect(DashcamService.processOwnerCurrentForTest, same(ownerToken), reason: 'ownership must not transfer while uncertain');

          b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
          await expectLater(
            b.initialize(),
            throwsA(isA<StateError>()),
            reason: 'B must be rejected immediately — fail-closed takes precedence over waiting, not handed off just because the Dart reference is gone',
          );
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A ever touched the platform');
        } finally {
          // Fase 16.2-R4.2B-R3 (§24, independent review — "reset movido para
          // DEPOIS do cleanup local"): clear the failure and let a fresh
          // local `dispose()` call reach `_controller = null` (the
          // established no-retry pattern — see the §12/§23 dispose-failure
          // tests' own identical doc) BEFORE simulating the process
          // restart — never before, since the coordinator helper now
          // refuses (throws) on a call that arrives while any raw local
          // state could still be considered live.
          fakePlatform.failDisposeWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          if (b != null) {
            await b.dispose().catchError((_) {});
          }
          await sub.cancel();
        }
      },
    );

    test('P10 — successful handoff: total native call ordering never lets B\'s createCameraWithSettings precede A\'s own dispose completing', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        await service.startLoopRecording();
        await service.stopLoopRecording();
        await service.dispose();

        final disposeIndex = fakePlatform.calls.lastIndexOf('dispose');
        expect(disposeIndex, greaterThanOrEqualTo(0));

        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          await b.initialize();
          final bCreateIndex = fakePlatform.calls.indexOf('createCameraWithSettings', disposeIndex);
          expect(bCreateIndex, greaterThan(disposeIndex), reason: 'B\'s own createCameraWithSettings must never precede A\'s own dispose completing');
        } finally {
          await b.dispose().catchError((_) {});
        }
      } finally {
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('P11 — same-owner reentrancy: repeated initialize()/start/rotation/release on the SAME instance never deadlocks and never double-acquires', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        final tokenAfterFirst = DashcamService.processOwnerCurrentForTest;
        await service.startLoopRecording();
        await service.stopLoopRecording();
        await service.initialize(); // re-entrant sequential call, same instance
        expect(DashcamService.processOwnerCurrentForTest, same(tokenAfterFirst), reason: 'the SAME instance re-acquiring must never wait on itself or change the recorded owner identity');
        await service.releaseIdleCamera();
        await service.initialize();
        expect(DashcamService.processOwnerCurrentForTest, same(tokenAfterFirst));
      } finally {
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('P12 — never-resolving initialize: coordinator stays occupied, B never touches the backend; test cleanup resolves the gate deterministically', () async {
      service = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        initializeCameraTimeout: const Duration(milliseconds: 50),
      );
      final initGate = Completer<void>(); // deliberately left incomplete during observation
      DashcamService? b;
      Future<void>? bFuture;
      try {
        fakePlatform.pendingInitializeCamera = initGate;
        unawaited(service.initialize().catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        bFuture = b.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(fakePlatform.calls.where((c) => c == 'initializeCamera'), hasLength(1), reason: 'only A\'s own — B never reaches its own native initializeCamera call');
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'the coordinator remains occupied by A the whole time — no fake release by timeout');
      } finally {
        if (!initGate.isCompleted) initGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
        if (b != null) {
          await bFuture?.catchError((_) {});
          await b.dispose().catchError((_) {});
        }
      }
    });

    test('P13 — never-resolving START: process stays blocked during observation; finally resolves the gate, drains, disposes, and frees the owner', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      final startGate = Completer<void>(); // deliberately left incomplete during observation
      try {
        await service.initialize();
        fakePlatform.pendingStartVideoCapturing = startGate;
        unawaited(service.startLoopRecording());
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final bFuture = b.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'B never reaches the backend while A\'s START is unresolved');
        await b.dispose().catchError((_) {}); // b never acquired anything real yet — safe no-op
        unawaited(bFuture.catchError((_) {}));
      } finally {
        if (!startGate.isCompleted) startGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test('P14 — public presentation timeout never releases the owner, for BOTH initialize and START, checked independently', () async {
      final a = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        initializeCameraTimeout: const Duration(milliseconds: 50),
      );
      final initGate = Completer<void>();
      try {
        fakePlatform.pendingInitializeCamera = initGate;
        await expectLater(a.initialize(), throwsA(isA<StateError>()));
        expect(DashcamService.processOwnerCurrentForTest, same(a.processOwnerTokenForTest), reason: 'initialize()\'s own presentation timeout must not release the owner');
        initGate.complete();
        for (var i = 0; i < 50 && a.previewController == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(a.previewController, isNotNull);
      } finally {
        if (!initGate.isCompleted) initGate.complete();
        await a.dispose().catchError((_) {});
        for (var i = 0; i < 50 && a.previewController != null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await waitForProcessOwner(null, maxIterations: 200);
      }

      service = DashcamService(
        config: config(),
        segmentDuration: const Duration(minutes: 10),
        startVideoRecordingTimeout: const Duration(milliseconds: 50),
      );
      final startGate = Completer<void>();
      try {
        await service.initialize();
        fakePlatform.pendingStartVideoCapturing = startGate;
        await service.startLoopRecording();
        expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'startLoopRecording()\'s own presentation timeout must not release the owner either');
      } finally {
        if (!startGate.isCompleted) startGate.complete();
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
    });

    test(
      'P15 — pre-admission: B genuinely disposed while still only waiting for ownership (never having '
      'touched the platform) never emits a stale native call once A later releases — Fase 16.2-R4.2B-R2 '
      '§13/§40 (independent review — the R1-era version of this test only waited ~100ms against B\'s '
      'own DEFAULT 10s initializeCameraTimeout, then let B initialize for real: it never actually '
      'exercised dispose-before-admission at all, since B was never disposed in it)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final initGate = Completer<void>();
        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          fakePlatform.pendingInitializeCamera = initGate;
          unawaited(service.initialize().catchError((_) {})); // A: genuinely stuck, so B is genuinely contended, not merely racing microtasks
          await Future<void>.delayed(Duration.zero);

          var bDone = false;
          final bFuture = b.initialize().whenComplete(() => bDone = true);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(bDone, isFalse, reason: 'B is still only waiting for admission, never having touched the platform');
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A\'s own so far');

          // B's own dispose() call sets `_disposed = true` synchronously,
          // but its own RETURNED Future would not resolve until B's own
          // queue reaches its turn — which cannot happen before B's own
          // still-blocked initialize() closure does (see this file's own
          // established `unawaited(...dispose()...)` pattern for the exact
          // same reason, e.g. P9's own finally block). `_disposed = true`
          // synchronously is all this test's own pre-admission abandonment
          // needs.
          unawaited(b.dispose().catchError((_) {}));
          initGate.complete(); // A's own stuck native initialize now resolves — but a SUCCESSFUL initialize() keeps ownership (by design), so A must be explicitly released for B to ever be woken at all.
          await service.dispose();
          await bFuture;
          expect(bDone, isTrue);
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(1),
            reason: 'B must never touch the backend — its own admission was invalidated by dispose() before it was ever granted',
          );
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await service.dispose().catchError((_) {});
          await b.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test('P16 — coordinator test isolation: after this test, the process owner is free, no process-level native op is pending, no controller is alive, no gate is active', () async {
      service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        await service.startLoopRecording();
        await service.stopLoopRecording();
      } finally {
        await service.dispose().catchError((_) {});
        await waitForControllerReleased();
      }
      // The shared tearDown below (which now only VERIFIES natural release
      // — see its own doc, Fase 16.2-R4.2B-R2 §23) is what actually
      // proves/enforces the isolation this test's own name describes —
      // asserted explicitly here too for this specific test's own
      // documentation value.
      await waitForProcessOwner(null);
      expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
    });
  });

  group('Fase 16.2-R4.2B-R2 — pre-admission safety + same-owner fail-closed precedence', () {
    test(
      'P1 — pre-admission timeout: B\'s own presentation deadline elapses while genuinely still waiting '
      'for A to release; B never emits a native call, even after A later, genuinely does release',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final initGate = Completer<void>();
        final b = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
        );
        try {
          fakePlatform.pendingInitializeCamera = initGate;
          unawaited(service.initialize().catchError((_) {})); // A: genuinely stuck, holding ownership
          await Future<void>.delayed(Duration.zero);

          await expectLater(
            b.initialize(),
            throwsA(isA<StateError>()),
            reason: 'B\'s own short presentation deadline elapses while still only waiting for admission',
          );
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A\'s own so far — B never touched the backend');

          // Only now, well after B's own deadline already fired, does A
          // actually release.
          initGate.complete();
          await service.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(1),
            reason: 'B must never emit a native call, even after A genuinely, later releases',
          );
          expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'B\'s own abandoned admission must not leave it holding — or having ever held — ownership');
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await service.dispose().catchError((_) {});
          await b.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'P2 — pre-admission dispose: B genuinely disposed while still only waiting for ownership never '
      'emits a stale native call once A later releases',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final initGate = Completer<void>();
        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          fakePlatform.pendingInitializeCamera = initGate;
          unawaited(service.initialize().catchError((_) {}));
          await Future<void>.delayed(Duration.zero);

          final bFuture = b.initialize();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));

          unawaited(b.dispose().catchError((_) {})); // sets _disposed = true synchronously — see P15's own identical doc
          initGate.complete(); // A's own stuck native initialize now resolves — but a SUCCESSFUL initialize() keeps ownership (by design), so A must be explicitly released for B to ever be woken at all.
          await service.dispose();
          await bFuture;

          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(1),
            reason: 'B must never touch the backend — its admission was invalidated by dispose() before it was ever granted',
          );
          expect(DashcamService.processOwnerCurrentForTest, isNull);
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await service.dispose().catchError((_) {});
          await b.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'P3 — same-owner + uncertain: once a dispose failure marks the coordinator fail-closed, the SAME '
      'instance calling initialize() again must be rejected too — uncertain has precedence over '
      'same-owner reentrancy',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final errors = <String>[];
        final sub = service.errors.listen(errors.add);
        try {
          await service.initialize();
          fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated dispose failure');
          await service.releaseIdleCamera(); // does not throw — reported via errors; leaves the coordinator uncertain
          for (var i = 0; i < 50 && errors.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(errors, hasLength(1));
          expect(DashcamService.processOwnerIsUncertainForTest, isTrue, reason: 'a native dispose failure must fail-closed the coordinator');

          fakePlatform.failDisposeWith = null;
          await expectLater(
            service.initialize(),
            throwsA(isA<StateError>()),
            reason: 'the SAME instance re-acquiring must be rejected too — uncertain takes precedence over same-owner reentrancy',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            hasLength(1),
            reason: 'only the ORIGINAL initialize() call\'s own — the rejected retry must never reach a second native initializeCamera call',
          );
        } finally {
          // Fase 16.2-R4.2B-R3 (§25, independent review — same fix as R1's
          // own P9): reset moved to AFTER local cleanup reaches terminality.
          fakePlatform.failDisposeWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          await sub.cancel();
        }
      },
    );

    test(
      'P4 — other-owner + uncertain: a DIFFERENT instance calling initialize() while the coordinator is '
      'fail-closed must not touch the backend either',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final errors = <String>[];
        final sub = service.errors.listen(errors.add);
        DashcamService? b;
        try {
          await service.initialize();
          fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated dispose failure');
          await service.releaseIdleCamera();
          for (var i = 0; i < 50 && errors.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(DashcamService.processOwnerIsUncertainForTest, isTrue);

          b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
          await expectLater(
            b.initialize(),
            throwsA(isA<StateError>()),
            reason: 'a different instance must be rejected too while the backend is fail-closed',
          );
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A\'s own original controller — B never touched the backend');
        } finally {
          // Fase 16.2-R4.2B-R3 (§25, independent review — same fix as R1's
          // own P9): reset moved to AFTER local cleanup reaches terminality.
          fakePlatform.failDisposeWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          if (b != null) {
            await b.dispose().catchError((_) {});
          }
          await sub.cancel();
        }
      },
    );

    test(
      'P5 — normal reentrancy (no uncertain): the SAME instance calling initialize() again after already '
      'owning remains reentrant-safe under the new acquire() precedence ordering',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          await service.initialize();
          final tokenAfterFirst = DashcamService.processOwnerCurrentForTest;
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));

          await service.initialize(); // sequential reentrant call, same instance, still owner
          expect(DashcamService.processOwnerCurrentForTest, same(tokenAfterFirst));
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse);
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(2),
            reason: 'a sequential call still legitimately builds a fresh controller (existing, approved R1 behavior) — this test only cares that reentrant ownership itself never waits/blocks/rejects',
          );
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'P6 — process-restart simulation refuses to mask a DIFFERENT instance\'s still-active ownership, '
      'refuses to force-clear a HEALTHY (non-uncertain) owner even for its own token, and is a safe '
      'no-op when nothing owns. Fase 16.2-R4.2B-R3 (§21/§22/§26, independent review P2 — "reset usado '
      'cedo demais / apaga owner saudável"): the R2-era version of this test ended by calling this '
      'helper on `service`\'s own token while it was still a perfectly healthy owner (not uncertain) — '
      'exactly the pattern the reviewer flagged as capable of silently masking a real leak. Rewritten '
      'as a pure PROHIBITION test: a healthy owner must release naturally via teardown, never via this '
      'test-only helper.',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'a no-op when nothing owns yet');

          await service.initialize();
          expect(
            () => DashcamService.simulateProcessRestartForTest(b.processOwnerTokenForTest),
            throwsA(isA<StateError>()),
            reason: 'a DIFFERENT instance\'s token must never be able to force-clear ownership it does not hold — that would mask a genuine cross-instance leak',
          );
          expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest), reason: 'the refused call must not have mutated anything');

          expect(
            () => DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest),
            throwsA(isA<StateError>()),
            reason: 'the CORRECT token must ALSO be refused while it is a healthy (non-uncertain) owner — this helper is not a general reset, only a test-only process-restart simulation for the fail-closed case',
          );
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse, reason: 'the refused call must not have mutated anything, including this flag');
          expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest));

          // Natural release — teardown, not the test-only helper.
          await service.dispose();
          expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'a healthy owner releases naturally via dispose()');
        } finally {
          await service.dispose().catchError((_) {});
          await b.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.2B-R3 — pre-native admission validity independent of contention', () {
    test(
      'R3-1 (§5/§54, MANDATORY — exact reviewer reproduction of P1) — a presentation deadline that '
      'elapses while genuinely queued behind this SAME instance\'s own earlier operation (no other '
      'process owner ever involved) must not let a stale initialize() reach the native platform once '
      'the local FIFO queue finally drains',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(seconds: 5),
          initializeCameraTimeout: const Duration(milliseconds: 50),
        );
        final stopGate = Completer<void>();
        try {
          await service.initialize(); // this FIRST, legitimate call already logs one initializeCamera
          final callsBeforeRecovery = fakePlatform.calls.where((c) => c == 'initializeCamera').length;
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopGate;
          final stopFuture = service.stopLoopRecording(); // occupies _queueTail, genuinely stuck — no other DashcamService/owner involved at all

          // Recovery-style initialize() requested while the queue is still
          // occupied by the stop above.
          final initFuture = service.initialize();
          // Fase 16.2-R4.2B-R4 (intervention — test determinism correction):
          // capture the RAW operation the instant it exists — synchronously,
          // before any `await` — so the later proof of "it never reaches
          // the native platform" can be anchored to THIS specific Future's
          // own genuine settlement, not a fixed real-time margin.
          final rawSettlement = service.pendingInitializeSettlement;
          expect(rawSettlement, isNotNull, reason: 'the second initialize() call must have created a real, queued raw operation to observe');
          await expectLater(
            initFuture,
            throwsA(isA<StateError>()),
            reason: 'the public presentation deadline elapses while still genuinely queued behind this SAME instance\'s own earlier work',
          );
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length,
            callsBeforeRecovery,
            reason: 'zero NEW native initializeCamera before the queue even drains',
          );

          // Now let the queue finally drain.
          stopGate.complete();
          await stopFuture.catchError((_) {});
          await waitForPendingStopToClear();

          // Causal proof, not a margin: wait for the captured RAW operation
          // itself to genuinely settle (Checkpoint 1's own abandonment),
          // then for its own self-clearing bookkeeping — the same pattern
          // `DashcamSessionController`'s own barrier-wait uses — instead of
          // presuming a fixed delay was "enough" for the now-unblocked
          // closure to reach and abandon.
          await rawSettlement!.catchError((_) {}).timeout(const Duration(seconds: 5));
          await waitForPendingInitializeSettlementToClear();
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length,
            callsBeforeRecovery,
            reason: 'the ALREADY-expired pre-emission intent must never reach the native platform, even once the local FIFO queue finally drains',
          );
          expect(
            DashcamService.processOwnerCurrentForTest,
            isNull,
            reason: 'Checkpoint 1 abandonment releases ownership unconditionally, even for this SAME, already-owning instance (see R4-1\'s own dedicated coverage of this exact mechanism)',
          );
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'R3-2 (§6/§55, MANDATORY) — dispose() requested while an initialize() request is still genuinely '
      'queued behind this SAME instance\'s own earlier operation results in ZERO native '
      'initializeCamera, independent of process contention',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(seconds: 5),
        );
        final stopGate = Completer<void>();
        try {
          await service.initialize(); // this FIRST, legitimate call already logs one initializeCamera
          final callsBeforeRecovery = fakePlatform.calls.where((c) => c == 'initializeCamera').length;
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopGate;
          final stopFuture = service.stopLoopRecording();

          final initFuture = service.initialize(); // queued behind the stop, default (long) deadline — dispose, not a deadline, is what invalidates it here
          // Fase 16.2-R4.2B-R4 (intervention — test determinism correction):
          // capture the RAW operation synchronously, the instant it exists.
          final rawSettlement = service.pendingInitializeSettlement;
          expect(rawSettlement, isNotNull, reason: 'the second initialize() call must have created a real, queued raw operation to observe');
          unawaited(initFuture.catchError((_) {}));
          await Future<void>.delayed(Duration.zero);

          unawaited(service.dispose().catchError((_) {})); // requested before this initialize() ever reaches admission
          stopGate.complete();
          await stopFuture.catchError((_) {});
          await waitForPendingStopToClear();

          // Causal proof, not a margin: wait for the captured RAW operation
          // itself to genuinely settle (Checkpoint 1's own `_disposed`
          // abandonment), then for its own self-clearing bookkeeping.
          await rawSettlement!.catchError((_) {}).timeout(const Duration(seconds: 5));
          await waitForPendingInitializeSettlementToClear();
          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera').length,
            callsBeforeRecovery,
            reason: 'ZERO NEW native initialize once disposed while still genuinely queued — independent of process contention',
          );
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'R3-3 (§11/§12/§53, MANDATORY) — a presentation deadline that elapses DURING availableCameras() '
      '(device discovery) must not let a stale initialize() reach controller.initialize() once '
      'discovery finally returns',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
        );
        final discoveryGate = Completer<void>();
        final discoveryEntered = Completer<void>();
        try {
          fakePlatform.pendingAvailableCameras = discoveryGate;
          fakePlatform.availableCamerasEnteredForTest = discoveryEntered;

          final initFuture = service.initialize();
          // Fase 16.2-R4.2B-R4 (intervention — test determinism correction):
          // capture the RAW operation synchronously, the instant it exists.
          final rawSettlement = service.pendingInitializeSettlement;
          expect(rawSettlement, isNotNull, reason: 'initialize() must have created a real raw operation to observe');

          // Causal proof that discovery genuinely entered the gate — not
          // inferred from a fixed delay.
          await discoveryEntered.future.timeout(const Duration(seconds: 5));

          await expectLater(
            initFuture,
            throwsA(isA<StateError>()),
            reason: 'presentation deadline elapses while device discovery is still pending',
          );

          discoveryGate.complete(); // only now — after the presentation view has objectively already expired

          // Causal proof, not a margin: wait for the captured RAW operation
          // (now unblocked in availableCameras()) to genuinely settle, then
          // for its own self-clearing bookkeeping.
          await rawSettlement!.catchError((_) {}).timeout(const Duration(seconds: 5));
          await waitForPendingInitializeSettlementToClear();

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            isEmpty,
            reason: 'discovery completing late must not authorize a stale initialize() emission',
          );
          expect(
            DashcamService.processOwnerCurrentForTest,
            isNull,
            reason: 'discovery-stage abandonment must release ownership too',
          );
        } finally {
          if (!discoveryGate.isCompleted) discoveryGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'R3-4 (§18/§56, MANDATORY — Dart-integrated multiple-waiter coverage) — A owner, B/C/D all '
      'genuinely waiting: releasing A admits exactly one new owner at a time, never two simultaneous '
      'native creates, and successive releases let each subsequent waiter progress in turn',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final initGate = Completer<void>();
        final waiters = List.generate(3, (_) => DashcamService(config: config(), segmentDuration: const Duration(minutes: 10)));
        final doneOrder = <int>[];

        Future<void> waitForDoneCount(int n) async {
          for (var iter = 0; iter < 200; iter++) {
            if (doneOrder.length >= n) return;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fail('waitForDoneCount: only ${doneOrder.length} of $n after 2000ms (doneOrder=$doneOrder)');
        }

        try {
          fakePlatform.pendingInitializeCamera = initGate;
          unawaited(service.initialize().catchError((_) {})); // A: genuinely stuck, holding ownership
          await Future<void>.delayed(Duration.zero);

          for (var i = 0; i < waiters.length; i++) {
            final idx = i;
            unawaited(waiters[idx].initialize().whenComplete(() => doneOrder.add(idx)));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(doneOrder, isEmpty, reason: 'nobody admitted yet — A still owns');
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A');

          initGate.complete();
          await service.dispose();

          await waitForDoneCount(1);
          expect(doneOrder, hasLength(1), reason: 'exactly one waiter admitted so far');
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(2), reason: 'A + exactly the one winner so far');
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(doneOrder, hasLength(1), reason: 'still only one — the other two remain genuinely blocked, never two simultaneous owners');

          await waiters[doneOrder[0]].dispose();
          await waitForDoneCount(2);
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(3));
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(doneOrder, hasLength(2));

          await waiters[doneOrder[1]].dispose();
          await waitForDoneCount(3);
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(4));
          expect(doneOrder.toSet(), {0, 1, 2}, reason: 'no FIFO guarantee, but every waiter is eventually, individually admitted exactly once');
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          for (final w in waiters) {
            await w.dispose().catchError((_) {});
          }
        }
      },
    );

    test(
      'R3-5 (§17/§57, MANDATORY) — A owner; B\'s own presentation deadline expires while still '
      'genuinely waiting; C is a genuinely valid, still-waiting request: releasing A lets C (never the '
      'already-abandoned B) proceed, with exactly one new native call attributable to C',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final initGate = Completer<void>();
        final b = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
        );
        final c = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10)); // default (long) deadline — genuinely still valid once A releases
        try {
          fakePlatform.pendingInitializeCamera = initGate;
          unawaited(service.initialize().catchError((_) {}));
          await Future<void>.delayed(Duration.zero);

          await expectLater(
            b.initialize(),
            throwsA(isA<StateError>()),
            reason: 'B\'s own short deadline elapses while still genuinely waiting for A',
          );

          var cDone = false;
          final cFuture = c.initialize().whenComplete(() => cDone = true);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(cDone, isFalse, reason: 'C is still genuinely waiting too');

          initGate.complete();
          await service.dispose();
          await cFuture;
          expect(cDone, isTrue);

          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(2),
            reason: 'A + exactly C — B never touched the backend',
          );
          expect(DashcamService.processOwnerCurrentForTest, same(c.processOwnerTokenForTest));
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await service.dispose().catchError((_) {});
          await b.dispose().catchError((_) {});
          await c.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'R3-6 (§19/§58, MANDATORY) — A owner with a live controller; B/C are genuinely waiting for it; A '
      'becomes uncertain (a dispose failure) while they wait: both wake and reject deterministically, '
      'zero native calls from either, nobody stuck',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final c = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final errors = <String>[];
        final sub = service.errors.listen(errors.add);
        try {
          await service.initialize(); // A owns, has a live controller

          // Fase 16.2-R4.2B-R3: `.then(onError:)` immediately, right when
          // each Future is created — not `expectLater` after a delay —
          // captures the eventual error into a plain variable instead of
          // leaving the raw rejecting Future unlistened-to for the whole
          // `errors`-wait window below, which Dart's zone machinery would
          // otherwise flag as an unhandled async error (a real test crash,
          // not just a missed assertion).
          Object? bError;
          Object? cError;
          final bSettled = b.initialize().then((_) {}, onError: (Object error) {
            bError = error;
          });
          final cSettled = c.initialize().then((_) {}, onError: (Object error) {
            cError = error;
          });
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(bError, isNull, reason: 'B still genuinely waiting');
          expect(cError, isNull, reason: 'C still genuinely waiting');
          expect(
            fakePlatform.calls.where((call) => call == 'createCameraWithSettings'),
            hasLength(1),
            reason: 'only A so far — B/C still genuinely waiting',
          );

          fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated dispose failure');
          await service.releaseIdleCamera(); // does not throw — reported via errors; leaves the coordinator uncertain and wakes every waiter
          for (var i = 0; i < 50 && errors.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(errors, hasLength(1));
          expect(DashcamService.processOwnerIsUncertainForTest, isTrue);

          await bSettled;
          await cSettled;
          expect(bError, isA<StateError>(), reason: 'B must wake and reject, not stay stuck');
          expect(cError, isA<StateError>(), reason: 'C must wake and reject, not stay stuck');
          expect(
            fakePlatform.calls.where((call) => call == 'createCameraWithSettings'),
            hasLength(1),
            reason: 'still only A — neither B nor C ever touched the backend',
          );
        } finally {
          fakePlatform.failDisposeWith = null;
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          await b.dispose().catchError((_) {});
          await c.dispose().catchError((_) {});
          await sub.cancel();
        }
      },
    );
  });

  group('Fase 16.2-R4.2B-R4 — monotonic intent + owner release on abandonment', () {
    test(
      'R4-1 (§9/§10/§13/§44, MANDATORY reproduction of P1-B) — owner release after pre-emission '
      'abandonment at Checkpoint 1: an already-owning instance whose NEW initialize() request expires '
      '(purely from local FIFO delay, no cross-instance contention) before ever re-touching the '
      'coordinator releases ownership immediately — BEFORE this test\'s own finally/dispose cleanup — '
      'and a brand new instance C initializes immediately with no additional action on the abandoned '
      'one',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          stopVideoRecordingTimeout: const Duration(seconds: 5),
          initializeCameraTimeout: const Duration(milliseconds: 50),
        );
        final stopGate = Completer<void>();
        DashcamService? c;
        try {
          await service.initialize();
          await service.startLoopRecording();

          fakePlatform.pendingStopVideoRecording = stopGate;
          final stopFuture = service.stopLoopRecording(); // occupies _queueTail

          final initFuture = service.initialize(); // recovery-style reinit, queued behind the stop
          // Fase 16.2-R4.2B-R4 (intervention — test determinism correction):
          // capture the RAW operation synchronously, the instant it exists.
          final rawSettlement = service.pendingInitializeSettlement;
          expect(rawSettlement, isNotNull, reason: 'the second initialize() call must have created a real, queued raw operation to observe');
          await expectLater(
            initFuture,
            throwsA(isA<StateError>()),
            reason: 'the public presentation deadline elapses while still genuinely queued',
          );

          stopGate.complete();
          await stopFuture.catchError((_) {});
          await waitForPendingStopToClear();
          // Causal proof, not a margin: wait for the captured RAW operation
          // itself to genuinely settle (reaching Checkpoint 1 and
          // abandoning), then for its own self-clearing bookkeeping —
          // instead of presuming a fixed delay was "enough" for the
          // now-unblocked closure to reach Checkpoint 1.
          await rawSettlement!.catchError((_) {}).timeout(const Duration(seconds: 5));
          await waitForPendingInitializeSettlementToClear();

          // Fase 16.2-R4.2B-R4 (§10): this assertion happens BEFORE any
          // finally/dispose cleanup below — the R3-era regression the
          // reviewer found was masked by tests that only ever checked owner
          // state AFTER their own finally had already (incidentally)
          // disposed the service.
          expect(
            DashcamService.processOwnerCurrentForTest,
            isNull,
            reason: 'a pre-emission abandonment must release ownership, not silently retain it',
          );
          expect(
            fakePlatform.calls.where((call) => call == 'initializeCamera'),
            hasLength(1),
            reason: 'only the ORIGINAL, first successful initialize — the abandoned request never touched the backend',
          );

          // C progresses immediately, with zero additional action on the
          // abandoned `service` instance.
          c = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
          await c.initialize().timeout(const Duration(seconds: 1));
          expect(DashcamService.processOwnerCurrentForTest, same(c.processOwnerTokenForTest));
        } finally {
          if (!stopGate.isCompleted) stopGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          if (c != null) {
            await c.dispose().catchError((_) {});
          }
        }
      },
    );

    test(
      'R4-2 (§45) — owner release after availableCameras() discovery abandonment: the deadline expires '
      'during discovery, discovery then resolves, zero initializeCamera is ever reached, ownership is '
      'liberated, and another instance progresses immediately',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(milliseconds: 50),
        );
        final discoveryGate = Completer<void>();
        final discoveryEntered = Completer<void>();
        DashcamService? c;
        try {
          fakePlatform.pendingAvailableCameras = discoveryGate;
          fakePlatform.availableCamerasEnteredForTest = discoveryEntered;
          final initFuture = service.initialize();
          // Fase 16.2-R4.2B-R4 (intervention — test determinism correction):
          // capture the RAW operation synchronously, the instant it exists.
          final rawSettlement = service.pendingInitializeSettlement;
          expect(rawSettlement, isNotNull, reason: 'initialize() must have created a real raw operation to observe');

          // Causal proof that discovery genuinely entered the gate.
          await discoveryEntered.future.timeout(const Duration(seconds: 5));

          await expectLater(initFuture, throwsA(isA<StateError>()));

          discoveryGate.complete(); // only now — after the presentation view has objectively already expired

          // Causal proof, not a margin: wait for the captured RAW operation
          // to genuinely settle, then for its own self-clearing bookkeeping.
          await rawSettlement!.catchError((_) {}).timeout(const Duration(seconds: 5));
          await waitForPendingInitializeSettlementToClear();

          expect(fakePlatform.calls.where((call) => call == 'initializeCamera'), isEmpty);
          expect(
            DashcamService.processOwnerCurrentForTest,
            isNull,
            reason: 'discovery-stage abandonment must release ownership too, not only the FIFO/contention checkpoints',
          );

          // A test-fixture artifact, not a production behavior this test
          // means to exercise: `discoveryEntered` already completed once for
          // `service`'s own call above, so it must be cleared before C's own
          // `initialize()` reaches `availableCameras()` too — otherwise the
          // fake's `Completer.complete()` throws "Future already completed".
          fakePlatform.availableCamerasEnteredForTest = null;
          fakePlatform.pendingAvailableCameras = null;

          c = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
          await c.initialize().timeout(const Duration(seconds: 1));
          expect(DashcamService.processOwnerCurrentForTest, same(c.processOwnerTokenForTest));
        } finally {
          if (!discoveryGate.isCompleted) discoveryGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          if (c != null) {
            await c.dispose().catchError((_) {});
          }
        }
      },
    );

    test(
      'R4-3 (§46) — abandonment/rejection can never clear uncertain: once the coordinator is fail-closed, '
      'every subsequent initialize() attempt on any instance — including this SAME one, reentrantly — '
      'is rejected without ever un-sticking it',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final errors = <String>[];
        final sub = service.errors.listen(errors.add);
        try {
          await service.initialize();
          fakePlatform.failDisposeWith = CameraException('native_dispose_failed', 'simulated dispose failure');
          await service.releaseIdleCamera();
          for (var i = 0; i < 50 && errors.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(DashcamService.processOwnerIsUncertainForTest, isTrue);
          final ownerToken = service.processOwnerTokenForTest;

          // Fase 16.2-R4.2B-R4 (§12/§46): a SECOND local dispose attempt on
          // the SAME already-`_isDisposed` controller succeeds locally (see
          // this file's own §12/§23/§42-J tests' identical doc) — clearing
          // `failDisposeWith` here confirms the invariant is about
          // [_DashcamProcessOwner.release] itself refusing while uncertain,
          // not merely about a native call continuing to fail.
          fakePlatform.failDisposeWith = null;
          await expectLater(
            service.initialize(),
            throwsA(isA<StateError>()),
            reason: 'rejected — uncertain has precedence over same-owner reentrancy (already covered by P3, reconfirmed here as part of this round\'s own abandonment-safety audit)',
          );
          expect(DashcamService.processOwnerIsUncertainForTest, isTrue, reason: 'must still be uncertain — no rejection/abandonment path may ever clear it');
          expect(DashcamService.processOwnerCurrentForTest, same(ownerToken), reason: 'ownership must not have moved or been released');

          // [_DashcamProcessOwner.release] is the single, unconditional
          // action every pre-emission abandonment checkpoint now funnels
          // through (see DashcamService._abandonInitializeBeforeNativeEmission's
          // own doc) — its own uncertain-check is what this test's real
          // guarantee rests on, structurally, regardless of which specific
          // caller/checkpoint invokes it.
        } finally {
          fakePlatform.failDisposeWith = null;
          DashcamService.simulateProcessRestartForTest(service.processOwnerTokenForTest);
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          await sub.cancel();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R1 — semanticStillValid composition, error origin tagging', () {
    test(
      'L8-A (§54) — process owner: a semanticStillValid predicate that goes false while genuinely '
      'waiting for a DIFFERENT instance\'s ownership causes clean abandonment once that ownership frees '
      '— zero native emission — preserving the same owner-release/deadline/uncertain contract as the '
      'existing FIFO/deadline-based abandonment',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final b = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final initGate = Completer<void>();
        var bStillValid = true;
        try {
          fakePlatform.pendingInitializeCamera = initGate;
          unawaited(service.initialize().catchError((_) {})); // A: genuinely stuck, holding ownership
          await Future<void>.delayed(Duration.zero);
          expect(DashcamService.processOwnerCurrentForTest, same(service.processOwnerTokenForTest));

          // B genuinely waits for A's ownership — its own semanticStillValid
          // predicate is still true at this point.
          var bError = false;
          final bFuture = b.initialize(semanticStillValid: () => bStillValid).then((_) {}, onError: (Object _) {
            bError = true;
          });
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(bError, isFalse, reason: 'B is still genuinely waiting for A\'s ownership');
          expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1), reason: 'only A so far');

          // Simulate a lifecycle invalidation for B while it is still
          // genuinely waiting for the coordinator.
          bStillValid = false;

          // A finally releases ownership.
          initGate.complete();
          await service.dispose();
          await bFuture;

          expect(bError, isFalse, reason: 'an abandoned pre-admission request resolves cleanly (StateError via its own presentation view only if genuinely still racing it), not as an unhandled error here');
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(1),
            reason: 'B must never touch the backend — its own semanticStillValid predicate abandoned it before acquiring',
          );
          expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'B correctly abandoned rather than acquiring — owner ends up free');
        } finally {
          if (!initGate.isCompleted) initGate.complete();
          await service.dispose().catchError((_) {});
          await b.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'L8-B (§54) — discovery: a semanticStillValid predicate that goes false while availableCameras() '
      'is genuinely pending causes abandonment once discovery resolves — zero initializeCamera — even '
      'with a LONG Stopwatch-based deadline (proving the predicate is a genuinely independent AND-term, '
      'not merely riding the existing deadline mechanism)',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          initializeCameraTimeout: const Duration(seconds: 10), // long — not what causes abandonment here
        );
        final discoveryGate = Completer<void>();
        var stillValid = true;
        try {
          fakePlatform.pendingAvailableCameras = discoveryGate;
          final callFuture = service.initialize(semanticStillValid: () => stillValid);
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Invalidate WHILE discovery is genuinely still pending.
          stillValid = false;
          discoveryGate.complete();

          // Fase 16.2-R4.3-R1: pre-native abandonment via semanticStillValid
          // resolves QUIETLY — no exception — matching the EXISTING
          // abandoned/!initialized contract this predicate is composed
          // into (the caller's own presentation deadline never fires here,
          // since initializeCameraTimeout is deliberately long; only the
          // semantic predicate causes this abandonment).
          await callFuture;
          await waitForPendingInitializeSettlementToClear();

          expect(
            fakePlatform.calls.where((c) => c == 'initializeCamera'),
            isEmpty,
            reason: 'discovery completing late must not authorize emission once semanticStillValid is false',
          );
          expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'abandonment must still release ownership');
        } finally {
          if (!discoveryGate.isCompleted) discoveryGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'L10-service (§40/§41/§56) — origin tagging: DashcamService.originatedErrors correctly tags a '
      'late startVideoCapturing() failure with the SPECIFIC controller it concerns — a later, genuinely '
      'DIFFERENT controller\'s own origin is never identical to an earlier one\'s, proving the origin '
      'comparison DashcamSessionController performs (a single identical() check) has a sound, correctly-'
      'differentiated value to compare against',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(minutes: 10),
          startVideoRecordingTimeout: const Duration(milliseconds: 50),
        );
        final origins = <Object?>[];
        final sub = service.originatedErrors.listen((e) => origins.add(e.origin));
        final startGateA = Completer<void>();
        final startGateB = Completer<void>();
        try {
          await service.initialize();
          final controllerA = service.previewController;
          expect(controllerA, isNotNull);

          fakePlatform.pendingStartVideoCapturing = startGateA;
          unawaited(service.startLoopRecording().catchError((_) {}));
          // Presentation deadline fires (50ms); the raw native START stays
          // retained/gated — nothing has been reported yet.
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(origins, isEmpty, reason: 'no late failure reported yet — the raw call is still genuinely pending');

          // The raw native START finally, genuinely fails, late.
          startGateA.completeError(CameraException('native_start_failed', 'late failure'));
          for (var i = 0; i < 200 && origins.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(origins, hasLength(1));
          expect(identical(origins.single, controllerA), isTrue, reason: 'the reported origin must be exactly the controller this failure concerns');

          // A second, genuinely different controller — proves origins are
          // NOT some shared/global sentinel, but a real, per-controller
          // identity that differs across instances.
          fakePlatform.pendingStartVideoCapturing = null;
          await service.releaseIdleCamera();
          await service.initialize();
          final controllerB = service.previewController;
          expect(identical(controllerA, controllerB), isFalse);

          fakePlatform.pendingStartVideoCapturing = startGateB;
          unawaited(service.startLoopRecording().catchError((_) {}));
          await Future<void>.delayed(const Duration(milliseconds: 150));
          startGateB.completeError(CameraException('native_start_failed', 'late failure B'));
          for (var i = 0; i < 200 && origins.length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(origins, hasLength(2));
          expect(identical(origins.last, controllerB), isTrue);
          expect(
            identical(origins.first, origins.last),
            isFalse,
            reason: 'two different controllers\' own late failures must carry two genuinely different origins',
          );
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGateA.isCompleted) startGateA.complete();
          if (!startGateB.isCompleted) startGateB.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          await sub.cancel();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.2 — targeted-cleanup FIFO re-validation (X9/X10)', () {
    test(
      'X9 (§25-§28/§51/§37, MANDATORY GATE, independent-review P2 + P1-B — "targeted release FIFO race" '
      '+ "targeted release libera process owner de G2") — releaseIdleCamera(expectedController: G1) is '
      'enqueued while G1 is still genuinely current, but an ALREADY-in-flight operation ahead of it in '
      'the FIFO (initialize()\'s own release-then-rebuild) replaces the current controller with G2 '
      'before this release\'s own closure ever gets its turn. Expected: the check is re-validated a '
      'SECOND time, exactly when the closure actually runs (not only once, synchronously, before '
      'enqueue) — a mismatch by then is a silent no-op over G2, never disposing it on G1\'s stale '
      'caller\'s behalf, AND (§37, strengthened this round) never releasing the global process owner '
      'either — the OLD version of this test passed despite that exact P1, since it never asserted on '
      'ownership at all',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final disposeGate = Completer<void>();
        try {
          await service.initialize();
          final controllerG1 = service.previewController!;
          final ownerToken = service.processOwnerTokenForTest;
          expect(DashcamService.processOwnerCurrentForTest, same(ownerToken), reason: 'test setup check: this service genuinely owns the process-wide coordinator after G1\'s own initialize()');

          // Gates the NEXT controller.dispose() call — this is what
          // initialize()'s own internal _doReleaseController calls to
          // release G1 before building G2.
          fakePlatform.pendingDispose = disposeGate;
          final initializeG2Future = service.initialize();

          // Causal proof G1's own dispose() call has genuinely been
          // reached (now gated) — G1 is still `_controller` at this exact
          // point (only nulled AFTER dispose() itself resolves).
          await waitForCallCount('dispose', 1);
          expect(service.previewController, same(controllerG1), reason: 'G1 is still current — its own dispose() is merely gated, not yet resolved');

          // The targeted release, issued WHILE G1 is still current — CHECK
          // 1 (synchronous, at call time) passes and this is enqueued,
          // behind the still-in-flight initialize()-for-G2 operation.
          final releaseFuture = service.releaseIdleCamera(expectedController: controllerG1);

          // Release the gate — G1's own dispose() resolves, initialize()
          // proceeds to build G2 to completion — entirely BEFORE the
          // targeted release's own enqueued closure can possibly get its
          // own turn (strict FIFO, this class's own doc §1).
          disposeGate.complete();
          await initializeG2Future;
          final controllerG2 = service.previewController;
          expect(identical(controllerG1, controllerG2), isFalse, reason: 'G2 must be a genuinely distinct controller');

          // The targeted release's own closure now finally runs.
          await releaseFuture;

          expect(service.previewController, same(controllerG2), reason: 'G2 must survive — G1\'s own stale release must never have touched it');
          expect(fakePlatform.disposedCameraIds, hasLength(1), reason: 'only G1 was ever disposed — G2 must not have been');
          // Fase 16.2-R4.3-R2.3 (§37, independent-review P1-B): the mismatch
          // above must NEVER have released the process-wide owner — G2 is
          // still open, still held by this SAME service.
          expect(
            DashcamService.processOwnerCurrentForTest,
            same(ownerToken),
            reason: 'targeted release mismatch must NEVER release the global process owner while G2 is still open — reopens physical camera exclusivity to a second service',
          );

          // Only once the REAL release (this service's own, unqualified
          // dispose() below) genuinely tears down G2 does ownership finally
          // free.
        } finally {
          fakePlatform.pendingDispose = null;
          if (!disposeGate.isCompleted) disposeGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          expect(DashcamService.processOwnerCurrentForTest, isNull, reason: 'after the REAL release (dispose()), the process owner must be freed normally');
        }
      },
    );

    test(
      'X10 (§27/§29/§51, independent-review P2, updated Fase 16.2-R4.3-R2.3 per P1-A — "targeted STOP '
      'FIFO race") — a targeted stopLoopRecording(expectedRecordingId:, expectedController:) for G1, '
      'issued WHILE a DIFFERENT caller\'s own hand-off teardown (releaseIdleCamera(), unqualified) has '
      'ALREADY materialized a real, gated _PendingNativeStop for that exact Recording. Since Fase '
      '16.2-R4.3-R2.3\'s own P1-A fix, this is no longer rejected by CHECK 1\'s bare `!_isRecording` '
      'guard — the targeted caller correctly ADOPTS the hand-off\'s own already-existing obligation '
      '(matching identity), never creates a second, independent native STOP, and its own presentation '
      'stays genuinely bounded to the SAME real gate the hand-off itself is waiting on — proving CHECK '
      '1\'s own target-match (§8) and CHECK 2\'s own "create fresh" branch (still present, still '
      'exercised whenever no existing/announced obligation is found — unweakened by this fix) coexist '
      'correctly with obligation adoption',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final stopGate = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();
          final controllerG1 = service.previewController!;
          final recordingIdG1 = service.activeRecordingId;
          expect(recordingIdG1, isNotNull);

          // Gate the native STOP a hand-off's own teardown will issue.
          fakePlatform.pendingStopVideoRecording = stopGate;

          // A hand-off begins (e.g. a superseding generation's own cleanup,
          // or a new session's own initialize()): releaseIdleCamera(),
          // unqualified, exactly like _stopCamera's own finally block or a
          // fresh initialize() call would issue.
          final handoffFuture = service.releaseIdleCamera();
          await waitForCallCount('stopVideoRecording', 1);
          expect(service.hasPendingNativeStop, isTrue, reason: 'test setup check: the hand-off\'s own teardown has genuinely materialized a real _PendingNativeStop for G1 by now');

          // A targeted stop for G1/R1, issued WHILE the hand-off's own
          // teardown is genuinely gated mid-flight.
          final staleStopOutcome = service.beginStopLoopRecording(expectedRecordingId: recordingIdG1, expectedController: controllerG1);

          // Fase 16.2-R4.3-R2.3 (P1-A): this call must ADOPT the hand-off's
          // own existing obligation — correct identity, never a fresh
          // native call, never resolved by CHECK 1's bare `!_isRecording`
          // guard.
          final handle = await staleStopOutcome.handle.timeout(const Duration(seconds: 2));
          expect(handle, isNotNull, reason: 'the targeted caller must adopt the hand-off\'s own already-existing STOP obligation, not observe null');
          expect(handle!.recordingId, recordingIdG1);
          expect(identical(handle.controller, controllerG1), isTrue);

          // The presentation must stay genuinely bounded to the SAME real
          // gate — proven directly: it does NOT resolve while the gate is
          // still held.
          var presentationResolved = false;
          unawaited(staleStopOutcome.presentation.then((_) => presentationResolved = true));
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(presentationResolved, isFalse, reason: 'the adopted obligation\'s own presentation must not resolve before the real, shared native STOP does');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'never a second, independent native STOP for the same Recording');

          // Release the real gate — both the hand-off's own future AND the
          // targeted caller's own adopted presentation/settlement resolve
          // from the SAME single native call.
          stopGate.complete();
          await handoffFuture;
          await staleStopOutcome.presentation;
          await handle.settlement;
          expect(service.previewController, isNull, reason: 'the hand-off\'s own real teardown completed normally');
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'exactly one native STOP total, shared by both callers');
        } finally {
          fakePlatform.pendingStopVideoRecording = null;
          if (!stopGate.isCompleted) stopGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.3 — strengthened direct assertions (§35)', () {
    test(
      'X12-direct (§35, strengthened — "assertar handle diretamente, não apenas efeito indireto") — the '
      'native STOP begins and settles essentially immediately (no gate at all). '
      'DashcamStopOutcome.handle is asserted DIRECTLY here: non-null, correct recordingId, correct '
      'controller identity, and its own settlement both completes successfully AND does so only once '
      '(no debugger needed to confirm any of this, unlike the independent review\'s own original '
      'verification of R2.2-X12)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          await service.initialize();
          await service.startLoopRecording();
          final controllerG1 = service.previewController!;
          final recordingIdG1 = service.activeRecordingId;
          expect(recordingIdG1, isNotNull);

          // No native gate of any kind.
          final outcome = service.beginStopLoopRecording();

          final handle = await outcome.handle.timeout(const Duration(seconds: 2));
          expect(handle, isNotNull, reason: 'a fast-settling STOP must still yield a real, non-null handle — never require a debugger to confirm');
          expect(handle!.recordingId, recordingIdG1, reason: 'the handle\'s own recordingId must match the Recording this call actually stopped');
          expect(identical(handle.controller, controllerG1), isTrue, reason: 'the handle\'s own controller must be the exact same object identity');

          // The settlement itself: completes successfully, terminal.
          await handle.settlement.timeout(const Duration(seconds: 2));
          await outcome.presentation;
          expect(service.hasPendingNativeStop, isFalse, reason: 'nothing left pending after a genuinely fast settle');
          expect(service.clips, hasLength(1));

          // Settlement is a Completer-backed Future — awaiting it a second
          // time must still resolve cleanly (idempotent), never hang/throw
          // differently.
          await handle.settlement;
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.3 — process owner preservation on targeted-release mismatch (P1-B)', () {
    test(
      'X14 (§20-§22/§37, MANDATORY GATE, independent-review P1-B — "process owner preservation" + '
      '"prova externa da exclusividade") — extends X9\'s own exact scenario with real, physical-'
      'exclusivity consequences: while G2 (this service\'s own) is still open, a genuinely SEPARATE, '
      'independent DashcamService instance is denied physical admission (its own initialize() cannot '
      'acquire the process-wide coordinator within its own short presentation deadline); once this '
      'service\'s own REAL release (dispose()) genuinely tears G2 down, that second instance is '
      'admitted normally. Also confirms the mismatch itself never touches "uncertain" fail-closed state.',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        final disposeGate = Completer<void>();
        DashcamService? other;
        try {
          await service.initialize();
          final controllerG1 = service.previewController!;
          final ownerToken = service.processOwnerTokenForTest;
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse, reason: 'test setup check');

          fakePlatform.pendingDispose = disposeGate;
          final initializeG2Future = service.initialize();
          await waitForCallCount('dispose', 1);

          final releaseFuture = service.releaseIdleCamera(expectedController: controllerG1);
          disposeGate.complete();
          await initializeG2Future;
          final controllerG2 = service.previewController;
          expect(identical(controllerG1, controllerG2), isFalse);
          await releaseFuture;

          // Same core P1-B property X9 already proves.
          expect(service.previewController, same(controllerG2), reason: 'G2 survives the targeted mismatch');
          expect(DashcamService.processOwnerCurrentForTest, same(ownerToken), reason: 'ownership stays with this service while G2 is open');
          expect(DashcamService.processOwnerIsUncertainForTest, isFalse, reason: 'a targeted release mismatch must never set/clear uncertain — it is a plain no-op, not a failure');

          // Fase 16.2-R4.3-R2.3 (§21, independent-review — "prova externa
          // da exclusividade"): a genuinely SEPARATE DashcamService
          // instance, sharing only the SAME static, process-wide
          // coordinator (never `service`'s own Dart-level state), must be
          // PHYSICALLY denied admission while G2 is still open — proving
          // the consequence, not just the internal field.
          other = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), initializeCameraTimeout: const Duration(milliseconds: 80));
          await expectLater(
            other.initialize(),
            throwsA(anything),
            reason: 'a second, independent service must NOT be admitted while the first service\'s own G2 is still genuinely open',
          );
          expect(other.previewController, isNull, reason: 'the second service must never have been granted a real controller');
          expect(
            fakePlatform.calls.where((c) => c == 'createCameraWithSettings'),
            hasLength(2),
            reason: 'only G1\'s own + G2\'s own creations (both belong to the first service) — the second service never got far enough to create its own',
          );

          // NOW the real release — this service's own, unqualified
          // dispose() — genuinely tears G2 down.
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
          await waitForProcessOwner(null);

          // The second service can now progress normally, through the
          // EXACT SAME production admission path (no test-only bypass).
          await other.initialize().timeout(const Duration(seconds: 5));
          expect(other.previewController, isNotNull, reason: 'the second service must now be admitted normally, via the same production protocol');
          expect(DashcamService.processOwnerCurrentForTest, same(other.processOwnerTokenForTest));
        } finally {
          fakePlatform.pendingDispose = null;
          if (!disposeGate.isCompleted) disposeGate.complete();
          await service.dispose().catchError((_) {});
          if (other != null) {
            await other.dispose().catchError((_) {});
          }
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.4 — durable announcement resolution (P1-A #2)', () {
    test(
      'X17 (§13/§14, MANDATORY GATE, independent-review P1-A #2 — "announcement discovery expires") — '
      'a native START occupies the FIFO (genuinely in flight, gated); an explicit, unqualified stop '
      'claims/announces itself and enqueues its own finalize closure BEHIND that still-running START — '
      'nothing has materialized a real _PendingNativeStop yet. A SECOND, independent caller adopts that '
      'announcement via beginStopLoopRecording() with a short stopVideoRecordingTimeout (50ms). Expected: '
      'this call\'s own presentation resolves bounded (~50ms) via the timeout, but '
      'DashcamStopOutcome.handle must NOT resolve to null just because presentation did — it keeps '
      'waiting on the announcement\'s own durable resolution. Once the FIFO frees up and the real STOP '
      'genuinely materializes and settles, the adopter still receives the correct, non-null handle — '
      'exactly one native STOP total, exactly one clip produced',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: const Duration(milliseconds: 50));
        final startGate = Completer<void>();
        try {
          await service.initialize();

          // Occupy the FIFO with a genuinely in-flight native START.
          fakePlatform.pendingStartVideoCapturing = startGate;
          unawaited(service.startLoopRecording());
          await waitForCallCount('startVideoCapturing', 1);
          expect(service.isRecording, isTrue, reason: 'test setup check: startLoopRecording()\'s own synchronous intent prefix already flipped this, even though the native call is still gated');
          expect(service.activeRecordingId, isNull, reason: 'test setup check: no Recording identity exists yet — the native START has not resolved');

          // An explicit, unqualified stop: claims the shared announcement
          // and enqueues its own finalize closure BEHIND the still-running
          // (gated) START — genuinely announced, not yet materialized.
          unawaited(service.stopLoopRecording());
          expect(service.isRecording, isFalse, reason: 'test setup check: the explicit stop\'s own synchronous intent prefix already flipped this');
          expect(service.hasPendingNativeStop, isFalse, reason: 'test setup check: nothing has materialized yet — the finalize closure is still queued behind the gated START');

          // A second, independent caller adopts the SAME announcement.
          final outcome = service.beginStopLoopRecording();

          var handleResolved = false;
          unawaited(outcome.handle.then((_) => handleResolved = true));

          // Wait comfortably past the short presentation deadline, while
          // the START (and therefore the STOP behind it) stays gated.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await outcome.presentation.timeout(
            const Duration(milliseconds: 1),
            onTimeout: () => fail('presentation must already be resolved (bounded by the short stopVideoRecordingTimeout) well before this point'),
          );
          expect(
            handleResolved,
            isFalse,
            reason:
                'Fase 16.2-R4.3-R2.4 P1-A #2: the presentation deadline expiring must NEVER retroactively resolve the physical handle discovery as "nothing" — the real obligation is still genuinely pending behind the gated START',
          );
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), isEmpty, reason: 'the real native STOP has not even been issued yet — still queued behind the gated START');

          // Release the FIFO — the START resolves, then the STOP's own
          // finalize closure finally gets its turn and genuinely runs.
          startGate.complete();

          final handle = await outcome.handle.timeout(const Duration(seconds: 2));
          expect(handle, isNotNull, reason: 'once the announcement genuinely materializes, the durable continuation must still deliver the real handle — never lost to the earlier presentation timeout');
          expect(handle!.recordingId, isNotNull);
          expect(handle.recordingId, service.activeRecordingId, reason: 'the handle\'s own recordingId matches the SAME Recording this whole scenario concerned');
          expect(identical(handle.controller, service.previewController), isTrue, reason: 'the handle\'s own controller is the SAME Recording this whole scenario concerned');

          await handle.settlement.timeout(const Duration(seconds: 2));
          await outcome.presentation;

          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'exactly one native STOP total for the whole scenario');
          expect(service.clips, hasLength(1), reason: 'the ONE physical clip this scenario produces must genuinely exist');
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X17-B (§9/§11/§15, terminal no-stop — "target deixa de ser válido") — a real, unqualified stop is '
      'announced and enqueued for G1 (not gated — resolves for real, essentially immediately); a SECOND '
      'caller adopts that SAME announcement via beginStopLoopRecording() targeting a DIFFERENT, '
      'mismatched expectedRecordingId — one of the announcement terminal paths this class\'s own doc '
      '(§11) enumerates ("target deixa de ser válido"). A deliberately LONG stopVideoRecordingTimeout '
      '(30s) is used specifically so a pass driven only by the (removed) timeout-based resolveNothing() '
      'could not accidentally still pass — this call\'s own handle must resolve to null promptly, from '
      'the REAL terminal mismatch, never from waiting out that 30s deadline. The REAL stop, for the '
      'caller it actually belongs to, still succeeds normally',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: const Duration(seconds: 30));
        try {
          await service.initialize();
          await service.startLoopRecording();
          final recordingIdG1 = service.activeRecordingId!;

          // The real, genuine stop — never gated, resolves quickly.
          final realStopFuture = service.stopLoopRecording();
          expect(service.hasPendingNativeStop, isFalse, reason: 'test setup check: outcome1\'s own closure has not had a chance to run yet — only announced');

          // A second caller adopts the SAME announcement, but targets a
          // Recording identity that was never going to match it.
          final outcome = service.beginStopLoopRecording(expectedRecordingId: recordingIdG1 + 999);

          final handle = await outcome.handle.timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('handleResolution must reach a REAL terminal null once the announcement genuinely resolves — it must not hang, and must not depend on the deliberately long (30s) presentation timeout to do so'),
          );
          expect(handle, isNull, reason: 'a genuine terminal mismatch resolution — this announcement was never going to satisfy THIS caller\'s own target, resolved fast, well inside the 30s presentation deadline');
          await outcome.presentation.timeout(const Duration(seconds: 2));

          // The REAL stop, for the Recording it actually concerned, still
          // completed normally — the mismatched adopter never disturbed it.
          await realStopFuture.timeout(const Duration(seconds: 2));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1));
          expect(service.clips, hasLength(1));
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.5 — stop intent identity (P1-3 / P1-2)', () {
    test(
      'X22 (§11/§12, MANDATORY GATE, independent-review P1-3 exact reproduction — "announcement compartilhado '
      'entre rotation e explicit stop") — a rotation intent is pending (claimed by its own tick, its finalize '
      'queued behind a stalled restart) and the camera is known-unavailable, so ROTATION\'s own policy will '
      'decline to stop and publish `null`. An explicit, unqualified stop arrives WHILE that rotation intent is '
      'still unresolved. Both are serialized by the one FIFO: rotation publishes `null`, and only THEN does the '
      'explicit stop\'s own finalize find the Recording genuinely active and issue a real STOP. Expected: the '
      'explicit stop receives ITS OWN real handle (non-null, its own intent id, the Recording it actually '
      'stopped) — rotation\'s `null` never terminally concludes it. The two are different intents with different '
      'purposes and each carries its own outcome; exactly one native STOP per Recording, none duplicated',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        service.trackStopIntentsForTest = true;
        final pendingRestart = Completer<void>();
        DashcamStopOutcome? outcome;
        try {
          await service.initialize();
          await service.startLoopRecording();
          final recordingIdA = service.activeRecordingId;
          expect(recordingIdA, isNotNull);

          // Segment A rotates normally into B, but B's own restart is
          // stalled — rotation's tick-1 operation occupies the FIFO.
          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          await waitForCallCount('startVideoCapturing', 2);

          // NOW the camera becomes known-unavailable: rotation's own policy
          // (_FinalizeReason.rotation) will decline to stop B.
          service.notifyAppBackgrounded();
          expect(service.cameraKnownUnavailable, isTrue);

          // Causal proof (not a fixed sleep): a later rotation tick has
          // claimed its own intent and it is still unresolved.
          DashcamStopIntentSnapshot? pendingRotation;
          for (var attempt = 0; attempt < 100 && pendingRotation == null; attempt++) {
            final unresolved = service.stopIntentsForTest.where((intent) => intent.purpose == 'rotation' && !intent.resolved);
            if (unresolved.isNotEmpty) {
              pendingRotation = unresolved.last;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(pendingRotation, isNotNull, reason: 'test setup: a rotation intent must be pending (unresolved) before the explicit stop arrives');
          final rotationIntentId = pendingRotation!.id;

          // The explicit stop arrives WHILE rotation's intent is unresolved.
          outcome = service.beginStopLoopRecording();
          expect(outcome.intentId, isNot(equals(rotationIntentId)), reason: 'the explicit stop must own its OWN intent, never share the rotation intent');

          // Release the stalled restart — B genuinely, natively starts;
          // rotation's own finalize then runs, sees B + cameraKnownUnavailable
          // and publishes `null`; the explicit stop's finalize then runs.
          pendingRestart.complete();

          final handle = await outcome.handle.timeout(
            const Duration(seconds: 3),
            onTimeout: () => fail('the explicit stop\'s own handle must resolve (to its own real stop) — never hang'),
          );
          expect(
            handle,
            isNotNull,
            reason: 'P1-3: rotation\'s `null` ("rotation declined") must NOT terminally conclude the explicit stop — its own real STOP found a genuine Recording',
          );
          expect(handle!.intentId, outcome.intentId, reason: 'the handle belongs to the explicit stop\'s own intent');
          final recordingIdB = handle.recordingId;
          expect(recordingIdB, isNotNull);
          expect(recordingIdB, isNot(equals(recordingIdA)), reason: 'the explicit stop concluded Recording B, not the one rotation already finalized');

          await handle.settlement.timeout(const Duration(seconds: 3));
          await outcome.presentation.timeout(const Duration(seconds: 3));

          final explicitIntentId = outcome.intentId;
          final intents = service.stopIntentsForTest;
          final rotation = intents.firstWhere((intent) => intent.id == rotationIntentId);
          final explicit = intents.firstWhere((intent) => intent.id == explicitIntentId);
          expect(rotation.purpose, 'rotation');
          expect(explicit.purpose, 'explicitStop');
          expect(rotation.purpose, isNot(equals(explicit.purpose)));
          expect(rotation.id, isNot(equals(explicit.id)));
          expect(rotation.resolved, isTrue);
          expect(rotation.resolvedRecordingId, isNull, reason: 'rotation legitimately resolved to "no stop" (its own policy) — contract-conformant');
          expect(explicit.resolved, isTrue);
          expect(explicit.resolvedRecordingId, recordingIdB, reason: 'the explicit intent resolved to the real stop of Recording B');

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(2),
            reason: 'exactly two native STOPs: A (rotation, normal) and B (the explicit stop, after rotation declined) — none duplicated',
          );
          expect(service.clips, hasLength(2));
        } finally {
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          fakePlatform.pendingStartVideoCapturing = null;
          if (outcome != null) await outcome.presentation.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X23-svc (§18, independent-review P1-2 exact reproduction, service side — "handle legítimo rejeitado por '
      'RecordingId snapshot antigo") — Recording #1 completes normally; a START for Recording #2 is issued and '
      'genuinely retained (gated) while activeRecordingId still reflects #1; an untargeted stop is issued in that '
      'window with a short presentation deadline, which expires; the START then finishes and the stop\'s own '
      'intent materializes a REAL stop of Recording #2. Expected: the late handle is delivered — its recordingId '
      'legitimately differs from the pre-issuance snapshot (#1), yet it carries the SAME intent id as the outcome '
      'that issued the stop (the service-side guarantee the caller trusts instead of the stale snapshot); exactly '
      'one physical STOP for #2',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: const Duration(milliseconds: 50));
        service.trackStopIntentsForTest = true;
        final startGate = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording();
          // Fase 16.2-R4.4-R1-T-Rm (R-m X23-svc, test-only): see [stopNormally].
          await stopNormally(service, () => service.stopLoopRecording());
          expect(service.clips, hasLength(1), reason: 'test setup: Recording #1\'s clip');
          final snapshotBeforeStop = service.activeRecordingId;

          fakePlatform.pendingStartVideoCapturing = startGate;
          unawaited(service.startLoopRecording());
          await waitForCallCount('startVideoCapturing', 2);
          expect(service.activeRecordingId, snapshotBeforeStop, reason: 'test setup: Recording #2 has not materialized — the identity snapshot still names #1');

          final outcome = service.beginStopLoopRecording();
          await outcome.presentation.timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('presentation must be bounded by the short stopVideoRecordingTimeout'),
          );
          var handleResolved = false;
          unawaited(outcome.handle.then((_) => handleResolved = true));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(handleResolved, isFalse, reason: 'the real obligation is still genuinely pending behind the gated START');

          startGate.complete();
          final handle = await outcome.handle.timeout(const Duration(seconds: 3));
          expect(handle, isNotNull, reason: 'P1-2: the legitimate late handle must not be lost');
          expect(handle!.recordingId, isNot(equals(snapshotBeforeStop)), reason: 'the stale snapshot names #1 — the handle is for #2');
          expect(handle.recordingId, service.activeRecordingId);
          expect(handle.intentId, outcome.intentId, reason: 'intent identity == handle intent identity: the trust anchor that replaces the snapshot');

          await handle.settlement.timeout(const Duration(seconds: 3));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'one STOP for #1 and exactly one for #2');
          expect(service.clips, hasLength(2));
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.5 — producer-bound clip provenance (P1-1)', () {
    test(
      'X24 (§35, MANDATORY GATE, independent-review P1-1 — "clip owner before exposure") — at the CLOSEST '
      'observable point after a clip is published (a test seam invoked synchronously right after `_clips.add`, '
      'before `_enforceStorageQuota`\'s first await — exactly the window the reviewer exploited) the clip is '
      'visible in DashcamService.clips AND already carries its producer token. Never "clips=1 / owner=0". The '
      'hook is then HELD open (the finalize has not concluded) and provenance is read again from OUTSIDE the '
      'service while the clip is still visible and finalize still unfinished',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: const Duration(milliseconds: 50));
        final publishedGate = Completer<void>();
        final atPublication = <({bool visible, Object? token, int? recordingId})>[];
        final published = Completer<void>();
        try {
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'tokenA');
          final recordingId = service.activeRecordingId;

          service.afterClipPublishedHookForTest = (clip) async {
            atPublication.add((visible: service.clips.contains(clip), token: clip.producerToken, recordingId: clip.recordingId));
            if (!published.isCompleted) published.complete();
            await publishedGate.future;
          };

          final stopping = service.stopLoopRecording();
          await published.future.timeout(const Duration(seconds: 3));

          expect(atPublication, hasLength(1));
          expect(atPublication.single.visible, isTrue, reason: 'the clip is publicly visible at this instant');
          expect(atPublication.single.token, 'tokenA', reason: 'AND its producer provenance already exists — no instant of "visible without provenance"');
          expect(atPublication.single.recordingId, recordingId);

          // Read from OUTSIDE, while the service is still mid-finalize (held
          // before quota enforcement): visible ⇒ provenance present.
          expect(service.clips, hasLength(1));
          expect(service.clips.single.producerToken, 'tokenA');
          expect(service.hasPendingNativeStop, isTrue, reason: 'the producing finalize has NOT concluded — the clip is exposed early, provenance-first');

          await stopping.timeout(const Duration(seconds: 3));
          publishedGate.complete();
          await waitForPendingStopToClear();
          expect(service.clips.single.producerToken, 'tokenA');
        } finally {
          service.afterClipPublishedHookForTest = null;
          if (!publishedGate.isCompleted) publishedGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X24-unknown (§30) — a Recording started WITHOUT a producer token yields clips with UNKNOWN provenance '
      '(`null`), never a token borrowed from anywhere else; consumers must not adopt them',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          await service.initialize();
          await service.startLoopRecording();
          await service.stopLoopRecording();
          expect(service.clips, hasLength(1));
          expect(service.clips.single.producerToken, isNull);
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X24-rotation (§32) — segment rotation inside one logical session creates a NEW Recording id but keeps the '
      'SAME producer token: every clip of every segment carries it (no clip is attributed to "whichever segment '
      'happened to be current"); a later logical session that starts with a different token yields clips '
      'carrying THAT token, not the earlier one',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(milliseconds: 30));
        try {
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'tokenA');
          // Harness T5: no stop deadline is configured here (production
          // default). The setup used to poll for "no native stop pending"
          // WHILE the 30 ms rotation timer was still running — a transient
          // state: once a rotation's finalize (a REAL File.copy of the clip)
          // outlasts a tick, the next rotation is already queued behind it
          // and a stop is pending at every poll. It now waits for a monotonic
          // fact instead: the third startVideoCapturing, only issued once two
          // rotations have been finalized and restarted. Bounded; fails
          // explicitly.
          await waitForCallCount('startVideoCapturing', 3, maxIterations: 200);
          await service.stopLoopRecording();
          // The stop cancelled the timer, so "nothing pending" is final from
          // here on, no longer transient. One event-loop turn first: rotation
          // ticks that fired before the stop may still be queued behind it.
          // They find nothing recording and must have run before the next
          // session's START below, whose intent they would otherwise read as
          // their own cue to restart.
          await Future<void>.delayed(Duration.zero);
          await waitForPendingStopToClear();

          final producedByA = service.clips.toList();
          expect(producedByA.length, greaterThanOrEqualTo(3), reason: 'two rotations + the final stop');
          expect(producedByA.every((clip) => clip.producerToken == 'tokenA'), isTrue, reason: 'rotation preserves the logical session\'s producer token');
          expect(producedByA.map((clip) => clip.recordingId).toSet(), hasLength(producedByA.length), reason: 'each segment is a distinct Recording');

          // A new logical session (new token) on the same service.
          await service.startLoopRecording(clipOwnerToken: 'tokenB');
          await service.stopLoopRecording();
          await waitForPendingStopToClear();
          final newest = service.clips.last;
          expect(newest.producerToken, 'tokenB', reason: 'a new logical session gets its own producer token');
          expect(service.clips.where((clip) => clip.producerToken == 'tokenA'), hasLength(producedByA.length), reason: 'earlier clips keep their producer');
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    // Fase 16.2-R4.4-R2 — ADAPTED (owner decision O4; D0 RK2).
    // BEFORE: a 0 MB quota made the service's own in-FIFO enforcement evict
    //   both clips, and their provenance with them (`clips` empty).
    // WHY superseded: the service enforces no quota any more; the physical
    //   quota evicts files in the index FIFO and the controller then calls
    //   `forgetClips` — that call is now where a clip leaves `clips`.
    // AFTER: (a) the 0 MB quota evicts nothing in the service — both clips and
    //   their tokens stay; (b) `forgetClips` of A's file removes A and its
    //   provenance in ONE synchronous step — no separate map, nothing left that
    //   names tokenA — and leaves B. End to end (pass → forgetClips → claims):
    //   X511.
    // NEGATIVE CONTROL: M9 (in-FIFO quota back) fails (a); a `forgetClips` that
    //   removes nothing fails (b).
    test(
      'X24-quota (§38) — provenance is bounded by the clips themselves: it lives ON the clip object, so a clip '
      'evicted by storage-quota enforcement takes its provenance with it in the same step (no separate map that '
      'needs a later pruning pass, nothing left referencing an evicted clip\'s producer)',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
        try {
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'tokenA');
          await service.stopLoopRecording();
          expect(service.clips.where((clip) => clip.producerToken == 'tokenA'), hasLength(1));

          service.updateConfig(config(storageQuotaMb: 0));
          await service.startLoopRecording(clipOwnerToken: 'tokenB');
          await service.stopLoopRecording();
          await waitForPendingStopToClear();

          expect(service.clips.map((clip) => clip.producerToken), ['tokenA', 'tokenB'], reason: 'no quota in the camera FIFO: nothing evicted here');
          final pathA = service.clips.first.file.path;
          service.forgetClips({pathA});
          expect(service.clips.map((clip) => clip.producerToken), ['tokenB'], reason: 'A and its provenance left in the same step');
          expect(service.clips.where((clip) => clip.producerToken == 'tokenA' || clip.file.path == pathA), isEmpty, reason: 'no provenance outlives the clip it describes');
        } finally {
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X27 (§41, combination — rotation intent + explicit stop intent + new segments, with producer tokens) — the '
      'X22 scenario (rotation declines with `null`, an explicit stop arrives while that intent is pending) run '
      'with producer tokens: each intent receives its own correct result, EVERY clip carries the token of the '
      'session that produced it, the explicit stop\'s handle carries that same token, and the explicit stop never '
      'terminates `null` because of the rotation\'s result. A later logical session then produces its own clip '
      'under its own token',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        service.trackStopIntentsForTest = true;
        final pendingRestart = Completer<void>();
        DashcamStopOutcome? outcome;
        try {
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'tokenA');

          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          await waitForCallCount('startVideoCapturing', 2);
          service.notifyAppBackgrounded();

          DashcamStopIntentSnapshot? pendingRotation;
          for (var attempt = 0; attempt < 100 && pendingRotation == null; attempt++) {
            final unresolved = service.stopIntentsForTest.where((intent) => intent.purpose == 'rotation' && !intent.resolved);
            if (unresolved.isNotEmpty) {
              pendingRotation = unresolved.last;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(pendingRotation, isNotNull, reason: 'test setup: a rotation intent is pending');

          outcome = service.beginStopLoopRecording();
          pendingRestart.complete();
          final handle = await outcome.handle.timeout(const Duration(seconds: 3));
          expect(handle, isNotNull, reason: 'the explicit stop must never terminate null because of the rotation\'s null');
          expect(handle!.intentId, outcome.intentId);
          expect(handle.intentId, isNot(equals(pendingRotation!.id)));
          expect(handle.producerToken, 'tokenA', reason: 'the handle carries the producer of the Recording it stops');
          await handle.settlement.timeout(const Duration(seconds: 3));
          await outcome.presentation.timeout(const Duration(seconds: 3));

          expect(service.clips, hasLength(2));
          expect(service.clips.every((clip) => clip.producerToken == 'tokenA'), isTrue, reason: 'every clip carries the session that produced it');

          // A later logical session — new segment, its own token.
          fakePlatform.pendingStartVideoCapturing = null;
          service.updateConfig(config());
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'tokenB');
          await service.stopLoopRecording();
          await waitForPendingStopToClear();
          expect(service.clips, hasLength(3));
          expect(service.clips.last.producerToken, 'tokenB');
          expect(service.clips.where((clip) => clip.producerToken == 'tokenA'), hasLength(2));
        } finally {
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          fakePlatform.pendingStartVideoCapturing = null;
          if (outcome != null) await outcome.presentation.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.5 — incompatible-intent barrier adoption and request identity', () {
    test(
      'X22-B (§9/§10, barrier + adoption of a REAL stop, the converse of X22) — a rotation intent is pending and '
      'the camera is NOT known-unavailable, so rotation WILL issue a real STOP of the Recording that is about to '
      'start; an explicit, unqualified stop arrives while that rotation intent is still unresolved. Expected: the '
      'explicit stop takes the rotation intent as a BARRIER and, when rotation materializes its real stop, ADOPTS '
      'it — its own handle is non-null, carries its OWN intent id and the Recording rotation stopped — with '
      'exactly one native STOP per Recording (the explicit stop never emits a second, duplicate STOP for the same '
      'Recording)',
      () async {
        service = DashcamService(
          config: config(),
          segmentDuration: const Duration(milliseconds: 30),
          startVideoRecordingTimeout: const Duration(seconds: 5),
        );
        service.trackStopIntentsForTest = true;
        final pendingRestart = Completer<void>();
        DashcamStopOutcome? outcome;
        try {
          await service.initialize();
          await service.startLoopRecording();
          final recordingIdA = service.activeRecordingId;

          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear();
          await waitForCallCount('startVideoCapturing', 2);
          expect(service.cameraKnownUnavailable, isFalse, reason: 'test setup: rotation will really stop the next Recording');

          DashcamStopIntentSnapshot? pendingRotation;
          for (var attempt = 0; attempt < 100 && pendingRotation == null; attempt++) {
            final unresolved = service.stopIntentsForTest.where((intent) => intent.purpose == 'rotation' && !intent.resolved);
            if (unresolved.isNotEmpty) {
              pendingRotation = unresolved.last;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(pendingRotation, isNotNull, reason: 'test setup: a rotation intent is pending');

          outcome = service.beginStopLoopRecording();
          expect(outcome.intentId, isNot(equals(pendingRotation!.id)));
          pendingRestart.complete();

          final handle = await outcome.handle.timeout(const Duration(seconds: 3), onTimeout: () => fail('the explicit stop\'s handle must resolve'));
          expect(handle, isNotNull, reason: 'the explicit stop adopts rotation\'s REAL stop of the Recording it also concerns');
          expect(handle!.intentId, outcome.intentId);
          expect(handle.recordingId, isNot(equals(recordingIdA)));
          await handle.settlement.timeout(const Duration(seconds: 3));
          await outcome.presentation.timeout(const Duration(seconds: 3));

          final explicitIntentId = outcome.intentId;
          final intents = service.stopIntentsForTest;
          final rotation = intents.firstWhere((intent) => intent.id == pendingRotation!.id);
          final explicit = intents.firstWhere((intent) => intent.id == explicitIntentId);
          expect(rotation.resolvedRecordingId, handle.recordingId, reason: 'rotation resolved to a real stop of that Recording');
          expect(explicit.resolvedRecordingId, handle.recordingId, reason: 'the explicit intent adopted the SAME real stop');
          expect(rotation.id, isNot(equals(explicit.id)));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'A (rotation tick 1) and B (rotation tick 2, adopted) — no duplicate STOP');
          expect(service.clips, hasLength(2));
        } finally {
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          fakePlatform.pendingStartVideoCapturing = null;
          if (outcome != null) await outcome.presentation.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X22-C (§9, request identity across a START) — an explicit stop, then a new START, then a second explicit '
      'stop are three DISTINCT requests: the second stop is not a join of the first (a START was issued between '
      'them), each outcome carries its own intent id, and exactly one physical STOP results',
      () async {
        service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10), stopVideoRecordingTimeout: const Duration(milliseconds: 50));
        service.trackStopIntentsForTest = true;
        final startGate = Completer<void>();
        try {
          await service.initialize();
          fakePlatform.pendingStartVideoCapturing = startGate;
          unawaited(service.startLoopRecording());
          await waitForCallCount('startVideoCapturing', 1);

          final first = service.beginStopLoopRecording();
          unawaited(service.startLoopRecording());
          final second = service.beginStopLoopRecording();
          expect(second.intentId, isNot(equals(first.intentId)), reason: 'a START was issued between the two stops — they are not the same request');

          startGate.complete();
          final firstHandle = await first.handle.timeout(const Duration(seconds: 3));
          final secondHandle = await second.handle.timeout(const Duration(seconds: 3));
          expect(firstHandle, isNotNull, reason: 'the first stop concludes the Recording that was starting');
          expect(firstHandle!.intentId, first.intentId);
          expect(secondHandle, isNull, reason: 'the second stop\'s own START was superseded by that very stop — no Recording exists for it, and it must not receive the first\'s stop');
          await firstHandle.settlement.timeout(const Duration(seconds: 3));
          await first.presentation.timeout(const Duration(seconds: 3));
          await second.presentation.timeout(const Duration(seconds: 3));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(1), reason: 'exactly one physical STOP');
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (!startGate.isCompleted) startGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });

  group('Fase 16.2-R4.3-R2.6 — transitive stop discovery (P1-B)', () {
    /// Reproduces the reviewer's chain setup: Recording #1 already produced its
    /// clip; a START for Recording #2 is retained (gated) while
    /// `activeRecordingId` still names #1 — so intents queued now will be
    /// serviced only after #2 exists.
    Future<({int id1, CameraController controller1, Completer<void> startGate})> arrangeChainSetup() async {
      await service.initialize();
      await service.startLoopRecording(clipOwnerToken: 'A');
      await service.stopLoopRecording();
      final id1 = service.activeRecordingId!;
      final controller1 = service.previewController!;
      final startGate = Completer<void>();
      fakePlatform.pendingStartVideoCapturing = startGate;
      unawaited(service.startLoopRecording(clipOwnerToken: 'A'));
      await waitForCallCount('startVideoCapturing', 2);
      return (id1: id1, controller1: controller1, startGate: startGate);
    }

    Future<DashcamPendingStopHandle?> handleOf(DashcamStopOutcome outcome) => outcome.handle.timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail('a stop intent\'s handle must always resolve (to a stop or to null) — never hang'),
    );

    DashcamService buildChainService({
      Duration segmentDuration = const Duration(minutes: 10),
      Duration stopVideoRecordingTimeout = const Duration(milliseconds: 50),
    }) {
      return DashcamService(
        config: config(),
        segmentDuration: segmentDuration,
        stopVideoRecordingTimeout: stopVideoRecordingTimeout,
        startVideoRecordingTimeout: const Duration(seconds: 5),
      );
    }

    test(
      'X35 (§33, MANDATORY GATE, independent-review P1-B exact reproduction — "three-intent chain") — an explicit '
      'stop (2) is queued behind a retained START and will stop Recording #2; a targeted cleanup (3) aimed at the '
      'stale Recording #1 is issued next (its own target will NOT match what 2 stops, so it resolves `null`); a '
      'second explicit stop (4) is issued last. R2.5 let 4 observe only 3, so 3\'s `null` hid the real physical '
      'stop. Expected: intent 4 DISCOVERS it through the ancestry — non-null handle for the right Recording, its '
      'OWN logical intent id (not 2\'s), the SAME physical stop identity as 2\'s, produced by intent 2 — with zero '
      'duplicate native STOP',
      () async {
        service = buildChainService();
        service.trackStopIntentsForTest = true;
        Completer<void>? startGate;
        try {
          final setup = await arrangeChainSetup();
          startGate = setup.startGate;

          final e2 = service.beginStopLoopRecording();
          final t3 = service.beginStopLoopRecording(expectedRecordingId: setup.id1, expectedController: setup.controller1);
          final e4 = service.beginStopLoopRecording();
          expect({e2.intentId, t3.intentId, e4.intentId}, hasLength(3), reason: 'three distinct logical intents');
          expect(service.maxStopIntentAncestryForTest, greaterThanOrEqualTo(2), reason: 'intent 4 observes the WHOLE unresolved chain (3 and 2), not only its predecessor');

          startGate.complete();
          final h2 = await handleOf(e2);
          final h3 = await handleOf(t3);
          final h4 = await handleOf(e4);

          expect(h2, isNotNull, reason: 'intent 2 stops the Recording that was still starting');
          expect(h3, isNull, reason: 'intent 3\'s stale target does not match — it legitimately resolves null');
          expect(h4, isNotNull, reason: 'P1-B: 3\'s intermediate null must NOT hide the physical stop 2 produced — 4 discovers it transitively');
          expect(h4!.recordingId, h2!.recordingId, reason: 'the SAME Recording');
          expect(h4.intentId, e4.intentId, reason: 'the logical intent stays 4');
          expect(h4.intentId, isNot(equals(h2.intentId)), reason: 'logical intent 4 is not logical intent 2');
          expect(h4.physicalStopId, h2.physicalStopId, reason: 'both intents refer to the ONE physical stop');
          expect(h4.producerIntentId, e2.intentId, reason: 'that physical stop was issued by intent 2');
          expect(h2.producerIntentId, e2.intentId);
          expect(h4.producerToken, 'A');

          await h2.settlement.timeout(const Duration(seconds: 3));
          await h4.settlement.timeout(const Duration(seconds: 3));
          await Future.wait([e2.presentation, t3.presentation, e4.presentation]).timeout(const Duration(seconds: 3));

          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'Recording #1 (earlier) + Recording #2 exactly once — no duplicate STOP');
          expect(service.clips, hasLength(2));
          expect(service.clips.every((clip) => clip.producerToken == 'A'), isTrue);

          final intents = service.stopIntentsForTest;
          expect(intents.firstWhere((i) => i.id == e4.intentId).resolvedPhysicalStopId, intents.firstWhere((i) => i.id == e2.intentId).resolvedPhysicalStopId);
          expect(service.liveStopIntentCountForTest, 0, reason: 'lineage is bounded: nothing live once every intent concluded');
          expect(service.stopIntentAncestryEntriesForTest, 0);
        } finally {
          fakePlatform.pendingStartVideoCapturing = null;
          if (startGate != null && !startGate.isCompleted) startGate.complete();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X36 (§34, rotation chain) — a rotation intent will (camera available) issue a REAL stop of the Recording '
      'about to start; a targeted cleanup aimed at the stale earlier Recording resolves `null` (target mismatch); '
      'a later explicit stop must still find the rotation\'s physical stop through the ancestry — never receive '
      '`null` just because the cleanup in between refused',
      () async {
        // Harness T5: classified by its own contract, not by proximity to X37.
        // X36 holds a native START (pendingRestart), never a native stop, and
        // no step of it needs a service deadline to expire: with the chain
        // builder's 50 ms stop deadline and with the production one it issues
        // the same native calls, intents and clips. That 50 ms only bounded
        // rotation 1's REAL clip finalize (the fake camera's own file write
        // plus File.copy): past it the service, correctly, marks the camera
        // unavailable and skips the restart this chain is built on — a setup
        // failure, not a finding. X36 therefore runs with the production
        // default (5 s), and its setup waits by condition with a finite
        // deadline of its own (200 x 10 ms, explicit fail(), shorter than the
        // service's).
        service = buildChainService(segmentDuration: const Duration(milliseconds: 30), stopVideoRecordingTimeout: const Duration(seconds: 5));
        service.trackStopIntentsForTest = true;
        final pendingRestart = Completer<void>();
        DashcamStopOutcome? explicit;
        DashcamStopOutcome? targeted;
        try {
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'A');
          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear(maxIterations: 200);
          await waitForCallCount('startVideoCapturing', 2, maxIterations: 200);
          expect(service.cameraKnownUnavailable, isFalse, reason: 'test setup: rotation will really stop the next Recording');

          DashcamStopIntentSnapshot? pendingRotation;
          for (var attempt = 0; attempt < 100 && pendingRotation == null; attempt++) {
            final unresolved = service.stopIntentsForTest.where((intent) => intent.purpose == 'rotation' && !intent.resolved);
            if (unresolved.isNotEmpty) {
              pendingRotation = unresolved.last;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(pendingRotation, isNotNull, reason: 'test setup: a rotation intent is pending');
          final id1 = service.activeRecordingId!;

          targeted = service.beginStopLoopRecording(expectedRecordingId: id1, expectedController: service.previewController);
          explicit = service.beginStopLoopRecording();
          expect(service.maxStopIntentAncestryForTest, greaterThanOrEqualTo(2), reason: 'the explicit stop observes both the cleanup and the rotation');
          pendingRestart.complete();

          final targetedHandle = await handleOf(targeted);
          final handle = await handleOf(explicit);
          expect(targetedHandle, isNull, reason: 'the cleanup\'s stale target does not match the Recording rotation stops');
          expect(handle, isNotNull, reason: 'the explicit stop discovers rotation\'s physical stop despite the intermediate cleanup');
          expect(handle!.intentId, explicit.intentId);
          expect(handle.producerIntentId, pendingRotation!.id, reason: 'rotation physically issued that stop');
          expect(handle.recordingId, isNot(equals(id1)));
          await handle.settlement.timeout(const Duration(seconds: 3));
          await explicit.presentation.timeout(const Duration(seconds: 3));

          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'A (rotation tick 1) and B (rotation tick 2) — no duplicate');
          expect(service.clips, hasLength(2));
        } finally {
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          fakePlatform.pendingStartVideoCapturing = null;
          if (explicit != null) await explicit.presentation.catchError((_) {});
          if (targeted != null) await targeted.presentation.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X37 (§35, long chain) — five intents of mixed purposes queue behind one stalled operation: rotation (real '
      'stop) → targeted cleanup → release → reinitialize → explicit. The final explicit stop must discover the '
      'rotation\'s physical stop through a four-deep ancestry — discovery does not depend on the immediate '
      'predecessor alone — and the whole chain drains with exactly one native STOP for that Recording',
      () async {
        // Harness T4: X37 never holds a native stop, so the service's stop
        // deadline is not under test here — but the chain builder's 50 ms one
        // also bounded rotation 1's REAL clip copy (File.copy; spikes of
        // 55-103 ms measured in T3). A spike past it made the service,
        // correctly, mark the camera unavailable and skip the restart this
        // chain is built on: a setup failure (T3: 1 of 5 runs of this file
        // with seed 2024). X37 therefore runs with the production default
        // (5 s), and its setup depends on the events themselves: each wait is
        // by condition with its own finite deadline (200 x 10 ms, explicit
        // fail(), shorter than the service's), and the precondition that was
        // implicit — rotation 1 finalized normally — is now asserted.
        service = buildChainService(segmentDuration: const Duration(milliseconds: 30), stopVideoRecordingTimeout: const Duration(seconds: 5));
        service.trackStopIntentsForTest = true;
        final pendingRestart = Completer<void>();
        DashcamStopOutcome? explicit;
        Future<void>? releasing;
        Future<void>? reinitializing;
        try {
          await service.initialize();
          await service.startLoopRecording(clipOwnerToken: 'A');
          fakePlatform.pendingStartVideoCapturing = pendingRestart;
          await waitForCallCount('stopVideoRecording', 1);
          await waitForPendingStopToClear(maxIterations: 200);
          expect(service.cameraKnownUnavailable, isFalse, reason: 'test setup: rotation 1 finalized Recording #1 normally, so it restarts and the pending rotation will really stop Recording #2');
          await waitForCallCount('startVideoCapturing', 2, maxIterations: 200);

          DashcamStopIntentSnapshot? pendingRotation;
          for (var attempt = 0; attempt < 100 && pendingRotation == null; attempt++) {
            final unresolved = service.stopIntentsForTest.where((intent) => intent.purpose == 'rotation' && !intent.resolved);
            if (unresolved.isNotEmpty) {
              pendingRotation = unresolved.last;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(pendingRotation, isNotNull, reason: 'test setup: a rotation intent is pending');
          final id1 = service.activeRecordingId!;

          final targeted = service.beginStopLoopRecording(expectedRecordingId: id1, expectedController: service.previewController);
          releasing = service.releaseIdleCamera();
          reinitializing = service.initialize().catchError((_) {});
          explicit = service.beginStopLoopRecording();

          final purposes = service.stopIntentsForTest.map((i) => i.purpose).toList();
          expect(purposes, containsAll(['rotation', 'targetedCleanup', 'release', 'reinitialize', 'explicitStop']), reason: 'test setup: the mixed-purpose chain exists');
          expect(service.maxStopIntentAncestryForTest, greaterThanOrEqualTo(4), reason: 'the explicit stop observes four unresolved ancestors, not just its predecessor');

          pendingRestart.complete();
          final handle = await handleOf(explicit);
          expect(await handleOf(targeted), isNull);
          expect(handle, isNotNull, reason: 'discovery through the long chain');
          expect(handle!.producerIntentId, pendingRotation!.id);
          expect(handle.intentId, explicit.intentId);
          await handle.settlement.timeout(const Duration(seconds: 3));
          await releasing.timeout(const Duration(seconds: 5));
          await reinitializing.timeout(const Duration(seconds: 5));

          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'rotation tick 1 (A) + the rotation\'s stop of B exactly once — the chain never duplicates it');
          final intents = service.stopIntentsForTest;
          expect(intents.every((i) => i.resolved), isTrue, reason: 'every intent in the chain concluded');
          expect(service.liveStopIntentCountForTest, 0);
          expect(service.stopIntentAncestryEntriesForTest, 0, reason: 'the lineage was released');
        } finally {
          if (!pendingRestart.isCompleted) pendingRestart.complete();
          fakePlatform.pendingStartVideoCapturing = null;
          if (explicit != null) await explicit.presentation.catchError((_) {});
          if (releasing != null) await releasing.catchError((_) {});
          if (reinitializing != null) await reinitializing.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X38 (§36, chain with NO physical stop) — a stalled initialize() blocks the FIFO; four intents of mixed '
      'purpose (release, explicit, release, explicit) queue behind it while nothing is recording. Expected: every '
      'intent concludes, every handle is `null`, zero native STOP is fabricated, and the lineage leaks nothing',
      () async {
        service = buildChainService();
        service.trackStopIntentsForTest = true;
        final initGate = Completer<void>();
        Future<void>? reinitializing;
        final outcomes = <DashcamStopOutcome>[];
        final releases = <Future<void>>[];
        try {
          await service.initialize();
          fakePlatform.pendingInitializeCamera = initGate;
          reinitializing = service.initialize().catchError((_) {});
          await waitForCallCount('initializeCamera', 2);

          releases.add(service.releaseIdleCamera());
          outcomes.add(service.beginStopLoopRecording());
          releases.add(service.releaseIdleCamera());
          outcomes.add(service.beginStopLoopRecording());
          expect(service.maxStopIntentAncestryForTest, greaterThanOrEqualTo(2), reason: 'test setup: a real chain of unresolved intents exists');

          initGate.complete();
          for (final outcome in outcomes) {
            expect(await handleOf(outcome), isNull, reason: 'no Recording exists anywhere in this chain — no obligation to discover');
          }
          await Future.wait(releases).timeout(const Duration(seconds: 5));
          await reinitializing.timeout(const Duration(seconds: 5));

          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), isEmpty, reason: 'zero artificial STOP');
          expect(service.stopIntentsForTest.every((i) => i.resolved), isTrue, reason: 'all intents terminated');
          expect(service.stopIntentsForTest.every((i) => i.resolvedRecordingId == null), isTrue, reason: 'no intent resolved to any Recording');
          expect(service.liveStopIntentCountForTest, 0);
          expect(service.stopIntentAncestryEntriesForTest, 0);
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGate.isCompleted) initGate.complete();
          for (final outcome in outcomes) {
            await outcome.presentation.catchError((_) {});
          }
          for (final pending in releases) {
            await pending.catchError((_) {});
          }
          if (reinitializing != null) await reinitializing.catchError((_) {});
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'X39 (§37, failed physical stop in a chain) — the X35 chain, but the native STOP of Recording #2 FAILS. '
      'Transitive discovery must not turn into a retry: intent 4 still adopts the (failed) physical stop\'s handle, '
      'its settlement rejects, and exactly ONE native STOP is ever emitted for that Recording — the failure is '
      'terminal (failedStopRecordingId prevails), reported exactly once, and a later stop request emits nothing',
      () async {
        service = buildChainService();
        service.trackStopIntentsForTest = true;
        Completer<void>? startGate;
        final errors = <DashcamServiceError>[];
        StreamSubscription<DashcamServiceError>? errorsSub;
        try {
          errorsSub = service.originatedErrors.listen(errors.add);
          final setup = await arrangeChainSetup();
          startGate = setup.startGate;

          final e2 = service.beginStopLoopRecording();
          final t3 = service.beginStopLoopRecording(expectedRecordingId: setup.id1, expectedController: setup.controller1);
          final e4 = service.beginStopLoopRecording();

          fakePlatform.failStopVideoRecordingWith = StateError('forced native STOP failure (X39)');
          startGate.complete();
          final h2 = await handleOf(e2);
          expect(await handleOf(t3), isNull);
          final h4 = await handleOf(e4);
          expect(h2, isNotNull);
          expect(h4, isNotNull, reason: 'intent 4 still discovers the physical stop — even though it will fail');
          expect(h4!.physicalStopId, h2!.physicalStopId);
          await expectLater(h4.settlement, throwsA(anything), reason: 'the adopted physical stop failed terminally');
          await Future.wait([e2.presentation, t3.presentation, e4.presentation]).timeout(const Duration(seconds: 3));
          await waitForPendingStopToClear();

          expect(
            fakePlatform.calls.where((c) => c == 'stopVideoRecording'),
            hasLength(2),
            reason: 'Recording #1 earlier + ONE failed attempt for #2 — transitive discovery never retries a failed stop',
          );
          expect(errors.where((e) => e.scope == DashcamServiceErrorScope.recordingResult), hasLength(1), reason: 'the failure is reported exactly once');

          final later = service.beginStopLoopRecording();
          await later.presentation.timeout(const Duration(seconds: 3));
          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), hasLength(2), reason: 'a later stop request emits no retry either');
        } finally {
          fakePlatform.failStopVideoRecordingWith = null;
          fakePlatform.pendingStartVideoCapturing = null;
          if (startGate != null && !startGate.isCompleted) startGate.complete();
          await errorsSub?.cancel();
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );

    test(
      'Ancestry sob retenção — crescimento e convergência (Fase 16.2-R4.3-R2.6-EVIDENCE-CLOSURE §2): '
      'extends X38\'s own "stalled initialize() blocks the FIFO, nothing recording" setup from 4 to 50 '
      'chained, mutually-incompatible intents (alternating release/explicitStop — same trick X37/X38 use '
      'to force each call to create a FRESH intent rather than join the previous one) to measure — not '
      'merely assert-zero-at-the-end — liveStopIntentCountForTest and stopIntentAncestryEntriesForTest '
      'WHILE the physical obligation is still genuinely retained (never inferred, sampled synchronously '
      'right after each intent is created), then their convergence once the FIFO finally drains. '
      'liveStopIntentCountForTest must grow EXACTLY linearly (one per still-unresolved intent — no intent '
      'is silently dropped, none is double-counted) and stopIntentAncestryEntriesForTest must grow exactly '
      'as the triangular number k*(k-1)/2 (intent k observes all k-1 already-unresolved predecessors, '
      'per _claimStopIntent\'s own "observe the WHOLE unresolved chain" contract — a closed-form, not a '
      'vague "some growth is expected") — this is necessary, bounded growth (bounded by however many '
      'stop-ish calls a real caller actually issues while the camera is stuck — segment rotation, an '
      'explicit user stop, a release, at most a handful in practice — never by an unrelated, unbounded '
      'history), not a leak: both counters must return to EXACTLY 0 the instant the retained obligation '
      'resolves, with no residual live intent and no residual ancestry edge.',
      () async {
        service = buildChainService();
        service.trackStopIntentsForTest = true;
        const chainLength = 50;
        final initGate = Completer<void>();
        final outcomes = <DashcamStopOutcome>[];
        final releases = <Future<void>>[];
        // Sampled synchronously after each intent is created — while the
        // FIFO is still genuinely blocked on initGate — never after the
        // fact, so this is a real growth curve, not an end-state inference.
        final liveCountSamples = <int>[];
        final ancestryEntriesSamples = <int>[];
        try {
          await service.initialize();
          fakePlatform.pendingInitializeCamera = initGate;
          final reinitializing = service.initialize().catchError((_) {});
          await waitForCallCount('initializeCamera', 2);

          for (var k = 1; k <= chainLength; k++) {
            if (k.isOdd) {
              releases.add(service.releaseIdleCamera());
            } else {
              outcomes.add(service.beginStopLoopRecording());
            }
            liveCountSamples.add(service.liveStopIntentCountForTest);
            ancestryEntriesSamples.add(service.stopIntentAncestryEntriesForTest);
          }

          // Closed-form proof, not just "it grew": intent k (1-indexed) has
          // exactly k-1 ancestors (every earlier, still-unresolved intent —
          // none of these can have resolved yet, the FIFO is still blocked
          // on initGate), so liveStopIntentCountForTest after k intents is
          // exactly k, and the cumulative ancestry-entries sum is the
          // triangular number k*(k-1)/2.
          for (var k = 1; k <= chainLength; k++) {
            expect(
              liveCountSamples[k - 1],
              k,
              reason: 'after $k intents, exactly $k must still be live — none dropped, none double-counted (linear growth)',
            );
            expect(
              ancestryEntriesSamples[k - 1],
              k * (k - 1) ~/ 2,
              reason: 'after $k intents, total ancestry edges must be the triangular number ${k * (k - 1) ~/ 2} '
                  '(intent $k observes exactly ${k - 1} still-unresolved predecessors) — a precise, not merely '
                  'monotonic, growth law',
            );
          }
          expect(
            service.maxStopIntentAncestryForTest,
            chainLength - 1,
            reason: 'the deepest single intent\'s own ancestry is the LAST one created — it alone observes all $chainLength - 1 predecessors',
          );

          // Boundedness under retention is not just "the peak count was
          // reasonable" — release the obligation now and prove every one of
          // the $chainLength intents actually concludes and the lineage
          // fully collapses, exactly like X37/X38's own established
          // terminal-convergence check, just at 12.5x the chain depth.
          initGate.complete();
          for (final outcome in outcomes) {
            await handleOf(outcome);
          }
          await Future.wait(releases).timeout(const Duration(seconds: 5));
          await reinitializing.timeout(const Duration(seconds: 5));

          expect(fakePlatform.calls.where((c) => c == 'stopVideoRecording'), isEmpty, reason: 'nothing was ever recording anywhere in this chain — zero artificial STOP');
          expect(service.stopIntentsForTest.every((i) => i.resolved), isTrue, reason: 'all $chainLength intents genuinely concluded, none abandoned mid-chain');
          expect(service.liveStopIntentCountForTest, 0, reason: 'convergence: no live intent left once the obligation resolved');
          expect(service.stopIntentAncestryEntriesForTest, 0, reason: 'convergence: no residual ancestry edge left once every intent resolved');
        } finally {
          fakePlatform.pendingInitializeCamera = null;
          if (!initGate.isCompleted) initGate.complete();
          for (final outcome in outcomes) {
            await outcome.presentation.catchError((_) {});
          }
          for (final pending in releases) {
            await pending.catchError((_) {});
          }
          await service.dispose().catchError((_) {});
          await waitForControllerReleased();
        }
      },
    );
  });
}
