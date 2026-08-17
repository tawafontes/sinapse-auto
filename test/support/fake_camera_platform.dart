import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';

/// A minimal, real (not mocked) [CameraPlatform] implementation for tests —
/// the same seam the `camera` plugin's own test suite uses
/// (`CameraPlatform.instance` is a settable static), letting Fase 15's
/// dashcam code run against a genuine `CameraController` in unit tests
/// without touching real hardware.
///
/// Only implements the subset of [CameraPlatform] that
/// `CameraController.initialize()`/`startVideoRecording()`/
/// `stopVideoRecording()`/`pausePreview()`/`resumePreview()`/`dispose()`
/// actually call (verified by reading `camera-0.12.0+2`'s own source) —
/// every other method keeps the base class's `UnimplementedError` default,
/// which is intentional: a test that exercises a path this fake doesn't
/// support should fail loudly, not silently succeed against an
/// under-specified double.
class FakeCameraPlatform extends CameraPlatform {
  FakeCameraPlatform({required this.tempDir});

  final Directory tempDir;

  List<CameraDescription> availableCamerasResult = const [
    CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90),
    CameraDescription(name: 'front', lensDirection: CameraLensDirection.front, sensorOrientation: 270),
  ];

  /// When set, [createCameraWithSettings] throws this instead of succeeding
  /// — the seam tests use to simulate `DashcamService.initialize()` failing
  /// (e.g. no camera hardware, permission denied).
  Object? failCreateCameraWith;

  /// When set, [stopVideoRecording] throws this instead of succeeding —
  /// simulates a segment finalize failing mid-recording.
  Object? failStopVideoRecordingWith;

  /// When set, [stopVideoRecording] awaits this before returning — lets a
  /// test simulate a camera-side finalize that's slower than other
  /// concurrent async work (e.g. `DrivingSessionRecorder.stopSession()`'s
  /// own, much lighter Hive-only path), the same real-world relative timing
  /// physical hardware testing found (Fase 15: a several-MB video file's
  /// MediaRecorder finalize + disk copy routinely outlasts the driving
  /// session's own stop bookkeeping). `null` (no delay) by default — every
  /// test that doesn't set this is unaffected.
  Duration? stopVideoRecordingDelay;

  int _nextCameraId = 0;
  int _clipIndex = 0;

  final List<String> calls = [];
  MediaSettings? lastMediaSettings;
  final List<int> disposedCameraIds = [];
  bool previewPaused = false;

  // `CameraController._initializeWithDescription` calls `.first` on both of
  // these — a stream that closes without ever emitting (e.g. `Stream.empty()`)
  // makes `.first` throw `StateError('No element')` as soon as it closes.
  // Real, never-auto-closing broadcast controllers let `.first` simply wait,
  // exactly like the real platform's error/closing channels do when nothing
  // has gone wrong — tests can push onto these directly to simulate one.
  final StreamController<CameraErrorEvent> _errorController = StreamController<CameraErrorEvent>.broadcast();
  final StreamController<CameraClosingEvent> _closingController = StreamController<CameraClosingEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => availableCamerasResult;

  @override
  Future<int> createCameraWithSettings(CameraDescription cameraDescription, MediaSettings mediaSettings) async {
    calls.add('createCameraWithSettings');
    lastMediaSettings = mediaSettings;
    final failure = failCreateCameraWith;
    if (failure != null) throw failure;
    return _nextCameraId++;
  }

  @override
  Future<void> initializeCamera(int cameraId, {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    calls.add('initializeCamera');
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) {
    return Stream.value(
      CameraInitializedEvent(cameraId, 1920, 1080, ExposureMode.auto, false, FocusMode.auto, false),
    );
  }

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errorController.stream;

  /// Lets a test simulate an asynchronous camera-lost error (e.g. hardware
  /// taken by another app mid-recording) — the exact case
  /// `DashcamService._onControllerValueChanged` exists to surface via its
  /// own `errors` stream.
  void emitCameraError(int cameraId, String description) {
    _errorController.add(CameraErrorEvent(cameraId, description));
  }

  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) => _closingController.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() {
    // Only ever `.listen()`'d (never `.first`'d) by CameraController, so —
    // unlike onCameraError/onCameraClosing above — a stream that closes
    // immediately without emitting is completely safe here.
    return const Stream<DeviceOrientationChangedEvent>.empty();
  }

  @override
  Future<void> prepareForVideoRecording() async {
    calls.add('prepareForVideoRecording');
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    calls.add('startVideoCapturing');
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    calls.add('stopVideoRecording');
    final failure = failStopVideoRecordingWith;
    if (failure != null) throw failure;
    final delay = stopVideoRecordingDelay;
    if (delay != null) await Future<void>.delayed(delay);
    final file = File('${tempDir.path}/fake_clip_${_clipIndex++}.mp4');
    // Non-empty so DashcamService's own File.length() read has something
    // real to report — content itself is never inspected by this app.
    file.writeAsBytesSync(List<int>.filled(1024, 0));
    return XFile(file.path);
  }

  @override
  Future<void> pausePreview(int cameraId) async {
    calls.add('pausePreview');
    previewPaused = true;
  }

  @override
  Future<void> resumePreview(int cameraId) async {
    calls.add('resumePreview');
    previewPaused = false;
  }

  @override
  Future<void> dispose(int cameraId) async {
    calls.add('dispose');
    disposedCameraIds.add(cameraId);
  }

  // Deliberately no close()/disposeFake() for _errorController/
  // _closingController: CameraController._initializeWithDescription attaches
  // a fire-and-forget `.first` listener to each (unawaited, meant to resolve
  // only if a real error/closing event ever arrives) and never cancels it.
  // Closing the controller out from under that still-pending listener (e.g.
  // from a test's tearDown) makes `.first` complete with a `StateError('No
  // element')` — an unhandled async error that then surfaces during
  // whichever test happens to be running when it fires, not this one. Each
  // test constructs a fresh FakeCameraPlatform, so simply leaving these
  // open for the object's lifetime (garbage-collected with it) is correct,
  // not a leak.
}
