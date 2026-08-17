import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_camera_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeCameraPlatform fakePlatform;
  late StreamController<TelemetrySnapshot> snapshotController;
  late StreamController<DetectedEvent> eventController;
  late DrivingSessionRecorder recorder;
  late DashcamPreferences preferences;
  late DashcamService service;
  late DashcamSessionController controller;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  TelemetrySnapshot snapshot({
    DateTime? timestamp,
    double? speedKmh,
    double? gForceMagnitude,
  }) {
    return TelemetrySnapshot(
      timestamp: timestamp ?? DateTime.now(),
      speedKmh: speedKmh,
      gForceMagnitude: gForceMagnitude,
      gnssQuality: GnssQuality.good,
      altitudeTrend: AltitudeTrend.stable,
    );
  }

  DetectedEvent detectedEvent({required EventSeverity severity, required DetectedEventType type}) {
    return DetectedEvent(type: type, timestamp: DateTime.now(), severity: severity, snapshot: snapshot(speedKmh: 99));
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dashcam_session_controller_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );

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

    snapshotController = StreamController<TelemetrySnapshot>.broadcast();
    eventController = StreamController<DetectedEvent>.broadcast();
    recorder = DrivingSessionRecorder(snapshotController.stream);
    preferences = DashcamPreferences();
    service = DashcamService(
      config: DashcamConfig(
        cameraSelection: CameraSelection.rear,
        storageQuotaMb: 1024,
        audioEnabled: false,
        resolution: VideoResolution.hd720,
        frameRate: 30,
        enabled: true,
      ),
      segmentDuration: const Duration(minutes: 10),
    );
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshotController.stream,
      eventStream: eventController.stream,
    );
  });

  tearDown(() async {
    // One test below disposes the controller itself to assert on the
    // hardware-release call directly — ChangeNotifier disallows a second
    // dispose(), so this guard makes tearDown safe for every other test too.
    try {
      controller.dispose();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await snapshotController.close();
    await eventController.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('status is disabled while DashcamPreferences.enabled is false, regardless of session state', () async {
    expect(controller.status, DashcamStatus.disabled);
    controller.startSession();
    expect(controller.status, DashcamStatus.disabled);
    expect(recorder.isRecording, isTrue, reason: 'the driving session itself must still start');
    expect(fakePlatform.calls, isEmpty, reason: 'no camera hardware should be touched while disabled');
  });

  test('enabling the feature starts the camera together with the session, reaching recording', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    // _startCamera is fired-and-forgotten from startSession(); its own
    // notifyListeners calls happen on real microtask/await boundaries.
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(controller.status, DashcamStatus.recording);
    expect(fakePlatform.calls, contains('createCameraWithSettings'));
    expect(fakePlatform.calls, contains('startVideoCapturing'));
  });

  test(
    'a camera failure never stops the driving session from starting or recording '
    '(Fase 15 failure-isolation requirement)',
    () async {
      await preferences.setEnabled(true);
      fakePlatform.failCreateCameraWith = CameraException('no_camera', 'forced failure for this test');

      final session = controller.startSession();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(recorder.isRecording, isTrue);
      expect(recorder.activeSession, session);
      expect(controller.status, DashcamStatus.error);
      expect(controller.errorMessage, isNotNull);
    },
  );

  test('stopping the session finalizes the camera and returns status to idle', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.status, DashcamStatus.recording);

    await controller.stopSession();

    expect(controller.status, DashcamStatus.idle);
    expect(recorder.isRecording, isFalse);
    expect(fakePlatform.calls, contains('stopVideoRecording'));
  });

  test(
    'stopping the session releases the camera hardware, not just the recording (Fase 15 — '
    'regression for a real bug found via physical hardware testing: the controller created by a '
    'session\'s initialize() was left held open for the REST OF THE APP PROCESS\'s lifetime once '
    'that session ended, if no further session ever started — confirmed on-device via '
    '`adb shell dumpsys media.camera` that this genuinely, repeatedly blocked an unrelated system '
    'service, Samsung\'s own adaptive-brightness component, from opening a DIFFERENT camera on the '
    'same device, logged by the platform\'s own camera service as "Too many cameras already open")',
    () async {
      await preferences.setEnabled(true);
      controller.startSession();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.status, DashcamStatus.recording);

      await controller.stopSession();

      expect(controller.status, DashcamStatus.idle);
      expect(
        fakePlatform.disposedCameraIds,
        contains(0),
        reason:
            'the camera opened for this session must be disposed once the session ends, not left '
            'held open indefinitely just because the app itself keeps running',
      );
    },
  );

  test('a session recorded with dashcam enabled gets a clip indexed in the dashcamSessionVideos box', () async {
    await preferences.setEnabled(true);
    final session = controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await controller.stopSession();

    final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
    final raw = box.get(session.id) as List?;
    expect(raw, isNotNull);
    final records = List<DashcamClipRecord>.from(raw!);
    expect(records, hasLength(1));
    expect(records.single.resolution, VideoResolution.hd720);
  });

  test('a session recorded with dashcam disabled has no entry in the dashcamSessionVideos box', () async {
    final session = controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await controller.stopSession();

    final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
    expect(box.get(session.id), isNull);
  });

  test('telemetry samples are written at the sampling cadence while recording', () async {
    await preferences.setEnabled(true);
    final session = controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    snapshotController.add(snapshot(timestamp: DateTime.now(), speedKmh: 55));
    // Real Timer.periodic(200ms) sampler — wait past one tick.
    await Future<void>.delayed(const Duration(milliseconds: 260));

    await controller.stopSession();

    final samples = await loadDashcamTelemetry(session.id);
    expect(samples, isNotEmpty);
    expect(samples.any((s) => s.speedKmh == 55), isTrue);
  });

  test(
    'a DetectedEvent writes one precise out-of-band sample immediately, tagged with its type',
    () async {
      await preferences.setEnabled(true);
      final session = controller.startSession();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      eventController.add(detectedEvent(severity: EventSeverity.warning, type: DetectedEventType.hardCorneringLeft));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await controller.stopSession();

      final samples = await loadDashcamTelemetry(session.id);
      expect(samples.any((s) => s.eventType == DetectedEventType.hardCorneringLeft && s.speedKmh == 99), isTrue);
    },
  );

  test('high/critical severity events protect the current clip; info severity does not', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    eventController.add(detectedEvent(severity: EventSeverity.info, type: DetectedEventType.stopped));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(service.clips.any((c) => c.isProtected), isFalse);

    eventController.add(detectedEvent(severity: EventSeverity.critical, type: DetectedEventType.highResultantG));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await controller.stopSession();
    expect(service.clips.single.isProtected, isTrue);
  });

  test('starting a session twice in a row does not create two cameras', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fakePlatform.calls.where((c) => c == 'createCameraWithSettings'), hasLength(1));
  });

  test(
    'starting a new session before the previous one\'s camera-stop has fully settled does not '
    'duplicate the previous session\'s clip into the new session\'s Hive record (Fase 15 — '
    'regression for a real bug found via physical hardware testing: two back-to-back sessions, '
    'the second started faster than the first\'s _stopCamera could finish, resulted in the SAME '
    'clip file being persisted under BOTH sessions\' dashcamSessionVideos entries — because the '
    'second session\'s _startCamera hit its "already starting/recording" guard and returned '
    'before ever refreshing _clipsBeforeThisSession, so when IT later stopped, it still saw the '
    'first session\'s now-finalized clip as "new" against its own stale, pre-first-session '
    'baseline)',
    () async {
      await preferences.setEnabled(true);
      final sessionA = controller.startSession();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Physical hardware testing found this race with a real several-MB
      // video file whose MediaRecorder finalize + disk copy took genuinely
      // longer than DrivingSessionRecorder's own (Hive-only) stopSession()
      // — long enough that a fresh "Iniciar sessão" tap landed while the
      // previous session's camera-side teardown was still in flight. The
      // fake platform's finalize is normally near-instant, so this delay
      // reproduces that same relative timing deterministically instead of
      // depending on winning a real race in a fast test.
      fakePlatform.stopVideoRecordingDelay = const Duration(milliseconds: 50);

      // Deliberately NOT awaited before starting the next session.
      final stopAFuture = controller.stopSession();
      // Long enough for DrivingSessionRecorder.stopSession()'s own Hive-only
      // path to clear _activeSession (so startSession() below genuinely
      // starts a NEW session, not the guarded-against same-session no-op),
      // but well short of the 50ms camera-side delay above — _stopCamera(A)
      // must still be in flight when session B starts.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final sessionB = controller.startSession();
      expect(sessionB.id, isNot(equals(sessionA.id)), reason: 'test setup check: must be a genuinely new session');

      fakePlatform.stopVideoRecordingDelay = null;
      await stopAFuture;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.status, DashcamStatus.recording, reason: 'session B must reach its own recording state');

      await controller.stopSession();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
      final rawA = box.get(sessionA.id) as List?;
      final rawB = box.get(sessionB.id) as List?;
      expect(rawA, isNotNull, reason: 'session A must have its own clip recorded');
      expect(rawB, isNotNull, reason: 'session B must have its own clip recorded');

      final clipsA = List<DashcamClipRecord>.from(rawA!);
      final clipsB = List<DashcamClipRecord>.from(rawB!);
      expect(clipsA, hasLength(1));
      expect(clipsB, hasLength(1));
      expect(
        clipsA.single.filePath,
        isNot(equals(clipsB.single.filePath)),
        reason: 'each session must be attributed its OWN clip file, never share the other session\'s',
      );
    },
  );

  test('backgrounding pauses the preview; resuming un-pauses it, without stopping recording', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fakePlatform.previewPaused, isTrue);
    expect(controller.status, DashcamStatus.recording, reason: 'backgrounding must not stop recording itself');

    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fakePlatform.previewPaused, isFalse);
  });

  test('dispose() releases the camera hardware', () async {
    await preferences.setEnabled(true);
    controller.startSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fakePlatform.calls, contains('dispose'));
  });
}
