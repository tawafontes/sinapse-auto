import '../services/altitude_trend.dart';
import '../services/gnss_quality.dart';

/// Central, immutable telemetry sample — the single struct every consumer
/// downstream of the Telemetry Engine (sessions, alerts, HUD, diagnostics)
/// reads, instead of each opening its own independent sensor subscriptions.
/// Assembled by `DashboardSensorStreams.snapshot` from the already-filtered
/// per-signal streams (`TelemetryEngine`'s speed/altitude/heading/GNSS
/// quality, plus the vehicle-axis-corrected g-force/pitch/roll streams) —
/// this class itself does no filtering or fusion of its own.
///
/// Every field below the required [timestamp] is nullable, and that
/// nullability is meaningful: `null` means "no valid reading has arrived
/// yet" (e.g. no GNSS fix obtained since app start), while a present value
/// of `0.0` means a genuine reading that happens to be zero (e.g.
/// `speedKmh == 0` while stationary with a good fix). Never coerce a null
/// field to `0` for display or storage — that silently erases the exact
/// distinction this architecture exists to preserve. Use [hasGnssFix] /
/// [gnssQuality] to decide whether position-derived fields are trustworthy
/// before reading them.
class TelemetrySnapshot {
  const TelemetrySnapshot({
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.altitudeMeters,
    this.speedKmh,
    this.headingDegrees,
    this.horizontalAccuracyMeters,
    this.verticalAccuracyMeters,
    this.satelliteCount,
    this.gnssQuality = GnssQuality.unavailable,
    this.altitudeTrend = AltitudeTrend.stable,
    this.longitudinalG,
    this.lateralG,
    this.verticalG,
    this.gForceMagnitude,
    this.pitchDegrees,
    this.rollDegrees,
    this.barometerActive = false,
  });

  /// Real wall-clock capture time of this sample — never derived from a UI
  /// frame callback. Kept precise and independent of rendering so it can
  /// later synchronize telemetry against graphs, session playback, and (per
  /// the architecture's own forward-looking requirement) a future Dashcam
  /// video's own frame timestamps.
  final DateTime timestamp;

  final double? latitude;
  final double? longitude;

  /// Fused (barometer+GPS where available), filtered altitude in meters —
  /// see `TelemetryEngine.altitudeMeters`.
  final double? altitudeMeters;

  /// Fused, filtered vehicle speed in km/h — see `TelemetryEngine.speedKmh`.
  final double? speedKmh;

  /// Direction of travel in degrees (0-360, 0 = north), GNSS-derived only.
  /// `null` below the low-speed heading threshold or when GNSS heading
  /// accuracy is insufficient — never a stale or guessed value. See
  /// `TelemetryEngine.headingDegrees` for the full rationale.
  final double? headingDegrees;

  final double? horizontalAccuracyMeters;
  final double? verticalAccuracyMeters;

  /// Always null on this plugin/platform combination — `package:geolocator`
  /// does not expose satellite count. See `GnssQuality`'s own doc.
  final int? satelliteCount;

  final GnssQuality gnssQuality;

  /// Whether altitude is climbing, descending, or holding steady — see
  /// `TelemetryEngine.altitudeTrend`. Defaults to [AltitudeTrend.stable],
  /// matching [gnssQuality]'s own "unknown reads as the least-alarming
  /// state" convention rather than a nullable field, since there's no
  /// meaningful "invalid" trend the way there's an invalid GNSS fix.
  final AltitudeTrend altitudeTrend;

  /// Vehicle-axis longitudinal acceleration, in g (+forward/-braking).
  final double? longitudinalG;

  /// Vehicle-axis lateral acceleration, in g (+right/-left).
  final double? lateralG;

  /// Vehicle-axis vertical acceleration, in g (+up/-down).
  final double? verticalG;

  /// Total G-force magnitude (vector length, orientation-independent), in g.
  final double? gForceMagnitude;

  final double? pitchDegrees;
  final double? rollDegrees;

  /// Whether at least one barometer sample has ever been received this
  /// session — `false` both before the first reading arrives and,
  /// permanently, on a device with no barometer at all (the stream simply
  /// never emits either way, so there's nothing more specific to
  /// distinguish). A plain, non-nullable "have we ever heard from this
  /// sensor" flag rather than a live staleness check: unlike GNSS, a
  /// barometer/accelerometer/gyroscope realistically never *stops* emitting
  /// mid-session on real hardware once started, so the extra staleness
  /// machinery [gnssQuality] needs (its own periodic timer) isn't
  /// justified here. Read this, not `hasGnssFix`, before relying on
  /// barometer-fused (rather than GPS-only) altitude — also the one signal
  /// a future Dashcam-readiness check would want from this model.
  final bool barometerActive;

  /// Whether [latitude]/[longitude] are present at all — does not by itself
  /// imply the fix is *good*, only that one has been obtained; check
  /// [gnssQuality] for trustworthiness.
  bool get hasGnssFix => latitude != null && longitude != null;
}
