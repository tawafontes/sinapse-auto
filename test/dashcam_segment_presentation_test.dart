// Fase 16.2-R4.4-HW-MIG-5-SIG-2 — DashcamService.segmentPresentationListenable: REC is red only
// for positive video evidence of the Recording this service adopted, and any stop, end, error or
// loss takes it away in the same step. FakeCameraPlatform.autoVideoEvidence is off in this file: a
// Start and video are separate facts, each released by the test.
//
// Every negative assertion is taken with the operation held on a gate, or right after the fact
// that must not change anything; no assertion depends on elapsed time. _until only waits for a
// state to be reached, and fails if it is not.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart' show CameraPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/services/dashcam_service.dart';

import 'support/fake_camera_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory dir;
  late FakeCameraPlatform fake;
  late DashcamService service;
  final ticks = <void Function()>[];
  final told = <DashcamSegmentPresentation>[];
  final errors = <DashcamServiceError>[];
  final held = <Completer<void>>[];

  DashcamSegmentPresentation shown() => service.segmentPresentationListenable.value;
  int count(String call) => fake.calls.where((c) => c == call).length;

  Future<void> until(bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > const Duration(seconds: 10)) {
        fail('never happened: $what (presentation=${shown().name}, calls=${fake.calls.join(',')})');
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  Completer<void> gate() {
    final completer = Completer<void>();
    held.add(completer);
    return completer;
  }

  void build({Duration startDeadline = const Duration(seconds: 5)}) {
    service = DashcamService(
      config: DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: 1024, audioEnabled: false, resolution: VideoResolution.hd720, frameRate: 30, enabled: true),
      // Rotations are driven by hand, never by a real timer.
      segmentDuration: const Duration(minutes: 10),
      startVideoRecordingTimeout: startDeadline,
    );
    service.segmentTimerArmedHookForTest = ticks.add;
    service.segmentPresentationListenable.addListener(() => told.add(shown()));
    service.originatedErrors.listen(errors.add);
  }

  Future<void> record({Duration startDeadline = const Duration(seconds: 5)}) async {
    build(startDeadline: startDeadline);
    await service.initialize();
    await service.startLoopRecording(clipOwnerToken: 'session-A');
  }

  Future<void> recordConfirmed() async {
    await record();
    fake.emitVideoProgress();
    expect(shown(), DashcamSegmentPresentation.videoConfirmed, reason: 'test setup');
  }

  /// A tick, with the rotation's STOP held inside the native call.
  Future<Completer<void>> rotateHoldingTheStop() async {
    final stopsBefore = count('stopVideoRecording');
    final stop = gate();
    fake.pendingStopVideoRecording = stop;
    ticks.last();
    await until(() => count('stopVideoRecording') == stopsBefore + 1, 'the rotation entering its STOP');
    return stop;
  }

  /// A tick whose STOP completes, with the restart held inside the native START.
  Future<Completer<void>> rotateHoldingTheStart() async {
    final startsBefore = count('startVideoCapturing');
    final start = gate();
    fake.pendingStartVideoCapturing = start;
    ticks.last();
    await until(() => count('startVideoCapturing') == startsBefore + 1, 'the rotation entering its restart START');
    fake.pendingStartVideoCapturing = null;
    return start;
  }

  // A broadcast stream delivers in a later microtask: "no error" is only meaningful after this.
  Future<void> errorsDelivered() => pumpEventQueue();

  Future<void> rotationSettled() => until(() => service.queuedRotationCountForTest == 0 && !service.hasPendingNativeStop, 'the rotation settling');

  setUp(() {
    ticks.clear();
    told.clear();
    errors.clear();
    held.clear();
    dir = Directory.systemTemp.createTempSync('dashcam_segment_presentation_test');
    fake = FakeCameraPlatform(tempDir: dir)..autoVideoEvidence = false;
    CameraPlatform.instance = fake;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    for (final completer in held) {
      if (!completer.isCompleted) completer.complete();
    }
    fake.pendingStartVideoCapturing = null;
    fake.pendingStopVideoRecording = null;
    fake.failStartVideoCapturingWith = null;
    await service.dispose().catchError((_) {});
    await until(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the release in tearDown');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A clip still being closed on Windows; the system temp folder takes it.
    }
  });

  group('rotation', () {
    test('X539 — REC goes neutral before the STOP returns, stays neutral through Start, and only progress turns it red', () async {
      await recordConfirmed();

      final stop = await rotateHoldingTheStop();
      expect(shown(), DashcamSegmentPresentation.transitioning, reason: 'the native STOP has not returned');
      expect(service.isRecording, isTrue, reason: 'the logical session is not touched');

      final start = gate();
      fake.pendingStartVideoCapturing = start;
      final startsBefore = count('startVideoCapturing');
      stop.complete();
      await until(() => count('startVideoCapturing') == startsBefore + 1, 'the restart START');
      fake.pendingStartVideoCapturing = null;
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'Finalize of the old segment is no evidence of the new one');

      start.complete();
      await rotationSettled();
      expect(service.previewController!.value.isRecordingVideo, isTrue);
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'N1: a Start alone does not turn REC red');

      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X540 — a first segment: Start without video stays neutral; progress turns it red', () async {
      await record();
      expect(service.previewController!.value.isRecordingVideo, isTrue);
      expect(shown(), DashcamSegmentPresentation.startPending);
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X541 — N6: progress delivered before the START returns is not lost, and shows nothing before adoption', () async {
      build();
      await service.initialize();
      final start = gate();
      fake.pendingStartVideoCapturing = start;
      final starting = service.startLoopRecording(clipOwnerToken: 'session-A');
      await until(() => count('startVideoCapturing') == 1, 'the native START');
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'not adopted yet');
      start.complete();
      await starting;
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X542 — repeated progress publishes nothing new', () async {
      await recordConfirmed();
      final told0 = told.length;
      fake.emitVideoProgress();
      fake.emitVideoProgress();
      expect(told.length, told0);
    });

    test('X543 — the Finalize a rotation asked for is not a failure and reports nothing', () async {
      await recordConfirmed();
      ticks.last();
      await until(() => count('startVideoCapturing') == 2, 'the restart');
      await rotationSettled();
      await errorsDelivered();
      expect(errors, isEmpty);
      expect(shown(), DashcamSegmentPresentation.startPending);
    });

    test('X544 — a stale tick does not touch a healthy segment', () async {
      await recordConfirmed();
      final firstTick = ticks.last;
      final start = await rotateHoldingTheStart();
      start.complete();
      await rotationSettled();
      fake.emitVideoProgress();
      final told0 = told.length;
      await service.stopLoopRecording();
      expect(told.length, greaterThan(told0));
      final told1 = told.length;
      firstTick();
      await rotationSettled();
      expect(told.length, told1, reason: 'the run is over: nothing published');
    });

    test('X545 — a lost event leaves REC neutral, and the next segment can still confirm', () async {
      await record();
      final start = await rotateHoldingTheStart();
      start.complete();
      await rotationSettled();
      expect(shown(), DashcamSegmentPresentation.startPending, reason: 'no progress of either segment ever arrived');
      expect(count('startVideoCapturing'), 2, reason: 'a missing signal starts nothing');

      ticks.last();
      await until(() => count('startVideoCapturing') == 3, 'the next restart');
      await rotationSettled();
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X546 — a late restart still needs evidence, and gets adopted at its settlement', () async {
      await record(startDeadline: const Duration(milliseconds: 60));
      fake.emitVideoProgress();
      final start = await rotateHoldingTheStart();
      await until(() => service.rotationRestartOverdue, 'the restart deadline');
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
      start.complete();
      await rotationSettled();
      expect(service.rotationRestartOverdue, isFalse);
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed), reason: 'late, and no video yet');
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });
  });

  group('end of the recording', () {
    test('X547 — N4: a spontaneous Finalize with an error goes neutral, reports once, and changes nothing else', () async {
      await recordConfirmed();
      final callsBefore = fake.calls.length;

      fake.emitRecordingEnded(error: 3);

      expect(shown(), DashcamSegmentPresentation.segmentEnded);
      await errorsDelivered();
      expect(errors, hasLength(1));
      expect(errors.single.scope, DashcamServiceErrorScope.recordingResult, reason: 'never poisons the session or the camera');
      expect(errors.single.message, contains('3'));
      expect(service.isRecording, isTrue, reason: 'no recovery in this round');
      expect(fake.calls.length, callsBefore, reason: 'no native call: no rotation forced, no restart');
    });

    test('X548 — progress after Finalize does not turn REC red', () async {
      await recordConfirmed();
      fake.emitRecordingEnded(error: 3);
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.segmentEnded);
      await errorsDelivered();
      expect(errors, hasLength(1));
    });

    test('X549 — a Finalize that arrived before adoption is seen at adoption: never red', () async {
      build();
      await service.initialize();
      final start = gate();
      fake.pendingStartVideoCapturing = start;
      final starting = service.startLoopRecording(clipOwnerToken: 'session-A');
      await until(() => count('startVideoCapturing') == 1, 'the native START');
      fake.emitVideoProgress();
      fake.emitRecordingEnded(error: 3);
      start.complete();
      await starting;
      expect(shown(), DashcamSegmentPresentation.segmentEnded);
      expect(told, isNot(contains(DashcamSegmentPresentation.videoConfirmed)));
      await errorsDelivered();
      expect(errors, hasLength(1));
    });

    test('X550 — the rotation after a spontaneous end needs new evidence', () async {
      await recordConfirmed();
      fake.emitRecordingEnded(error: 3);
      ticks.last();
      await until(() => count('startVideoCapturing') == 2, 'the next rotation');
      await rotationSettled();
      expect(shown(), DashcamSegmentPresentation.startPending);
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });
  });

  group('previous generation', () {
    test('X551 — N2: after the STOP of A, facts arriving while B is unadopted do not light REC', () async {
      await recordConfirmed();
      final start = await rotateHoldingTheStart();
      // The slot now holds B's token; what the plugin would attribute to A has no slot to land on,
      // and B's own progress before adoption must still show nothing.
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.startPending);
      start.complete();
      await rotationSettled();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed, reason: 'B is adopted with its own evidence');
    });

    test('X552 — a slot that moved to another recording is not this one: neutral, no failure reported', () async {
      await recordConfirmed();
      fake.clearRecordingEvidence();
      expect(shown(), DashcamSegmentPresentation.startPending);
      await errorsDelivered();
      expect(errors, isEmpty);
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.startPending);
    });
  });

  test('X564 — N2: evidence of another token never confirms the adopted recording', () async {
    await record();
    fake.moveEvidenceToAnotherRecording();
    expect(shown(), DashcamSegmentPresentation.startPending);
    expect(told, isNot(contains(DashcamSegmentPresentation.videoConfirmed)));
    await errorsDelivered();
    expect(errors, isEmpty);
  });

  group('stop, abort, lifecycle', () {
    test('X553 — manual STOP: neutral before its native call returns; later evidence never relights', () async {
      await recordConfirmed();
      final stop = gate();
      fake.pendingStopVideoRecording = stop;
      final stopping = service.stopLoopRecording();
      expect(shown(), DashcamSegmentPresentation.inactive, reason: 'in the same step as the request');
      await until(() => count('stopVideoRecording') == 1, 'the native STOP');
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.inactive);
      stop.complete();
      await stopping;
      expect(shown(), DashcamSegmentPresentation.inactive);
      await errorsDelivered();
      expect(errors, isEmpty, reason: 'its Finalize was requested');
    });

    test('X554 — STOP during a START in flight: the Recording is cleaned up, never adopted, never red', () async {
      build();
      await service.initialize();
      final start = gate();
      fake.pendingStartVideoCapturing = start;
      final starting = service.startLoopRecording(clipOwnerToken: 'session-A');
      await until(() => count('startVideoCapturing') == 1, 'the native START');
      final stopping = service.stopLoopRecording();
      fake.emitVideoProgress();
      start.complete();
      await starting;
      await stopping;
      expect(told, isNot(contains(DashcamSegmentPresentation.videoConfirmed)));
      expect(shown(), DashcamSegmentPresentation.inactive);
    });

    test('X555 — a START that fails leaves REC neutral', () async {
      build();
      await service.initialize();
      fake.failStartVideoCapturingWith = StateError('no');
      await service.startLoopRecording(clipOwnerToken: 'session-A').catchError((_) {});
      expect(told, isNot(contains(DashcamSegmentPresentation.videoConfirmed)));
      expect(shown(), isNot(DashcamSegmentPresentation.videoConfirmed));
    });

    test('X556 — HOME: backgrounding removes ownership; old evidence does not return, a new START needs its own', () async {
      await recordConfirmed();
      service.notifyAppBackgrounded();
      expect(shown(), DashcamSegmentPresentation.inactive);
      fake.emitRecordingEnded(error: 4);
      await errorsDelivered();
      expect(errors, isEmpty, reason: 'the end is the expected effect of the background, already known');

      await service.stopLoopRecording().catchError((_) {});
      await service.initialize();
      await service.startLoopRecording(clipOwnerToken: 'session-A');
      expect(shown(), DashcamSegmentPresentation.startPending);
      fake.emitVideoProgress();
      expect(shown(), DashcamSegmentPresentation.videoConfirmed);
    });

    test('X557 — dispose: neutral at once and the slot is no longer watched', () async {
      await recordConfirmed();
      unawaited(service.dispose());
      expect(shown(), DashcamSegmentPresentation.inactive);
      final told0 = told.length;
      fake.emitRecordingEnded(error: 4);
      expect(told.length, told0);
      await errorsDelivered();
      expect(errors, isEmpty);
    });

    test('X558 — no evidence available (channel failed, plugin cleared the slot before adoption): neutral, recording unaffected', () async {
      build();
      await service.initialize();
      final start = gate();
      fake.pendingStartVideoCapturing = start;
      final starting = service.startLoopRecording(clipOwnerToken: 'session-A');
      await until(() => count('startVideoCapturing') == 1, 'the native START');
      fake.clearRecordingEvidence();
      start.complete();
      await starting;
      expect(service.previewController!.value.isRecordingVideo, isTrue);
      expect(service.isRecording, isTrue);
      expect(shown(), DashcamSegmentPresentation.startPending);
      await errorsDelivered();
      expect(errors, isEmpty);
    });
  });
}
