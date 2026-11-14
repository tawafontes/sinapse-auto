import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// What [DualCameraBridge.open] (and `rebind`) bound.
typedef DualCameraOpened = ({
  int textureId,
  bool handlesCropAndRotation,
  int previewWidth,
  int previewHeight,
  String? video,
  int displayRotation,
});

/// One fact from the native recorder (`DualCameraRecorder.kt`).
class DualCameraEvent {
  const DualCameraEvent(this.kind, this.data);

  /// `recordStart`, `progress`, `finalize`, `transform`, `surfaceAvailable`, `surfaceCleanup`.
  final String kind;
  final Map<Object?, Object?> data;

  int? get token => (data['token'] as num?)?.toInt();
  int? get error => (data['error'] as num?)?.toInt();
  String? get path => data['path'] as String?;
  int? get rotationDegrees => (data['rotationDegrees'] as num?)?.toInt();
}

/// The native side of the dashcam's "Ambas" mode: the back and front cameras
/// composed into one preview texture and one recorded file (see
/// `DualCameraRecorder.kt`). An interface so `DashcamCameraPlatform` is tested
/// against a scripted fake.
abstract interface class DualCameraBridge {
  /// Whether this phone can run the back and front cameras at once.
  Future<bool> isSupported();

  /// Binds both cameras at the current display rotation, [frontPrimary]
  /// deciding which one fills the frame (the other is the PiP).
  Future<DualCameraOpened> open({required bool frontPrimary});

  /// Binds again at the current display rotation (not while recording).
  Future<DualCameraOpened> rebind();

  /// Starts recording to [path]; [token] identifies it in every [events] fact.
  /// Rebinds first when the display turned since the bind.
  Future<void> start({required String path, required int token, required bool audio});

  /// Asks the recording to stop; its `finalize` event follows.
  Future<void> stop();

  /// Stops, unbinds and releases the texture.
  Future<void> close();

  Stream<DualCameraEvent> get events;
}

class MethodChannelDualCameraBridge implements DualCameraBridge {
  MethodChannelDualCameraBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        _events.add(DualCameraEvent(call.arguments['kind'] as String, Map<Object?, Object?>.from(call.arguments as Map)));
      }
    });
  }

  static const _channel = MethodChannel('com.synapseauto.synapse_auto/dual_camera');
  static bool get isPlatformSupported => Platform.isAndroid;

  final _events = StreamController<DualCameraEvent>.broadcast();

  @override
  Stream<DualCameraEvent> get events => _events.stream;

  DualCameraOpened _opened(Map<Object?, Object?> m) => (
        textureId: (m['textureId'] as num).toInt(),
        handlesCropAndRotation: m['handlesCropAndRotation'] as bool? ?? false,
        previewWidth: (m['previewWidth'] as num?)?.toInt() ?? 1280,
        previewHeight: (m['previewHeight'] as num?)?.toInt() ?? 720,
        video: m['video'] as String?,
        displayRotation: (m['displayRotation'] as num?)?.toInt() ?? 0,
      );

  @override
  Future<bool> isSupported() async => await _channel.invokeMethod<bool>('isSupported') ?? false;

  @override
  Future<DualCameraOpened> open({required bool frontPrimary}) async =>
      _opened((await _channel.invokeMethod<Map<Object?, Object?>>('open', {'primary': frontPrimary ? 'front' : 'back'}))!);

  @override
  Future<DualCameraOpened> rebind() async => _opened((await _channel.invokeMethod<Map<Object?, Object?>>('rebind'))!);

  @override
  Future<void> start({required String path, required int token, required bool audio}) =>
      _channel.invokeMethod<void>('start', {'path': path, 'token': token, 'audio': audio});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<void> close() => _channel.invokeMethod<void>('close');
}
