import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Fase 16.2-R4.4-R2 — the facts about the filesystem that Dart cannot read
/// itself (R4.4-R2-D0, §4 and §5.1: there is no Dart API for a volume's free
/// space nor for a file's group), and the one native operation the clip
/// accounting needs. The native side ANSWERS; every decision — what counts,
/// what is evicted, whether a recording may start — is taken in Dart
/// (`dashcam_storage_quota.dart`).
///
/// Production: [MethodChannelDashcamStorageProbe], backed by `MainActivity.kt`
/// (Android only). Tests: a deterministic fake.
abstract interface class DashcamStorageProbe {
  /// Whether this platform has the native side at all. `false` is answered
  /// synchronously, so a caller can skip the probe without an `await` — the
  /// bridge exists only on Android (the one platform validated on hardware).
  bool get isSupported;

  /// The volume holding [path] (an existing file or directory). Throws when
  /// it cannot be read.
  Future<DashcamVolumeStats> volumeStats(String path);

  /// P3-HW-1 (R4.4-R1-HW): a clip renamed out of the setgid `cache/`
  /// directory keeps the app's CACHE group, so Android counts it as "Cache"
  /// and ranks the app first for cache trimming (D0 §2: accounting and order
  /// only — no cleanup deletes by group). For each of [paths], a regular file
  /// whose group is the app's cache group gets the app's own group
  /// (`chown(path, -1, getgid())`); nothing else is touched — no rename, no
  /// copy, no other file. Idempotent. Throws only when the call as a whole
  /// failed; a failure on one file is counted in the result.
  Future<DashcamGroupRepair> normalizeClipGroups(List<String> paths);
}

/// What the volume reports — `statfs` of the filesystem, through
/// `android.os.StatFs`. [availableBytes] is what an app may still write
/// (blocks reserved for root excluded): the same figure Android's storage
/// monitor and CameraX's own floor read.
class DashcamVolumeStats {
  const DashcamVolumeStats({required this.availableBytes, required this.totalBytes});

  final int availableBytes;
  final int totalBytes;
}

/// The outcome of [DashcamStorageProbe.normalizeClipGroups], in counts only
/// (no paths, so nothing of it can leak into a log).
class DashcamGroupRepair {
  const DashcamGroupRepair({
    this.normalized = 0,
    this.alreadyAppGroup = 0,
    this.otherGroup = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  /// Moved from the cache group to the app's group (confirmed by a new stat).
  final int normalized;

  /// Already in the app's group: nothing done.
  final int alreadyAppGroup;

  /// In a group that is neither: left alone.
  final int otherGroup;

  /// Not a regular file, missing, or outside the app's own data directory:
  /// left alone.
  final int skipped;

  /// The repair was attempted and failed. The file is untouched otherwise and
  /// is tried again by the next start.
  final int failed;
}

/// The production [DashcamStorageProbe] — `MainActivity.kt`'s
/// [channelName], Android only.
class MethodChannelDashcamStorageProbe implements DashcamStorageProbe {
  const MethodChannelDashcamStorageProbe() : _supportedForTest = false;

  /// Calls the channel on any platform — for a test that mocks it, so the
  /// encoding of both directions is exercised.
  @visibleForTesting
  const MethodChannelDashcamStorageProbe.forTest() : _supportedForTest = true;

  final bool _supportedForTest;

  static const channelName = 'com.synapseauto.synapse_auto/dashcam_storage';
  static const _channel = MethodChannel(channelName);

  @override
  bool get isSupported => _supportedForTest || Platform.isAndroid;

  @override
  Future<DashcamVolumeStats> volumeStats(String path) async {
    final reply = await _channel.invokeMapMethod<String, Object?>('volumeStats', {'path': path});
    final available = reply?['availableBytes'];
    final total = reply?['totalBytes'];
    if (available is! int || total is! int || available < 0 || total <= 0) {
      throw const FormatException('volumeStats: malformed reply');
    }
    return DashcamVolumeStats(availableBytes: available, totalBytes: total);
  }

  @override
  Future<DashcamGroupRepair> normalizeClipGroups(List<String> paths) async {
    if (paths.isEmpty) return const DashcamGroupRepair();
    final reply = await _channel.invokeMapMethod<String, Object?>('normalizeClipGroups', {'paths': paths});
    int count(String key) {
      final value = reply?[key];
      if (value is! int || value < 0) throw FormatException('normalizeClipGroups: malformed "$key"');
      return value;
    }

    return DashcamGroupRepair(
      normalized: count('normalized'),
      alreadyAppGroup: count('alreadyAppGroup'),
      otherGroup: count('otherGroup'),
      skipped: count('skipped'),
      failed: count('failed'),
    );
  }
}
