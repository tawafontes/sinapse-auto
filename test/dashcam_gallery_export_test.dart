// Gallery export of dashcam clips — every published segment is copied into the phone's gallery
// through DashcamGalleryExporter, while the private clip, its index entry and the recording are
// untouched by the copy or by its failure. Driven by a real DashcamSessionController +
// DashcamService over the fake camera platform, with a fake exporter standing in for the native
// MediaStore copy (which only real hardware can validate).
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
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/dashcam_gallery_exporter.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_camera_platform.dart';
import 'support/index_queue_isolation.dart';

class _SavedVideo {
  _SavedVideo(this.path, this.displayName, this.recordedAt, this.existedAtCopy);

  final String path;
  final String displayName;
  final DateTime recordedAt;
  final bool existedAtCopy;
}

class _FakeGalleryExporter implements DashcamGalleryExporter {
  _FakeGalleryExporter({this.isSupported = true});

  @override
  final bool isSupported;

  final saved = <_SavedVideo>[];

  /// Thrown by the next copies, in order; empty → the copy succeeds.
  final failures = <Object>[];

  @override
  Future<void> saveVideo({required String path, required String displayName, required DateTime recordedAt}) async {
    saved.add(_SavedVideo(path, displayName, recordedAt, File(path).existsSync()));
    if (failures.isNotEmpty) throw failures.removeAt(0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dashcamGalleryDisplayName', () {
    test('is SynapseAuto_<local date>_<local time>.mp4, zero-padded', () {
      expect(dashcamGalleryDisplayName(DateTime(2026, 3, 4, 5, 6, 7)), 'SynapseAuto_20260304_050607.mp4');
      expect(dashcamGalleryDisplayName(DateTime(2026, 11, 30, 23, 59, 58)), 'SynapseAuto_20261130_235958.mp4');
    });

    test('uses local time for a UTC instant', () {
      final local = DateTime(2026, 7, 1, 12, 0, 0);
      expect(dashcamGalleryDisplayName(local.toUtc()), dashcamGalleryDisplayName(local));
    });
  });

  group('MethodChannelDashcamGalleryExporter', () {
    const channel = MethodChannel(MethodChannelDashcamGalleryExporter.channelName);
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    test('is not supported off Android (the test host), so nothing is ever called there', () {
      expect(const MethodChannelDashcamGalleryExporter().isSupported, Platform.isAndroid);
    });

    test('sends the path, the display name and the start in epoch ms', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'content://media/external/video/media/1';
      });
      final at = DateTime(2026, 11, 11, 10, 20, 30);
      await const MethodChannelDashcamGalleryExporter.forTest().saveVideo(path: '/data/x/clip.mp4', displayName: 'SynapseAuto_x.mp4', recordedAt: at);
      expect(calls.single.method, 'saveVideo');
      expect(calls.single.arguments, {'path': '/data/x/clip.mp4', 'displayName': 'SynapseAuto_x.mp4', 'recordedAtMs': at.millisecondsSinceEpoch});
    });

    test('a storage_permission error becomes DashcamGalleryPermissionDenied; any other stays a PlatformException', () async {
      var code = 'storage_permission';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: code, message: 'native');
      });
      const exporter = MethodChannelDashcamGalleryExporter.forTest();
      Future<void> save() => exporter.saveVideo(path: '/p', displayName: 'n.mp4', recordedAt: DateTime(2026));
      await expectLater(save(), throwsA(isA<DashcamGalleryPermissionDenied>()));
      code = 'save_failed';
      await expectLater(save(), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'save_failed')));
    });
  });

  group('DashcamSessionController gallery export', () {
    late Directory dir;
    late FakeCameraPlatform fakePlatform;
    late StreamController<TelemetrySnapshot> snapshots;
    late StreamController<DetectedEvent> events;
    late DrivingSessionRecorder recorder;
    late DashcamPreferences preferences;
    late DashcamService service;
    late DashcamSessionController controller;
    late _FakeGalleryExporter exporter;
    final reported = <String>[];
    StreamSubscription<DashcamServiceError>? errorsSub;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    Future<void> until(bool Function() condition, String what) async {
      final clock = Stopwatch()..start();
      while (!condition()) {
        if (clock.elapsed > const Duration(seconds: 10)) fail('never happened: $what (status=${controller.status.name}, calls=${fakePlatform.calls.join(',')})');
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    void build(_FakeGalleryExporter galleryExporter) {
      exporter = galleryExporter;
      service = DashcamService(
        config: DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: 1024, audioEnabled: false, resolution: VideoResolution.hd720, frameRate: 30, enabled: true),
        segmentDuration: const Duration(minutes: 10),
      );
      errorsSub = service.originatedErrors.listen((error) => reported.add(error.message));
      controller = DashcamSessionController(
        dashcamService: service,
        dashcamPreferences: preferences,
        sessionRecorder: recorder,
        snapshotStream: snapshots.stream,
        eventStream: events.stream,
        galleryExporter: galleryExporter,
      );
    }

    Future<String> recordOneSegment() async {
      final session = controller.startSession();
      await until(() => controller.status == DashcamStatus.recording, 'the session recording');
      await controller.stopSession();
      await until(() => !service.hasPendingNativeStop, 'the stop settled');
      await indexQueueSettledForTest();
      return session.id;
    }

    setUp(() async {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      dir = Directory.systemTemp.createTempSync('dashcam_gallery_export_test');
      fakePlatform = FakeCameraPlatform(tempDir: dir);
      CameraPlatform.instance = fakePlatform;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
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
      snapshots = StreamController<TelemetrySnapshot>.broadcast();
      events = StreamController<DetectedEvent>.broadcast();
      recorder = DrivingSessionRecorder(snapshots.stream);
      preferences = DashcamPreferences();
      await preferences.setEnabled(true);
      reported.clear();
    });

    tearDown(() async {
      if (recorder.state != DrivingSessionRecorderState.idle) {
        try {
          await controller.stopSession();
        } catch (_) {}
      }
      controller.dispose();
      await until(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown');
      await indexQueueSettledForTest();
      await errorsSub?.cancel();
      await snapshots.close();
      await events.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
      await Hive.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a published segment is copied to the gallery once — from the private clip, which stays and is indexed', () async {
      build(_FakeGalleryExporter());
      final sessionId = await recordOneSegment();
      await until(() => exporter.saved.isNotEmpty, 'the gallery copy');

      final clip = service.clips.single;
      final copy = exporter.saved.single;
      expect(copy.path, clip.file.path);
      expect(copy.existedAtCopy, isTrue, reason: 'the copy reads the published private clip');
      expect(copy.displayName, dashcamGalleryDisplayName(clip.recordedAt));
      expect(copy.recordedAt, clip.recordedAt);
      expect(clip.file.existsSync(), isTrue, reason: 'the private clip is kept for the index, the quota and playback');
      final indexed = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId) as List?;
      expect(indexed, hasLength(1), reason: 'the clip is indexed as before');
      expect(controller.galleryExportFailureMessage, isNull);
    });

    test('a failed copy is reported and shown, nothing else changes; the next successful copy clears it', () async {
      build(_FakeGalleryExporter()..failures.add(const DashcamGalleryPermissionDenied()));
      final first = await recordOneSegment();
      await until(() => controller.galleryExportFailureMessage != null, 'the failure being shown');

      expect(controller.galleryExportFailureMessage, contains('Armazenamento'));
      expect(reported.where((m) => m.contains('galeria')), hasLength(1));
      expect(controller.status, isNot(DashcamStatus.error), reason: 'a gallery failure is diagnostic only');
      expect(service.clips.single.file.existsSync(), isTrue);
      expect(Hive.box(HiveBoxNames.dashcamSessionVideos).get(first) as List?, hasLength(1));

      await until(() => controller.canStartSession, 'the next session admitted');
      await recordOneSegment();
      await until(() => exporter.saved.length == 2, 'the second copy');
      await until(() => controller.galleryExportFailureMessage == null, 'the failure cleared');
    });

    test('a platform without the native side exports nothing', () async {
      build(_FakeGalleryExporter(isSupported: false));
      await recordOneSegment();
      expect(service.clips, hasLength(1));
      expect(exporter.saved, isEmpty);
      expect(controller.galleryExportFailureMessage, isNull);
    });
  });
}
