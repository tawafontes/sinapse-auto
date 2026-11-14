import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraController;
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dual_camera/dashcam_camera_platform.dart';
import 'package:synapse_auto/services/dual_camera/dual_camera_bridge.dart';

import 'support/fake_camera_platform.dart';

/// The camera plugin, with a device orientation that a test can turn.
class TurningCameraPlatform extends FakeCameraPlatform {
  TurningCameraPlatform({required super.tempDir});

  final orientation = StreamController<DeviceOrientationChangedEvent>.broadcast();

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() => orientation.stream;
}

/// `DualCameraRecorder.kt` scripted: one composite, files really written,
/// progress and Finalize delivered as the native side does.
class FakeDualCameraBridge implements DualCameraBridge {
  FakeDualCameraBridge({this.supported = true});

  bool supported;
  final calls = <String>[];
  final _events = StreamController<DualCameraEvent>.broadcast();
  int displayRotation = 0;
  int boundRotation = 0;
  bool? lastFrontPrimary;
  ({String path, int token})? recording;

  @override
  Stream<DualCameraEvent> get events => _events.stream;

  DualCameraOpened _opened() {
    boundRotation = displayRotation;
    return (textureId: 7, handlesCropAndRotation: true, previewWidth: 1280, previewHeight: 720, video: '1280x720', displayRotation: displayRotation);
  }

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<DualCameraOpened> open({required bool frontPrimary}) async {
    calls.add('open');
    lastFrontPrimary = frontPrimary;
    return _opened();
  }

  @override
  Future<DualCameraOpened> rebind() async {
    calls.add('rebind');
    return _opened();
  }

  @override
  Future<void> start({required String path, required int token, required bool audio}) async {
    calls.add(boundRotation != displayRotation ? 'start+rebind' : 'start');
    boundRotation = displayRotation;
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(64, 1));
    recording = (path: path, token: token);
    scheduleMicrotask(() {
      _events.add(DualCameraEvent('recordStart', {'token': token}));
      _events.add(DualCameraEvent('progress', {'token': token}));
    });
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    final r = recording;
    recording = null;
    if (r == null) return;
    scheduleMicrotask(() => _events.add(DualCameraEvent('finalize', {'token': r.token, 'path': r.path, 'error': 0})));
  }

  @override
  Future<void> close() async {
    calls.add('close');
    recording = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late TurningCameraPlatform plugin;
  late FakeDualCameraBridge dual;
  late DashcamCameraPlatform platform;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dashcam_dual_camera_test');
    plugin = TurningCameraPlatform(tempDir: dir);
    dual = FakeDualCameraBridge();
    platform = DashcamCameraPlatform(inner: plugin, dual: dual, recordingDirectory: () async => dir);
    CameraPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    await platform.disposePlatform();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A file still held on Windows; the temp folder is cleaned anyway.
    }
  });

  DashcamConfig config({CameraSelection selection = CameraSelection.both, bool frontPrimary = false}) => DashcamConfig(
        cameraSelection: selection,
        storageQuotaMb: 1024,
        audioEnabled: false,
        resolution: VideoResolution.hd720,
        frameRate: 30,
        enabled: true,
        dualFrontPrimary: frontPrimary,
      );

  Future<void> until(bool Function() condition, {String label = 'condition'}) async {
    for (var i = 0; i < 400; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting for $label');
  }

  group('the platform', () {
    test('offers the composite only where the phone supports it, after the plugin\'s cameras', () async {
      final cameras = await platform.availableCameras();
      expect(cameras.map((c) => c.name), ['back', 'front', DashcamCameraPlatform.backPrimaryName, DashcamCameraPlatform.frontPrimaryName]);
      expect(cameras.where(DashcamCameraPlatform.isDualCamera).every((c) => c.lensDirection == CameraLensDirection.external), isTrue,
          reason: 'a pick by lens direction never lands on it');

      final unsupported = DashcamCameraPlatform(inner: plugin, dual: FakeDualCameraBridge(supported: false));
      expect((await unsupported.availableCameras()).map((c) => c.name), ['back', 'front']);
      await unsupported.disposePlatform();
    });

    test('a real CameraController records on the composite, with the plugin\'s kind of evidence', () async {
      final description = (await platform.availableCameras()).firstWhere((c) => c.name == DashcamCameraPlatform.frontPrimaryName);
      final controller = CameraController(description, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      expect(dual.lastFrontPrimary, isTrue);
      expect(controller.value.previewSize, const Size(1280, 720));

      await controller.startVideoRecording();
      final token = platform.recordingEvidence.value!.token;
      await until(() => platform.recordingEvidence.value!.videoProgress, label: 'video progress');
      final file = await controller.stopVideoRecording();
      expect(File(file.path).existsSync(), isTrue);
      expect(platform.recordingEvidence.value!.token, token);
      expect(platform.recordingEvidence.value!.ended, isTrue);
      expect(platform.recordingEvidence.value!.endError, 0);

      await controller.dispose();
      expect(dual.calls.last, 'close');
      expect(plugin.calls, isNot(contains('createCameraWithSettings')), reason: 'the plugin never opened a camera');
    });

    test('a turn rebinds at once when idle, and asks for a new segment while recording', () async {
      final description = (await platform.availableCameras()).firstWhere((c) => c.name == DashcamCameraPlatform.backPrimaryName);
      final controller = CameraController(description, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      final requests = <void>[];
      final sub = DashcamCameraPlatform.segmentRotationRequests.listen(requests.add);

      dual.displayRotation = 90;
      plugin.orientation.add(const DeviceOrientationChangedEvent(DeviceOrientation.landscapeLeft));
      await until(() => dual.calls.contains('rebind'), label: 'rebind when idle');
      expect(requests, isEmpty);

      await controller.startVideoRecording();
      dual.displayRotation = 0;
      plugin.orientation.add(const DeviceOrientationChangedEvent(DeviceOrientation.portraitUp));
      await until(() => requests.isNotEmpty, label: 'segment request while recording');
      expect(dual.calls.where((c) => c == 'rebind'), hasLength(1), reason: 'never rebinds under a recording');

      await controller.stopVideoRecording();
      await controller.dispose();
      await sub.cancel();
    });

    test('the plugin\'s cameras go to the plugin untouched, its evidence included', () async {
      final controller = CameraController((await platform.availableCameras()).first, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      await controller.startVideoRecording();
      expect(platform.recordingEvidence.value, isNotNull);
      expect(platform.recordingEvidence.value!.token, plugin.recordingEvidence.value!.token);
      await controller.stopVideoRecording();
      await controller.dispose();
      expect(dual.calls, isEmpty);
    });
  });

  group('DashcamService on the composite', () {
    test('"Ambas" records on the composite; a turn while recording closes the segment now and the next one rebinds', () async {
      final service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        expect(DashcamCameraPlatform.isDualCamera(service.previewController!.description), isTrue);
        expect(dual.lastFrontPrimary, isFalse, reason: 'back camera primary by default');
        await service.startLoopRecording();
        await until(() => dual.calls.contains('start'), label: 'first segment');

        // The phone turns while recording: the segment closes now, and the
        // next START rebinds at the new orientation.
        dual.displayRotation = 90;
        plugin.orientation.add(const DeviceOrientationChangedEvent(DeviceOrientation.landscapeLeft));
        await until(() => dual.calls.contains('start+rebind'), label: 'a new segment on a rebind');
        await until(() => service.clips.isNotEmpty, label: 'the first segment kept as a clip');

        await service.stopLoopRecording();
        expect(service.clips, hasLength(2));
      } finally {
        await service.dispose();
      }
    });

    test('"Ambas" where the phone cannot: the rear camera, as before', () async {
      dual.supported = false;
      platform = DashcamCameraPlatform(inner: plugin, dual: dual, recordingDirectory: () async => dir);
      CameraPlatform.instance = platform;
      final service = DashcamService(config: config(), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        expect(service.previewController!.description.name, 'back');
      } finally {
        await service.dispose();
      }
    });

    test('rotateSegmentNow with nothing recording does nothing', () async {
      final service = DashcamService(config: config(selection: CameraSelection.rear), segmentDuration: const Duration(minutes: 10));
      try {
        await service.initialize();
        expect(service.rotateSegmentNow(), isFalse);
      } finally {
        await service.dispose();
      }
    });
  });
}
