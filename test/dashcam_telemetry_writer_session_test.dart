// Fase 16.2-R4.3-R2.6.9 — X140/X141: the telemetry writer's automatic flush is
// held (the real IOSink over a gated file consumer, test/support/
// telemetry_io_gate.dart) while the REAL DashcamSessionController stops the
// session (X140) or is disposed (X141), over the fake camera platform. Samples
// come from DetectedEvents with speeds 1..N; no snapshot is ever sent to the
// controller, so its 200 ms sampler adds nothing and the accepted set is
// known exactly.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/dashcam_telemetry_sample.dart';
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
import 'support/telemetry_io_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeCameraPlatform fakePlatform;
  late StreamController<TelemetrySnapshot> recorderSnapshots;
  late StreamController<TelemetrySnapshot> controllerSnapshots;
  late StreamController<DetectedEvent> events;
  late DrivingSessionRecorder recorder;
  late DashcamPreferences preferences;
  late DashcamService service;
  late DashcamSessionController controller;
  late TelemetryIoGate gate;
  late int emitted;
  DashcamTelemetryWriter? writer;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  Future<void> until(bool Function() condition, String label, {Duration timeout = const Duration(seconds: 5)}) async {
    final sw = Stopwatch()..start();
    while (!condition()) {
      if (sw.elapsed > timeout) fail('timed out waiting for: $label');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// [n] DetectedEvents (warning: no clip protection); event #i carries speed
  /// i, and becomes exactly one telemetry sample.
  void emit(int n) {
    for (var k = 0; k < n; k++) {
      emitted++;
      final now = DateTime.now();
      events.add(
        DetectedEvent(
          type: DetectedEventType.hardCorneringLeft,
          timestamp: now,
          severity: EventSeverity.warning,
          snapshot: TelemetrySnapshot(timestamp: now, speedKmh: emitted.toDouble(), gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable),
        ),
      );
    }
  }

  /// Session recording with the camera; the writer's automatic flush of
  /// samples 1-25 held; samples 26-28 pending behind it.
  Future<DrivingSession> recordWithHeldFlush() async {
    late DrivingSession session;
    gate.run(() => session = controller.startSession());
    await until(() => controller.status == DashcamStatus.recording, 'camera recording');
    expect(writer, isNotNull, reason: 'setup: the writer was opened through the hook');
    gate.hold = true;
    emit(25);
    await gate.untilHeld();
    emit(3);
    await until(() => writer!.acceptedSampleCountForTest == 28, '28 samples accepted');
    expect(gate.deliveries, 1, reason: 'setup: one delivery, held');
    return session;
  }

  List<int?> speedsOf(List<Object?> values) => [for (final v in values) (v as num?)?.toInt()];

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_telemetry_writer_session_test');
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

    recorderSnapshots = StreamController<TelemetrySnapshot>.broadcast();
    controllerSnapshots = StreamController<TelemetrySnapshot>.broadcast();
    events = StreamController<DetectedEvent>.broadcast();
    recorder = DrivingSessionRecorder(recorderSnapshots.stream);
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
      snapshotStream: controllerSnapshots.stream,
      eventStream: events.stream,
    );
    await preferences.setEnabled(true);
    gate = TelemetryIoGate();
    emitted = 0;
    writer = null;
    controller.openTelemetryWriterHookForTest = (w, open) {
      writer = w;
      return open();
    };
  });

  tearDown(() async {
    // A failed assertion must not leave a delivery held behind the teardown.
    gate.hold = false;
    gate.releaseAll();
    try {
      controller.dispose();
    } catch (_) {}
    for (var i = 0; i < 300 && (DashcamService.processOwnerCurrentForTest != null || service.previewController != null); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await recorderSnapshots.close();
    await controllerSnapshots.close();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    // Also fails the test if a telemetry file handle is still open (Windows).
    dir.deleteSync(recursive: true);
  });

  group('Fase 16.2-R4.3-R2.6.9 — telemetry writer under the session controller', () {
    test(
      'X140 a normal STOP while the automatic flush is held waits for it, writes every accepted sample once and '
      'closes the file once; the session ends exactly as before (recorder idle, clip indexed, camera stopped)',
      () async {
        final session = await recordWithHeldFlush();
        final w = writer!;

        var stopDone = false;
        Object? stopError;
        gate.run(
          () => controller.stopSession().then<void>(
            (_) {
              stopDone = true;
            },
            onError: (Object e, StackTrace _) {
              stopDone = true;
              stopError = e;
            },
          ),
        );
        // STOP reached its telemetry close, which is waiting for the held flush.
        await until(() => w.isClosed, 'STOP closing the writer');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(stopDone, isFalse, reason: 'pre-fix: STOP finished at once (close threw and was swallowed), losing 26-28');
        expect(gate.closes, 0, reason: 'the file is not closed under a bound flush');
        expect(w.add(DashcamTelemetrySample(timestamp: DateTime.now(), speedKmh: 999)), isFalse, reason: 'no sample after close');

        gate.hold = false;
        gate.releaseAll();
        await until(() => stopDone, 'STOP done');
        expect(stopError, isNull);

        final speeds = [for (final s in await loadDashcamTelemetry(session.id)) s.speedKmh?.toInt()];
        expect(speeds, [for (var i = 1; i <= 28; i++) i], reason: 'every accepted sample once, in order (pre-fix: 26-28 lost)');
        expect(speedsOf(gate.writtenSpeeds), speeds);
        expect(w.acceptedSampleCountForTest, 28);
        expect(gate.deliveries, 2, reason: 'the held flush, then close\'s final batch');
        expect(gate.maxActiveDeliveries, 1);
        expect(gate.closes, 1, reason: 'closed exactly once (pre-fix: never)');
        expect(gate.openHandles, 0);

        // STOP semantics unchanged.
        expect(recorder.state, DrivingSessionRecorderState.idle);
        expect(controller.status, DashcamStatus.idle);
        expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(session.id)!.endTime, isNotNull);
        expect(fakePlatform.calls, contains('stopVideoRecording'));
        await until(() => (Hive.box(HiveBoxNames.dashcamSessionVideos).get(session.id) as List?)?.length == 1, 'clip indexed');
      },
    );

    test(
      'X141 disposing the controller while recording, with the automatic flush held, closes the writer once after '
      'the flush, writes every accepted sample and raises no asynchronous error',
      () async {
        final session = await recordWithHeldFlush();
        final w = writer!;

        controller.dispose();
        expect(w.isClosed, isTrue, reason: 'dispose closes the writer');
        expect(w.add(DashcamTelemetrySample(timestamp: DateTime.now(), speedKmh: 999)), isFalse);
        final closeFuture = w.close();
        expect(identical(w.flush(), closeFuture), isTrue, reason: 'no new work after close');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(gate.closes, 0, reason: 'the file is not closed under a bound flush');
        expect(gate.heldCount, 1);

        gate.hold = false;
        gate.releaseAll();
        // Pre-fix: dispose's unawaited close threw StateError "StreamSink is
        // bound to a stream" (uncaught), and the file handle stayed open.
        await closeFuture;
        final speeds = [for (final s in await loadDashcamTelemetry(session.id)) s.speedKmh?.toInt()];
        expect(speeds, [for (var i = 1; i <= 28; i++) i]);
        expect(gate.deliveries, 2);
        expect(gate.closes, 1);
        expect(gate.openHandles, 0);
        // The rest of dispose is unaffected: the camera is released.
        await until(() => DashcamService.processOwnerCurrentForTest == null, 'camera released');
        expect(fakePlatform.calls, contains('dispose'));
      },
    );
  });
}
