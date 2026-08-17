import 'package:hive/hive.dart';

import 'dashcam_config.dart';

part 'dashcam_clip_record.g.dart';

/// One finalized dashcam video segment, indexed against the driving session
/// it was recorded during.
///
/// Not a [HiveObject] — like [DrivingSessionSample], these are always stored
/// as a `List<DashcamClipRecord>` value under a single session's id key in
/// [HiveBoxNames.dashcamSessionVideos], never as independently-addressable
/// box entries of their own. [recordedAt] is the wall-clock instant the
/// underlying `CameraController.startVideoRecording()` call for this segment
/// was made (not when it was finalized) — see `DashcamService`'s own doc for
/// why that distinction matters for lining a video position up against
/// telemetry.
///
/// typeId: 15
@HiveType(typeId: 15)
class DashcamClipRecord {
  DashcamClipRecord({
    required this.filePath,
    required this.recordedAt,
    this.durationSeconds = 0,
    this.sizeBytes = 0,
    this.isProtected = false,
    this.resolution = VideoResolution.hd720,
    this.audioEnabled = false,
  });

  @HiveField(0, defaultValue: '')
  final String filePath;

  @HiveField(1)
  final DateTime recordedAt;

  @HiveField(2, defaultValue: 0)
  final int durationSeconds;

  @HiveField(3, defaultValue: 0)
  final int sizeBytes;

  @HiveField(4, defaultValue: false)
  final bool isProtected;

  @HiveField(5, defaultValue: VideoResolution.hd720)
  final VideoResolution resolution;

  @HiveField(6, defaultValue: false)
  final bool audioEnabled;
}
