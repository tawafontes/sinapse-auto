import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:geolocator/geolocator.dart';

import '../models/telemetry_snapshot.dart';
import 'altitude_trend.dart';
import 'complementary_filter.dart';
import 'display_smoothing.dart';
import 'gnss_quality.dart';
import 'obd/obd_service.dart';
import 'power_profile_preferences.dart';
import 'sensor_service.dart';
import 'stream_pairing.dart';
import 'telemetry_engine.dart';
import 'vehicle_coordinate_system.dart';

/// Raw pitch/roll (dx = pitch, dy = roll), in degrees, from a raw
/// accelerometer vector — pulled out of [DashboardSensorStreams] as a plain
/// function so the axis mapping can be unit-tested directly against known
/// vectors without a real accelerometer stream.
///
/// The device is mounted screen facing the driver, either portrait
/// (vertical) or landscape (horizontal) — not lying flat, which the naive
/// `atan2(y,z)`/`atan2(x,…)` formulas from most tilt-sensor references
/// assume. Rotating the mount 90° between the two swaps which native axis
/// reads gravity at level (Y in portrait, X in landscape), but leaves the
/// native Z axis's role unchanged (it's always the roll-invariant / pitch
/// axis, since screen-facing-driver never changes) — that's why the pitch
/// formula (`-z` over the combined X/Y magnitude) works unmodified in both
/// orientations, while roll needs to read from a different native axis per
/// orientation (`x` in portrait, `y` in landscape) to keep its sign.
///
/// Which mount is in play is decided per-sample, purely from the vector
/// itself (`x.abs()` vs `y.abs()`) — NOT from `MediaQuery`/screen rotation,
/// which would tie this to the app's UI orientation (auto-rotate state, any
/// lock, relayout lag) instead of the phone's actual physical attitude.
/// Reading gravity's dominant axis straight out of the sample sidesteps all
/// of that: whichever of X/Y is larger in magnitude is the one closer to
/// "up" (near ±g at level), which is exactly the axis the current mount
/// uses as the pitch reference / roll-invariant pairing — self-contained,
/// and correct within the tilt ranges this instrument actually cares about
/// (well under the 45° crossover).
///
/// Getting the branch wrong (in either direction) reproduces a specific,
/// telltale bug: the "wrong" axis for roll behaves as a magnitude-only term
/// (always positive, since it's ~g·cos of the true angle), so pure pitch
/// leaks into roll as a spurious positive reading, and roll to one side
/// reads positive as expected while the other side also reads positive
/// instead of negative.
///
/// Roll's overall sign (`-x` for portrait, `+y` for landscape) is confirmed
/// against real hardware via the ROLL footer label specifically — the one
/// place in the widget that reads this value with no rendering transform in
/// between. Earlier rounds validated intermediate signs (`+x` portrait,
/// then `-y` landscape) against the *visual* roll pointer/aircraft symbol
/// instead, at a time when that rendering had its own independent sign bugs
/// layered on top; each fix looked correct against the picture on screen
/// while actually leaving the numeric value backwards, until checking the
/// label text directly (unambiguous, no rendering in the loop) exposed it.
/// Both branches flipped together here, since the label was backwards the
/// same way regardless of mount.
@visibleForTesting
Offset pitchRollDegreesFromAccelerometer(double x, double y, double z) {
  final pitchDegrees = math.atan2(-z, math.sqrt(x * x + y * y)) * 180 / math.pi;
  final rollDegrees = isLandscapeMount(x, y)
      ? math.atan2(y, math.sqrt(x * x + z * z)) * 180 / math.pi
      : math.atan2(-x, math.sqrt(y * y + z * z)) * 180 / math.pi;
  return Offset(pitchDegrees, rollDegrees);
}

/// True when gravity's dominant native axis is X rather than Y — i.e. the
/// mount is landscape (screen wide), not portrait (screen tall). This is
/// [pitchRollDegreesFromAccelerometer]'s own roll-branch test, pulled out so
/// it's independently unit-testable (or worse, depending on `MediaQuery`/UI
/// rotation, which [pitchRollDegreesFromAccelerometer]'s doc comment already
/// explains is the wrong signal for the *physical* mount). A magnitude-only
/// check is sufficient for pitch/roll's own hardware-validated formula, but
/// *not* for g-force's own mount detection — see
/// `vehicle_coordinate_system.dart`'s [PhoneMountOrientation]/
/// [detectMountOrientation], which additionally need the dominant axis's
/// *sign* to tell the two possible landscape mounts apart, and are
/// deliberately independent of this function rather than building on it.
@visibleForTesting
bool isLandscapeMount(double gravityX, double gravityY) => gravityX.abs() > gravityY.abs();

/// Converts a raw gyroscope sample (rad/s, Android's native unit) into
/// pitch/roll *rates* in degrees/second — the same units and sign
/// convention as [pitchRollDegreesFromAccelerometer]'s own output, so a
/// [ComplementaryFilter] can blend the two directly. [isLandscape] must come
/// from the same self-detected mount as the paired accelerometer sample
/// (see [isLandscapeMount]) — pitch's rotation axis swaps native axis
/// between mounts exactly like roll's already does.
///
/// ### Derivation
/// Both formulas below follow from one standard identity for a vector that
/// is constant in the world frame but observed from a frame rotating with
/// angular velocity `ω` (as a body-fixed gyroscope reports it): the
/// vector's rate of change *as seen in the rotating frame* is `-ω × v`.
/// Applying this to gravity (`v ≈ (0, g, 0)` in portrait at rest, `≈ (g, 0,
/// 0)` in landscape — the same at-rest vectors [pitchRollDegreesFromAccelerometer]'s
/// own doc comment establishes) and linearizing each angle formula near
/// level (`pitch ≈ -z/g`, portrait roll `≈ -x/g`, landscape roll `≈ y/g`,
/// for small angles) gives, after converting to degrees:
///  * portrait: `pitchRate = +gyroX`, `rollRate = -gyroZ`.
///  * landscape: `pitchRate = -gyroY`, `rollRate = -gyroZ` (same as
///    portrait — roll's rotation axis, native Z, never changes role between
///    mounts, matching [pitchRollDegreesFromAccelerometer]'s own doc
///    comment about Z).
///
/// This derivation is cross-checked (not just self-asserted) in
/// `dashboard_sensor_streams_test.dart` against a numerical derivative of
/// the already hardware-validated [pitchRollDegreesFromAccelerometer]
/// itself — an independent check that doesn't reuse this same reasoning, so
/// a sign error here couldn't cancel out and hide. The *absolute* sign
/// (matching real hardware, not just internal consistency with the
/// accelerometer formula) still needs on-device confirmation — see this
/// round's delivery notes for the specific test to run.
@visibleForTesting
({double pitch, double roll}) pitchRollRatesDegPerSecFromGyroscope(
  double gyroX,
  double gyroY,
  double gyroZ, {
  required bool isLandscape,
}) {
  const radToDeg = 180 / math.pi;
  return (
    pitch: (isLandscape ? -gyroY : gyroX) * radToDeg,
    roll: -gyroZ * radToDeg,
  );
}

/// Derives the dashboard-facing signals (`SensorType`) from
/// [SensorService]'s raw hardware streams, [TelemetryEngine]'s centralized
/// fusion/filtering, and `vehicle_coordinate_system.dart`'s Smartphone →
/// Vehicle Coordinate System transform — the single distribution point
/// every dashboard widget consumes. Interpretive geometry lives here (the
/// tilt formula) and in `vehicle_coordinate_system.dart` (g-force's own
/// mount-orientation axis remapping) — kept out of [SensorService] itself
/// so that class stays focused on unifying raw providers, and out of
/// [TelemetryEngine] since it's a "which physical axis means what" concern
/// orthogonal to (and computed before) that class's signal filtering.
///
/// Every stream below is a memoized `late final` field, not a getter — built
/// exactly once per instance, so its identity (and any filter state inside
/// it) survives every dashboard rebuild. A plain getter would rebuild a
/// fresh `Stream` object on every access, which the widgets' own
/// `didUpdateWidget` checks would detect as "changed" and resubscribe to,
/// silently discarding whatever [TelemetryEngine]'s Kalman/adaptive-
/// exponential filters had converged to.
///
/// Speed, altitude and g-force are fused/filtered/validated by [engine];
/// [inclinationPitchRollDegrees] is the one signal deliberately left on its
/// own hand-tuned pipeline (see [StabilizedOffsetStream]) rather than routed
/// through the engine — its accelerometer-tilt sign conventions were
/// hardware-validated through a genuinely painful multi-round debugging
/// history (see [pitchRollDegreesFromAccelerometer]'s doc comment) and
/// aren't part of the telemetry engine's own acceptance criteria (GPS-
/// derived speed/altitude, accelerometer-derived g-force). It does now fuse
/// the gyroscope on top of that same accelerometer formula (see
/// [ComplementaryFilter] and [pitchRollRatesDegPerSecFromGyroscope]) —
/// *augmenting*, not replacing, the hardware-validated tilt formula: the
/// accelerometer angle is still what the fused estimate converges to and is
/// corrected against on every sample, the gyroscope only bridges the gaps
/// between corrections so transient linear acceleration (a bump, braking,
/// accelerating) can't masquerade as a real attitude change.
/// [DashboardSensorStreams.snapshot]'s GPS-cadence throttle gap (Fase 13.2:
/// deliberately does *not* apply to g-force-triggered emissions — see that
/// field's own doc for the root-cause finding behind this split).
const Duration snapshotGpsCadenceGap = Duration(milliseconds: 200);

/// True once at least [gap] has elapsed since [lastEmitted] (or immediately,
/// if nothing has been emitted yet) — the exact gate
/// [DashboardSensorStreams.snapshot] applies to its GPS-cadence fields only.
/// Pulled out as a pure, `DateTime`-in/bool-out function (mirroring
/// `telemetry_engine.dart`'s own [throttleAdaptive] gate) so the specific
/// timing boundary is independently testable without a real, hardware-backed
/// [DashboardSensorStreams] instance.
@visibleForTesting
bool shouldEmitThrottled({required DateTime? lastEmitted, required DateTime now, required Duration gap}) {
  return lastEmitted == null || now.difference(lastEmitted) >= gap;
}

class DashboardSensorStreams {
  DashboardSensorStreams(this.sensors, {PowerProfilePreferences? powerProfile, this.obd})
    : engine = TelemetryEngine(sensors, powerProfile: powerProfile);

  final SensorService sensors;
  final TelemetryEngine engine;

  /// The second physical source (OBD-II phase 1), owned by the
  /// `DrivingSessionHost`; `null` where the app has none (tests, non-Android).
  /// Its live values join [snapshot]; the dashboard's OBD widgets also read
  /// its last values and link state from here, to show the last value with a
  /// red border after a drop (owner decision) — display only, they never talk
  /// to the adapter.
  final ObdService? obd;

  static const _gravity = 9.80665;

  // Artificial horizon stabilization (see StabilizedOffsetStream/
  // OneEuroFilter) — tuned for the accelerometer's ~200ms sample interval.
  //
  // _inclinationMinCutoffHz: the OneEuroFilter's cutoff while pitch/roll is
  // essentially static — chosen to reproduce roughly the same steady-state
  // smoothing the previous fixed-alpha EMA had (alpha≈0.3 at a 200ms
  // interval corresponds to a cutoff of about this value), so at-rest
  // behavior isn't a regression; lower this for even heavier vibration
  // rejection at rest, at the cost of more lag on genuinely slow tilts.
  static const _inclinationMinCutoffHz = 0.3;
  // _inclinationBeta: how fast the filter's cutoff rises with the
  // estimated angular rate (degrees/second) — this is what lets a real,
  // sustained incline change (several degrees/second) get tracked quickly
  // while vibration (which averages near-zero rate under smoothing) stays
  // heavily filtered. Raise this for snappier response to real changes, at
  // the cost of letting more noise through while the vehicle is actively
  // pitching/rolling.
  static const _inclinationBeta = 0.5;
  // Tightened from the previous fixed filter's 0.5°, now that the adaptive
  // filter above does the heavy lifting against vibration — this stage
  // only needs to catch genuinely imperceptible residual flicker, not
  // vibration itself (over-widening this would blunt real precision, per
  // the spec's own caution against an excessive deadband).
  static const _inclinationDeadZoneDegrees = 0.3;
  // Unchanged — a hard ceiling on visual speed so a big real change (or a
  // calibration reset) ramps in rather than snaps; not the mechanism doing
  // the vibration rejection, so it didn't need retuning.
  static const _inclinationMaxSlewDegreesPerUpdate = 3.0;

  // Accelerometer/gyroscope complementary fusion (see ComplementaryFilter's
  // own doc for the full rationale) — this runs *before* the
  // OneEuroFilter/dead-zone/slew display stabilization above, feeding it an
  // already dynamics-corrected signal instead of the raw, transient-
  // acceleration-contaminated accelerometer angle. gyroWeight=0.96 at the
  // accelerometer's 50Hz sample rate gives roughly a 0.5s time constant for
  // the accelerometer to correct gyro drift (updateInterval/(1-gyroWeight)
  // = 0.02/0.04) — fast enough that drift never meaningfully accumulates,
  // slow enough that a sub-second transient (a bump, a brief acceleration)
  // barely perturbs the fused output.
  static const _inclinationGyroWeight = 0.96;

  /// GNSS-Doppler speed (never a position-difference calculation), quality-
  /// validated, outlier-rejected, then Kalman/adaptive-exponential filtered
  /// — see [TelemetryEngine.speedKmh].
  late final Stream<double> speedKmh = engine.speedKmh;

  /// Barometer+GPS sensor-fused altitude (automatic GPS-only fallback with
  /// no barometer), then Kalman/adaptive-exponential filtered — see
  /// [TelemetryEngine.altitudeMeters].
  late final Stream<double> altitudeMeters = engine.altitudeMeters;

  /// Fused, stabilized roll/pitch, in degrees (dx = pitch, dy = roll) —
  /// feeds the artificial horizon, which needs actual degree values rather
  /// than a normalized range (unlike the old bubble level, this isn't
  /// clamped to ±45°: roll zones extend out to 90°).
  ///
  /// Three explicit stages (see this class's own doc comment for the full
  /// rationale):
  ///  1. RAW — [pitchRollDegreesFromAccelerometer] on the raw accelerometer
  ///     sample, unchanged, still independently unit-testable against known
  ///     vectors.
  ///  2. PROCESSED — [ComplementaryFilter] (one instance each for pitch and
  ///     roll) fuses that raw angle with the paired gyroscope sample's rate
  ///     ([pitchRollRatesDegPerSecFromGyroscope]), correcting for transient
  ///     linear-acceleration contamination the accelerometer alone can't
  ///     distinguish from a real attitude change. Falls back to the raw
  ///     accelerometer angle automatically on a device with no gyroscope
  ///     (see [ComplementaryFilter.filter]'s own doc).
  ///  3. DISPLAY — the same [stabilizedForDisplay] (OneEuroFilter/dead-zone/
  ///     slew) already used before this round, constants unchanged: it now
  ///     smooths the fused signal instead of the raw accelerometer-only one.
  ///
  /// [pairedWithLatest] pairs every accelerometer sample (RAW's own source)
  /// with the latest gyroscope reading — same "frequent signal paired with
  /// a comparably-fast companion" idiom already used by
  /// [pairedWithMountOrientation] for g-force, reused here rather than
  /// duplicated.
  ///
  /// [asBroadcastStream] is required, same reasoning as
  /// [_vehicleAcceleration]/[TelemetryEngine]'s own `_throttleAdaptive`:
  /// this whole chain is built from stateful `.map()`/[stabilizedForDisplay]
  /// closures (the two [ComplementaryFilter] instances, [pairedWithLatest]'s
  /// own `latest` tracking, the display stage's own low-pass/dead-zone/slew
  /// state), and has two downstream listeners (the dashboard tile and,
  /// if opened, a fullscreen view) — without it, each listener would force
  /// its own independent re-run of this entire chain, corrupting both
  /// [ComplementaryFilter] instances' shared mutable state.
  late final Stream<Offset> inclinationPitchRollDegrees = _buildInclinationStream();

  Stream<Offset> _buildInclinationStream() {
    final pitchFusion = ComplementaryFilter(gyroWeight: _inclinationGyroWeight);
    final rollFusion = ComplementaryFilter(gyroWeight: _inclinationGyroWeight);
    return pairedWithLatest(sensors.accelerometerStream, sensors.gyroscopeStream)
        .map((sample) {
          final (accel, gyro) = sample;
          final rawAngles = pitchRollDegreesFromAccelerometer(accel.x, accel.y, accel.z);
          final rates = gyro == null
              ? null
              : pitchRollRatesDegPerSecFromGyroscope(
                  gyro.x,
                  gyro.y,
                  gyro.z,
                  isLandscape: isLandscapeMount(accel.x, accel.y),
                );
          final fusedPitch = pitchFusion.filter(rawAngles.dx, rates?.pitch, accel.timestamp);
          final fusedRoll = rollFusion.filter(rawAngles.dy, rates?.roll, accel.timestamp);
          return (Offset(fusedPitch, fusedRoll), accel.timestamp);
        })
        .stabilizedForDisplay(
          minCutoff: _inclinationMinCutoffHz,
          beta: _inclinationBeta,
          deadZone: _inclinationDeadZoneDegrees,
          maxDeltaPerUpdate: _inclinationMaxSlewDegreesPerUpdate,
        )
        .asBroadcastStream();
  }

  /// Every raw accelerometer sample mapped onto the vehicle's own axes (see
  /// `vehicle_coordinate_system.dart` — the single Smartphone → Vehicle
  /// Coordinate System transformation layer) — computed exactly once per
  /// sample and shared by both [gForceOffset] and [gForceVertical] below,
  /// rather than each independently re-running the same
  /// [pairedWithMountOrientation] pipeline over the very same
  /// `userAccelerometerStream`/`accelerometerStream` pair (duplicating both
  /// the sensor subscription and the per-sample [vehicleAxesFromPhone]
  /// computation for no benefit).
  ///
  /// [asBroadcastStream] is required here, same reasoning as
  /// [inclinationPitchRollDegrees]/[TelemetryEngine]'s own
  /// `_throttleAdaptive`: this stream is itself built from stateful
  /// `.map()` closures (the mount-orientation debounce inside
  /// [pairedWithMountOrientation], and [pairedWithLatest]'s own `latest`
  /// tracking), and has two downstream listeners
  /// ([gForceOffset]/[gForceVertical]) — without it, each listener would
  /// force its own independent re-run of this entire chain, right back to
  /// the duplication this field exists to eliminate.
  late final Stream<({double x, double y, double z, DateTime timestamp})> _vehicleAcceleration =
      pairedWithMountOrientation(sensors.userAccelerometerStream, sensors.accelerometerStream)
          .map((sample) {
            final (orientation, v) = sample;
            final axes = vehicleAxesFromPhone(v.x, v.y, v.z, orientation: orientation);
            return (x: axes.x, y: axes.y, z: axes.z, timestamp: v.timestamp);
          })
          .asBroadcastStream();

  /// Lateral/longitudinal G, normalized to -1..1 (representing ±2g) for the
  /// g-force-meter dot — `dx` = [vehicleAxesFromPhone]'s `y` (lateral,
  /// right-positive), `dy` = its `x` (longitudinal, forward-positive).
  /// Already in the vehicle's own coordinate system via
  /// [_vehicleAcceleration], so no further orientation handling is needed
  /// here or in the widget. Centralized OneEuroFilter-based stabilization
  /// (denoise + dead zone + slew-rate limit) applied via
  /// [TelemetryEngine.filterGForceOffset] — the real per-sample timestamp is
  /// threaded through since that filter needs true elapsed time, not an
  /// assumed interval.
  late final Stream<Offset> gForceOffset = engine.filterGForceOffset(
    _vehicleAcceleration.map(
      (v) => (
        Offset((v.y / _gravity / 2).clamp(-1.0, 1.0), (v.x / _gravity / 2).clamp(-1.0, 1.0)),
        v.timestamp,
      ),
    ),
  );

  /// Total G-force magnitude, in g, for the numeric style — orientation-
  /// independent (a vector's length doesn't change based on which axis
  /// carries which component), so unlike [gForceOffset]/[gForceVertical]
  /// this needs no vehicle-axis transformation at all. Centralized
  /// OneEuroFilter-based filtering (denoise only, no slew cap — see
  /// [TelemetryEngine]'s own doc comment for why) applied via
  /// [TelemetryEngine.filterGForceMagnitude].
  late final Stream<double> gForceMagnitude = engine.filterGForceMagnitude(
    sensors.userAccelerometerStream.map((v) => (v.magnitude / _gravity, v.timestamp)),
  );

  /// Vertical G (bumps, dips, jumps) — the one component [gForceOffset]
  /// doesn't already cover (that one's lateral/longitudinal only).
  /// Normalized to -1..1, same ±2g full scale as
  /// [gForceOffset]/[gForceMagnitude], for the g-force meter's vertical bar.
  /// Same shared [_vehicleAcceleration] as [gForceOffset]. Centralized
  /// OneEuroFilter-based stabilization applied via
  /// [TelemetryEngine.filterGForceVertical].
  late final Stream<double> gForceVertical = engine.filterGForceVertical(
    _vehicleAcceleration.map((v) => ((v.z / _gravity / 2).clamp(-1.0, 1.0), v.timestamp)),
  );

  /// The unified, central telemetry state — every session/alert/HUD/
  /// diagnostics consumer reads this instead of assembling its own picture
  /// from the individual signals above. Combines [engine]'s GPS-native
  /// streams (speed, altitude, heading, GNSS quality) with this class's own
  /// vehicle-axis-corrected ones (g-force, pitch/roll) plus raw
  /// latitude/longitude/accuracy pulled directly from [sensors.positionStream]
  /// (the one piece of raw GPS data no filtered signal above already
  /// carries). No new sensor subscriptions of its own — every source here
  /// is one of the streams already built above, or the app's single shared
  /// GPS subscription via [sensors].
  ///
  /// Cascades laziness correctly: subscribing to [snapshot] is what starts
  /// each underlying source (GPS, accelerometer, gyroscope, barometer) if
  /// nothing else in the app is already listening to it; the last listener
  /// leaving stops them again, exactly like every other stream here.
  ///
  /// GPS-cadence fields (position, speed, altitude, heading, GNSS quality,
  /// altitude trend, barometer-active) are throttled to a fixed ~5Hz
  /// ceiling — a plain merge-and-re-emit-on-every-update design would
  /// otherwise re-derive the whole snapshot on every underlying tick, far
  /// faster than any GPS-derived signal itself actually changes, wasteful
  /// of CPU/battery for no benefit.
  ///
  /// G-force fields (see [gForceMagnitude]/[gForceOffset]/[gForceVertical])
  /// are the one exception, and are **not** subject to that throttle (Fase
  /// 13.2's own root-cause finding — see this class's delivery notes):
  /// [EventDetectionEngine]'s level-based trackers need at least two samples
  /// spanning their own ~150-200ms minimum-duration window to confirm a hard
  /// acceleration/braking/cornering event, and this device's accelerometer
  /// alone already delivers ~100Hz — a blanket 200ms throttle here silently
  /// discarded ~95% of that resolution before the detector ever saw it,
  /// which is precisely why genuine, threshold-and-duration-qualifying
  /// physical events (confirmed independently in the g-force-widget-facing
  /// [gForceOffset]/[gForceMagnitude] streams themselves, which were never
  /// throttled) went undetected. This mirrors [TelemetryEngine]'s own
  /// already-documented g-force philosophy (see [TelemetryEngine.filterGForceMagnitude]'s
  /// doc: "g-force instead updates as fast as SensorService's own
  /// accelerometer sampling rate delivers... no artificial cap coupled to
  /// vehicle speed") — this fix simply stops undoing that one throttle stage
  /// later, in the snapshot layer.
  late final Stream<TelemetrySnapshot> snapshot = _buildSnapshotStream();

  Stream<TelemetrySnapshot> _buildSnapshotStream() {
    late StreamController<TelemetrySnapshot> controller;
    final subs = <StreamSubscription<void>>[];

    double? latitude, longitude, altitude, speed, heading, horizontalAccuracy, verticalAccuracy;
    double? pitch, roll, gMagnitude, longitudinalG, lateralG, verticalGValue;
    var gnssQualityValue = GnssQuality.unavailable;
    var altitudeTrendValue = AltitudeTrend.stable;
    var barometerActiveValue = false;
    ObdLinkState? obdState = obd?.state;
    double? engineRpm, engineLoad, engineCoolant, vehicleVoltage;
    DateTime? lastGpsCadenceEmit;

    void emitNow() {
      controller.add(
        TelemetrySnapshot(
          timestamp: DateTime.now(),
          latitude: latitude,
          longitude: longitude,
          altitudeMeters: altitude,
          speedKmh: speed,
          headingDegrees: heading,
          horizontalAccuracyMeters: horizontalAccuracy,
          verticalAccuracyMeters: verticalAccuracy,
          gnssQuality: gnssQualityValue,
          altitudeTrend: altitudeTrendValue,
          longitudinalG: longitudinalG,
          lateralG: lateralG,
          verticalG: verticalGValue,
          gForceMagnitude: gMagnitude,
          pitchDegrees: pitch,
          rollDegrees: roll,
          barometerActive: barometerActiveValue,
          obdLinkState: obdState,
          engineRpm: engineRpm,
          engineLoadPercent: engineLoad,
          engineCoolantC: engineCoolant,
          vehicleVoltage: vehicleVoltage,
        ),
      );
    }

    // GPS-cadence trigger path — throttled (see this field's own doc).
    void emitThrottled() {
      final now = DateTime.now();
      if (!shouldEmitThrottled(lastEmitted: lastGpsCadenceEmit, now: now, gap: snapshotGpsCadenceGap)) return;
      lastGpsCadenceEmit = now;
      emitNow();
    }

    controller = StreamController<TelemetrySnapshot>.broadcast(
      onListen: () {
        subs.add(
          sensors.positionStream.listen((Position p) {
            latitude = p.latitude;
            longitude = p.longitude;
            horizontalAccuracy = p.accuracy > 0 ? p.accuracy : null;
            verticalAccuracy = p.altitudeAccuracy > 0 ? p.altitudeAccuracy : null;
            emitThrottled();
          }),
        );
        subs.add(
          engine.speedKmh.listen((v) {
            speed = v;
            emitThrottled();
          }),
        );
        subs.add(
          engine.altitudeMeters.listen((v) {
            altitude = v;
            emitThrottled();
          }),
        );
        subs.add(
          engine.headingDegrees.listen((v) {
            heading = v;
            emitThrottled();
          }),
        );
        subs.add(
          engine.gnssQuality.listen((v) {
            gnssQualityValue = v;
            emitThrottled();
          }),
        );
        subs.add(
          engine.altitudeTrend.listen((v) {
            altitudeTrendValue = v;
            emitThrottled();
          }),
        );
        subs.add(
          // Barometer availability only, not a value — the barometer's
          // actual readings already feed TelemetryEngine's altitude fusion
          // internally; this listener exists solely so `barometerActive`
          // can report "has this device ever produced a barometer sample"
          // without Diagnostics (or a future consumer) needing its own
          // separate subscription to find that out. A device with no
          // barometer surfaces that as a stream error, same as
          // TelemetryEngine's own altitude pipeline handles it — swallowed
          // here too, since "no barometer" simply means this listener never
          // fires and `barometerActive` correctly stays false.
          sensors.barometerStream.listen(
            (_) {
              barometerActiveValue = true;
              emitThrottled();
            },
            onError: (Object error, StackTrace stackTrace) {},
          ),
        );
        subs.add(
          inclinationPitchRollDegrees.listen((v) {
            pitch = v.dx;
            roll = v.dy;
            emitThrottled();
          }),
        );
        // OBD-II (phase 1): at most 2 Hz, so on the throttled path like GPS.
        // Only live values go in — see TelemetrySnapshot's vehicle fields. The
        // service also emits on every link state change, which is what turns
        // these back to null after a drop.
        final obdService = obd;
        if (obdService != null) {
          subs.add(
            obdService.readingsStream.listen((readings) {
              double? live(ObdSignal signal) => obdService.isFresh(signal) ? readings[signal]?.value : null;
              obdState = obdService.state;
              engineRpm = live(ObdSignal.rpm);
              engineLoad = live(ObdSignal.engineLoad);
              engineCoolant = live(ObdSignal.coolant);
              vehicleVoltage = live(ObdSignal.adapterVoltage);
              emitThrottled();
            }),
          );
        }
        // G-force trigger path — deliberately NOT throttled (see this
        // field's own doc for why).
        subs.add(
          gForceMagnitude.listen((v) {
            gMagnitude = v;
            emitNow();
          }),
        );
        subs.add(
          gForceOffset.listen((v) {
            lateralG = v.dx;
            longitudinalG = v.dy;
            emitNow();
          }),
        );
        subs.add(
          gForceVertical.listen((v) {
            verticalGValue = v;
            emitNow();
          }),
        );
      },
      onCancel: () async {
        for (final sub in subs) {
          await sub.cancel();
        }
        subs.clear();
      },
    );
    return controller.stream;
  }
}
