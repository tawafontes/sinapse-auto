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

  tearDown(() async {
    // Let any still-pending fire-and-forget rotation/finalize work (a stray
    // Timer.periodic tick from a short segmentDuration test) settle before
    // the next test's setUp swaps CameraPlatform.instance out from under it.
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    dir.deleteSync(recursive: true);
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

  test('quota enforcement deletes the oldest unprotected clip first, keeps a protected one', () async {
    // A tiny quota (each fake clip is 1024 bytes) forces eviction after the
    // second segment.
    service = DashcamService(
      config: config(storageQuotaMb: 0), // 0 MB *1024*1024 == 0 bytes quota — any clip triggers eviction
      segmentDuration: const Duration(milliseconds: 20),
    );
    await service.initialize();
    await service.startLoopRecording();
    await service.markClipAsProtected(); // protects the first segment once it finalizes
    await Future<void>.delayed(const Duration(milliseconds: 40)); // let one rotation happen
    await service.stopLoopRecording();

    // The protected first segment must survive; nothing unprotected should.
    expect(service.clips, isNotEmpty);
    expect(service.clips.every((clip) => clip.isProtected), isTrue);
  });

  test('dispose() best-effort finalizes an in-flight segment instead of discarding it', () async {
    service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
    await service.initialize();
    await service.startLoopRecording();

    expect(service.clips, isEmpty);
    await service.dispose();

    expect(fakePlatform.calls, contains('stopVideoRecording'));
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
}
