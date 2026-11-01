// Fase 16.2-R4.3-R2.6.10 — X151–X156: telemetry I/O failure semantics under the
// REAL DashcamSessionController (+ DashcamService over the fake camera
// platform, the real recorder over Hive, the real DashcamTelemetryWriter).
// Samples come from DetectedEvents with speeds 1..N and no snapshot ever
// reaches the controller, so the accepted set is known exactly. The telemetry
// file is either real dart:io (X151: a directory where the file must be) or
// behind test/support/telemetry_io_gate.dart (hold = a hung disk, failNext = a
// write error). Every scenario runs in one error zone: an automatic flush's
// failure is an uncaught error by contract (X138), and is asserted as such.
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
import 'support/index_queue_isolation.dart';
import 'support/telemetry_io_gate.dart';

/// Outcome of a Future observed without awaiting it.
class _Watched {
  _Watched(Future<Object?> future) {
    future.then<void>(
      (_) {
        done = true;
      },
      onError: (Object e, StackTrace _) {
        done = true;
        error = e;
      },
    );
  }
  bool done = false;
  Object? error;
}

/// Runs [body] in one error zone and returns its uncaught asynchronous
/// errors; a failure of [body] itself is rethrown outside the zone.
Future<List<Object>> _uncaughtErrorsOf(Future<void> Function() body) {
  final uncaught = <Object>[];
  final done = Completer<List<Object>>();
  runZonedGuarded(() async {
    try {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      done.complete(uncaught);
    } catch (e, s) {
      done.completeError(e, s);
    }
  }, (e, s) => uncaught.add(e));
  return done.future;
}

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
  late List<DashcamTelemetryWriter> writers;
  late List<FlutterErrorDetails> reported;
  late void Function(FlutterErrorDetails details)? previousOnError;
  var disposed = false;

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

  String jsonl(String id) => '${dir.path}/dashcam_telemetry/$id.jsonl';

  Future<List<int?>> speedsOf(String id) async => [for (final s in await loadDashcamTelemetry(id)) s.speedKmh?.toInt()];

  List<int> range(int from, int to) => [for (var i = from; i <= to; i++) i];

  bool cameraReleased() => DashcamService.processOwnerCurrentForTest == null && service.previewController == null;

  int? clipsOf(String id) => (Hive.box(HiveBoxNames.dashcamSessionVideos).get(id) as List?)?.length;

  /// Session A recording under the gate; automatic flush of 1..25 held; 26..28
  /// pending behind it.
  Future<(DrivingSession, DashcamTelemetryWriter)> recordWithHeldFlush() async {
    late DrivingSession a;
    gate.run(() => a = controller.startSession());
    await until(() => controller.status == DashcamStatus.recording, 'A recording');
    final w = writers.single;
    gate.hold = true;
    emit(25);
    await gate.untilHeld();
    emit(3);
    await until(() => w.acceptedSampleCount == 28, '28 samples accepted');
    return (a, w);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_telemetry_failure_session_test');
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
    writers = [];
    disposed = false;
    reported = [];
    previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    controller.openTelemetryWriterHookForTest = (w, open) {
      writers.add(w);
      return open();
    };
  });

  tearDown(() async {
    FlutterError.onError = previousOnError;
    // A failed assertion must not leave a delivery held behind the teardown.
    gate.hold = false;
    gate.releaseAll();
    if (!disposed) {
      try {
        controller.dispose();
      } catch (_) {}
    }
    for (var i = 0; i < 300 && !cameraReleased(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Fase 16.2-R4.4-R2.1.1-F1-R (test isolation): every camera is released, so
    // no late STOP pass can still queue; the index turns this test left (a test
    // that does not read the index does not wait for them) settle here, against
    // this test's boxes and directory — never inside the next test's FIFO.
    await indexQueueSettledForTest();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await recorderSnapshots.close();
    await controllerSnapshots.close();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    // Also fails the test if a telemetry file handle is still open (Windows).
    dir.deleteSync(recursive: true);
  });

  group('Fase 16.2-R4.3-R2.6.10 — telemetry I/O failures under the session controller', () {
    test('X151 (real) a telemetry file that cannot be opened is never published as recording: error with the open '
        'failure, no sample accepted, STOP keeps the error, the next session is healthy', () async {
      final statuses = <DashcamStatus>[];
      var statusesOfA = <DashcamStatus>[];
      late DrivingSession a;
      late DrivingSession b;
      final errors = await _uncaughtErrorsOf(() async {
        controller.addListener(() => statuses.add(controller.status));
        a = controller.startSession();
        // Before the writer opens (the camera initializes first): no fake.
        Directory(jsonl(a.id)).createSync(recursive: true);
        await until(() => controller.status == DashcamStatus.error, 'START settled');
        final w = writers.single;
        expect(w.state, DashcamTelemetryWriterState.failed);
        expect(w.failure, isA<FileSystemException>());
        expect(controller.errorMessage, contains('Cannot open file'), reason: 'the real open failure, not a generic error');
        emit(30);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(w.acceptedSampleCount, 0, reason: 'pre-fix: 30/30 accepted, 0 written');
        await controller.stopSession();
        expect(controller.status, DashcamStatus.error, reason: 'the STOP does not turn it into success');
        expect(controller.errorMessage, contains('Cannot open file'));
        expect(recorder.state, DrivingSessionRecorderState.idle);
        expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(a.id)!.endTime, isNotNull);
        await until(() => clipsOf(a.id) == 1, 'A\'s clip indexed (the camera recorded video)');
        await until(cameraReleased, 'camera released');

        // A late callback of A's writer: nothing reopens it.
        expect(w.add(DashcamTelemetrySample(timestamp: DateTime.now(), speedKmh: 999)), isFalse);
        expect(await w.open(), isFalse);

        statusesOfA = List.of(statuses);
        final firstB = emitted + 1;
        b = controller.startSession();
        await until(() => controller.status == DashcamStatus.recording, 'B recording');
        expect(controller.errorMessage, isNull);
        expect(writers, hasLength(2));
        expect(writers.last.state, DashcamTelemetryWriterState.open);
        emit(3);
        await until(() => writers.last.acceptedSampleCount == 3, 'B accepted 3');
        await controller.stopSession();
        expect(await speedsOf(b.id), range(firstB, firstB + 2));
        expect(controller.status, DashcamStatus.idle);
      });
      expect(errors, isEmpty, reason: 'pre-fix: the lazy open failure was an uncaught error');
      expect(reported, isEmpty);
      expect(statusesOfA, isNotEmpty);
      expect(statusesOfA, isNot(contains(DashcamStatus.recording)), reason: 'A was never shown as recording (pre-fix: "Gravando" with 0% telemetry)');
      expect(FileSystemEntity.isDirectorySync(jsonl(a.id)), isTrue);
    });

    test('X152 (gated) a write failure while recording: the writer refuses from then on, the controller says what is '
        'lost while the camera keeps recording, and STOP ends in error — not a silent success', () async {
      const ioError = FileSystemException('write failed (injected)', 'x152.jsonl');
      late DrivingSession a;
      late DashcamTelemetryWriter w;
      var notifications = 0;
      final errors = await _uncaughtErrorsOf(() async {
        gate.run(() => a = controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'A recording');
        w = writers.single;
        emit(25);
        await until(() => w.persistedSampleCount == 25, 'first automatic flush written');
        expect(controller.telemetryFailureMessage, isNull);
        controller.addListener(() => notifications++);
        gate.failNext(ioError);
        emit(25);
        await until(() => w.failure != null, 'the second automatic flush failed');
        await until(() => notifications > 0, 'listeners told about the failure');
        expect(controller.status, DashcamStatus.recording, reason: 'the camera still records video — not a camera error');
        expect(service.isRecording, isTrue);
        expect(controller.telemetryFailureMessage, allOf(contains('25 de 50 amostras gravadas'), contains('injected')));
        emit(3);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(w.acceptedSampleCount, 50, reason: 'pre-fix: 53 accepted, 25 written');
        expect(w.refusedSampleCount, 3);

        final stop = _Watched(controller.stopSession());
        await until(() => stop.done, 'STOP done');
        expect(stop.error, isNull, reason: 'the driving session itself is finalized');
        expect(controller.status, DashcamStatus.error, reason: 'pre-fix: idle, errorMessage null');
        expect(controller.errorMessage, allOf(contains('25 de 50 amostras gravadas'), contains('3 recusadas'), contains('injected')));
        expect(recorder.state, DrivingSessionRecorderState.idle);
        expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(a.id)!.endTime, isNotNull);
        await until(() => clipsOf(a.id) == 1, 'clip indexed');
        expect(cameraReleased(), isTrue);
        expect(gate.closes, 1);
        expect(gate.openHandles, 0);

        // Late callbacks after the STOP: refused; no reopen.
        expect(w.add(DashcamTelemetrySample(timestamp: DateTime.now(), speedKmh: 999)), isFalse);
        await w.open();
        expect(gate.opens, 1);

        // The next session starts clean, on its own file.
        final firstB = emitted + 1;
        late DrivingSession b;
        gate.run(() => b = controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'B recording');
        expect(controller.errorMessage, isNull);
        expect(controller.telemetryFailureMessage, isNull);
        emit(3);
        await until(() => writers.last.acceptedSampleCount == 3, 'B accepted 3');
        await controller.stopSession();
        expect(await speedsOf(b.id), range(firstB, firstB + 2));
      });
      expect(errors, [same(ioError)], reason: 'the automatic flush\'s own failure, once; nothing secondary');
      expect(reported, isEmpty, reason: 'published as the status, not reported twice');
      expect(await speedsOf(a.id), range(1, 25), reason: 'the persisted prefix, no duplicate');
    });

    test('X153 (gated) STOP with the telemetry close pending forever: the camera is released anyway, the STOP stays '
        'pending, and the status is `finalizing` — never Ready — until the file is really closed', () async {
      final statuses = <DashcamStatus>[];
      late DrivingSession a;
      late DashcamTelemetryWriter w;
      late _Watched stop;
      final errors = await _uncaughtErrorsOf(() async {
        (a, w) = await recordWithHeldFlush();
        controller.addListener(() => statuses.add(controller.status));
        stop = _Watched(controller.stopSession());
        await until(cameraReleased, 'camera released while the telemetry close is pending');
        expect(fakePlatform.calls, contains('dispose'), reason: 'pre-fix: the camera stayed held behind the writer');
        // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): the recorder closes A
        // concurrently with the camera teardown; this read assumed it was the
        // faster of the two (found by delaying only the recorder's
        // finalization, T-Rm 05_hardened/recorder_latent). It is awaited — and
        // it must still happen while the telemetry close is held forever.
        await until(() => recorder.state == DrivingSessionRecorderState.idle, 'the recorder closed A, the telemetry close still pending');
        expect(recorder.state, DrivingSessionRecorderState.idle);
        expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(a.id)!.endTime, isNotNull);
        await until(() => controller.status == DashcamStatus.finalizing, 'finalizing');
        // No timer declares it done.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(stop.done, isFalse, reason: 'the session is not falsely concluded');
        expect(controller.status, DashcamStatus.finalizing);
        expect(dashcamStatusLabel(controller.status), isNot(dashcamStatusLabel(DashcamStatus.idle)));
        expect(w.isClosed, isTrue);
        expect(gate.closes, 0, reason: 'the file is not closed under the held write');
        expect(controller.pendingTelemetryFinalizationsForTest, 1);
        expect(statuses, isNot(contains(DashcamStatus.idle)), reason: 'pre-fix: "Pronto" with the file unfinished');

        gate.hold = false;
        gate.releaseAll();
        await until(() => stop.done, 'STOP done once the file is closed');
        expect(stop.error, isNull);
        expect(controller.status, DashcamStatus.idle);
        expect(controller.pendingTelemetryFinalizationsForTest, 0);
      });
      expect(errors, isEmpty);
      expect(reported, isEmpty);
      expect(await speedsOf(a.id), range(1, 28), reason: 'nothing lost while waiting');
      expect(gate.closes, 1);
      expect(gate.openHandles, 0);
    });

    test('X154 (gated) a new session during the previous session\'s pending telemetry close gets the released camera '
        'and its OWN file, and is never shown Ready; both files end exact', () async {
      final statuses = <DashcamStatus>[];
      late DrivingSession a;
      late DrivingSession b;
      late DashcamTelemetryWriter w;
      final errors = await _uncaughtErrorsOf(() async {
        (a, w) = await recordWithHeldFlush();
        final stopA = _Watched(controller.stopSession());
        // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): B used to start once A's
        // camera was released, assuming the recorder had already closed A; with
        // a slower recorder finalization startSession() is REFUSED ("still
        // being ended") — found by delaying only the recorder's finalization
        // (T-Rm 05_hardened/recorder_latent). Admission (canStartSession) is
        // awaited too; A's telemetry close stays held.
        await until(() => cameraReleased() && controller.status == DashcamStatus.finalizing && controller.canStartSession, 'A: camera released, file pending, A closed by the recorder');
        controller.addListener(() => statuses.add(controller.status));
        final startsBefore = fakePlatform.calls.where((c) => c == 'startVideoCapturing').length;
        gate.run(() => b = controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'B recording with the camera A released');
        expect(fakePlatform.calls.where((c) => c == 'startVideoCapturing').length, startsBefore + 1, reason: 'pre-fix: B never got a camera');
        expect(writers, hasLength(2));
        expect(identical(writers.last, w), isFalse);
        expect(writers.last.sessionId, b.id, reason: 'B writes its own file, never A\'s');
        expect(writers.last.state, DashcamTelemetryWriterState.open);
        expect(stopA.done, isFalse, reason: 'A\'s telemetry close is still pending');
        expect(gate.heldCount, 1);
        emit(3);
        await until(() => writers.last.acceptedSampleCount == 3, 'B accepted 3');

        gate.hold = false;
        gate.releaseAll();
        await until(() => stopA.done, 'A finalized');
        expect(stopA.error, isNull);
        expect(controller.status, DashcamStatus.recording, reason: 'A\'s late completion does not touch B\'s status');
        await controller.stopSession();
        expect(controller.status, DashcamStatus.idle);
      });
      expect(errors, isEmpty);
      expect(reported, isEmpty);
      expect(statuses.takeWhile((s) => s != DashcamStatus.recording), isNot(contains(DashcamStatus.idle)),
          reason: 'B\'s start never showed "Pronto" (pre-fix: "Dashcam: Pronto" with no camera)');
      expect(await speedsOf(a.id), range(1, 28));
      expect(await speedsOf(b.id), range(29, 31));
    });

    test('X155 (gated) the previous session\'s telemetry close failing while a newer session records is reported '
        '(FlutterError), not published over the newer session\'s status', () async {
      const ioError = FileSystemException('write failed (injected)', 'x155.jsonl');
      late DrivingSession a;
      late DashcamTelemetryWriter w;
      final errors = await _uncaughtErrorsOf(() async {
        (a, w) = await recordWithHeldFlush();
        final stopA = _Watched(controller.stopSession());
        // Fase 16.2-R4.4-R1-T-Rm (R-m, test-only): see X154 — admission
        // (canStartSession) is awaited before B starts; A's telemetry close
        // stays held.
        await until(() => cameraReleased() && controller.status == DashcamStatus.finalizing && controller.canStartSession, 'A: camera released, file pending, A closed by the recorder');
        gate.run(() => controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'B recording');
        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        await until(() => stopA.done, 'A finalized (with a failure)');
        expect(stopA.error, isNull, reason: 'the STOP request completes; the failure is reported, not thrown');
        expect(controller.status, DashcamStatus.recording, reason: 'B\'s camera is fine');
        expect(controller.errorMessage, isNull);
        expect(w.failure, same(ioError));
        expect(w.unpersistedSampleCount, 28);
        await controller.stopSession();
      });
      expect(errors, [same(ioError)], reason: 'A\'s automatic flush (unawaited) failing');
      expect(reported.map((d) => d.exception), [same(ioError)], reason: 'A\'s close outcome, reported exactly once');
      expect(reported.single.library, 'dashcam session controller');
      expect(await speedsOf(a.id), isEmpty, reason: 'the failed batch is never retried');
    });

    test('X156 (gated) dispose owns the telemetry close it starts: a STOP\'s pending close finishes after dispose without '
        'reopening anything; a failure found only by dispose\'s own close is reported once', () async {
      const ioError = FileSystemException('final write failed (injected)', 'x156.jsonl');
      final errors = await _uncaughtErrorsOf(() async {
        // (1) STOP pending, then dispose.
        final (a, w) = await recordWithHeldFlush();
        final stopA = _Watched(controller.stopSession());
        await until(() => cameraReleased() && controller.status == DashcamStatus.finalizing, 'A: camera released, file pending');
        controller.dispose();
        disposed = true;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(controller.pendingTelemetryFinalizationsForTest, 1, reason: 'still owned after dispose');
        expect(gate.opens, 1);
        gate.hold = false;
        gate.releaseAll();
        await controller.telemetryFinalizationsForTest();
        await until(() => stopA.done, 'A\'s STOP completes after dispose');
        expect(stopA.error, isNull);
        expect(w.state, DashcamTelemetryWriterState.closed);
        expect(await speedsOf(a.id), range(1, 28));
        expect(gate.opens, 1, reason: 'nothing reopened by the late completion');
        expect(reported, isEmpty);
      });
      expect(errors, isEmpty);

      // (2) A fresh controller: dispose while recording; only dispose's close hits the failure.
      final c2 = DashcamSessionController(
        dashcamService: DashcamService(
          config: DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: 1024, audioEnabled: false, resolution: VideoResolution.hd720, frameRate: 30, enabled: true),
          segmentDuration: const Duration(minutes: 10),
        ),
        dashcamPreferences: preferences,
        sessionRecorder: recorder,
        snapshotStream: controllerSnapshots.stream,
        eventStream: events.stream,
      );
      final c2Writers = <DashcamTelemetryWriter>[];
      c2.openTelemetryWriterHookForTest = (w, open) {
        c2Writers.add(w);
        return open();
      };
      final errors2 = await _uncaughtErrorsOf(() async {
        await until(() => recorder.state == DrivingSessionRecorderState.idle, 'recorder idle');
        gate.run(() => c2.startSession());
        await until(() => c2.status == DashcamStatus.recording, 'recording');
        emit(3);
        await until(() => c2Writers.single.acceptedSampleCount == 3, '3 accepted');
        gate.failNext(ioError);
        c2.dispose();
        await c2.telemetryFinalizationsForTest();
      });
      expect(errors2, isEmpty, reason: 'pre-fix: an unowned close → uncaught error');
      expect(reported.map((d) => d.exception), [same(ioError)], reason: 'the primary error, reported exactly once');
      expect(c2Writers.single.state, DashcamTelemetryWriterState.closed);
      expect(gate.openHandles, 0, reason: 'the handle is released even though the final write failed');
    });
  });
}
