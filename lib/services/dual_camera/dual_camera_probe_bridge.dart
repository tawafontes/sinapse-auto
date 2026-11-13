import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Where one camera goes in the composed frame: offset and scale in normalized
/// device coordinates (-1..1, the frame's center at 0,0), as CameraX's
/// `CompositionSettings` takes them.
typedef CameraPlacement = ({double offsetX, double offsetY, double scaleX, double scaleY});

/// A composition to try: where the back and the front camera go, and which one
/// is the primary — drawn first, under the other.
typedef DualLayout = ({String name, CameraPlacement back, CameraPlacement front, bool frontPrimary});

/// What the native side bound: the preview texture and the resolutions
/// CameraX chose for the composed Preview and VideoCapture.
typedef DualCameraStart = ({
  int textureId,
  bool handlesCropAndRotation,
  String? preview,
  int? previewRotation,
  String? video,
  int? videoRotation,
  bool concurrentModeOn,
});

/// The device's concurrent camera support.
typedef DualCameraSupport = ({bool feature, List<List<String>> combos, bool concurrentModeOn});

/// The dashcam dual camera phase 0 probe (2026-11-13), implemented natively
/// (`DualCameraProbe.kt`, CameraX concurrent camera with composition); an
/// interface so its screen can be tested against a fake.
abstract interface class DualCameraProbeBridge {
  Future<DualCameraSupport> inspect();
  Future<DualCameraStart> start(DualLayout layout);
  Future<void> record(String path);
  Future<void> stopRecording();
  Future<void> release();

  /// Native events: `previewSurface`, `transform`, `recordStart`,
  /// `recordProgress`, `recordFinalize`, `surfaceCleanup`, `surfaceAvailable`
  /// — each a map with its `kind`.
  Stream<Map<String, Object?>> get events;
}

class DualCameraProbeException implements Exception {
  const DualCameraProbeException(this.code, this.message);

  final String code;
  final String? message;

  @override
  String toString() => '$code: $message';
}

class MethodChannelDualCameraProbeBridge implements DualCameraProbeBridge {
  MethodChannelDualCameraProbeBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event') _events.add(Map<String, Object?>.from(call.arguments as Map));
    });
  }

  static const _channel = MethodChannel('com.synapseauto.synapse_auto/dual_camera_probe');

  static bool get isSupported => Platform.isAndroid;

  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw DualCameraProbeException(e.code, e.message);
    }
  }

  @override
  Future<DualCameraSupport> inspect() async {
    final map = await _call<Map<Object?, Object?>>('inspect') ?? const {};
    return (
      feature: map['feature'] as bool? ?? false,
      combos: [
        for (final combo in (map['combos'] as List<Object?>? ?? const []).cast<List<Object?>>())
          [for (final camera in combo.cast<Map<Object?, Object?>>()) '${camera['facing']} (sensor ${camera['sensorRotation']}°)'],
      ],
      concurrentModeOn: map['concurrentModeOn'] as bool? ?? false,
    );
  }

  Map<String, double> _placement(CameraPlacement p) => {'offsetX': p.offsetX, 'offsetY': p.offsetY, 'scaleX': p.scaleX, 'scaleY': p.scaleY};

  @override
  Future<DualCameraStart> start(DualLayout layout) async {
    final map = await _call<Map<Object?, Object?>>('start', {
          'layout': {'back': _placement(layout.back), 'front': _placement(layout.front)},
          'primary': layout.frontPrimary ? 'front' : 'back',
        }) ??
        const {};
    return (
      textureId: map['textureId'] as int,
      handlesCropAndRotation: map['handlesCropAndRotation'] as bool? ?? false,
      preview: map['preview'] as String?,
      previewRotation: map['previewRotation'] as int?,
      video: map['video'] as String?,
      videoRotation: map['videoRotation'] as int?,
      concurrentModeOn: map['concurrentModeOn'] as bool? ?? false,
    );
  }

  @override
  Future<void> record(String path) => _call<void>('record', {'path': path});

  @override
  Future<void> stopRecording() => _call<void>('stopRecording');

  @override
  Future<void> release() => _call<void>('release');
}
