// Fase 16.2-R4.4-HW-MIG-5-SIG-2.1 — every native videoProgress/recordingEnded belongs to the physical
// recording that produced it, from its START, even with a reused path, late callbacks and channels
// out of order. Nothing of the plugin or the service is faked here: the real AndroidCameraCameraX runs
// on top of native objects held by the test (_Native), real CameraController and DashcamService run on
// top of it, and messages reach the plugin's real handler as encoded bytes through the real messenger.
//
// _Native holds no identity logic: it keeps what the plugin handed to each START and sends it back.
// Its wire format is pinned against Java by the bytes shared with the JUnit test (see
// recording_evidence_contract_test.dart and verify.sh).
import 'dart:async';
import 'dart:io';

import 'package:camera_android_camerax/camera_android_camerax.dart';
// ignore: implementation_imports
import 'package:camera_android_camerax/src/camerax_library.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/screens/sessions/session_recording_screen.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/unit_preferences.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_preview_view.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_rec_indicator.dart';

import 'support/index_queue_isolation.dart';

const _channel = 'synapse_auto.camera_android_camerax/recording_evidence';

/// One physical recording, as the Android side knows it.
class _Recording extends Fake implements Recording {
  _Recording(this.native, this.path, this.listener, this.identity);

  final _Native native;
  final String path;
  final VideoRecordEventListener listener;
  final Object identity;

  /// What `VideoRecordEventListenerImpl` encodes at the moment it sends. Pending bytes do not change
  /// when the next recording starts.
  ByteData message(String kind, [int? error]) => const StandardMessageCodec().encodeMessage(<Object?>[kind, identity, error])!;

  void emitPigeon(VideoRecordEvent event) => listener.onEvent(listener, event);

  void writeFile() => File(path).writeAsBytesSync(List<int>.filled(1024, 0));

  /// The recording ends with no STOP: its private message and its Finalize, as the listener sends them.
  Future<void> endSpontaneously(int error) async {
    writeFile();
    native.finalized.add(this);
    await deliver(message('recordingEnded', error));
    emitPigeon(VideoRecordEventFinalize.pigeon_detached());
  }

  @override
  Future<void> close() async {
    if (native.finalized.contains(this)) return;
    writeFile();
    final gate = native.holdFinalize;
    if (gate != null) await gate.future;
    native.finalized.add(this);
    emitPigeon(VideoRecordEventFinalize.pigeon_detached());
  }
}

/// A message on the private channel, through the handler the plugin registered on the real messenger.
Future<void> deliver(ByteData? message) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(_channel, message, (_) {});
}

Future<void> deliverRaw(Object? message) => deliver(const StandardMessageCodec().encodeMessage(message));

/// The Android side of the plugin, in the test's hands.
class _Native {
  _Native(this.path);

  /// Always the same: what `File.createTempFile` may return again once the previous file was moved.
  final String path;
  final recordings = <_Recording>[];
  final listeners = <VideoRecordEventListener>{};
  final finalized = <_Recording>{};
  Completer<void>? holdStartEvent;
  Completer<void>? holdFinalize;
  Object? failStartWith;
  Object? failAllocationWith;
  var allocations = 0;
  var allocationAttempts = 0;

  final _held = <Completer<void>>[];
  Completer<void> gate() {
    final completer = Completer<void>();
    _held.add(completer);
    return completer;
  }

  void releaseEverything() {
    holdStartEvent = null;
    holdFinalize = null;
    failStartWith = null;
    failAllocationWith = null;
    for (final completer in _held) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  _Recording get last => recordings.last;

  /// Only a free name comes back, as with a real `createTempFile`, which also creates the file.
  Future<String> temporaryFile() async {
    final clock = Stopwatch()..start();
    while (File(path).existsSync()) {
      if (clock.elapsed > const Duration(seconds: 4)) fail('the previous recording never left $path');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    File(path).writeAsBytesSync(const <int>[]);
    return path;
  }

  _Recording start(VideoRecordEventListener listener) {
    final failure = failStartWith;
    if (failure != null) throw failure;
    final recording = _Recording(this, path, listener, _identityOf[listener]!);
    recordings.add(recording);
    listeners.add(listener);
    final gate = holdStartEvent;
    if (gate == null) {
      recording.emitPigeon(VideoRecordEventStart.pigeon_detached());
    } else {
      unawaited(gate.future.then((_) => recording.emitPigeon(VideoRecordEventStart.pigeon_detached())));
    }
    return recording;
  }
}

/// `VideoRecordEventListenerProxyApi`'s static counter. Not reset by anything here, as nothing in a Dart
/// isolate resets the real one.
var _processCounter = 0;

/// The identity each listener was created with: what the constructor message carried to native.
final _identityOf = Expando<Object>();

// ignore: must_be_immutable
class _FakeProvider extends Fake implements ProcessCameraProvider {
  _FakeProvider(this.videoCapture);
  final VideoCapture videoCapture;
  Future<void> Function()? onUnbindAll;
  @override
  Future<bool> isBound(UseCase useCase) async => identical(useCase, videoCapture);
  @override
  Future<void> unbind(List<UseCase> useCases) async {}
  @override
  Future<void> unbindAll() async => onUnbindAll?.call();
}

class _FakeVideoCapture extends Fake implements VideoCapture {}

class _FakeImageAnalysis extends Fake implements ImageAnalysis {
  @override
  Future<void> clearAnalyzer() async {}
}

class _FakePending extends Fake implements PendingRecording {
  _FakePending(this.native);
  final _Native native;
  @override
  Future<PendingRecording> withAudioEnabled(bool initialMuted) async => this;
  @override
  Future<PendingRecording> asPersistentRecording() async => this;
  @override
  Future<Recording> start(VideoRecordEventListener listener) async => native.start(listener);
}

class _FakeRecorder extends Fake implements Recorder {
  _FakeRecorder(this.native);
  final _Native native;
  @override
  Future<PendingRecording> prepareRecording(String path) async => _FakePending(native);
}

class _FakeSystemServices extends Fake implements SystemServicesManager {
  _FakeSystemServices(this.native);
  final _Native native;
  @override
  Future<String> getTempFilePath(String prefix, String suffix) => native.temporaryFile();
}

class _FakeOrientation extends Fake implements DeviceOrientationManager {
  @override
  Future<void> stopListeningForDeviceOrientationChange() async {}
}

/// The real plugin. Overridden: only what brings a camera up, which this file is not about.
/// `startVideoCapturing`, `stopVideoRecording`, `dispose` and the channel handler are the plugin's own.
class _RealPlugin extends AndroidCameraCameraX {
  _RealPlugin(_Native native) {
    final capture = _FakeVideoCapture();
    videoCapture = capture;
    imageAnalysis = _FakeImageAnalysis();
    processCameraProvider = provider = _FakeProvider(capture);
    recorder = _FakeRecorder(native);
    enableRecordingAudio = false;
    captureOrientationLocked = true;
  }

  late final _FakeProvider provider;
  int _nextCameraId = 0;
  final _errors = StreamController<CameraErrorEvent>.broadcast();
  final _closing = StreamController<CameraClosingEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => const [CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90)];
  @override
  Future<int> createCameraWithSettings(CameraDescription cameraDescription, MediaSettings? mediaSettings) async => _nextCameraId++;
  @override
  Future<void> initializeCamera(int cameraId, {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) => Stream.value(CameraInitializedEvent(cameraId, 1920, 1080, ExposureMode.auto, false, FocusMode.auto, false));
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;
  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) => _closing.stream;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() => const Stream.empty();
  @override
  Future<void> prepareForVideoRecording() async {}
  @override
  Future<void> pausePreview(int cameraId) async {}
  @override
  Future<void> resumePreview(int cameraId) async {}
  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand();
}

void _installNative(_Native native) {
  PigeonOverrides.systemServicesManager_new = ({required void Function(SystemServicesManager, String) onCameraError}) => _FakeSystemServices(native);
  PigeonOverrides.deviceOrientationManager_new = ({required void Function(DeviceOrientationManager, String) onDeviceOrientationChanged}) => _FakeOrientation();
  PigeonOverrides.videoRecordEventListener_allocateRecordingIdentity = () async {
    native.allocationAttempts++;
    final failure = native.failAllocationWith;
    if (failure != null) throw failure;
    native.allocations++;
    return ++_processCounter;
  };
  PigeonOverrides.videoRecordEventListener_new = ({required int recordingIdentity, required void Function(VideoRecordEventListener, VideoRecordEvent) onEvent}) {
    final listener = VideoRecordEventListener.pigeon_detached(onEvent: onEvent);
    _identityOf[listener] = recordingIdentity;
    return listener;
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory dir;
  late _Native native;
  late _RealPlugin plugin;
  late DashcamService service;
  final ticks = <void Function()>[];
  final told = <DashcamSegmentPresentation>[];
  final errors = <DashcamServiceError>[];

  DashcamSegmentPresentation shown() => service.segmentPresentationListenable.value;

  Future<void> until(bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > const Duration(seconds: 10)) fail('never happened: $what (presentation=${shown().name}, recordings=${native.recordings.length})');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> errorsDelivered() => pumpEventQueue();

  void build() {
    service = DashcamService(
      config: DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: 1024, audioEnabled: false, resolution: VideoResolution.hd720, frameRate: 30, enabled: true),
      segmentDuration: const Duration(minutes: 10),
    );
    service.segmentTimerArmedHookForTest = ticks.add;
    service.segmentPresentationListenable.addListener(() => told.add(shown()));
    service.originatedErrors.listen(errors.add);
  }

  Future<void> record() async {
    build();
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'session-A');
  }

  Future<void> rotationSettled() => until(() => service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop, 'the rotation settling');

  /// A rotation to the next recording, which gets the same path, all the way to its adoption.
  Future<void> rotate() async {
    final before = native.recordings.length;
    ticks.last();
    await until(() => native.recordings.length == before + 1, 'the next recording starting');
    await rotationSettled();
    expect(native.last.path, native.recordings[before - 1].path, reason: 'the scenario needs the path reused');
    expect(service.previewController!.value.isRecordingVideo, isTrue, reason: 'test setup');
  }

  setUp(() {
    ticks.clear();
    told.clear();
    errors.clear();
    dir = Directory.systemTemp.createTempSync('dashcam_recording_identity_protocol_test');
    native = _Native('${dir.path}/REC_same.mp4');
    _installNative(native);
    plugin = _RealPlugin(native);
    CameraPlatform.instance = plugin;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    native.releaseEverything();
    await service.dispose().catchError((_) {});
    await until(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the release in tearDown');
    await indexQueueSettledForTest();
    PigeonOverrides.pigeon_reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A clip still being closed on Windows; the system temp folder takes it.
    }
  });

  group('recording B on the path of recording A', () {
    test('X565 — late progress of A does not light REC for B (Codex AUD-01, step 4)', () async {
      await record();
      final a = native.last;
      final pendingProgress = a.message('videoProgress');
      await rotate();
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'B has no video yet');

      await deliver(pendingProgress);

      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'that progress is of A');
      expect(told, isNot(contains(DashcamSegmentPresentation.videoConfirmed)));

      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed, reason: 'B can still confirm itself');
    });

    test('X566 — late terminal of A does not end B (Codex AUD-01, step 6)', () async {
      await record();
      final a = native.last;
      final pendingEnd = a.message('recordingEnded', 3);
      await rotate();

      await deliver(pendingEnd);

      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'that end is of A');
      await errorsDelivered();
      expect(errors, isEmpty, reason: 'B did not end');

      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X567 — progress and then terminal of A, both pending, after B is confirmed: B stays red, no failure', () async {
      await record();
      final a = native.last;
      final pending = [a.message('videoProgress'), a.message('recordingEnded', 0)];
      await rotate();
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
      final told0 = told.length;

      for (final message in pending) {
        await deliver(message);
      }

      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
      expect(told.length, told0, reason: 'nothing published');
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    test('X568 — callbacks in inverted order: terminal of A, then progress of A, then progress of B', () async {
      await record();
      final a = native.last;
      final pending = [a.message('recordingEnded', 3), a.message('videoProgress')];
      await rotate();

      for (final message in pending) {
        await deliver(message);
        expect(shown(), DashcamSegmentPresentation.startPending);
      }
      await deliver(native.last.message('videoProgress'));

      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    test('X569 — progress of B before its Start crosses Pigeon: kept for B, while one of A in the same window counts for nobody', () async {
      await record();
      final a = native.last;
      final pendingOfA = a.message('videoProgress');
      final startEvent = native.gate();
      native.holdStartEvent = startEvent;
      ticks.last();
      await until(() => native.recordings.length == 2, 'the native START of B');
      native.holdStartEvent = null;

      await deliver(pendingOfA);
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'B is not adopted before its START returns');
      expect(plugin.recordingEvidence.value!.videoProgress, isTrue, reason: 'but its fact is not lost');

      startEvent.complete();
      await rotationSettled();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X570 — without B\'s own progress, a Start with A\'s progress in the same window stays neutral', () async {
      await record();
      final a = native.last;
      final pendingOfA = a.message('videoProgress');
      final startEvent = native.gate();
      native.holdStartEvent = startEvent;
      ticks.last();
      await until(() => native.recordings.length == 2, 'the native START of B');
      native.holdStartEvent = null;

      await deliver(pendingOfA);
      expect(plugin.recordingEvidence.value!.videoProgress, isFalse, reason: 'the fact of A is not recorded for B');

      startEvent.complete();
      await rotationSettled();
      expect(shown(), DashcamSegmentPresentation.startPending);
    });

    test('X571 — A\'s private messages arrive before its Finalize crosses Pigeon: the requested STOP reports nothing and A\'s evidence is gone', () async {
      await record();
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
      final finalize = native.gate();
      native.holdFinalize = finalize;

      ticks.last();
      await until(() => shown() == DashcamSegmentPresentation.transitioning, 'the rotation withdrawing');
      await deliver(native.last.message('recordingEnded', 0));
      expect(shown(), DashcamSegmentPresentation.transitioning);

      native.holdFinalize = null;
      finalize.complete();
      await until(() => native.recordings.length == 2, 'B starting');
      await rotationSettled();
      expect(shown(), DashcamSegmentPresentation.startPending);
      await errorsDelivered();
      expect(errors, isEmpty);
    });
  });

  group('identity', () {
    test('X572 — one listener per physical recording, each with an identity of its own, available before its START', () async {
      await record();
      await rotate();
      await rotate();
      expect(native.listeners, hasLength(3));
      expect(native.recordings.map((r) => r.identity).toSet(), hasLength(3));
      expect(native.recordings.map((r) => r.path).toSet(), hasLength(1));
      expect(plugin.recordingEvidence.value!.token, native.last.identity, reason: 'the service adopts what native was given');
    });

    test('X573 — an identity nobody was given, and any message before the first START, change nothing', () async {
      build();
      await service.initialize();
      // Nothing started: the handler may not even exist yet, and the slot must stay empty.
      await deliverRaw(<Object?>['videoProgress', 7, null]);
      expect(plugin.recordingEvidence.value, isNull);

      await service.startLoopRecording(clipOwnerToken: 'session-A');
      final mine = plugin.recordingEvidence.value!.token;
      await deliverRaw(<Object?>['videoProgress', mine + 1, null]);
      await deliverRaw(<Object?>['recordingEnded', mine - 1, 3]);
      expect(shown(), DashcamSegmentPresentation.startPending);
      expect(plugin.recordingEvidence.value!.videoProgress, isFalse);
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    test('X574 — invalid messages through the real codec: dropped, with no error and no change, the path of the SIG-2 format among them', () async {
      await record();
      final identity = native.last.identity;
      final told0 = told.length;
      for (final Object? message in <Object?>[
        null,
        'videoProgress',
        <Object?>['videoProgress'],
        <Object?>['videoProgress', identity],
        <Object?>['videoProgress', identity, null, null],
        <Object?>['unknown', identity, null],
        <Object?>['recordingEnded', identity, 'three'],
        <Object?>['videoProgress', native.path, null],
        <Object?>['recordingEnded', native.path, 3],
        <Object?>['videoProgress', '$identity', null],
        <Object?>[identity, 'videoProgress', null],
        <Object?>[1, 2, 3],
      ]) {
        await deliverRaw(message);
      }
      expect(told.length, told0);
      expect(plugin.recordingEvidence.value!.videoProgress, isFalse);
      expect(plugin.recordingEvidence.value!.ended, isFalse);
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    // Not a new engine or process: same isolate. Those are in the fork's README and in X590-X592.
    test('X575 — a new plugin instance in the same isolate: the identities of the previous one mean nothing to it', () async {
      await record();
      final pending = [native.last.message('videoProgress'), native.last.message('recordingEnded', 3)];
      await service.dispose();
      await until(() => service.previewController == null, 'the release');
      told.clear();

      final next = _Native('${dir.path}/REC_same.mp4');
      _installNative(next);
      final nextPlugin = _RealPlugin(next);
      CameraPlatform.instance = nextPlugin;
      native = next;
      plugin = nextPlugin;
      await record();
      for (final message in pending) {
        await deliver(message);
      }
      expect(shown(), DashcamSegmentPresentation.startPending);
      await errorsDelivered();
      expect(errors, isEmpty);
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed, reason: 'the message reaches the plugin that started the recording');
    });

    test('X585 — a second plugin instance recording does not silence the service\'s recording', () async {
      await record();
      final other = _Native('${dir.path}/REC_other.mp4');
      _installNative(other);
      final otherPlugin = _RealPlugin(other);
      await otherPlugin.startVideoCapturing(const VideoCaptureOptions(0));
      _installNative(native);
      told.clear();

      await deliver(other.last.message('videoProgress'));
      expect(otherPlugin.recordingEvidence.value!.videoProgress, isTrue);
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'not this recording');
      expect(told, isEmpty);

      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);

      await deliver(other.last.message('recordingEnded', 3));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed, reason: 'its end is not this recording\'s');
      await errorsDelivered();
      expect(errors, isEmpty);
      await otherPlugin.dispose(0);
    });

    test('X586 — a new service on the same plugin: late messages of the old service\'s recording confirm nothing, its own do', () async {
      await record();
      final old = native.last;
      await service.dispose();
      await until(() => service.previewController == null, 'the release');
      final presentationOfOld = shown();
      told.clear();

      await deliver(old.message('videoProgress'));
      expect(shown(), presentationOfOld, reason: 'the disposed service adopted nothing any more');
      expect(told, isEmpty);

      await record();
      expect(identical(CameraPlatform.instance, plugin), isTrue, reason: 'test setup');
      expect(shown(), DashcamSegmentPresentation.startPending);
      await deliver(old.message('videoProgress'));
      await deliver(old.message('recordingEnded', 3));
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'old, with the handler installed again');
      await errorsDelivered();
      expect(errors, isEmpty);

      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X587 — a handler displaced mid-recording: no proof means no REC, and the next rotation recovers', () async {
      await record();
      const foreign = BasicMessageChannel<Object?>(_channel, StandardMessageCodec());
      final stolen = <Object?>[];
      foreign.setMessageHandler((message) async => stolen.add(message));
      told.clear();

      await deliver(native.last.message('videoProgress'));
      expect(stolen, hasLength(1), reason: 'the scenario needs the message lost');
      expect(shown(), DashcamSegmentPresentation.startPending);
      expect(told, isEmpty);

      await rotate();
      expect(shown(), DashcamSegmentPresentation.startPending);
      await deliver(native.recordings[0].message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'the first recording, on the handler installed again');
      await deliver(native.last.message('videoProgress'));
      expect(stolen, hasLength(1));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X588 — a progress message lost in transport: that segment stays unconfirmed, the next one confirms', () async {
      await record();
      // Nothing delivered: the listener sends once and never again.
      expect(shown(), DashcamSegmentPresentation.startPending);
      await rotate();
      expect(shown(), DashcamSegmentPresentation.startPending);
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X589 — the owner table does not grow with recordings or outlive the plugin\'s dispose', () async {
      final base = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      await record();
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, base + 1);
      await rotate();
      await rotate();
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, base + 1);
      await plugin.dispose(0);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, base);
    });
  });

  // Fase 16.2-R4.4-HW-MIG-5-SIG-2.3. Lifecycle is modeled, not executed: A of a "previous incarnation" is
  // an identity from the process counter that nothing in this Dart isolate knows, with the bytes its
  // surviving listener would send. Nothing here runs a real hot restart or a real engine teardown.
  group('another incarnation in the same process', () {
    ByteData fromA(int identity, String kind, [int? error]) => const StandardMessageCodec().encodeMessage(<Object?>[kind, identity, error])!;

    test('X590 — progress of A of the previous incarnation does not light B; B\'s first own progress does', () async {
      final a = ++_processCounter;
      await record();
      expect(native.last.identity, isNot(a));
      await deliver(fromA(a, 'videoProgress'));
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'REC neutral with no valid evidence');
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X591 — the terminal of A of the previous incarnation does not end B', () async {
      final a = ++_processCounter;
      await record();
      await deliver(fromA(a, 'recordingEnded', 3));
      await errorsDelivered();
      expect(shown(), DashcamSegmentPresentation.startPending);
      expect(errors, isEmpty);
      expect(service.isRecording, isTrue);
    });

    test('X592 — callbacks of A arrive before, during and after B\'s START: none counts, whatever is pending', () async {
      final a = ++_processCounter;
      await deliver(fromA(a, 'videoProgress')); // no handler yet in this "isolate" for some orders
      native.holdStartEvent = native.gate();
      build();
      await service.initialize();
      final starting = service.startLoopRecording(clipOwnerToken: 'session-A');
      await until(() => native.recordings.isNotEmpty, 'B starting');
      await deliver(fromA(a, 'videoProgress'));
      native.holdStartEvent!.complete();
      native.holdStartEvent = null;
      await starting;
      await deliver(fromA(a, 'videoProgress'));
      await deliver(fromA(a, 'recordingEnded', 3));
      expect(shown(), DashcamSegmentPresentation.startPending);
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    test('X593 — the listener of each physical recording holds what native allocated; progress before adoption is kept; rotations ascend', () async {
      final before = _processCounter;
      native.holdStartEvent = native.gate();
      build();
      await service.initialize();
      final starting = service.startLoopRecording(clipOwnerToken: 'session-A');
      await until(() => native.recordings.isNotEmpty, 'the START');
      expect(native.last.identity, before + 1, reason: 'exactly the value the allocator returned');
      await deliver(native.last.message('videoProgress')); // early: its adoption has not happened
      native.holdStartEvent!.complete();
      native.holdStartEvent = null;
      await starting;
      expect(shown(), DashcamSegmentPresentation.videoConfirmed, reason: 'not lost at adoption');

      await rotate();
      await rotate();
      expect(native.recordings.map((r) => r.identity), [before + 1, before + 2, before + 3], reason: 'serialized STARTs, one value each');
      expect(native.allocations, 3, reason: 'none for a STOP, no per-frame cost');
    });

    test('X594 — a new plugin in a new service gets values the previous plugin never had', () async {
      await record();
      final previous = native.last.identity;
      await service.dispose();
      await until(() => service.previewController == null, 'the release');

      final next = _Native('${dir.path}/REC_same.mp4');
      _installNative(next);
      native = next;
      plugin = _RealPlugin(next);
      CameraPlatform.instance = plugin;
      await record();
      expect(native.last.identity, isNot(previous));
      expect(native.last.identity as int, greaterThan(previous as int));
    });
  });

  group('a platform dispose that is suspended or fails', () {
    test('X595 — while the platform dispose is suspended, late evidence confirms nothing and reports nothing', () async {
      await record();
      final recording = native.last;
      final gate = native.gate();
      plugin.provider.onUnbindAll = () => gate.future;
      final disposing = plugin.dispose(0);
      expect(plugin.recordingEvidence.value, isNull, reason: 'withdrawn before its first await');
      await deliver(recording.message('videoProgress'));
      await deliver(recording.message('recordingEnded', 3));
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
      await errorsDelivered();
      expect(errors, isEmpty);
      gate.complete();
      await disposing;
      plugin.provider.onUnbindAll = null;
    });

    test('X596 — a platform dispose that fails: the error stays the caller\'s, evidence stays refused, no owner remains', () async {
      await record();
      final recording = native.last;
      final owners = AndroidCameraCameraX.recordingEvidenceOwnerCount;
      plugin.provider.onUnbindAll = () async => throw StateError('release failed');
      await expectLater(plugin.dispose(0), throwsStateError);
      expect(AndroidCameraCameraX.recordingEvidenceOwnerCount, owners - 1);
      await deliver(recording.message('videoProgress'));
      expect(plugin.recordingEvidence.value, isNull);
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
      plugin.provider.onUnbindAll = null;
    });

    test('X597 — a START whose allocation fails is a failed START: no recording, nothing adopted, REC not red', () async {
      native.failAllocationWith = StateError('allocator failed');
      build();
      await service.initialize();
      await service.startLoopRecording(clipOwnerToken: 'session-A').catchError((_) {});
      expect(native.recordings, isEmpty);
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
      await deliverRaw(<Object?>['videoProgress', _processCounter + 1, null]);
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
    });

    // Synapse Auto (R4.4-HW-MIG-5-SIG-2.4): the error an exhausted allocator replies, as Pigeon delivers it (pinned by allocatorT6 in JUnit).
    test('X599 — an exhausted allocator fails each START for its caller: no recording, no other camera, never red', () async {
      native.failAllocationWith = PlatformException(code: 'IllegalStateException', message: 'java.lang.IllegalStateException: Recording identities exhausted');
      build();
      await service.initialize();
      final cameras = plugin._nextCameraId;
      for (var attempt = 1; attempt <= 3; attempt++) {
        Object? seen;
        await service.startLoopRecording(clipOwnerToken: 'session-$attempt').timeout(const Duration(seconds: 5)).catchError((Object error) {
          seen = error;
        });
        expect(seen, isA<CameraException>().having((CameraException e) => e.description, 'description', 'java.lang.IllegalStateException: Recording identities exhausted'), reason: 'observed by the caller of START');
        expect(service.isRecording, isFalse, reason: 'the attempt left no intent behind');
        expect(native.allocationAttempts, attempt, reason: 'the queue moved on to the next START');
        expect(native.recordings, isEmpty);
        expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
      }
      expect(plugin._nextCameraId, cameras, reason: 'failing an allocation creates no camera');
      expect(told, isNot(contains(DashcamSegmentPresentation.videoConfirmed)));
    });

    test('X600 — after that failure STOP and dispose are not held by anything it left behind', () async {
      native.failAllocationWith = PlatformException(code: 'IllegalStateException', message: 'java.lang.IllegalStateException: Recording identities exhausted');
      build();
      await service.initialize();
      await service.startLoopRecording(clipOwnerToken: 'session-A').catchError((_) {});
      await service.stopLoopRecording().timeout(const Duration(seconds: 5));
      expect(native.recordings, isEmpty);
      expect(service.startAttemptSettling, isFalse);
      await service.dispose().timeout(const Duration(seconds: 5));
      expect(service.previewController, isNull);
    });

    test('X598 — STOP needs neither the channel nor the allocator', () async {
      await record();
      final allocations = native.allocations;
      native.failAllocationWith = StateError('allocator failed');
      await service.stopLoopRecording();
      expect(native.finalized, contains(native.last));
      expect(native.allocations, allocations);
      expect(errors, isEmpty);
    });
  });

  group('invalidation before delivery', () {
    test('X576 — manual STOP before the delivery of its own progress: nothing relights, nothing is reported', () async {
      await record();
      final a = native.last;
      final pending = [a.message('videoProgress'), a.message('recordingEnded', 0)];
      final finalize = native.gate();
      native.holdFinalize = finalize;
      final stopping = service.stopLoopRecording();
      expect(shown(), DashcamSegmentPresentation.inactive, reason: 'in the same step as the request');
      for (final message in pending) {
        await deliver(message);
        expect(shown(), DashcamSegmentPresentation.inactive);
      }
      native.holdFinalize = null;
      finalize.complete();
      await stopping;
      expect(told, isNot(contains(DashcamSegmentPresentation.videoConfirmed)));
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    test('X577 — dispose: late messages reach no slot and no service', () async {
      await record();
      final a = native.last;
      await deliver(a.message('videoProgress'));
      final disposing = service.dispose();
      expect(shown(), DashcamSegmentPresentation.inactive);
      final told0 = told.length;
      await deliver(a.message('recordingEnded', 4));
      await disposing;
      await until(() => service.previewController == null, 'the release');
      await deliver(a.message('videoProgress'));
      expect(plugin.recordingEvidence.value, isNull, reason: 'the plugin let go of the recording');
      expect(told.length, told0);
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    test('X578 — HOME: A\'s messages after it do not count; the return needs evidence of its own recording', () async {
      await record();
      final a = native.last;
      await deliver(a.message('videoProgress'));
      service.notifyAppBackgrounded();
      expect(shown(), DashcamSegmentPresentation.inactive);
      await deliver(a.message('recordingEnded', 4));
      expect(shown(), DashcamSegmentPresentation.inactive);
      await errorsDelivered();
      expect(errors, isEmpty);

      await service.stopLoopRecording().catchError((_) {});
      await service.initialize();
      await service.startLoopRecording(clipOwnerToken: 'session-A');
      expect(native.recordings, hasLength(2));
      expect(shown(), DashcamSegmentPresentation.startPending);
      await deliver(a.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.startPending);
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });
  });

  group('end, loss, transport', () {
    test('X579 — spontaneous Finalize of B: the Pigeon event and the private message of the same recording end it once; its rotation returns with C confirmed only by C', () async {
      await record();
      await rotate();
      final b = native.last;
      await deliver(b.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);

      await b.endSpontaneously(3);
      expect(shown(), DashcamSegmentPresentation.segmentEnded);
      await errorsDelivered();
      expect(errors, hasLength(1));
      expect(errors.single.scope, DashcamServiceErrorScope.recordingResult);
      expect(errors.single.message, contains('3'));
      expect(service.isRecording, isTrue, reason: 'no recovery in this round: residual, reported separately');
      expect(native.recordings, hasLength(2), reason: 'and no START because of it');

      await deliver(b.message('recordingEnded', 3));
      await errorsDelivered();
      expect(errors, hasLength(1), reason: 'a duplicate terminal is absorbed');

      await rotate();
      expect(shown(), DashcamSegmentPresentation.startPending);
      await deliver(b.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'late progress of the recording that ended');
      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
      await errorsDelivered();
      expect(errors, hasLength(1));
    });

    test('X580 — lost progress leaves REC neutral; a lost terminal after progress leaves red until the STOP withdraws it, and neither touches the recording', () async {
      await record();
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'progress never delivered');
      expect(service.previewController!.value.isRecordingVideo, isTrue);

      await deliver(native.last.message('videoProgress'));
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
      // The native end happens and its private message is lost: the limit of a signal STOP never waits for.
      native.finalized.add(native.last);
      native.last.writeFile();
      native.last.emitPigeon(VideoRecordEventFinalize.pigeon_detached());
      await errorsDelivered();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed, reason: 'documented limit, see the report');

      await service.stopLoopRecording();
      expect(shown(), DashcamSegmentPresentation.inactive);
    });

    test('X581 — a failing native START: the identity it bound is never adopted, and its messages count for nobody', () async {
      await record();
      final a = native.last;
      await deliver(a.message('videoProgress'));
      native.failStartWith = StateError('no');
      ticks.last();
      await until(() => shown() != DashcamSegmentPresentation.transitioning && !service.hasPendingNativeStop, 'the failed restart');
      await rotationSettled();
      expect(native.recordings, hasLength(1));
      await deliver(a.message('videoProgress'));
      await deliver(a.message('recordingEnded', 3));
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
      expect(shown(), isNot(DashcamSegmentPresentation.segmentEnded));
      native.failStartWith = null;
    });

    test('X582 — no flood: five rotations with duplicates of every message create one listener and one confirmation per recording', () async {
      await record();
      for (var rotation = 0; rotation < 6; rotation++) {
        for (var duplicate = 0; duplicate < 5; duplicate++) {
          await deliver(native.last.message('videoProgress'));
        }
        if (rotation < 5) await rotate();
      }
      expect(native.listeners, hasLength(6));
      expect(told.where((p) => p == DashcamSegmentPresentation.videoConfirmed), hasLength(6));
    });
  });

  testWidgets('X583 — both REC widgets and the session line, over the real plugin: late evidence of A shows nothing, B\'s turns all three red', (tester) async {
    // This test runs its own session over the same fixture.
    late DashcamSessionController controller;
    late DrivingSessionRecorder recorder;
    final snapshots = StreamController<TelemetrySnapshot>.broadcast();
    final events = StreamController<DetectedEvent>.broadcast();
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
        Hive.registerAdapter(DrivingSessionAdapter());
        Hive.registerAdapter(DrivingSessionSampleAdapter());
        Hive.registerAdapter(DrivingSessionEventTypeAdapter());
        Hive.registerAdapter(EventSeverityAdapter());
        Hive.registerAdapter(DrivingSessionEventAdapter());
        Hive.registerAdapter(CameraSelectionAdapter());
        Hive.registerAdapter(VideoResolutionAdapter());
        Hive.registerAdapter(DashcamConfigAdapter());
        Hive.registerAdapter(DashcamClipRecordAdapter());
      }
      Hive.init(dir.path);
      await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
      await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
      await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
      await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
      await Hive.openBox(HiveBoxNames.appSettings);
      final preferences = DashcamPreferences();
      await preferences.setEnabled(true);
      recorder = DrivingSessionRecorder(snapshots.stream);
      build();
      controller = DashcamSessionController(dashcamService: service, dashcamPreferences: preferences, sessionRecorder: recorder, snapshotStream: snapshots.stream, eventStream: events.stream);
      controller.startSession();
      await until(() => controller.status == DashcamStatus.recording && native.recordings.length == 1, 'the session recording');
    });
    const recKey = Key('rec');
    const previewKey = Key('preview');
    const sessionKey = Key('session');
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [KeyedSubtree(key: recKey, child: DashcamRecIndicator(controller: controller, onTap: () {}))]),
          body: Column(
            children: [
              SizedBox(height: 480, child: KeyedSubtree(key: previewKey, child: DashcamPreviewView(controller: controller))),
              Expanded(
                child: KeyedSubtree(
                  key: sessionKey,
                  child: UnitPreferencesScope(preferences: UnitPreferences(), child: SessionRecordingScreen(recorder: recorder, dashcamController: controller)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    bool indicatorRed() => (tester.widget<IconButton>(find.descendant(of: find.byKey(recKey), matching: find.byType(IconButton))).icon as Icon).icon == Icons.fiber_manual_record;
    bool previewRed() => find.descendant(of: find.byKey(previewKey), matching: find.textContaining('REC')).evaluate().isNotEmpty;
    bool sessionRed() => find.descendant(of: find.byKey(sessionKey), matching: find.text('Gravando')).evaluate().isNotEmpty;
    try {
      await tester.pump();
      expect([indicatorRed(), previewRed(), sessionRed()], [false, false, false]);
      expect(find.byType(DashcamCameraSurface), findsOneWidget);

      final a = native.last;
      final pending = [a.message('videoProgress'), a.message('recordingEnded', 3)];
      await tester.runAsync(() async {
        await deliver(a.message('videoProgress'));
      });
      await tester.pump();
      expect([indicatorRed(), previewRed(), sessionRed()], [true, true, true], reason: 'A confirmed by its own progress');
      final surface = tester.element(find.byType(DashcamCameraSurface));

      await tester.runAsync(() async {
        ticks.last();
        await until(() => native.recordings.length == 2, 'B starting');
        await rotationSettled();
      });
      await tester.pump();
      expect([indicatorRed(), previewRed(), sessionRed()], [false, false, false], reason: 'B has no video');

      await tester.runAsync(() async {
        for (final message in pending) {
          await deliver(message);
        }
      });
      await tester.pump();
      expect([indicatorRed(), previewRed(), sessionRed()], [false, false, false], reason: 'late messages of A');
      expect(controller.segmentPresentation, DashcamSegmentPresentation.startPending);

      await tester.runAsync(() async {
        await deliver(native.last.message('videoProgress'));
      });
      await tester.pump();
      expect([indicatorRed(), previewRed(), sessionRed()], [true, true, true], reason: 'B confirmed by its own progress');
      expect(identical(tester.element(find.byType(DashcamCameraSurface)), surface), isTrue, reason: 'never remounted');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await controller.stopSession().timeout(const Duration(seconds: 15)).catchError((_) {});
        controller.dispose();
        await until(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown');
        await indexQueueSettledForTest();
        await snapshots.close();
        await events.close();
        await Hive.close();
      });
    }
  });
}
