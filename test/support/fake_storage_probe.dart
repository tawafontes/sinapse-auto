import 'dart:async';

import 'package:synapse_auto/services/dashcam_storage_probe.dart';

/// Fase 16.2-R4.4-R2 — a deterministic [DashcamStorageProbe]: the volume is
/// whatever the test says ([availableBytes] / [totalBytes], or [availableNow]
/// computed at each read — e.g. from the bytes left in a directory, so an
/// eviction really frees space), a read can fail ([volumeFailure]) or be held
/// ([volumeGate]), and every group repair is recorded.
class FakeStorageProbe implements DashcamStorageProbe {
  FakeStorageProbe({this.availableBytes = 64 * _gib, this.totalBytes = 128 * _gib, this.supported = true});

  static const _gib = 1024 * 1024 * 1024;

  bool supported;
  int availableBytes;
  int totalBytes;

  /// When set, the available bytes of each read (overrides [availableBytes]).
  int Function()? availableNow;

  /// When set, each read throws it.
  Object? volumeFailure;

  /// When set, each read waits for it (after counting the call).
  Completer<void>? volumeGate;

  /// Completed by the first read that reaches the probe.
  final Completer<void> volumeRead = Completer<void>();

  int volumeCalls = 0;
  final List<String> volumePaths = [];

  final List<List<String>> groupRepairCalls = [];

  /// When set, each repair throws it.
  Object? repairFailure;

  /// How many of the paths each repair reports as failed.
  int repairFailedCount = 0;

  @override
  bool get isSupported => supported;

  @override
  Future<DashcamVolumeStats> volumeStats(String path) async {
    volumeCalls++;
    volumePaths.add(path);
    if (!volumeRead.isCompleted) volumeRead.complete();
    final gate = volumeGate;
    if (gate != null) await gate.future;
    final failure = volumeFailure;
    if (failure != null) throw failure;
    return DashcamVolumeStats(availableBytes: availableNow?.call() ?? availableBytes, totalBytes: totalBytes);
  }

  @override
  Future<DashcamGroupRepair> normalizeClipGroups(List<String> paths) async {
    groupRepairCalls.add(List.unmodifiable(paths));
    final failure = repairFailure;
    if (failure != null) throw failure;
    final failed = repairFailedCount.clamp(0, paths.length);
    return DashcamGroupRepair(normalized: paths.length - failed, failed: failed);
  }
}
