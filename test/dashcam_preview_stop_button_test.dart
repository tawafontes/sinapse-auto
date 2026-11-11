// The dashcam fullscreen preview's "Parar" button — the same stop as the session screen's
// "Finalizar sessão" (DashcamSessionController.stopSession): it ends the camera and the driving
// session together, is offered only while the session is recording, and a double tap is one stop.
// Driven by a real DashcamSessionController + DashcamService over the fake camera platform.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart' show CameraPlatform;
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
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_preview_view.dart';

import 'support/fake_camera_platform.dart';
import 'support/index_queue_isolation.dart';

class _PreviewFake extends FakeCameraPlatform {
  _PreviewFake({required super.tempDir});

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand(key: Key('surface'));
}

class _Rig {
  static const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory dir;
  late _PreviewFake platform;
  late DashcamService service;
  late DashcamSessionController controller;
  late DrivingSessionRecorder recorder;
  final snapshots = StreamController<TelemetrySnapshot>.broadcast();
  final events = StreamController<DetectedEvent>.broadcast();
  final held = <Completer<void>>[];

  int count(String call) => platform.calls.where((c) => c == call).length;

  Future<void> until(bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > const Duration(seconds: 10)) fail('never happened: $what (calls=${platform.calls.join(',')})');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> start() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_preview_stop_button_test');
    platform = _PreviewFake(tempDir: dir);
    CameraPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
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
    final preferences = DashcamPreferences();
    await preferences.setEnabled(true);
    recorder = DrivingSessionRecorder(snapshots.stream);
    service = DashcamService(
      config: DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: 1024, audioEnabled: false, resolution: VideoResolution.hd720, frameRate: 30, enabled: true),
      segmentDuration: const Duration(minutes: 10),
    );
    controller = DashcamSessionController(dashcamService: service, dashcamPreferences: preferences, sessionRecorder: recorder, snapshotStream: snapshots.stream, eventStream: events.stream);
  }

  Future<void> close() async {
    for (final completer in held) {
      if (!completer.isCompleted) completer.complete();
    }
    platform.pendingStopVideoRecording = null;
    try {
      await controller.stopSession().timeout(const Duration(seconds: 15));
    } catch (_) {}
    controller.dispose();
    await until(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown');
    await indexQueueSettledForTest();
    await snapshots.close();
    await events.close();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<void> _mount(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: DashcamPreviewView(controller: rig.controller))));
}

final _stopButton = find.widgetWithText(FilledButton, 'Parar');

/// The button's own callback, run in the real zone (inside `runAsync`): the stop it starts writes
/// files and Hive boxes, which never progress under the widget tester's fake clock. The button is
/// found on screen first, so this still proves it is shown and wired to the stop.
void _pressStop(WidgetTester tester) => tester.widget<ButtonStyleButton>(_stopButton).onPressed!();

void main() {
  testWidgets('no stop is offered before a session starts', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await _mount(tester, rig);
      await tester.pump();
      expect(find.text('Iniciar sessão'), findsOneWidget);
      expect(_stopButton, findsNothing);
    } finally {
      await tester.runAsync(rig.close);
    }
  });

  testWidgets('while recording, "Parar" stops the camera and finishes the driving session; it is gone afterwards', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await tester.runAsync(() async {
        rig.controller.startSession();
        await rig.until(() => rig.controller.status == DashcamStatus.recording, 'the session recording');
      });
      await _mount(tester, rig);
      await tester.pump();
      expect(_stopButton, findsOneWidget);

      await tester.runAsync(() async {
        _pressStop(tester);
        await rig.until(() => rig.recorder.state == DrivingSessionRecorderState.idle && !rig.service.hasPendingNativeStop, 'the session stopped');
      });
      await tester.pump();

      expect(rig.count('stopVideoRecording'), 1);
      expect(rig.recorder.activeSession, isNull);
      expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).values.single.endTime, isNotNull, reason: 'the session was finalized and saved');
      expect(_stopButton, findsNothing);
      expect(find.text('Iniciar sessão'), findsOneWidget);
    } finally {
      await tester.runAsync(rig.close);
    }
  });

  testWidgets('a double tap is one stop, and the button disappears while the stop is being finalized', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await tester.runAsync(() async {
        rig.controller.startSession();
        await rig.until(() => rig.controller.status == DashcamStatus.recording, 'the session recording');
      });
      await _mount(tester, rig);
      await tester.pump();

      final stop = Completer<void>();
      rig.held.add(stop);
      rig.platform.pendingStopVideoRecording = stop;
      await tester.runAsync(() async {
        _pressStop(tester);
        _pressStop(tester);
      });
      await tester.runAsync(() => rig.until(() => rig.count('stopVideoRecording') == 1, 'the native STOP'));
      await tester.pump();
      expect(rig.recorder.state, isNot(DrivingSessionRecorderState.recording));
      expect(_stopButton, findsNothing, reason: 'nothing more to stop while the stop is under way');

      await tester.runAsync(() async {
        stop.complete();
        await rig.until(() => rig.recorder.state == DrivingSessionRecorderState.idle && !rig.service.hasPendingNativeStop, 'the session stopped');
      });
      expect(rig.count('stopVideoRecording'), 1, reason: 'the second tap joined the first stop');
      expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).values, hasLength(1));
    } finally {
      await tester.runAsync(rig.close);
    }
  });

  group('confirmLeaveDashcamFullscreen (the fullscreen double-tap)', () {
    Future<BuildContext> mountHost(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.expand(key: Key('host')))));
      return tester.element(find.byKey(const Key('host')));
    }

    /// Asks in the REAL zone, so the stop a "Sim" issues (Hive, files) runs
    /// there too — the dialog itself is shown and answered by frames.
    Future<Future<bool>> ask(WidgetTester tester, _Rig rig, BuildContext context) async {
      late Future<bool> answer;
      // A block body: an arrow would return the answer's Future, and runAsync
      // would wait for a dialog nobody has answered yet.
      await tester.runAsync(() async {
        answer = confirmLeaveDashcamFullscreen(context, rig.controller);
      });
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('with nothing recording it leaves at once, without asking', (tester) async {
      final rig = _Rig();
      await tester.runAsync(rig.start);
      try {
        final context = await mountHost(tester);
        final answer = await ask(tester, rig, context);
        expect(find.text('Deseja encerrar a gravação?'), findsNothing);
        await tester.runAsync(() async => expect(await answer, isTrue));
      } finally {
        await tester.runAsync(rig.close);
      }
    });

    testWidgets('while recording it asks; "Não" stays and keeps recording', (tester) async {
      final rig = _Rig();
      await tester.runAsync(rig.start);
      try {
        await tester.runAsync(() async {
          rig.controller.startSession();
          await rig.until(() => rig.controller.status == DashcamStatus.recording, 'the session recording');
        });
        final context = await mountHost(tester);
        final answer = await ask(tester, rig, context);
        expect(find.text('Deseja encerrar a gravação?'), findsOneWidget);

        await tester.tap(find.text('Não'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async => expect(await answer, isFalse));
        expect(rig.recorder.state, DrivingSessionRecorderState.recording);
        expect(rig.count('stopVideoRecording'), 0);
      } finally {
        await tester.runAsync(rig.close);
      }
    });

    testWidgets('while recording, "Sim" stops the camera and the session and leaves', (tester) async {
      final rig = _Rig();
      await tester.runAsync(rig.start);
      try {
        await tester.runAsync(() async {
          rig.controller.startSession();
          await rig.until(() => rig.controller.status == DashcamStatus.recording, 'the session recording');
        });
        final context = await mountHost(tester);
        final answer = await ask(tester, rig, context);

        await tester.tap(find.text('Sim'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          expect(await answer, isTrue);
          await rig.until(() => rig.recorder.state == DrivingSessionRecorderState.idle && !rig.service.hasPendingNativeStop, 'the session stopped');
        });
        expect(rig.count('stopVideoRecording'), 1);
        expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).values.single.endTime, isNotNull);
      } finally {
        await tester.runAsync(rig.close);
      }
    });
  });
}
