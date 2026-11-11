import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Copies a finished dashcam clip into the phone's gallery
/// (`Movies/Synapse Auto`, through Android's MediaStore).
///
/// The clip itself stays in the app's private `dashcam_clips/`: the clip
/// index, the storage quota, protection and in-app playback all keep working
/// on that private file, which the app alone owns (an external app or the user
/// deleting a gallery file can never break them). The gallery copy is the
/// user's: the quota never counts or deletes it, and deleting a session in the
/// app does not remove it.
///
/// Production: [MethodChannelDashcamGalleryExporter], backed by
/// `MainActivity.kt` (Android only). Tests: a fake, or nothing — on a platform
/// without the native side [isSupported] is `false` and nothing is called.
abstract interface class DashcamGalleryExporter {
  /// Whether this platform has the native side at all. Answered synchronously,
  /// so a caller can skip the export without an `await`.
  bool get isSupported;

  /// Copies the file at [path] into the gallery as [displayName], dated
  /// [recordedAt]. Throws [DashcamGalleryPermissionDenied] when Android (before
  /// 10) has not granted storage access, and anything else for other failures;
  /// on failure no partial entry is left in the gallery.
  Future<void> saveVideo({required String path, required String displayName, required DateTime recordedAt});
}

/// Android before 10 needs the storage permission to write into the shared
/// Movies folder, and it has not been granted.
class DashcamGalleryPermissionDenied implements Exception {
  const DashcamGalleryPermissionDenied();

  @override
  String toString() => 'DashcamGalleryPermissionDenied';
}

/// `SynapseAuto_20261111_143012.mp4` — the clip's start in local time. Two
/// clips with the same second get distinct names from MediaStore itself.
String dashcamGalleryDisplayName(DateTime recordedAt) {
  final t = recordedAt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'SynapseAuto_${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.mp4';
}

/// The production [DashcamGalleryExporter] — `MainActivity.kt`'s
/// [channelName], Android only. The copy runs on a native background thread,
/// never on the main thread (which also runs the Dart UI isolate and the
/// camera's callbacks).
class MethodChannelDashcamGalleryExporter implements DashcamGalleryExporter {
  const MethodChannelDashcamGalleryExporter() : _supportedForTest = false;

  /// Calls the channel on any platform — for a test that mocks it.
  @visibleForTesting
  const MethodChannelDashcamGalleryExporter.forTest() : _supportedForTest = true;

  final bool _supportedForTest;

  static const channelName = 'com.synapseauto.synapse_auto/dashcam_gallery';
  static const _channel = MethodChannel(channelName);

  @override
  bool get isSupported => _supportedForTest || Platform.isAndroid;

  @override
  Future<void> saveVideo({required String path, required String displayName, required DateTime recordedAt}) async {
    try {
      await _channel.invokeMethod<String>('saveVideo', {
        'path': path,
        'displayName': displayName,
        'recordedAtMs': recordedAt.millisecondsSinceEpoch,
      });
    } on PlatformException catch (error) {
      if (error.code == 'storage_permission') throw const DashcamGalleryPermissionDenied();
      rethrow;
    }
  }
}
