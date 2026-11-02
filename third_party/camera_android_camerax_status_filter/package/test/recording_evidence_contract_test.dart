// Synapse Auto (R4.4-HW-MIG-5-SIG-2.1): the private channel's messages, over the real binary messenger
// path, reach the evidence slot only with the identity of the recording it holds, that identity is
// given to native by the real generated constructor before PendingRecording.start, and START/STOP
// stay as they are. The paths here are deliberately all the same.

import 'dart:async';
import 'dart:typed_data' show Endian;

import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_android_camerax/src/camerax_library.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import 'android_camera_camerax_test.mocks.dart';

const int _cameraId = 17;
const String _channel = 'synapse_auto.camera_android_camerax/recording_evidence';
const String _constructorChannel =
    'dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.pigeon_defaultConstructor';
const String _path = '/temp/REC.mp4';

// What VideoRecordEventListenerRecordingEvidenceTest.java captures from the real Java listener for
// identity 0x0123456789AB: verify.sh fails if the two files stop agreeing.
const String _goldenProgress = '0c03070d766964656f50726f677265737304ab8967452301000000';
const String _goldenEnded =
    '0c03070e7265636f7264696e67456e64656404ab896745230100000303000000';
const int _goldenIdentity = 0x0123456789AB;

// VideoRecordEventListenerProxyApi's static counter, as these tests model it: it outlives anything
// here, which is what a new isolate in the same process finds.
int _nativeCounter = 0;
Future<int> _nativeAllocate() async => ++_nativeCounter;

ByteData _bytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return ByteData.sublistView(out);
}

String _hex(ByteData data) => data.buffer
    .asUint8List(data.offsetInBytes, data.lengthInBytes)
    .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

void _emit(VideoRecordEvent event) {
  AndroidCameraCameraX.videoRecordingEventStreamController.add(event);
}

VideoRecordEventStart _start() => VideoRecordEventStart.pigeon_detached();
VideoRecordEventFinalize _finalize() => VideoRecordEventFinalize.pigeon_detached();

Future<void> _deliver(ByteData? message) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    _channel,
    message,
    (_) {},
  );
}

Future<void> _rawNative(Object? message) =>
    _deliver(const StandardMessageCodec().encodeMessage(message));

/// What the native listener sends: one message, through the channel the plugin installed.
Future<void> _native(String kind, int identity, [int? error]) =>
    _rawNative(<Object?>[kind, identity, error]);

class _Rig {
  _Rig({bool realListener = false, this.realAllocator = false}) {
    camera.processCameraProvider = provider;
    camera.recorder = recorder;
    camera.videoCapture = MockVideoCapture();
    camera.cameraSelector = MockCameraSelector();
    camera.cameraInfo = MockCameraInfo();
    camera.imageAnalysis = MockImageAnalysis();
    camera.enableRecordingAudio = false;
    camera.captureOrientationLocked = true;

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
          when(manager.getTempFilePath(camera.videoPrefix, '.mp4')).thenAnswer((_) async => _path);
          return manager;
        };
    PigeonOverrides.videoRecordEventListener_allocateRecordingIdentity = realAllocator
        ? null
        : () async {
            log.add('allocate');
            final int identity = await (allocate ?? _nativeAllocate)();
            allocated.add(identity);
            return identity;
          };
    PigeonOverrides.videoRecordEventListener_new = realListener
        ? null
        : ({
            required void Function(VideoRecordEventListener, VideoRecordEvent) onEvent,
            required int recordingIdentity,
          }) {
            identities.add(recordingIdentity);
            final listener = VideoRecordEventListener.pigeon_detached(onEvent: onEvent);
            listeners.add(listener);
            return listener;
          };
    PigeonOverrides.cameraCharacteristics_infoSupportedHardwareLevel =
        MockCameraCharacteristicsKey();

    final boundCamera = MockCamera();
    final boundInfo = MockCameraInfo();
    when(recorder.prepareRecording(any)).thenAnswer((_) async => pending);
    when(pending.withAudioEnabled(any)).thenAnswer((_) async => pending);
    when(pending.asPersistentRecording()).thenAnswer((_) async => pending);
    when(pending.start(any)).thenAnswer((Invocation invocation) async {
      log.add('start');
      startedWith.add(invocation.positionalArguments.single as VideoRecordEventListener);
      await onNativeStart?.call();
      return nativeRecording;
    });
    when(nativeRecording.close()).thenAnswer((_) async => _emit(_finalize()));
    when(provider.isBound(any)).thenAnswer((_) async => false);
    when(provider.bindToLifecycle(any, any)).thenAnswer((_) async => boundCamera);
    when(boundCamera.getCameraInfo()).thenAnswer((_) async => boundInfo);
    when(boundInfo.getCameraState()).thenAnswer((_) async => MockLiveCameraState());
    when(
      cameraInfo2.getCameraCharacteristic(any),
    ).thenAnswer((_) async => InfoSupportedHardwareLevel.limited);
  }

  final AndroidCameraCameraX camera = AndroidCameraCameraX();
  final MockProcessCameraProvider provider = MockProcessCameraProvider();
  final MockRecorder recorder = MockRecorder();
  final MockPendingRecording pending = MockPendingRecording();
  final MockRecording nativeRecording = MockRecording();
  final bool realAllocator;
  final allocated = <int>[];
  Future<int> Function()? allocate;
  final identities = <int>[];
  final listeners = <VideoRecordEventListener>[];
  final startedWith = <VideoRecordEventListener>[];
  final log = <String>[];
  Future<void> Function()? onNativeStart;

  RecordingEvidence? get evidence => camera.recordingEvidence.value;

  Future<void> startRecording() async {
    onNativeStart ??= () async => _emit(_start());
    await camera.startVideoCapturing(const VideoCaptureOptions(_cameraId));
  }

  Future<XFile> stopRecording() => camera.stopVideoRecording(_cameraId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(PigeonOverrides.pigeon_reset);

  // Synapse Auto (R4.4-HW-MIG-5-SIG-2.3). T1-T3 asserted the same things and failed on the code before
  // the fix (the round's report has that run). Lifecycle here is modeled, not executed: a "previous
  // incarnation" is an identity native handed out that no Dart object of this isolate knows.
  group('identity comes from native', () {
    test('T1: the slot holds what native allocated, and A of the previous incarnation lights nothing', () async {
      final a = await _nativeAllocate(); // A: its listener survives, its isolate does not
      final current = _Rig();
      await current.startRecording();
      expect(current.evidence!.token, current.allocated.single, reason: 'no number of its own');
      expect(current.evidence!.token, isNot(a));

      await _native('videoProgress', a);
      expect(current.evidence!.videoProgress, isFalse, reason: 'A proved nothing about B');

      await _native('videoProgress', current.evidence!.token);
      expect(current.evidence!.videoProgress, isTrue, reason: "B's own first progress");
    });

    test('T1b: the terminal of A of the previous incarnation does not end B', () async {
      final a = await _nativeAllocate();
      final current = _Rig();
      await current.startRecording();
      await _native('recordingEnded', a, 3);
      expect(current.evidence!.ended, isFalse, reason: 'A ended, not B');
    });

    test('allocation, constructor and native START happen in that order, with one value', () async {
      final rig = _Rig();
      rig.onNativeStart = () async {
        rig.log.add('start');
        _emit(_start());
      };
      await rig.startRecording();
      expect(rig.log.where((String e) => e != 'start'), <String>['allocate']);
      expect(rig.identities, rig.allocated, reason: 'the listener carries what was allocated');
      expect(rig.evidence!.token, rig.allocated.single);
    });

    test('one allocation per physical START, none for a START that does nothing or for a STOP', () async {
      final rig = _Rig();
      await rig.startRecording();
      await rig.startRecording(); // `recording` is set: upstream's early return
      expect(rig.allocated, hasLength(1));
      await rig.stopRecording();
      expect(rig.allocated, hasLength(1));
      await rig.startRecording();
      expect(rig.allocated, hasLength(2));
      expect(rig.allocated.toSet(), hasLength(2));
    });

    test('the real generated static call reaches the allocator channel and its reply is the identity', () async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const allocator =
          'dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.allocateRecordingIdentity';
      final rig = _Rig(realAllocator: true);
      messenger.setMockMessageHandler(allocator, (ByteData? message) async {
        rig.log.add('allocate');
        return const StandardMessageCodec().encodeMessage(<Object?>[0x7FFFFFFFFFFF]);
      });
      addTearDown(() => messenger.setMockMessageHandler(allocator, null));

      await rig.startRecording();

      expect(rig.log, <String>['allocate', 'start']);
      expect(rig.identities.single, 0x7FFFFFFFFFFF, reason: 'more than 32 bits survive the path');
      expect(rig.evidence!.token, 0x7FFFFFFFFFFF);
    });

    test('an allocator that fails fails that START before any native recording, and the next one works', () async {
      final rig = _Rig();
      rig.allocate = () async => throw StateError('exhausted');
      await expectLater(rig.startRecording(), throwsStateError);
      expect(rig.startedWith, isEmpty);
      expect(rig.evidence, isNull);
      expect(rig.camera.recording, isNull);

      rig.allocate = null;
      await rig.startRecording();
      expect(rig.evidence!.token, rig.allocated.single);
    });

    test('identities nobody was given are refused: zero, negative, above the counter', () async {
      final rig = _Rig();
      await rig.startRecording();
      final told = <RecordingEvidence?>[];
      rig.camera.recordingEvidence.addListener(() => told.add(rig.evidence));
      for (final identity in <int>[0, -1, _nativeCounter + 1, -9223372036854775808]) {
        await _native('videoProgress', identity);
        await _native('recordingEnded', identity, 3);
      }
      expect(told, isEmpty);
    });
  });

  // Synapse Auto (R4.4-HW-MIG-5-SIG-2.4): what Dart sees of an exhausted allocator is the error reply
  // that VideoRecordEventListenerRecordingEvidenceTest pins on the Java side, through the real generated
  // call. Native and Dart do not run together here.
  group('exhausted allocator', () {
    const allocator =
        'dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.allocateRecordingIdentity';
    const lastIdentity = 9223372036854775806; // Long.MAX_VALUE - 1; MAX_VALUE itself means exhausted.

    _Rig rigWithAllocatorReply(Object? Function() reply) {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final rig = _Rig(realAllocator: true);
      messenger.setMockMessageHandler(allocator, (ByteData? message) async {
        rig.log.add('allocate');
        return const StandardMessageCodec().encodeMessage(reply());
      });
      addTearDown(() => messenger.setMockMessageHandler(allocator, null));
      return rig;
    }

    test('T6: every START fails with the error, and nothing physical began', () async {
      final rig = rigWithAllocatorReply(
        () => <Object?>['IllegalStateException', 'java.lang.IllegalStateException: Recording identities exhausted', null],
      );
      final told = <RecordingEvidence?>[];
      rig.camera.recordingEvidence.addListener(() => told.add(rig.evidence));

      for (var attempt = 1; attempt <= 3; attempt++) {
        await expectLater(
          rig.startRecording().timeout(const Duration(seconds: 5)),
          throwsA(
            isA<PlatformException>()
                .having((PlatformException e) => e.code, 'code', 'IllegalStateException')
                .having((PlatformException e) => e.message, 'message', 'java.lang.IllegalStateException: Recording identities exhausted'),
          ),
        );
        expect(rig.log, List<String>.filled(attempt, 'allocate'), reason: 'no native START');
        expect(rig.identities, isEmpty, reason: 'no listener with an identity nobody allocated');
        expect(rig.startedWith, isEmpty);
        expect(rig.evidence, isNull);
        expect(rig.camera.recording, isNull);
        expect(rig.camera.pendingRecording, isNull);
        expect(rig.camera.videoOutputPath, isNull);
      }
      verifyNever(rig.provider.bindToLifecycle(any, any));
      verifyNever(rig.recorder.prepareRecording(any));
      expect(told.whereType<RecordingEvidence>(), isEmpty);
    });

    test('T7: an error reply adopts no number: late messages of any identity light nothing', () async {
      final rig = rigWithAllocatorReply(
        () => <Object?>['IllegalStateException', 'java.lang.IllegalStateException: Recording identities exhausted', null],
      );
      final owners = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      await expectLater(rig.startRecording(), throwsA(isA<PlatformException>()));
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, owners);
      for (final identity in <int>[0, -1, 1, lastIdentity, 9223372036854775807]) {
        await _native('videoProgress', identity);
        expect(rig.evidence, isNull);
      }
    });

    test('T8: the last identity is the same number in the slot, the listener and the message', () async {
      final rig = rigWithAllocatorReply(() => <Object?>[lastIdentity]);
      await rig.startRecording();
      expect(rig.log, <String>['allocate', 'start']);
      expect(rig.identities.single, lastIdentity);
      expect(rig.evidence!.token, lastIdentity);
      await _native('videoProgress', lastIdentity);
      expect(rig.evidence!.token, lastIdentity);
      expect(rig.evidence!.videoProgress, isTrue);
    });

    test('a dispose after those failures still completes', () async {
      final rig = rigWithAllocatorReply(
        () => <Object?>['IllegalStateException', 'java.lang.IllegalStateException: Recording identities exhausted', null],
      );
      await expectLater(rig.startRecording(), throwsA(isA<PlatformException>()));
      await rig.camera.dispose(_cameraId).timeout(const Duration(seconds: 5));
      expect(rig.evidence, isNull);
    });
  });

  group('dispose withdraws the evidence before its first await', () {
    Completer<void> holdRelease(_Rig rig) {
      final gate = Completer<void>();
      rig.camera.preview = MockPreview();
      when(rig.camera.preview!.releaseSurfaceProvider()).thenAnswer((_) => gate.future);
      return gate;
    }

    test('T2: suspended at its first await, it refuses progress and terminal of its recording', () async {
      final rig = _Rig();
      await rig.startRecording();
      final token = rig.evidence!.token;
      final gate = holdRelease(rig);
      final disposing = rig.camera.dispose(_cameraId);

      await _native('videoProgress', token);
      await _native('recordingEnded', token, 3);
      expect(rig.evidence, isNull);

      gate.complete();
      await disposing;
      expect(rig.evidence, isNull);
    });

    test('T2b: slot and owner are gone in the synchronous prefix', () async {
      final rig = _Rig();
      await rig.startRecording();
      final owners = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      final gate = holdRelease(rig);
      final disposing = rig.camera.dispose(_cameraId);
      expect(rig.evidence, isNull);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, owners - 1);
      gate.complete();
      await disposing;
    });

    test('T3: a failing release leaves no registration, keeps the error, and evidence stays refused', () async {
      final rig = _Rig();
      await rig.startRecording();
      final token = rig.evidence!.token;
      final owners = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      rig.camera.preview = MockPreview();
      when(rig.camera.preview!.releaseSurfaceProvider()).thenAnswer((_) async => throw StateError('release failed'));

      await expectLater(rig.camera.dispose(_cameraId), throwsStateError);

      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, owners - 1);
      await _native('videoProgress', token);
      await _native('recordingEnded', token, 3);
      expect(rig.evidence, isNull);
    });

    for (final (String step, void Function(_Rig) arm) in <(String, void Function(_Rig))>[
      ('unbindAll', (_Rig r) => when(r.provider.unbindAll()).thenAnswer((_) async => throw StateError('x'))),
      ('clearAnalyzer', (_Rig r) => when(r.camera.imageAnalysis!.clearAnalyzer()).thenAnswer((_) async => throw StateError('x'))),
    ]) {
      test('a failure at $step instead of the first step changes nothing', () async {
        final rig = _Rig();
        await rig.startRecording();
        final token = rig.evidence!.token;
        arm(rig);
        await expectLater(rig.camera.dispose(_cameraId), throwsStateError);
        await _native('videoProgress', token);
        expect(rig.evidence, isNull);
      });
    }

    test('the release keeps its order and its recording state rules', () async {
      final rig = _Rig();
      await rig.startRecording();
      final order = <String>[];
      rig.camera.preview = MockPreview();
      when(rig.camera.preview!.releaseSurfaceProvider()).thenAnswer((_) async => order.add('surface'));
      when(rig.provider.unbindAll()).thenAnswer((_) async => order.add('unbind'));
      when(rig.camera.imageAnalysis!.clearAnalyzer()).thenAnswer((_) async => order.add('analyzer'));
      await rig.camera.dispose(_cameraId);
      expect(order, <String>['surface', 'unbind', 'analyzer']);
      expect(rig.camera.recording, isNull);
      expect(rig.camera.pendingRecording, isNull);
      expect(rig.camera.videoOutputPath, isNull);
    });

    test('after a failed release `recording` stays as upstream left it, and evidence does not return', () async {
      final rig = _Rig();
      await rig.startRecording();
      rig.camera.preview = MockPreview();
      when(rig.camera.preview!.releaseSurfaceProvider()).thenAnswer((_) async => throw StateError('x'));
      await expectLater(rig.camera.dispose(_cameraId), throwsStateError);
      expect(rig.camera.recording, rig.nativeRecording);
      await rig.startRecording(); // upstream's early return: nothing new is bound
      expect(rig.evidence, isNull);
      expect(rig.allocated, hasLength(1));
    });

    test('dispose twice in a row, and twice at once, is safe', () async {
      final rig = _Rig();
      await rig.startRecording();
      final owners = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      await rig.camera.dispose(_cameraId);
      await rig.camera.dispose(_cameraId);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, owners - 1);

      final first = Completer<void>();
      final second = Completer<void>();
      final gates = <Completer<void>>[first, second];
      rig.camera.preview = MockPreview();
      when(rig.camera.preview!.releaseSurfaceProvider()).thenAnswer((_) => gates.removeAt(0).future);
      final disposing = <Future<void>>[rig.camera.dispose(_cameraId), rig.camera.dispose(_cameraId)];
      first.complete();
      await disposing[0];

      // One dispose is still running: a START now holds nothing.
      await rig.startRecording();
      expect(rig.evidence, isNull, reason: 'the first dispose must not reopen what the second holds');

      second.complete();
      await disposing[1];
    });

    test("an old instance's dispose does not remove the entry of the instance that now holds the number", () async {
      // Cannot happen with native's counter: forced, so that this rule does not rest on that one.
      final old = _Rig();
      old.allocate = () async => 424242;
      await old.startRecording();
      final replacement = _Rig();
      replacement.allocate = () async => 424242;
      await replacement.startRecording();
      final owners = AndroidCameraCameraX.recordingEvidenceOwnerCount;

      await old.camera.dispose(_cameraId);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, owners, reason: 'not its entry');
      expect(old.evidence, isNull);

      await _native('videoProgress', 424242);
      expect(replacement.evidence!.videoProgress, isTrue);
      await replacement.camera.dispose(_cameraId);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, owners - 1);
    });

    test('a START caught by a dispose never holds evidence, and the next START does', () async {
      final rig = _Rig();
      final allocating = Completer<int>();
      rig.allocate = () => allocating.future;
      rig.onNativeStart = () async => _emit(_start());
      final starting = rig.camera.startVideoCapturing(const VideoCaptureOptions(_cameraId));
      await pumpEventQueue();
      expect(rig.log, <String>['allocate'], reason: 'test setup');

      await rig.camera.dispose(_cameraId);
      allocating.complete(_nativeCounter + 1000);
      await starting;

      expect(rig.evidence, isNull);
      expect(rig.startedWith, hasLength(1), reason: 'the physical START is not this code to cancel');
      await _native('videoProgress', _nativeCounter + 1000);
      expect(rig.evidence, isNull, reason: 'late, the same identity finds nobody');

      await rig.stopRecording();
      rig.allocate = null;
      await rig.startRecording();
      expect(rig.evidence!.token, rig.allocated.last, reason: 'the instance is reused by a new camera');
      await _native('videoProgress', rig.evidence!.token);
      expect(rig.evidence!.videoProgress, isTrue);
    });

    test('a START that begins while a dispose is suspended holds nothing, before or after it ends', () async {
      final rig = _Rig();
      await rig.startRecording();
      await rig.stopRecording();
      final gate = holdRelease(rig);
      final disposing = rig.camera.dispose(_cameraId);

      final allocating = Completer<int>();
      rig.allocate = () => allocating.future;
      final starting = rig.camera.startVideoCapturing(const VideoCaptureOptions(_cameraId));
      await pumpEventQueue();

      gate.complete();
      await disposing;
      allocating.complete(_nativeCounter + 2000);
      await starting;
      expect(rig.evidence, isNull);
    });
  });

  test('a new camera on the same instance: the previous one cannot reach it, its own recording can', () async {
    final rig = _Rig();
    await rig.startRecording();
    final previous = rig.evidence!.token;
    rig.camera.preview = MockPreview();
    when(rig.camera.preview!.releaseSurfaceProvider()).thenAnswer((_) async => throw StateError('x'));
    await expectLater(rig.camera.dispose(_cameraId), throwsStateError);
    when(rig.camera.preview!.releaseSurfaceProvider()).thenAnswer((_) async {});
    await rig.camera.dispose(_cameraId);

    await rig.startRecording();
    await _native('videoProgress', previous);
    expect(rig.evidence!.videoProgress, isFalse);
    await _native('videoProgress', rig.evidence!.token);
    expect(rig.evidence!.videoProgress, isTrue);
  });

  test('N6: a message delivered while the native START runs is not lost', () async {
    // The handler is static and never removed: left by an earlier test, it would hide a late install.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMessageHandler(_channel, null);
    final rig = _Rig();
    rig.onNativeStart = () async {
      await _native('videoProgress', rig.identities.last);
      _emit(_start());
    };
    await rig.startRecording();
    expect(rig.evidence!.videoProgress, isTrue);
  });

  test('the identity exists before the native START; Start alone proves no video', () async {
    final rig = _Rig();
    int? tokenAtNativeStart;
    rig.onNativeStart = () async {
      tokenAtNativeStart = rig.evidence?.token;
      _emit(_start());
    };
    await rig.startRecording();
    expect(tokenAtNativeStart, rig.identities.single);
    expect(rig.evidence!.token, tokenAtNativeStart);
    expect(rig.evidence!.videoProgress, isFalse);
    expect(rig.evidence!.ended, isFalse);
  });

  test('the listener given to START is the one created with the identity in the slot', () async {
    final rig = _Rig();
    await rig.startRecording();
    await rig.stopRecording();
    await rig.startRecording();
    expect(rig.startedWith, rig.listeners, reason: 'one each, in order');
    expect(rig.listeners.toSet(), hasLength(2));
    expect(rig.identities.toSet(), hasLength(2));
    expect(rig.evidence!.token, rig.identities.last);
  });

  test('the real generated constructor gives native the identity before start', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final rig = _Rig(realListener: true);
    Object? constructorMessage;
    messenger.setMockMessageHandler(_constructorChannel, (ByteData? message) async {
      rig.log.add('constructor');
      constructorMessage = const StandardMessageCodec().decodeMessage(message);
      return const StandardMessageCodec().encodeMessage(<Object?>[null]);
    });
    addTearDown(() => messenger.setMockMessageHandler(_constructorChannel, null));

    await rig.startRecording();

    expect(rig.log, <String>['allocate', 'constructor', 'start'], reason: 'bound before the native START');
    expect((constructorMessage! as List<Object?>)[1], rig.evidence!.token);
  });

  test('the bytes the Java listener sends are what this handler understands', () async {
    expect(
      _hex(
        const StandardMessageCodec().encodeMessage(<Object?>[
          'videoProgress',
          _goldenIdentity,
          null,
        ])!,
      ),
      _goldenProgress,
    );
    expect(
      _hex(
        const StandardMessageCodec().encodeMessage(<Object?>[
          'recordingEnded',
          _goldenIdentity,
          3,
        ])!,
      ),
      _goldenEnded,
    );
    // Only for the identity in the slot: the same bytes are refused for any other recording.
    final rig = _Rig();
    await rig.startRecording();
    final before = rig.evidence;
    await _deliver(_bytes(_goldenProgress));
    await _deliver(_bytes(_goldenEnded));
    expect(identical(rig.evidence, before), isTrue);
  });

  test('N2: the same path, another recording: messages of A have no slot to land on', () async {
    final rig = _Rig();
    await rig.startRecording();
    final a = rig.identities.last;
    await rig.stopRecording();
    await rig.startRecording();
    final told = <RecordingEvidence?>[];
    rig.camera.recordingEvidence.addListener(() => told.add(rig.evidence));

    await _native('videoProgress', a);
    await _native('recordingEnded', a, 3);

    expect(told, isEmpty);
    expect(rig.evidence!.videoProgress, isFalse);
    expect(rig.evidence!.ended, isFalse);

    await _native('videoProgress', rig.identities.last);
    expect(rig.evidence!.videoProgress, isTrue);
  });

  test('progress after the end changes nothing', () async {
    final rig = _Rig();
    await rig.startRecording();
    final identity = rig.identities.last;
    await _native('recordingEnded', identity, 3);
    await _native('videoProgress', identity);
    expect(rig.evidence!.ended, isTrue);
    expect(rig.evidence!.endError, 3);
    expect(rig.evidence!.videoProgress, isFalse);
  });

  test('a duplicate tells nobody', () async {
    final rig = _Rig();
    await rig.startRecording();
    final identity = rig.identities.last;
    await _native('videoProgress', identity);
    var told = 0;
    rig.camera.recordingEvidence.addListener(() => told++);
    await _native('videoProgress', identity);
    await _native('recordingEnded', identity, 0);
    await _native('recordingEnded', identity, 3);
    expect(told, 1, reason: 'only the first terminal');
    expect(rig.evidence!.endError, 0);
  });

  test('malformed messages are dropped without an error', () async {
    final rig = _Rig();
    await rig.startRecording();
    final identity = rig.identities.last;
    for (final Object? message in <Object?>[
      null,
      'videoProgress',
      <Object?>['videoProgress'],
      <Object?>['videoProgress', identity],
      <Object?>['unknown', identity, null],
      <Object?>['recordingEnded', identity, 'three'],
      <Object?>['videoProgress', identity, 'not null'],
      <Object?>['videoProgress', identity, 3],
      <Object?>['videoProgress', _path, null],
      <Object?>['recordingEnded', _path, 3],
      <Object?>['videoProgress', '$identity', null],
      <Object?>[1, 2, 3],
    ]) {
      await _rawNative(message);
    }
    expect(rig.evidence!.videoProgress, isFalse);
    expect(rig.evidence!.ended, isFalse);
  });

  test('dispose lets go of the recording: late messages find no slot', () async {
    final rig = _Rig();
    await rig.startRecording();
    final identity = rig.identities.last;
    await rig.camera.dispose(_cameraId);
    expect(rig.evidence, isNull);
    await _native('videoProgress', identity);
    await _native('recordingEnded', identity, 4);
    expect(rig.evidence, isNull);
  });

  test('START and STOP still end on Start and Finalize alone, not on the channel', () async {
    final rig = _Rig();
    rig.onNativeStart = () async {
      await _native('videoProgress', rig.identities.last);
      _emit(_start());
    };
    await rig.startRecording();
    await _native('recordingEnded', rig.identities.last, 0);
    expect(rig.camera.recording, rig.nativeRecording, reason: 'a channel message ends nothing');
    expect((await rig.stopRecording()).path, _path);
    expect(rig.camera.recording, isNull);
  });

  test('a channel that delivers nothing leaves no evidence and the recording unaffected', () async {
    final rig = _Rig();
    await rig.startRecording();
    expect(rig.evidence!.videoProgress, isFalse);
    expect(rig.camera.recording, rig.nativeRecording);
    expect((await rig.stopRecording()).path, _path);
  });

  test('the golden layout is accepted once the identity bytes are the slot\'s', () async {
    // Native chooses the identity, so the eight bytes that hold it are the only ones replaced.
    String withToken(String golden, int token) {
      final bytes = ByteData(8)..setInt64(0, token, Endian.little);
      return golden.replaceFirst('ab89674523010000', _hex(bytes));
    }

    final rig = _Rig();
    await rig.startRecording();
    final token = rig.evidence!.token;
    await _deliver(_bytes(withToken(_goldenProgress, token)));
    expect(rig.evidence!.videoProgress, isTrue);
    await _deliver(_bytes(withToken(_goldenEnded, token)));
    expect(rig.evidence!.ended, isTrue);
    expect(rig.evidence!.endError, 3);
  });

  group('channel ownership', () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    test('a second instance does not take the channel from the first', () async {
      final first = _Rig();
      await first.startRecording();
      final second = _Rig();
      await second.startRecording();
      final firstIdentity = first.evidence!.token;
      final secondIdentity = second.evidence!.token;
      expect(secondIdentity, isNot(firstIdentity));

      await _native('videoProgress', firstIdentity);
      expect(first.evidence!.videoProgress, isTrue, reason: 'its recording is still heard');
      expect(second.evidence!.videoProgress, isFalse, reason: 'and nobody else hears it');

      await _native('recordingEnded', secondIdentity, 3);
      expect(second.evidence!.ended, isTrue);
      expect(first.evidence!.ended, isFalse);
    });

    test('dispose of one instance neither stops the other nor stays referenced', () async {
      final base = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      final first = _Rig();
      await first.startRecording();
      final second = _Rig();
      await second.startRecording();
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, base + 2);
      final firstIdentity = first.evidence!.token;

      await first.camera.dispose(_cameraId);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, base + 1);

      await _native('videoProgress', firstIdentity);
      expect(first.evidence, isNull, reason: 'a late message finds no owner');
      await _native('videoProgress', second.evidence!.token);
      expect(second.evidence!.videoProgress, isTrue);

      await second.camera.dispose(_cameraId);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, base);
    });

    test('recordings do not accumulate owners', () async {
      final rig = _Rig();
      await rig.startRecording();
      final base = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      for (var i = 0; i < 5; i++) {
        await rig.stopRecording();
        await rig.startRecording();
        expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, base);
      }
    });

    test('a displaced handler reads as no proof, and the next START takes the channel back', () async {
      final rig = _Rig();
      await rig.startRecording();
      final lost = rig.evidence!.token;
      final foreign = <Object?>[];
      const BasicMessageChannel<Object?> other = BasicMessageChannel<Object?>(
        _channel,
        StandardMessageCodec(),
      );
      other.setMessageHandler((Object? message) async => foreign.add(message));

      await _native('videoProgress', lost);
      expect(foreign, hasLength(1));
      expect(rig.evidence!.videoProgress, isFalse, reason: 'no proof, so no REC');

      await rig.stopRecording();
      await rig.startRecording();
      await _native('videoProgress', lost);
      expect(rig.evidence!.videoProgress, isFalse, reason: 'old, on the handler installed again');
      await _native('videoProgress', rig.evidence!.token);
      expect(rig.evidence!.videoProgress, isTrue);
      expect(foreign, hasLength(1), reason: 'the displacing handler is gone');
    });

    test('a message that never arrives costs that recording only', () async {
      final rig = _Rig();
      await rig.startRecording();
      expect(rig.evidence!.videoProgress, isFalse);
      await rig.stopRecording();
      await rig.startRecording();
      expect(rig.evidence!.videoProgress, isFalse);
      await _native('videoProgress', rig.evidence!.token);
      expect(rig.evidence!.videoProgress, isTrue);
    });

    test('a message before any handler is kept by the framework and refused by identity', () async {
      // What a recording that survived a hot restart can do in the new isolate before its first START.
      messenger.setMessageHandler(_channel, null);
      final early = const StandardMessageCodec().encodeMessage(<Object?>['videoProgress', 1, null]);
      await _deliver(early);
      final rig = _Rig();
      final told = <RecordingEvidence?>[];
      rig.camera.recordingEvidence.addListener(() => told.add(rig.evidence));
      await rig.startRecording();
      await pumpEventQueue();
      expect(rig.evidence!.videoProgress, isFalse);
      expect(told.where((RecordingEvidence? e) => e?.videoProgress ?? false), isEmpty);
    });
  });

  test('currentRecordingEvidenceSource reports the registered platform only if it provides evidence', () {
    final previous = CameraPlatform.instance;
    addTearDown(() => CameraPlatform.instance = previous);
    final camera = AndroidCameraCameraX();
    CameraPlatform.instance = camera;
    expect(identical(currentRecordingEvidenceSource(), camera), isTrue);
  });
}
