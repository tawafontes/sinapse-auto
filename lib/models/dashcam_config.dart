import 'package:hive/hive.dart';

part 'dashcam_config.g.dart';

/// Which physical camera(s) the dashcam should record from.
///
/// typeId: 5
@HiveType(typeId: 5)
enum CameraSelection {
  @HiveField(0)
  rear,
  @HiveField(1)
  front,
  @HiveField(2)
  both,
}

/// Recording resolution for dashcam clips.
///
/// typeId: 6
@HiveType(typeId: 6)
enum VideoResolution {
  @HiveField(0)
  sd480,
  @HiveField(1)
  hd720,
  @HiveField(2)
  fhd1080,
  @HiveField(3)
  uhd4k,
}

/// Persisted configuration for the dashcam feature.
///
/// typeId: 7
@HiveType(typeId: 7)
class DashcamConfig extends HiveObject {
  DashcamConfig({
    required this.cameraSelection,
    required this.storageQuotaMb,
    required this.audioEnabled,
    required this.resolution,
    required this.frameRate,
    this.enabled = false,
  });

  @HiveField(0)
  CameraSelection cameraSelection;

  /// Maximum disk space, in megabytes, that loop-recorded clips may occupy.
  /// Oldest unprotected clips are deleted first once this is exceeded.
  @HiveField(1)
  int storageQuotaMb;

  @HiveField(2)
  bool audioEnabled;

  @HiveField(3)
  VideoResolution resolution;

  @HiveField(4)
  int frameRate;

  /// Whole-feature opt-in switch (Fase 15). Defaults to `false` so a fresh
  /// install touches no camera/microphone hardware until the user explicitly
  /// enables Dashcam in Settings.
  @HiveField(5, defaultValue: false)
  bool enabled;
}
