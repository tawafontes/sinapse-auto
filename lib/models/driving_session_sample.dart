import 'package:hive/hive.dart';

part 'driving_session_sample.g.dart';

/// One decimated telemetry sample recorded during a driving session — see
/// `DrivingSessionRecorder` for the recording rate. Every field beyond
/// [timestamp] is nullable with the same "no reading" vs. "valid zero"
/// semantics as `TelemetrySnapshot`, since a sample is essentially a
/// point-in-time copy of the relevant [TelemetrySnapshot] fields, kept as
/// a much smaller, Hive-persistable sibling type rather than persisting
/// [TelemetrySnapshot] itself (which also carries GNSS-quality/accuracy
/// fields not needed for playback/charts).
///
/// Not a [HiveObject] — these are always stored as a `List<DrivingSessionSample>`
/// value under a single session's key in the samples box, never as
/// independently-addressable box entries of their own.
///
/// typeId: 11
@HiveType(typeId: 11)
class DrivingSessionSample {
  DrivingSessionSample({
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.speedKmh,
    this.altitudeMeters,
    this.longitudinalG,
    this.lateralG,
    this.verticalG,
    this.pitchDegrees,
    this.rollDegrees,
  });

  @HiveField(0)
  final DateTime timestamp;

  @HiveField(1)
  final double? latitude;

  @HiveField(2)
  final double? longitude;

  @HiveField(3)
  final double? speedKmh;

  @HiveField(4)
  final double? altitudeMeters;

  @HiveField(5)
  final double? longitudinalG;

  @HiveField(6)
  final double? lateralG;

  @HiveField(7)
  final double? verticalG;

  @HiveField(8)
  final double? pitchDegrees;

  @HiveField(9)
  final double? rollDegrees;
}
