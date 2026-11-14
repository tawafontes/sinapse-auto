import 'dart:async';
import 'dart:io';

import 'package:camera_android_camerax/camera_android_camerax.dart' show RecordingEvidence, RecordingEvidenceSource;
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation, PlatformException;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'dual_camera_bridge.dart';

/// The app's [CameraPlatform] (dashcam "Ambas" mode, 2026-11-14): every camera
/// the plugin knows goes on to the plugin ([inner]) untouched, and one more —
/// the back and front cameras composed by `DualCameraRecorder.kt` — is offered
/// when the phone supports it. To `DashcamService` the composite is just one
/// more [CameraDescription]: the same `CameraController`, the same START /
/// STOP, rotation, timeouts, clip index, quota and telemetry, and the same
/// [RecordingEvidence] the plugin's fork reports (one slot, the token given at
/// START, video progress, then the Finalize with its error) — so none of the
/// dashcam's validated machinery is duplicated for the second mode.
///
/// What only the composite does:
///  * its frame's orientation is fixed when the cameras are bound (phase 0),
///    so on a turn it rebinds right away when idle, and while recording asks
///    the dashcam to close the segment now ([segmentRotationRequests]); the
///    next START then rebinds at the new rotation (owner decision: follow the
///    turn, accepting ~1 s without video);
///  * it never shares CameraX with the plugin: the dashcam owns one camera at
///    a time, so the two are never bound together.
class DashcamCameraPlatform extends CameraPlatform implements RecordingEvidenceSource {
  DashcamCameraPlatform({required this.inner, required this.dual, Future<Directory> Function()? recordingDirectory})
      : _recordingDirectory = recordingDirectory ?? getTemporaryDirectory {
    final innerEvidence = inner is RecordingEvidenceSource ? (inner as RecordingEvidenceSource).recordingEvidence : null;
    _innerEvidence = innerEvidence;
    _evidence.value = innerEvidence?.value;
    innerEvidence?.addListener(_onInnerEvidence);
    _events = dual.events.listen(_onDualEvent);
  }

  /// Replaces the plugin as [CameraPlatform.instance], on Android only.
  static void install() {
    if (!MethodChannelDualCameraBridge.isPlatformSupported || CameraPlatform.instance is DashcamCameraPlatform) return;
    CameraPlatform.instance = DashcamCameraPlatform(inner: CameraPlatform.instance, dual: MethodChannelDualCameraBridge());
  }

  /// The composite, with the back camera filling the frame and the front one
  /// as the PiP (the default), or the other way round.
  static const backPrimaryName = 'synapse_dual:back_primary';
  static const frontPrimaryName = 'synapse_dual:front_primary';

  static bool isDualCamera(CameraDescription description) => description.name.startsWith('synapse_dual:');

  /// The installed platform, or `null` (tests, non-Android).
  static DashcamCameraPlatform? get installed {
    final platform = CameraPlatform.instance;
    return platform is DashcamCameraPlatform ? platform : null;
  }

  /// Asks the dashcam to close the running segment now: the composite's
  /// frame keeps its bind orientation, and the phone turned. Static, so the
  /// dashcam needs no reference to this platform (it may not be installed).
  static Stream<void> get segmentRotationRequests => _segmentRotationRequests.stream;
  static final _segmentRotationRequests = StreamController<void>.broadcast();

  final CameraPlatform inner;
  final DualCameraBridge dual;
  final Future<Directory> Function() _recordingDirectory;

  ValueListenable<RecordingEvidence?>? _innerEvidence;
  final ValueNotifier<RecordingEvidence?> _evidence = ValueNotifier(null);
  late final StreamSubscription<DualCameraEvent> _events;
  bool? _supported;

  /// Camera ids handed out for the composite, far from the plugin's (0, 1, …).
  int _nextDualId = 1 << 20;

  /// Recording tokens of the composite, far from the plugin's.
  int _nextToken = 1 << 40;

  _DualCamera? _camera;

  @override
  ValueListenable<RecordingEvidence?> get recordingEvidence => _evidence;

  void _onInnerEvidence() {
    if (_camera == null) _evidence.value = _innerEvidence?.value;
  }

  bool _isDual(int cameraId) => _camera?.id == cameraId;

  _DualCamera _require(int cameraId) {
    final camera = _camera;
    if (camera == null || camera.id != cameraId) throw CameraException('cameraNotFound', 'no composite camera $cameraId');
    return camera;
  }

  /// Whether the composite is offered: asked once, a failure counting as no.
  Future<bool> dualSupported() async {
    if (_supported != null) return _supported!;
    try {
      _supported = await dual.isSupported();
    } on Object {
      _supported = false;
    }
    return _supported!;
  }

  @override
  Future<List<CameraDescription>> availableCameras() async {
    final cameras = await inner.availableCameras();
    if (!await dualSupported()) return cameras;
    // External, so a pick by lens direction (back, front) never lands on it.
    return [
      ...cameras,
      const CameraDescription(name: backPrimaryName, lensDirection: CameraLensDirection.external, sensorOrientation: 90),
      const CameraDescription(name: frontPrimaryName, lensDirection: CameraLensDirection.external, sensorOrientation: 90),
    ];
  }

  @override
  Future<int> createCamera(CameraDescription cameraDescription, ResolutionPreset? resolutionPreset, {bool enableAudio = false}) =>
      createCameraWithSettings(cameraDescription, MediaSettings(resolutionPreset: resolutionPreset, enableAudio: enableAudio));

  @override
  Future<int> createCameraWithSettings(CameraDescription cameraDescription, MediaSettings mediaSettings) async {
    if (!isDualCamera(cameraDescription)) return inner.createCameraWithSettings(cameraDescription, mediaSettings);
    final previous = _camera;
    if (previous != null) await _close(previous);
    final camera = _DualCamera(
      id: _nextDualId++,
      frontPrimary: cameraDescription.name == frontPrimaryName,
      audio: mediaSettings.enableAudio,
    );
    _camera = camera;
    _evidence.value = null;
    return camera.id;
  }

  @override
  Future<void> initializeCamera(int cameraId, {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    if (!_isDual(cameraId)) return inner.initializeCamera(cameraId, imageFormatGroup: imageFormatGroup);
    final camera = _require(cameraId);
    final DualCameraOpened opened;
    try {
      opened = await dual.open(frontPrimary: camera.frontPrimary);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
    camera.opened = opened;
    camera.boundOrientation = _orientationForRotation(opened.displayRotation);
    debugPrint('dual camera: open texture=${opened.textureId} preview=${opened.previewWidth}x${opened.previewHeight} video=${opened.video} display=${opened.displayRotation}°');
    camera.orientation = inner.onDeviceOrientationChanged().listen((event) => _onTurn(camera, event.orientation));
    camera.initialized.add(CameraInitializedEvent(
      cameraId,
      opened.previewWidth.toDouble(),
      opened.previewHeight.toDouble(),
      ExposureMode.auto,
      false,
      FocusMode.auto,
      false,
    ));
  }

  static DeviceOrientation _orientationForRotation(int degrees) => switch (degrees % 360) {
        90 => DeviceOrientation.landscapeLeft,
        180 => DeviceOrientation.portraitDown,
        270 => DeviceOrientation.landscapeRight,
        _ => DeviceOrientation.portraitUp,
      };

  void _onTurn(_DualCamera camera, DeviceOrientation orientation) {
    camera.deviceOrientation.value = orientation;
    if (_camera != camera || orientation == camera.boundOrientation) return;
    if (camera.recording != null) {
      debugPrint('dual camera: turned to ${orientation.name} while recording: closing the segment');
      _segmentRotationRequests.add(null);
      return;
    }
    unawaited(_rebind(camera));
  }

  Future<void> _rebind(_DualCamera camera) async {
    if (camera.rebinding) return;
    camera.rebinding = true;
    try {
      final opened = await dual.rebind();
      if (_camera != camera) return;
      camera.opened = opened;
      camera.boundOrientation = _orientationForRotation(opened.displayRotation);
      debugPrint('dual camera: rebound at ${opened.displayRotation}°');
    } on PlatformException catch (e) {
      debugPrint('dual camera: rebind failed: ${e.code} ${e.message}');
    } finally {
      camera.rebinding = false;
    }
  }

  void _onDualEvent(DualCameraEvent event) {
    final camera = _camera;
    if (camera == null) return;
    switch (event.kind) {
      case 'transform':
        camera.rotationDegrees.value = event.rotationDegrees ?? 0;
      case 'progress':
        final current = _evidence.value;
        if (current != null && current.token == event.token && !current.ended) {
          _evidence.value = RecordingEvidence(token: current.token, videoProgress: true);
        }
      case 'finalize':
        final current = _evidence.value;
        if (current != null && current.token == event.token) {
          _evidence.value = RecordingEvidence(token: current.token, videoProgress: current.videoProgress, ended: true, endError: event.error);
        }
        final recording = camera.recording;
        if (recording != null && recording.token == event.token) {
          camera.recording = null;
          if (!recording.finalized.isCompleted) recording.finalized.complete(event);
        }
    }
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _isDual(cameraId) ? _require(cameraId).initialized.stream : inner.onCameraInitialized(cameraId);

  @override
  Stream<CameraResolutionChangedEvent> onCameraResolutionChanged(int cameraId) =>
      _isDual(cameraId) ? const Stream.empty() : inner.onCameraResolutionChanged(cameraId);

  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) =>
      _isDual(cameraId) ? _require(cameraId).closing.stream : inner.onCameraClosing(cameraId);

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      _isDual(cameraId) ? _require(cameraId).errors.stream : inner.onCameraError(cameraId);

  @override
  Stream<VideoRecordedEvent> onVideoRecordedEvent(int cameraId) =>
      _isDual(cameraId) ? const Stream.empty() : inner.onVideoRecordedEvent(cameraId);

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() => inner.onDeviceOrientationChanged();

  @override
  Future<void> lockCaptureOrientation(int cameraId, DeviceOrientation orientation) async {
    if (!_isDual(cameraId)) return inner.lockCaptureOrientation(cameraId, orientation);
  }

  @override
  Future<void> unlockCaptureOrientation(int cameraId) async {
    if (!_isDual(cameraId)) return inner.unlockCaptureOrientation(cameraId);
  }

  @override
  Future<void> prepareForVideoRecording() => inner.prepareForVideoRecording();

  @override
  Future<void> startVideoRecording(int cameraId, {Duration? maxVideoDuration}) =>
      startVideoCapturing(VideoCaptureOptions(cameraId));

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    if (!_isDual(options.cameraId)) return inner.startVideoCapturing(options);
    final camera = _require(options.cameraId);
    if (camera.recording != null) throw CameraException('videoRecordingFailed', 'already recording');
    final token = _nextToken++;
    final directory = await _recordingDirectory();
    final path = '${directory.path}/dual_$token.mp4';
    final recording = _DualRecording(token, path);
    camera.recording = recording;
    // The slot holds this recording from the moment START returns, like the
    // plugin's fork: the dashcam adopts it right after.
    _evidence.value = RecordingEvidence(token: token);
    try {
      await dual.start(path: path, token: token, audio: camera.audio);
    } on PlatformException catch (e) {
      camera.recording = null;
      _evidence.value = RecordingEvidence(token: token, ended: true, endError: -1);
      throw CameraException(e.code, e.message);
    }
    // A turn that happened before this START is in the rebind native did.
    camera.boundOrientation = camera.deviceOrientation.value ?? camera.boundOrientation;
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    if (!_isDual(cameraId)) return inner.stopVideoRecording(cameraId);
    final camera = _require(cameraId);
    final recording = camera.recording;
    if (recording == null) throw CameraException('videoRecordingFailed', 'not recording');
    try {
      await dual.stop();
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
    final event = await recording.finalized.future;
    if (!File(recording.path).existsSync()) {
      throw CameraException('videoRecordingFailed', 'no file (native error ${event.error})');
    }
    return XFile(recording.path);
  }

  @override
  Future<void> pausePreview(int cameraId) async {
    if (!_isDual(cameraId)) return inner.pausePreview(cameraId);
  }

  @override
  Future<void> resumePreview(int cameraId) async {
    if (!_isDual(cameraId)) return inner.resumePreview(cameraId);
  }

  @override
  Widget buildPreview(int cameraId) {
    if (!_isDual(cameraId)) return inner.buildPreview(cameraId);
    return _DualPreview(camera: _require(cameraId));
  }

  @override
  Future<void> dispose(int cameraId) async {
    if (!_isDual(cameraId)) return inner.dispose(cameraId);
    final camera = _camera;
    if (camera != null && camera.id == cameraId) await _close(camera);
  }

  Future<void> _close(_DualCamera camera) async {
    if (_camera == camera) _camera = null;
    await camera.orientation?.cancel();
    final recording = camera.recording;
    camera.recording = null;
    try {
      await dual.close();
    } on PlatformException {
      // Already released.
    }
    if (recording != null && !recording.finalized.isCompleted) {
      recording.finalized.complete(DualCameraEvent('finalize', {'token': recording.token, 'error': -1}));
    }
    // Like the plugin's dispose: the slot lets go of this camera's recording.
    _evidence.value = _innerEvidence?.value;
    camera.dispose();
  }

  /// Tests only.
  @visibleForTesting
  Future<void> disposePlatform() async {
    _innerEvidence?.removeListener(_onInnerEvidence);
    await _events.cancel();
  }

  // Everything else a dashcam never asks: the plugin's answer for its own
  // cameras, a plain refusal for the composite.

  @override
  Future<XFile> takePicture(int cameraId) => _isDual(cameraId) ? throw CameraException('unsupported', 'composite') : inner.takePicture(cameraId);

  @override
  Future<void> pauseVideoRecording(int cameraId) =>
      _isDual(cameraId) ? throw CameraException('unsupported', 'composite') : inner.pauseVideoRecording(cameraId);

  @override
  Future<void> resumeVideoRecording(int cameraId) =>
      _isDual(cameraId) ? throw CameraException('unsupported', 'composite') : inner.resumeVideoRecording(cameraId);

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {
    if (!_isDual(cameraId)) return inner.setFlashMode(cameraId, mode);
  }

  @override
  Future<void> setExposureMode(int cameraId, ExposureMode mode) async {
    if (!_isDual(cameraId)) return inner.setExposureMode(cameraId, mode);
  }

  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {
    if (!_isDual(cameraId)) return inner.setFocusMode(cameraId, mode);
  }

  @override
  Future<double> getMinZoomLevel(int cameraId) async => _isDual(cameraId) ? 1 : inner.getMinZoomLevel(cameraId);

  @override
  Future<double> getMaxZoomLevel(int cameraId) async => _isDual(cameraId) ? 1 : inner.getMaxZoomLevel(cameraId);

  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async {
    if (!_isDual(cameraId)) return inner.setZoomLevel(cameraId, zoom);
  }
}

class _DualRecording {
  _DualRecording(this.token, this.path);

  final int token;
  final String path;
  final Completer<DualCameraEvent> finalized = Completer();
}

class _DualCamera {
  _DualCamera({required this.id, required this.frontPrimary, required this.audio});

  final int id;
  final bool frontPrimary;
  final bool audio;
  DualCameraOpened? opened;
  DeviceOrientation? boundOrientation;
  _DualRecording? recording;
  bool rebinding = false;
  StreamSubscription<DeviceOrientationChangedEvent>? orientation;
  final initialized = StreamController<CameraInitializedEvent>.broadcast();
  final closing = StreamController<CameraClosingEvent>.broadcast();
  final errors = StreamController<CameraErrorEvent>.broadcast();

  /// The rotation CameraX says the texture needs (its transformation info).
  final rotationDegrees = ValueNotifier<int>(0);

  /// The live device orientation, for the preview's turn.
  final deviceOrientation = ValueNotifier<DeviceOrientation?>(null);

  /// The streams are left open: `CameraController` waits on
  /// `onCameraError(id).first`, which a closed, empty stream fails ("No
  /// element") — the camera plugin never closes them either.
  void dispose() {}
}

/// The composite's live image, presented the way the plugin's own
/// `buildPreview` is: upright for the device's natural (portrait) orientation,
/// so the dashcam's `DashcamCameraSurface` — which turns that by the live
/// device orientation — shows it upright on screen. The texture needs
/// [_DualCamera.rotationDegrees] on screen (the phase 0 probe), so here it is
/// that minus the device's own turn.
class _DualPreview extends StatelessWidget {
  const _DualPreview({required this.camera});

  final _DualCamera camera;

  static const _deviceTurns = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeRight: 1,
    DeviceOrientation.portraitDown: 2,
    DeviceOrientation.landscapeLeft: 3,
  };

  @override
  Widget build(BuildContext context) {
    final opened = camera.opened;
    if (opened == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([camera.rotationDegrees, camera.deviceOrientation]),
      builder: (context, _) {
        final textureTurns = opened.handlesCropAndRotation ? 0 : camera.rotationDegrees.value ~/ 90;
        final deviceTurns = _deviceTurns[camera.deviceOrientation.value ?? DeviceOrientation.portraitUp]!;
        final turns = (textureTurns - deviceTurns) % 4;
        return RotatedBox(quarterTurns: turns, child: Texture(textureId: opened.textureId));
      },
    );
  }
}
