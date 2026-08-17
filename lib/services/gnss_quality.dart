/// Central, technically-justified GNSS quality classification — shared by
/// the Telemetry Engine, the Diagnostics screen, and the alerts system, so
/// "what counts as weak GNSS" is defined exactly once.
///
/// Horizontal accuracy (meters, 1-sigma, as reported by the platform via
/// [Position.accuracy]) is the primary signal: it's the one figure of merit
/// every Android GNSS chipset reports consistently. Satellite count, DOP,
/// and fix type are NOT available — `package:geolocator`'s cross-platform
/// [Position] doesn't expose them (see `reading_quality.dart`'s own doc for
/// this same, deliberate limitation) — so [TelemetrySnapshot.satelliteCount]
/// stays permanently null on this plugin, not silently omitted.
library;

import 'package:geolocator/geolocator.dart';

import 'outlier_rejector.dart' show isReadingFresh;

enum GnssQuality { unavailable, weak, moderate, good, excellent }

/// Centralized, configurable thresholds — loosely follow the accuracy
/// classes commonly cited for consumer multi-constellation GNSS chipsets: a
/// modern phone with a clear sky view typically settles around 3-5m
/// (excellent); 5-10m is still very usable for automotive speed/position
/// (good); 10-20m is visibly degraded — urban canyon, light foliage
/// (moderate); beyond that the fix is barely more than "somewhere nearby" —
/// heavy obstruction, cold start (weak). Past [weakMaxMeters], or with no
/// fix recent enough to trust, the signal is [GnssQuality.unavailable].
class GnssQualityThresholds {
  GnssQualityThresholds._();

  static const excellentMaxMeters = 5.0;
  static const goodMaxMeters = 10.0;
  static const moderateMaxMeters = 20.0;
  static const weakMaxMeters = 50.0;

  /// How old a fix may be and still be classified at all — matches
  /// [TelemetryEngine]'s own `_maxReadingAge` filter-input threshold (this
  /// is the same "genuinely stale/delayed platform callback" cutoff, reused
  /// rather than re-invented with a different number).
  static const maxFixAge = Duration(seconds: 10);

  /// How long the *absence* of any new fix at all must persist before a
  /// previously-good quality reading is downgraded to
  /// [GnssQuality.unavailable] — longer than [maxFixAge] alone would imply
  /// on its own reading-by-reading, since this one guards against total
  /// signal loss (tunnel, parking garage) rather than a single delayed
  /// sample: long enough not to flicker on one missed 1Hz update, short
  /// enough that "unavailable" reflects genuine loss promptly.
  static const staleSignalTimeout = Duration(seconds: 5);

  /// How often the "has the signal gone stale" check re-evaluates while
  /// something is listening — cheap (a single periodic timer, only while a
  /// listener is attached), fine-grained enough that the UI doesn't lag
  /// behind an actual signal loss by more than a second or so.
  static const staleCheckInterval = Duration(seconds: 1);
}

/// Classifies a single [position] reading. `null` (never obtained a fix, or
/// nothing recent enough to trust) is [GnssQuality.unavailable].
///
/// A `0.0` [Position.accuracy] is treated as "unknown, don't trust it" —
/// not "perfect" — matching `reading_quality.dart`'s own established
/// convention: a real GNSS fix never reports exactly zero accuracy.
GnssQuality classifyGnssQuality(Position? position, {required DateTime now}) {
  if (position == null) return GnssQuality.unavailable;
  if (!isReadingFresh(position.timestamp, now: now, maxAge: GnssQualityThresholds.maxFixAge)) {
    return GnssQuality.unavailable;
  }
  final accuracy = position.accuracy;
  if (accuracy.isNaN || accuracy <= 0) return GnssQuality.unavailable;
  if (accuracy <= GnssQualityThresholds.excellentMaxMeters) return GnssQuality.excellent;
  if (accuracy <= GnssQualityThresholds.goodMaxMeters) return GnssQuality.good;
  if (accuracy <= GnssQualityThresholds.moderateMaxMeters) return GnssQuality.moderate;
  if (accuracy <= GnssQualityThresholds.weakMaxMeters) return GnssQuality.weak;
  return GnssQuality.unavailable;
}

/// Maps a running average of [GnssQuality.index] values (as accumulated by
/// e.g. `DrivingSessionRecorder`'s `avgGnssQualityIndex`) back to the
/// nearest [GnssQuality] label for display — rounds to the closest ordinal
/// rather than truncating, so an average of 3.6 (mostly "excellent" with a
/// little "good") reads as excellent, not good.
GnssQuality gnssQualityFromAverageIndex(double averageIndex) {
  final rounded = averageIndex.round().clamp(0, GnssQuality.values.length - 1);
  return GnssQuality.values[rounded];
}

/// Portuguese label for a [GnssQuality] value — shared by the Diagnostics
/// screen and the driving-session recording/detail screens, so "what a
/// quality band is called" is defined exactly once rather than each screen
/// keeping its own copy.
String gnssQualityLabel(GnssQuality quality) {
  switch (quality) {
    case GnssQuality.unavailable:
      return 'Indisponível';
    case GnssQuality.weak:
      return 'Fraco';
    case GnssQuality.moderate:
      return 'Moderado';
    case GnssQuality.good:
      return 'Bom';
    case GnssQuality.excellent:
      return 'Excelente';
  }
}
