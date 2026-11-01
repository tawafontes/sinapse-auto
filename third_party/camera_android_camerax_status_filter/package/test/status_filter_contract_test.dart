// Synapse Auto (R4.4-HW-MIG-4): the plugin's START/STOP over the real VideoRecordEvent stream must
// behave the same with and without Status events. Every scenario runs in both worlds, so a
// difference between them is a behavior the Android filter would change.

import 'dart:async';

import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_android_camerax/src/camerax_library.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import 'android_camera_camerax_test.mocks.dart';

const int _cameraId = 17;

void _emit(VideoRecordEvent event) {
  AndroidCameraCameraX.videoRecordingEventStreamController.add(event);
}

VideoRecordEventStart _start() => VideoRecordEventStart.pigeon_detached();
VideoRecordEventFinalize _finalize() => VideoRecordEventFinalize.pigeon_detached();

/// One camera with a scripted native side. [frames] stands for the Status events: Dart receives
/// them as the plain [VideoRecordEvent], since Pigeon has no Status type.
class _Rig {
  _Rig({required this.frames}) {
    camera.processCameraProvider = provider;
    camera.recorder = recorder;
    camera.videoCapture = MockVideoCapture();
    camera.cameraSelector = MockCameraSelector();
    camera.cameraInfo = MockCameraInfo();
    camera.imageAnalysis = MockImageAnalysis();
    camera.enableRecordingAudio = false;
    camera.captureOrientationLocked = true;

    var path = 0;
    PigeonOverrides.deviceOrientationManager_new =
        ({required void Function(DeviceOrientationManager, String) onDeviceOrientationChanged}) =>
            MockDeviceOrientationManager();
    GenericsPigeonOverrides.observerNew =
        <T>({required void Function(Observer<T>, T) onChanged}) {
          return Observer<T>.detached(onChanged: onChanged);
        };
    final cameraInfo2 = MockCamera2CameraInfo();
    PigeonOverrides.camera2CameraInfo_from = ({required dynamic cameraInfo}) => cameraInfo2;
    PigeonOverrides.systemServicesManager_new =
        ({required void Function(SystemServicesManager, String) onCameraError}) {
          final manager = MockSystemServicesManager();
          when(
            manager.getTempFilePath(camera.videoPrefix, '.mp4'),
          ).thenAnswer((_) async => '/temp/REC${path++}.mp4');
          return manager;
        };
    PigeonOverrides.videoRecordEventListener_new =
        ({required void Function(VideoRecordEventListener, VideoRecordEvent) onEvent}) {
          return VideoRecordEventListener.pigeon_detached(onEvent: onEvent);
        };
    PigeonOverrides.cameraCharacteristics_infoSupportedHardwareLevel =
        MockCameraCharacteristicsKey();

    final boundCamera = MockCamera();
    final boundInfo = MockCameraInfo();
    when(recorder.prepareRecording(any)).thenAnswer((_) async => pending);
    when(pending.withAudioEnabled(any)).thenAnswer((_) async => pending);
    when(pending.asPersistentRecording()).thenAnswer((_) async => pending);
    when(pending.start(any)).thenAnswer((_) async {
      onNativeStart?.call();
      return nativeRecording;
    });
    when(nativeRecording.close()).thenAnswer((_) async => onNativeClose?.call());
    when(provider.isBound(any)).thenAnswer((_) async => false);
    when(provider.bindToLifecycle(any, any)).thenAnswer((_) async => boundCamera);
    when(boundCamera.getCameraInfo()).thenAnswer((_) async => boundInfo);
    when(boundInfo.getCameraState()).thenAnswer((_) async => MockLiveCameraState());
    when(
      cameraInfo2.getCameraCharacteristic(any),
    ).thenAnswer((_) async => InfoSupportedHardwareLevel.limited);
  }

  final int frames;
  final AndroidCameraCameraX camera = AndroidCameraCameraX();
  final MockProcessCameraProvider provider = MockProcessCameraProvider();
  final MockRecorder recorder = MockRecorder();
  final MockPendingRecording pending = MockPendingRecording();
  final MockRecording nativeRecording = MockRecording();
  void Function()? onNativeStart;
  void Function()? onNativeClose;

  void status() {
    for (var i = 0; i < frames; i++) {
      _emit(VideoRecordEvent.pigeon_detached());
    }
  }

  /// The normal native script: Start, a segment of frames, and Finalize on close.
  void scriptNormal() {
    onNativeStart = () {
      status();
      _emit(_start());
      status();
    };
    onNativeClose = () {
      status();
      _emit(_finalize());
      status();
    };
  }

  Future<void> startRecording() => camera.startVideoCapturing(const VideoCaptureOptions(_cameraId));

  Future<XFile> stopRecording() => camera.stopVideoRecording(_cameraId);
}

Future<void> _settle() => pumpEventQueue(times: 200);

Future<bool> _isPending(Future<Object?> future) async {
  var done = false;
  unawaited(future.whenComplete(() => done = true));
  await _settle();
  return !done;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (String world, int frames) in <(String, int)>[
    ('without Status (filter)', 0),
    ('with Status (upstream)', 300),
  ]) {
    group(world, () {
      test('START returns only after Start, STOP only after Finalize', () async {
        final rig = _Rig(frames: frames);
        rig.onNativeStart = rig.status;
        final start = rig.startRecording();
        expect(await _isPending(start), isTrue);
        _emit(_start());
        await start;
        expect(rig.camera.recording, rig.nativeRecording);

        rig.onNativeClose = rig.status;
        final stop = rig.stopRecording();
        expect(await _isPending(stop), isTrue);
        expect(rig.camera.recording, rig.nativeRecording);
        _emit(_finalize());
        final file = await stop;
        expect(file.path, '/temp/REC0.mp4');
        expect(rig.camera.recording, isNull);
        expect(rig.camera.pendingRecording, isNull);
      });

      test('three recordings in a row keep their own paths', () async {
        final rig = _Rig(frames: frames)..scriptNormal();
        final paths = <String>[];
        for (var i = 0; i < 3; i++) {
          await rig.startRecording();
          paths.add((await rig.stopRecording()).path);
        }
        expect(paths, <String>['/temp/REC0.mp4', '/temp/REC1.mp4', '/temp/REC2.mp4']);
        verify(rig.pending.start(any)).called(3);
        verify(rig.nativeRecording.close()).called(3);
      });

      test('aborted START: Finalize without Start leaves START waiting for a Start', () async {
        final rig = _Rig(frames: frames);
        rig.onNativeStart = () {
          rig.status();
          _emit(_finalize());
        };
        final start = rig.startRecording();
        expect(await _isPending(start), isTrue);
        _emit(_start());
        await start;
      });

      test('late STOP: Finalize long after close still completes it', () async {
        final rig = _Rig(frames: frames)..scriptNormal();
        await rig.startRecording();
        rig.onNativeClose = rig.status;
        final stop = rig.stopRecording();
        expect(await _isPending(stop), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        rig.status();
        expect(await _isPending(stop), isTrue);
        _emit(_finalize());
        expect((await stop).path, '/temp/REC0.mp4');
      });

      test('dispose during recording: the stale Finalize does not end the next STOP', () async {
        final rig = _Rig(frames: frames)..scriptNormal();
        await rig.startRecording();
        await rig.camera.dispose(_cameraId);
        expect(rig.camera.recording, isNull);
        // unbindAll() finalizes the recording natively, after dispose cleared the Dart state.
        rig.status();
        _emit(_finalize());

        // START skips the stale Finalize; the next STOP waits for its own.
        await rig.startRecording();
        rig.onNativeClose = rig.status;
        final stop = rig.stopRecording();
        expect(await _isPending(stop), isTrue);
        _emit(_finalize());
        expect((await stop).path, '/temp/REC1.mp4');
      });

      test('out of order: Finalize queued before STOP completes it right after close', () async {
        final rig = _Rig(frames: frames)..scriptNormal();
        await rig.startRecording();
        // CameraX auto-finalized the recording (source inactive), before the app asked to stop.
        _emit(_finalize());
        rig.onNativeClose = rig.status;
        expect((await rig.stopRecording()).path, '/temp/REC0.mp4');
      });

      test('stray Start before a stop does not complete the stop', () async {
        final rig = _Rig(frames: frames)..scriptNormal();
        await rig.startRecording();
        rig.onNativeClose = () {
          rig.status();
          _emit(_start());
          rig.status();
        };
        final stop = rig.stopRecording();
        expect(await _isPending(stop), isTrue);
        _emit(_finalize());
        await stop;
      });
    });
  }
}
