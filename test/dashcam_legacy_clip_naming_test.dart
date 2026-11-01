import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_clip_descriptor.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/services/dashcam_clip_files.dart';
import 'package:synapse_auto/services/dashcam_service.dart';

import 'support/fake_camera_platform.dart';

// Fase 16.2-R4.4-R2.1.1-REG-2 — the name of a clip without a session token
// (`clip_<ms>.mp4`) is strictly increasing, whatever the clock does. Before it,
// two clips finishing in the same millisecond got the same name: the second
// promotion threw DashcamClipCollision, STOP only reported it on `errors`, and
// the clip stayed outside `dashcam_clips/`.
//
// The allocator state is static and never reset, on purpose: these tests read
// the latest value from a real clip and state everything relative to it.

/// The fake recording, with bytes of its own: a mixed-up or overwritten clip
/// cannot pass as the right one.
class _DistinctBytesCameraPlatform extends FakeCameraPlatform {
  _DistinctBytesCameraPlatform({required super.tempDir});

  final List<String> sourcePaths = [];

  static List<int> bytesOf(int index) => List<int>.filled(1024, index + 1);

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    final file = await super.stopVideoRecording(cameraId);
    File(file.path).writeAsBytesSync(bytesOf(sourcePaths.length));
    sourcePaths.add(file.path);
    return file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final legacyName = RegExp(r'^clip_([0-9]+)\.mp4$');

  late Directory dir;
  late _DistinctBytesCameraPlatform platform;
  late DashcamService service;
  late List<String> errors;

  DashcamConfig config() => DashcamConfig(
    cameraSelection: CameraSelection.rear,
    storageQuotaMb: 1024,
    audioEnabled: false,
    resolution: VideoResolution.hd720,
    frameRate: 30,
    enabled: true,
  );

  Future<void> buildService() async {
    service = DashcamService(config: config());
    service.errors.listen(errors.add);
    await service.initialize();
  }

  Future<void> disposeService() async {
    await service.dispose();
    await pumpEventQueue(times: 50);
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dashcam_legacy_clip_naming_test');
    platform = _DistinctBytesCameraPlatform(tempDir: dir);
    CameraPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
    errors = [];
    DashcamClipStorageCounters.resetForTest();
    await buildService();
  });

  tearDown(() async {
    await disposeService();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// One whole recording, without a token: the legacy path.
  Future<void> recordOneClip() async {
    await service.startLoopRecording();
    await service.stopLoopRecording();
    await pumpEventQueue(times: 50);
  }

  String nameOf(DashcamClip clip) => dashcamClipBasename(clip.file.path);

  int msOf(String name) {
    final match = legacyName.firstMatch(name);
    expect(match, isNotNull, reason: 'the legacy format is clip_<digits>.mp4 exactly: $name');
    expect(DashcamClipDescriptor.parse(name), isNull, reason: 'a legacy name is never a v1 name: $name');
    return int.parse(match!.group(1)!);
  }

  test('T1 — the same millisecond, repeatedly and across a new service instance: every clip gets a name of its own, strictly increasing, and nothing collides', () async {
    final fixedNow = DateTime.now().millisecondsSinceEpoch;
    service.legacyClipNowMsForTest = () => fixedNow;
    for (var i = 0; i < 3; i++) {
      await recordOneClip();
    }
    final values = [for (final clip in service.clips) msOf(nameOf(clip))];
    expect(values, hasLength(3), reason: 'errors: $errors');

    // The directory is shared: a new instance must not start over.
    await disposeService();
    await buildService();
    service.legacyClipNowMsForTest = () => fixedNow;
    await recordOneClip();
    expect(service.clips, hasLength(1), reason: 'errors: $errors');
    values.add(msOf(nameOf(service.clips.single)));

    for (var i = 1; i < values.length; i++) {
      expect(values[i], greaterThan(values[i - 1]), reason: 'strictly increasing: $values');
    }
    expect(values.first, greaterThanOrEqualTo(fixedNow));
    expect(errors, isEmpty);
    expect(DashcamClipStorageCounters.collisions, 0);
  });

  test('T2 — a repeated and a regressive clock: the sequence stays strictly increasing, follows a clock that is ahead, and recordedAt stays the real start of the recording', () async {
    await recordOneClip();
    final last = msOf(nameOf(service.clips.single));
    const hour = 3600000;

    final clock = <int>[last + hour, last + hour, last, 0, last + 2 * hour];
    final expected = <int>[last + hour, last + hour + 1, last + hour + 2, last + hour + 3, last + 2 * hour];
    var next = 0;
    service.legacyClipNowMsForTest = () => clock[next++];

    final before = DateTime.now();
    for (var i = 0; i < clock.length; i++) {
      await recordOneClip();
    }
    final after = DateTime.now();

    final published = service.clips.skip(1).toList();
    expect([for (final clip in published) msOf(nameOf(clip))], expected, reason: 'errors: $errors');
    for (final clip in published) {
      expect(clip.recordedAt.isBefore(before), isFalse, reason: 'recordedAt is not derived from the name');
      expect(clip.recordedAt.isAfter(after), isFalse, reason: 'recordedAt is not derived from the name');
    }
    expect(errors, isEmpty);
    expect(DashcamClipStorageCounters.collisions, 0);
  });

  test('T3 — publication integrity: colliding candidates are both published with their own bytes; a name already on disk is never overwritten, fails explicitly, and the next clip still publishes', () async {
    final fixedNow = DateTime.now().millisecondsSinceEpoch;
    service.legacyClipNowMsForTest = () => fixedNow;
    await recordOneClip();
    await recordOneClip();

    expect(service.clips, hasLength(2), reason: 'errors: $errors');
    expect(nameOf(service.clips[0]), isNot(nameOf(service.clips[1])));
    for (var i = 0; i < 2; i++) {
      final clip = service.clips[i];
      expect(clip.file.parent.path, endsWith(dashcamClipsDirectoryName));
      expect(clip.file.readAsBytesSync(), _DistinctBytesCameraPlatform.bytesOf(i));
      expect(clip.sizeBytes, 1024);
      expect(File(platform.sourcePaths[i]).existsSync(), isFalse, reason: 'moved, not copied');
    }
    expect(errors, isEmpty);
    expect(DashcamClipStorageCounters.collisions, 0);

    // Outside the guarantee: a file this process did not name, e.g. left by an
    // earlier process whose clock was ahead.
    final taken = msOf(nameOf(service.clips.last)) + 1000;
    final sentinel = File('${service.clips.last.file.parent.path}/clip_$taken.mp4');
    const sentinelBytes = [9, 9, 9];
    sentinel.writeAsBytesSync(sentinelBytes);
    service.legacyClipNowMsForTest = () => taken;
    await recordOneClip();

    expect(service.clips, hasLength(2), reason: 'the refused clip is not published');
    expect(DashcamClipStorageCounters.collisions, 1);
    expect(errors, contains(contains('DashcamClipCollision')), reason: 'the failure is explicit');
    expect(sentinel.readAsBytesSync(), sentinelBytes, reason: 'never overwritten');
    expect(File(platform.sourcePaths[2]).readAsBytesSync(), _DistinctBytesCameraPlatform.bytesOf(2), reason: 'the refused recording stays intact at its source');

    // The same clock does not get stuck on that name.
    await recordOneClip();
    expect(service.clips, hasLength(3), reason: 'errors: $errors');
    expect(msOf(nameOf(service.clips.last)), taken + 1);
    expect(service.clips.last.file.readAsBytesSync(), _DistinctBytesCameraPlatform.bytesOf(3));
    expect(sentinel.readAsBytesSync(), sentinelBytes);
  });
}
