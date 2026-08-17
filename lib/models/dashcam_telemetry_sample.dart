import 'detected_event.dart';

/// One periodic telemetry sample recorded alongside an active dashcam
/// recording (Fase 15) — a much smaller, JSON-Lines-persistable sibling of
/// [TelemetrySnapshot], not a wrapper around it: only the fields a video
/// scrub-overlay actually needs, in the same unit-suffixed naming
/// convention `TelemetrySnapshot`/`DrivingSessionSample` already use.
///
/// Deliberately has no `sessionId` field — the `.jsonl` file this is
/// appended to (see `DashcamTelemetryWriter`) already belongs exclusively to
/// one session, exactly the same reasoning `DrivingSessionSample` already
/// applies by relying on its container key instead of self-embedding an id.
///
/// Not a [HiveObject]/`@HiveType` — see `DashcamTelemetryWriter`'s own doc
/// for why this is stored as an append-only JSON-Lines file instead of Hive.
class DashcamTelemetrySample {
  const DashcamTelemetrySample({
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.speedKmh,
    this.altitudeMeters,
    this.headingDegrees,
    this.pitchDegrees,
    this.rollDegrees,
    this.longitudinalG,
    this.lateralG,
    this.verticalG,
    this.resultantG,
    this.eventType,
  });

  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final double? speedKmh;
  final double? altitudeMeters;
  final double? headingDegrees;
  final double? pitchDegrees;
  final double? rollDegrees;
  final double? longitudinalG;
  final double? lateralG;
  final double? verticalG;
  final double? resultantG;

  /// Set only for the one sample (if any) taken at the same instant a
  /// [DetectedEvent] was confirmed — lets a playback overlay tag "this is
  /// the moment of the hard-braking event" without a second lookup.
  final DetectedEventType? eventType;

  Map<String, Object?> toJson() => {
    't': timestamp.toIso8601String(),
    if (latitude != null) 'lat': latitude,
    if (longitude != null) 'lon': longitude,
    if (speedKmh != null) 'spd': speedKmh,
    if (altitudeMeters != null) 'alt': altitudeMeters,
    if (headingDegrees != null) 'hdg': headingDegrees,
    if (pitchDegrees != null) 'pit': pitchDegrees,
    if (rollDegrees != null) 'rol': rollDegrees,
    if (longitudinalG != null) 'glo': longitudinalG,
    if (lateralG != null) 'gla': lateralG,
    if (verticalG != null) 'gve': verticalG,
    if (resultantG != null) 'gre': resultantG,
    if (eventType != null) 'evt': eventType!.name,
  };

  /// Returns `null` (never throws) for a malformed/truncated line — a
  /// crash-truncated last line in the `.jsonl` file must not take down the
  /// whole session's readout, only drop that one sample.
  static DashcamTelemetrySample? tryFromJson(Map<String, Object?> json) {
    final rawTimestamp = json['t'];
    if (rawTimestamp is! String) return null;
    final timestamp = DateTime.tryParse(rawTimestamp);
    if (timestamp == null) return null;

    final rawEvent = json['evt'];
    DetectedEventType? eventType;
    if (rawEvent is String) {
      for (final candidate in DetectedEventType.values) {
        if (candidate.name == rawEvent) {
          eventType = candidate;
          break;
        }
      }
    }

    double? asDouble(Object? value) => value is num ? value.toDouble() : null;

    return DashcamTelemetrySample(
      timestamp: timestamp,
      latitude: asDouble(json['lat']),
      longitude: asDouble(json['lon']),
      speedKmh: asDouble(json['spd']),
      altitudeMeters: asDouble(json['alt']),
      headingDegrees: asDouble(json['hdg']),
      pitchDegrees: asDouble(json['pit']),
      rollDegrees: asDouble(json['rol']),
      longitudinalG: asDouble(json['glo']),
      lateralG: asDouble(json['gla']),
      verticalG: asDouble(json['gve']),
      resultantG: asDouble(json['gre']),
      eventType: eventType,
    );
  }
}
