import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:geolocator/geolocator.dart';

import '../models/power_profile.dart';
import 'adaptive_exponential_filter.dart';
import 'altitude_fusion.dart';
import 'altitude_trend.dart';
import 'display_smoothing.dart';
import 'gnss_quality.dart';
import 'kalman_filter.dart';
import 'outlier_rejector.dart';
import 'power_profile_preferences.dart';
import 'reading_quality.dart';
import 'sensor_service.dart';

/// Drops an emission from [source] unless at least [gapProvider]'s current
/// value has elapsed since the last one this let through — always lets the
/// first value through.
///
/// Wrapped in [Stream.asBroadcastStream] so [source] (and this function's
/// own `lastEmitted` state) runs exactly once per upstream event no matter
/// how many listeners the returned stream ends up with, rather than once
/// *per listener*. This matters because [source] here is always itself a
/// chain of plain `.map()`/`.where()` calls carrying mutable closure state
/// (Kalman filters, [AltitudeFusion], quality/outlier checks) — Dart's
/// synchronous stream combinators re-run that whole chain independently for
/// every listener attached to the final stream, rather than running it once
/// and fanning the result out. With two listeners on the same memoized
/// `late final` stream (the dashboard tile and, if opened, a fullscreen
/// view of the same signal), their two passes over the very same upstream
/// event land microseconds apart — whichever runs first "wins" `lastEmitted`
/// for that event, so the other's check always reads "too soon" and drops
/// every single event, forever. This was confirmed by direct experiment
/// (not assumed): a two-listener probe against the exact un-wrapped pattern
/// showed the second listener receiving nothing at all, ever — which is
/// exactly why a fullscreen speed/altitude view showed "--" indefinitely
/// instead of catching up after a moment. [asBroadcastStream] is the
/// standard, official fix for sharing a stateful stream pipeline across
/// multiple listeners.
///
/// General-purpose infrastructure, not just a testing seam: reused directly
/// by `DashboardSensorStreams.snapshot` to cap its own emission rate with
/// the exact same multi-listener-safe behavior, rather than duplicating
/// this logic a second time.
Stream<T> throttleAdaptive<T>(Stream<T> source, Duration Function() gapProvider) {
  DateTime? lastEmitted;
  return source
      .where((_) {
        final now = DateTime.now();
        if (lastEmitted == null || now.difference(lastEmitted!) >= gapProvider()) {
          lastEmitted = now;
          return true;
        }
        return false;
      })
      .asBroadcastStream();
}

/// Centralized sensor fusion, filtering and validation layer sitting
/// between raw hardware ([SensorService]) and the dashboard's distribution
/// shape adapter (`DashboardSensorStreams`).
///
/// Pipeline for speed/altitude (GPS-derived): quality validation
/// ([isPositionAcceptable]) → outlier rejection ([isPlausibleSpeedKmh]/
/// [isPlausibleAltitudeChange]/[isReadingFresh]) → (altitude only)
/// barometer/GPS fusion ([AltitudeFusion]) → [KalmanFilter1D] →
/// [AdaptiveExponentialFilter] → adaptive-frequency emission throttle
/// ([_throttleAdaptive]). The Kalman stage optimally weighs each individual
/// measurement's trustworthiness (using GNSS-reported accuracy where
/// available); the adaptive-exponential stage afterwards separately shapes
/// how *responsive* the already-denoised signal looks — heavy smoothing
/// while essentially flat, fast tracking the moment it starts changing for
/// real — which a fixed-Q Kalman filter doesn't do on its own. A Kalman
/// filter carries no guarantee of converging to exactly 0, so a minimal
/// cosmetic snap-to-zero (reusing `display_smoothing.dart`'s existing
/// `smoothedForDisplay(windowSize: 1, floor: ...)` "floor-only" mode) is
/// kept as the final stage for speed and g-force.
///
/// G-force ([filterGForceMagnitude]/[filterGForceVertical]/
/// [filterGForceOffset]) deliberately skips [_throttleAdaptive]: that
/// throttle buckets its gap by the *vehicle's* current speed, which is the
/// right idea for a GPS-derived signal (a ceiling on what the chipset can
/// deliver anyway) but the wrong one for an accelerometer-derived,
/// safety-relevant signal — under that throttle, g-force updated at only
/// 1Hz while parked/near-stationary, exactly when a driver is most likely
/// to test it (a hard launch from a stop) or experience a real, fast event.
/// G-force instead updates as fast as [SensorService]'s own accelerometer
/// sampling rate delivers (see that class's doc comment), wrapped only in
/// [_shareable] for the multi-listener safety every stream here still
/// needs — no artificial cap coupled to vehicle speed.
///
/// G-force also uses a different *filter algorithm* than speed/altitude:
/// [OneEuroFilter] (via [StabilizedOffsetStream]/[StabilizedValueStream])
/// instead of [KalmanFilter1D], reusing the exact same stack already
/// hardware-validated for the artificial horizon — an adaptive low-pass
/// whose cutoff rises with the signal's own estimated speed, plus a dead
/// zone (settles cleanly anywhere in range, not just near zero) and,
/// for [filterGForceOffset]/[filterGForceVertical] only, a slew-rate limiter
/// so the *visual* dot/bar position ramps rather than snaps.
/// [filterGForceMagnitude] deliberately omits the slew cap (`maxDeltaPerUpdate:
/// double.infinity`): that stream also feeds the peak-G record, and an
/// artificial cap on how fast the displayed value may rise would
/// systematically blunt a genuine, fast impact instead of merely smoothing
/// cosmetic jitter — the dead zone alone still keeps it calm at rest.
///
/// Every stream this class exposes is built lazily (via `late final` field
/// initializers over [sensors]'s own lazy broadcast streams) so nothing
/// here runs — no GPS, no barometer — until a widget actually listens,
/// exactly like [SensorService] itself. Almost nothing here owns anything
/// to dispose: the one exception is [gnssQuality]'s internal staleness
/// timer, which is itself scoped to its own stream's listen/cancel
/// lifecycle (started on first listener, cancelled on the last) — see that
/// field's own doc for why a timer is unavoidable there specifically.
///
/// [headingDegrees] and [gnssQuality] are GPS-native concerns (sourced
/// directly from [Position]'s own fields, no vehicle-mount geometry
/// involved) and so live here alongside speed/altitude. Deliberately
/// **still** out of scope for this engine: inclination/tilt and g-force's
/// vehicle-axis transform (both computed by `DashboardSensorStreams`,
/// which owns the "which physical axis means what" mount-geometry concern
/// — orthogonal to, and computed before, this class's own signal
/// filtering). `DashboardSensorStreams.snapshot` is what combines this
/// engine's GPS-native signals with those geometry-dependent ones into one
/// unified [TelemetrySnapshot] for session/alert/HUD/diagnostics
/// consumers — this engine itself never needs to know about vehicle axes.
class TelemetryEngine {
  TelemetryEngine(this.sensors, {PowerProfilePreferences? powerProfile}) : _powerProfile = powerProfile;

  final SensorService sensors;

  /// Null for every existing caller/test that doesn't pass one — see
  /// [_currentEmissionGap] for the resulting default ([PowerProfile.normal]'s
  /// rates, byte-for-byte the original fixed thresholds this class always
  /// had), so introducing power profiles changes no prior behavior for a
  /// caller that hasn't opted in.
  final PowerProfilePreferences? _powerProfile;

  // --- Speed (m/s domain internally; converted to km/h only at the very
  // last step, since GNSS's own `speedAccuracy` is reported in m/s and must
  // stay in the same unit as the Kalman filter it drives — mixing units
  // here would silently under-scale the filter's trust in bad readings). ---
  static const _speedProcessNoise = 0.5; // (m/s)^2 per update — tracks a few m/s of real accel/decel within a couple of updates.
  static const _speedMeasurementNoiseFallback = 1.0; // (m/s)^2 — ~1 m/s stdev, typical GNSS speed accuracy, used when the platform reports none.
  static const _speedMinAlpha = 0.15; // heavy smoothing while essentially stationary.
  static const _speedMaxAlpha = 0.9; // near-immediate tracking once really accelerating/braking.
  static const _speedRateOfChangeForMaxAlpha = 2.0; // m/s delta between updates that counts as "really accelerating".
  static const _speedFloorKmh = 1.0; // cosmetic snap-to-zero — matches the previous display_smoothing floor.

  // --- Altitude (meters). Fusion already does the heavy lifting; Kalman
  // here only mops up residual fusion noise. ---
  static const _altitudeProcessNoise = 0.1; // m^2 per update.
  static const _altitudeMeasurementNoise = 0.5; // m^2 — fixed; fusion has no per-sample accuracy of its own to expose.
  static const _altitudeMinAlpha = 0.05;
  static const _altitudeMaxAlpha = 0.4;
  static const _altitudeRateOfChangeForMaxAlpha = 2.0; // meters delta between updates that counts as "really climbing/descending".

  // --- G-force (normalized -1..1 representing +/-2g, matching the existing
  // convention). OneEuroFilter-based (see this class's own doc comment for
  // why, in place of Kalman) — minCutoff/beta/deadZone are all tuned in this
  // same normalized -1..1 domain, not raw m/s^2 or g.
  //
  // Offset (lateral/longitudinal dot) and vertical (bar) get the full
  // three-layer treatment including a slew cap, since both are purely
  // visual positions. Magnitude (feeds the peak-G record) gets a snappier
  // beta and no slew cap at all — see this class's doc comment for why a
  // cap there would blunt genuine peaks.
  //
  // minCutoff=1.0Hz: real road/engine vibration sits well above 1Hz, so this
  // still smooths it out at rest; a g-force event develops far faster than
  // the ~0.3Hz used for vehicle tilt (a hard brake ramps up in a fraction of
  // a second, not the couple of seconds a vehicle pitch change takes), hence
  // the higher baseline cutoff than inclination's.
  static const _gForceOffsetMinCutoffHz = 1.0;
  static const _gForceVerticalMinCutoffHz = 1.0;
  static const _gForceMagnitudeMinCutoffHz = 0.8; // a touch heavier at rest — a calmer numeric readout, magnitude's own beta still tracks real peaks fast.
  // beta: how fast the cutoff rises with the signal's own estimated speed
  // (signal units/second, where the full range is only 2.0 wide here) —
  // higher than inclination's 0.5 across the board, since g-force dynamics
  // are faster; magnitude's beta is the highest of the three, since it's the
  // one signal here with zero slew cap to fall back on for tracking speed.
  static const _gForceOffsetBeta = 0.6;
  static const _gForceVerticalBeta = 0.8; // bumps/dips are often sharper, shorter impulses than lateral/longitudinal g.
  static const _gForceMagnitudeBeta = 1.0;
  // deadZone: small in this -1..1 domain — enough to kill residual flicker
  // right at/near zero (this is what replaces the old separate
  // "floor"-only snap-to-zero: a dead zone already covers that, and also
  // anywhere else in range, not just the origin).
  static const _gForceOffsetDeadZone = 0.015;
  static const _gForceVerticalDeadZone = 0.015;
  static const _gForceMagnitudeDeadZone = 0.015;
  // maxDeltaPerUpdate: a hard ceiling on visual speed so even a large real
  // change ramps in over several updates instead of snapping — sized so a
  // 0-to-full-scale sweep takes roughly 150-250ms (a handful of updates at
  // the accelerometer's 50Hz), fast enough to not read as laggy, slow enough
  // to look physical rather than nervous. Not applied to magnitude at all
  // (see this class's doc comment).
  static const _gForceOffsetMaxSlewPerUpdate = 0.2;
  static const _gForceVerticalMaxSlewPerUpdate = 0.3;

  // --- Quality/outlier thresholds. ---
  static const _maxReadingAge = Duration(seconds: 10); // generous — only catches a genuinely stale/delayed platform callback.

  // --- Heading (automotive direction of travel — see [headingDegrees]'s own
  // doc for the full rationale). ---
  //
  // GNSS course-over-ground is derived from the device's own velocity
  // vector; below walking-adjacent speed that vector's *direction* is
  // dominated by positional noise (a stationary phone's fix wanders by
  // several meters even sitting still, which alone can swing an apparent
  // bearing by dozens of degrees) rather than genuine vehicle heading, so a
  // numeric-but-meaningless value would be actively misleading on a
  // HUD/navigation-adjacent display — worse than admitting "unknown". 8km/h
  // (~2.2 m/s, brisk walking pace) sits comfortably above where GNSS course
  // noise dominates for a modern smartphone chipset, while still low enough
  // to pick up heading promptly from a stop.
  static const _minSpeedForHeadingKmh = 8.0;
  // Generous — platform heading accuracy at typical automotive GNSS quality
  // is usually well under this; only rejects genuinely poor bearing
  // estimates. A `0.0` headingAccuracy (like `Position.accuracy`'s own
  // documented contract) means "unknown, not reported" here too, so it is
  // NOT gated on — treated as "trust the heading value itself."
  static const _maxHeadingAccuracyDegrees = 45.0;
  // Vector-average smoothing factor for [headingDegrees] — moderate: this
  // signal doesn't need to be as snappy as speed, and averaging in the unit-
  // circle domain (see [_CircularHeadingSmoother]) is what makes a
  // 359°→0° transition read as a tiny step instead of a ~360° swing.
  static const _headingSmoothingAlpha = 0.3;

  // --- Adaptive-frequency emission throttle. Buckets are a ceiling on
  // GPS-derived signals (can only slow down what the chipset actually
  // delivers, not manufacture a faster rate), and a literal target for the
  // accelerometer-derived g-force signal (which already ticks far faster
  // than 10Hz natively) — EXCEPT g-force never actually routes through this
  // throttle at all (see [filterGForceMagnitude] et al.'s own doc), in
  // every [PowerProfile] including [PowerProfile.economy]: this throttle
  // only ever governs speed/altitude/heading, never a safety-relevant
  // signal, regardless of the active power profile. ---
  static const _parkedSpeedThresholdKmh = 5.0;
  static const _highwaySpeedThresholdKmh = 80.0;

  // Per-profile (parked, city, highway) emission gaps. `normal` matches
  // this class's original, single fixed set of thresholds exactly — the
  // default the engine already uses when constructed without a
  // [PowerProfilePreferences] (every existing caller/test), so introducing
  // profiles changes no prior behavior. `economy` widens all three gaps
  // (fewer, less frequent recomputations — real CPU/battery savings);
  // `performance` narrows them (the GPS-derived ceiling this class's own
  // doc already explains it can't force faster than the chipset delivers,
  // but the *bucket* itself stops being the limiting factor sooner).
  // `dashcamReady` intentionally matches `normal` — this profile prepares
  // the architecture for a future camera module, it does not itself change
  // telemetry behavior.
  static const Map<PowerProfile, ({Duration parked, Duration city, Duration highway})> _emissionGapsByProfile = {
    PowerProfile.normal: (
      parked: Duration(seconds: 1),
      city: Duration(milliseconds: 200),
      highway: Duration(milliseconds: 100),
    ),
    PowerProfile.economy: (
      parked: Duration(seconds: 2),
      city: Duration(milliseconds: 500),
      highway: Duration(milliseconds: 200),
    ),
    PowerProfile.performance: (
      parked: Duration(milliseconds: 500),
      city: Duration(milliseconds: 100),
      highway: Duration(milliseconds: 50),
    ),
    PowerProfile.dashcamReady: (
      parked: Duration(seconds: 1),
      city: Duration(milliseconds: 200),
      highway: Duration(milliseconds: 100),
    ),
  };

  /// The most recent speed value (km/h) seen by [speedKmh]'s own pipeline —
  /// the one piece of state deliberately shared across every pipeline in
  /// this class, since the adaptive-frequency bucket is driven by vehicle
  /// speed regardless of which signal is being throttled. Null before the
  /// first speed reading, or if nothing is currently listening to
  /// [speedKmh] at all (e.g. a dashboard showing only a g-force widget) —
  /// treated as "highway" (the least-throttled bucket) in that case,
  /// deliberately erring toward not missing dynamics on a safety-adjacent
  /// signal like g-force rather than toward battery savings.
  double? _lastSpeedKmh;

  Duration _currentEmissionGap() {
    // Re-read on every call (not cached at construction) so a profile
    // change made while the app is already running (via the reactive
    // PowerProfilePreferences) takes effect on this engine's very next
    // emission — no reconstruction needed.
    final gaps = _emissionGapsByProfile[_powerProfile?.profile ?? PowerProfile.normal]!;
    final speed = _lastSpeedKmh;
    if (speed == null) return gaps.highway;
    if (speed < _parkedSpeedThresholdKmh) return gaps.parked;
    if (speed < _highwaySpeedThresholdKmh) return gaps.city;
    return gaps.highway;
  }

  /// The last stage of the speed/altitude pipelines — see [throttleAdaptive]
  /// itself for what it does and why it's essential that it (not something
  /// earlier in the pipeline) is the point where the stream becomes safely
  /// shareable across multiple listeners.
  Stream<T> _throttleAdaptive<T>(Stream<T> source) => throttleAdaptive(source, _currentEmissionGap);

  /// The g-force pipelines' equivalent last stage: the same
  /// [Stream.asBroadcastStream] multi-listener safety [_throttleAdaptive]
  /// provides, without the vehicle-speed-bucketed throttle itself (see this
  /// class's own doc comment for why that throttle is wrong for g-force).
  Stream<T> _shareable<T>(Stream<T> source) => source.asBroadcastStream();

  /// Fused, filtered vehicle speed in km/h. Source: [SensorService.positionStream]
  /// (GNSS Doppler speed — never a position-difference calculation).
  late final Stream<double> speedKmh = _buildSpeedStream();

  Stream<double> _buildSpeedStream() {
    final kalman = KalmanFilter1D(
      processNoise: _speedProcessNoise,
      measurementNoise: _speedMeasurementNoiseFallback,
    );
    final adaptive = AdaptiveExponentialFilter(
      minAlpha: _speedMinAlpha,
      maxAlpha: _speedMaxAlpha,
      rateOfChangeForMaxAlpha: _speedRateOfChangeForMaxAlpha,
    );

    final filtered = sensors.positionStream
        .where(isPositionAcceptable)
        .where((Position p) => isReadingFresh(p.timestamp, now: DateTime.now(), maxAge: _maxReadingAge))
        .where((Position p) => isPlausibleSpeedKmh(p.speed * 3.6))
        .map((Position p) {
          // speedAccuracy is a reported standard deviation (m/s); the
          // Kalman filter's R is a variance, hence the square.
          final r = p.speedAccuracy > 0 ? p.speedAccuracy * p.speedAccuracy : null;
          final metersPerSecond = kalman.filter(p.speed, measurementNoise: r);
          return adaptive.filter(metersPerSecond);
        })
        .map((metersPerSecond) => metersPerSecond * 3.6)
        .map((kmh) {
          _lastSpeedKmh = kmh;
          return kmh;
        })
        .smoothedForDisplay(windowSize: 1, floor: _speedFloorKmh);

    return _throttleAdaptive(filtered);
  }

  /// Fused, filtered altitude in meters. Barometer-preferred, GPS-anchored
  /// (see [AltitudeFusion]) — automatically GPS-only on a device with no
  /// barometer, with no special-casing needed here.
  late final Stream<double> altitudeMeters = _buildAltitudeStream();

  Stream<double> _buildAltitudeStream() {
    final fusion = AltitudeFusion();
    final kalman = KalmanFilter1D(
      processNoise: _altitudeProcessNoise,
      measurementNoise: _altitudeMeasurementNoise,
    );
    final adaptive = AdaptiveExponentialFilter(
      minAlpha: _altitudeMinAlpha,
      maxAlpha: _altitudeMaxAlpha,
      rateOfChangeForMaxAlpha: _altitudeRateOfChangeForMaxAlpha,
    );

    double? lastAcceptedGpsAltitude;
    DateTime? lastAcceptedGpsTimestamp;

    final gpsUpdates = sensors.positionStream
        .where(isPositionAcceptable)
        .where((Position p) => isReadingFresh(p.timestamp, now: DateTime.now(), maxAge: _maxReadingAge))
        .where((Position p) {
          final previous = lastAcceptedGpsAltitude;
          final previousTimestamp = lastAcceptedGpsTimestamp;
          if (previous == null || previousTimestamp == null) return true;
          return isPlausibleAltitudeChange(
            previousMeters: previous,
            candidateMeters: p.altitude,
            elapsed: p.timestamp.difference(previousTimestamp),
          );
        })
        .map<double?>((Position p) {
          lastAcceptedGpsAltitude = p.altitude;
          lastAcceptedGpsTimestamp = p.timestamp;
          fusion.addGpsReading(p.altitude, p.timestamp);
          return fusion.fusedAltitudeMeters;
        });

    final baroUpdates = sensors.barometerStream
        // A device with no barometer surfaces that as a stream ERROR (a
        // PlatformException from the platform channel), not simply "never
        // emits" — swallowed here rather than left to propagate as an
        // unhandled exception, since "no barometer" is this pipeline's own
        // already-documented, expected fallback path (see this stream's
        // class-level doc comment), not a genuine failure.
        .handleError((Object error, StackTrace stackTrace) {})
        .map<double?>((reading) {
          fusion.addBarometerReading(reading.pressureHpa, reading.timestamp);
          return fusion.fusedAltitudeMeters;
        });

    final filtered = _merge(gpsUpdates, baroUpdates)
        .where((meters) => meters != null)
        .map((meters) => kalman.filter(meters!))
        .map((meters) => adaptive.filter(meters));

    return _throttleAdaptive(filtered);
  }

  /// Whether altitude is climbing, descending, or holding steady — derived
  /// from [altitudeMeters] (already fused/filtered, so this classifier only
  /// has to reject residual noise, not raw GPS/barometer jitter) via
  /// [AltitudeTrendClassifier]'s hysteresis/confirm-streak, so a handful of
  /// ordinary jitter samples never flips this away from
  /// [AltitudeTrend.stable]. See [AltitudeTrendThresholds] for the tuning
  /// rationale.
  late final Stream<AltitudeTrend> altitudeTrend = _buildAltitudeTrendStream();

  Stream<AltitudeTrend> _buildAltitudeTrendStream() {
    final classifier = AltitudeTrendClassifier();
    final filtered = altitudeMeters.map((meters) => classifier.classify(meters, DateTime.now()));
    return _shareable(filtered);
  }

  /// Applies this engine's centralized g-force filtering (OneEuroFilter +
  /// dead zone, no slew cap — see the class-level constants and this class's
  /// own doc comment for why) to an already mount-orientation-corrected raw
  /// g-force magnitude stream, paired with each sample's real timestamp (the
  /// filter needs true elapsed time, not an assumed interval). The
  /// mount-orientation self-detection/axis-remapping itself stays in
  /// `DashboardSensorStreams` (it's a geometric concern about *which* raw
  /// accelerometer axis means what, tied to how the phone is physically
  /// mounted — orthogonal to, and computed before, the filtering this engine
  /// centralizes).
  Stream<double> filterGForceMagnitude(Stream<(double, DateTime)> raw) {
    final filtered = raw.stabilizedForDisplay(
      minCutoff: _gForceMagnitudeMinCutoffHz,
      beta: _gForceMagnitudeBeta,
      deadZone: _gForceMagnitudeDeadZone,
      maxDeltaPerUpdate: double.infinity,
    );
    return _shareable(filtered);
  }

  /// Same treatment as [filterGForceMagnitude], for the vertical g-force
  /// component — this one *does* get a slew cap, since it only feeds the
  /// vertical bar's visual position, not a peak record directly compared
  /// against future readings the way magnitude's max badge is.
  Stream<double> filterGForceVertical(Stream<(double, DateTime)> raw) {
    final filtered = raw.stabilizedForDisplay(
      minCutoff: _gForceVerticalMinCutoffHz,
      beta: _gForceVerticalBeta,
      deadZone: _gForceVerticalDeadZone,
      maxDeltaPerUpdate: _gForceVerticalMaxSlewPerUpdate,
    );
    return _shareable(filtered);
  }

  /// Same treatment as [filterGForceVertical], for the lateral/longitudinal
  /// g-force offset (the dial dot) — [StabilizedOffsetStream] filters both
  /// axes together (independent [OneEuroFilter] per axis, one shared 2D dead
  /// zone/slew based on the combined distance), matching how the previous
  /// Kalman-based version already treated the two axes independently.
  Stream<Offset> filterGForceOffset(Stream<(Offset, DateTime)> raw) {
    final filtered = raw.stabilizedForDisplay(
      minCutoff: _gForceOffsetMinCutoffHz,
      beta: _gForceOffsetBeta,
      deadZone: _gForceOffsetDeadZone,
      maxDeltaPerUpdate: _gForceOffsetMaxSlewPerUpdate,
    );
    return _shareable(filtered);
  }

  /// Vehicle direction of travel, in degrees (0-360, 0 = north) — GNSS
  /// course-over-ground only, never the phone's own physical orientation
  /// and never the magnetometer. `null` ("no reliable heading right now",
  /// distinct from `0°`/north) below [_minSpeedForHeadingKmh] or when
  /// [Position.headingAccuracy] reports an insufficient bearing estimate —
  /// see this class's own constants for the technical justification of
  /// both thresholds.
  ///
  /// Magnetometer-based heading (useful exactly in the low-speed regime
  /// this stream can't cover) is a deliberate, documented omission this
  /// round: a trustworthy compass heading needs tilt compensation against
  /// the accelerometer plus a hard/soft-iron calibration flow, neither of
  /// which exists in this app yet — shipping an uncalibrated magnetometer
  /// reading would silently look plausible while being wrong by an
  /// unpredictable margin, which is worse than the honest `null` this
  /// stream returns instead. Left as a clearly scoped future addition.
  ///
  /// Smoothed via [_CircularHeadingSmoother] (vector averaging, not a plain
  /// numeric low-pass) specifically so the circular nature of a compass
  /// bearing is handled correctly — a heading crossing from 359° to 1°
  /// smooths as the 2° step it actually is, never as a ~358° swing the
  /// wrong way around.
  late final Stream<double?> headingDegrees = _buildHeadingStream();

  Stream<double?> _buildHeadingStream() {
    final smoother = CircularHeadingSmoother(alpha: _headingSmoothingAlpha);
    final filtered = sensors.positionStream
        .where(isPositionAcceptable)
        .where((Position p) => isReadingFresh(p.timestamp, now: DateTime.now(), maxAge: _maxReadingAge))
        .map<double?>((Position p) {
          final speedKmhNow = p.speed * 3.6;
          if (!isPlausibleSpeedKmh(speedKmhNow) || speedKmhNow < _minSpeedForHeadingKmh) return null;
          if (p.heading.isNaN) return null;
          if (p.headingAccuracy > 0 && p.headingAccuracy > _maxHeadingAccuracyDegrees) return null;
          return smoother.smooth(p.heading);
        });
    return _throttleAdaptive(filtered);
  }

  /// Current GNSS fix quality — see [GnssQuality]/[classifyGnssQuality] for
  /// the classification itself. Unlike every other stream in this class,
  /// this one owns a small periodic timer ([GnssQualityThresholds.staleCheckInterval]),
  /// because quality needs to actively transition to
  /// [GnssQuality.unavailable] on total signal loss (tunnel, parking
  /// garage) — [SensorService.positionStream] is push-only and simply stops
  /// emitting when GPS drops, so without an independent clock this stream
  /// would otherwise freeze forever at whatever quality the last fix had.
  /// The timer is scoped to this stream's own listen/cancel lifecycle
  /// (started on first listener, cancelled on the last), matching every
  /// other lazy, hardware-backed stream in this app.
  late final Stream<GnssQuality> gnssQuality = _buildGnssQualityStream();

  Stream<GnssQuality> _buildGnssQualityStream() {
    late StreamController<GnssQuality> controller;
    StreamSubscription<Position>? positionSub;
    Timer? staleCheckTimer;
    Position? lastPosition;
    DateTime? lastPositionArrivedAt;

    void emit() {
      final arrivedAt = lastPositionArrivedAt;
      final stillFresh = arrivedAt == null || DateTime.now().difference(arrivedAt) <= GnssQualityThresholds.staleSignalTimeout;
      controller.add(stillFresh ? classifyGnssQuality(lastPosition, now: DateTime.now()) : GnssQuality.unavailable);
    }

    controller = StreamController<GnssQuality>.broadcast(
      onListen: () {
        positionSub = sensors.positionStream.listen((p) {
          lastPosition = p;
          lastPositionArrivedAt = DateTime.now();
          emit();
        });
        staleCheckTimer = Timer.periodic(GnssQualityThresholds.staleCheckInterval, (_) => emit());
      },
      onCancel: () async {
        await positionSub?.cancel();
        staleCheckTimer?.cancel();
        lastPosition = null;
        lastPositionArrivedAt = null;
      },
    );
    return controller.stream.distinct();
  }
}

/// Vector-average smoother for a circular quantity (a compass bearing in
/// degrees, 0-360) — averaging the unit-circle (cos, sin) components rather
/// than the raw angle is what makes a 359°→0° crossing smooth as the small
/// step it actually is, instead of the plain-numeric average's ~180° swing
/// the wrong way around. Standalone (not reusing [AdaptiveExponentialFilter],
/// which operates on a plain linear domain) since circular smoothing needs
/// this specific vector construction, not a different set of tuning knobs.
///
/// Not private ([@visibleForTesting]): the wraparound behavior is exactly
/// the kind of easy-to-get-subtly-wrong math worth testing directly against
/// known angle sequences, matching this codebase's established convention
/// for pure geometry/math helpers (see `dashboard_sensor_streams.dart`'s
/// own `pitchRollDegreesFromAccelerometer`).
@visibleForTesting
class CircularHeadingSmoother {
  CircularHeadingSmoother({required this.alpha});

  /// Fixed exponential-smoothing factor in the vector domain — heading
  /// doesn't need [AdaptiveExponentialFilter]'s rate-adaptive behavior
  /// (unlike speed/altitude, a sudden real heading change — turning a
  /// corner — is exactly the kind of change that should stay smoothed, not
  /// snapped to instantly).
  final double alpha;

  double? _cosAvg;
  double? _sinAvg;

  double smooth(double headingDegrees) {
    final rad = headingDegrees * math.pi / 180;
    final cosV = math.cos(rad);
    final sinV = math.sin(rad);
    final cosAvg = _cosAvg;
    final sinAvg = _sinAvg;
    if (cosAvg == null || sinAvg == null) {
      _cosAvg = cosV;
      _sinAvg = sinV;
    } else {
      _cosAvg = cosAvg + alpha * (cosV - cosAvg);
      _sinAvg = sinAvg + alpha * (sinV - sinAvg);
    }
    final smoothedDegrees = math.atan2(_sinAvg!, _cosAvg!) * 180 / math.pi;
    return smoothedDegrees < 0 ? smoothedDegrees + 360 : smoothedDegrees;
  }
}

/// Merges [a] and [b] into a single stream that emits every element from
/// both sources as they arrive — used to combine GPS altitude and
/// barometer updates into one feed for [AltitudeFusion], without pulling in
/// a new dependency for what's otherwise a one-off need. Mirrors the same
/// manual-`StreamController`-composition idiom already used by
/// `dashboard_sensor_streams.dart`'s `pairedWithLatest`.
Stream<T> _merge<T>(Stream<T> a, Stream<T> b) {
  late StreamController<T> controller;
  StreamSubscription<T>? subA;
  StreamSubscription<T>? subB;
  var doneCount = 0;

  void handleDone() {
    doneCount++;
    if (doneCount == 2) controller.close();
  }

  controller = StreamController<T>.broadcast(
    onListen: () {
      subA = a.listen(controller.add, onError: controller.addError, onDone: handleDone);
      subB = b.listen(controller.add, onError: controller.addError, onDone: handleDone);
    },
    onCancel: () async {
      await subA?.cancel();
      await subB?.cancel();
    },
  );
  return controller.stream;
}
