import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/sensor_reading.dart';
import 'stream_pairing.dart';

/// The phone's physical mount rotation about its own front/back axis — the
/// only axis a dashboard mount actually rotates around (screen always
/// facing the driver, never lying flat). Every raw accelerometer sample is
/// classified into exactly one of these four before it's transformed into
/// [vehicleAxesFromPhone]'s vehicle-relative output — this is what lets the
/// g-force meter represent the *vehicle's* forces unchanged, regardless of
/// how the phone itself happens to be rotated in its mount.
///
/// Unlike the artificial horizon's own [isLandscapeMount]-based detection
/// (a plain magnitude comparison, `|x| vs |y|`, sufficient for that
/// widget's own hardware-validated formula), g-force needs the *sign* too:
/// the two landscape mounts (rotating the phone 90° clockwise vs.
/// counterclockwise from portrait, as seen by whoever is facing the screen)
/// are physically distinct — they put opposite native axes toward "up" —
/// and produce opposite lateral/vertical readings. A magnitude-only check
/// cannot tell them apart; [detectMountOrientation] can, from the sign of
/// whichever native axis dominates.
@visibleForTesting
enum PhoneMountOrientation {
  /// Natural/default portrait: top of the phone points up.
  portraitUpright,

  /// Portrait, rotated 180°: top of the phone points down.
  portraitUpsideDown,

  /// Landscape, reached by physically rotating the phone 90° clockwise from
  /// [portraitUpright] (as seen by someone facing the screen).
  landscapeClockwise,

  /// Landscape, reached by physically rotating the phone 90° counterclockwise
  /// from [portraitUpright].
  landscapeCounterClockwise,
}

/// Classifies the phone's current mount rotation from a single
/// gravity-including accelerometer sample ([gravityX]/[gravityY] — the
/// device's Z axis plays no part, since it never changes role under a
/// rotation about itself). Whichever of X/Y has the larger magnitude is the
/// one closer to "up" (near ±g at level); its *sign* then picks which of
/// the two possible mounts on that axis applies. Defaults to
/// [PhoneMountOrientation.portraitUpright] only in the sense that a tie
/// (both exactly zero, never happens with real hardware noise) falls to the
/// portrait branch — see [pairedWithMountOrientation] for the *stream-level*
/// default before any sample has arrived at all.
@visibleForTesting
PhoneMountOrientation detectMountOrientation(double gravityX, double gravityY) {
  if (gravityX.abs() > gravityY.abs()) {
    return gravityX > 0 ? PhoneMountOrientation.landscapeCounterClockwise : PhoneMountOrientation.landscapeClockwise;
  }
  return gravityY >= 0 ? PhoneMountOrientation.portraitUpright : PhoneMountOrientation.portraitUpsideDown;
}

/// Transforms one raw accelerometer sample (already gravity-removed — see
/// [pairedWithMountOrientation]'s own doc) from the phone's native body-frame
/// axes into the vehicle's own axes, given the current [orientation] from
/// [detectMountOrientation]. This is the single Smartphone Coordinate
/// System → Vehicle Coordinate System transformation layer: every other
/// piece of this app (the g-force meter, in both Dashboard and Fullscreen)
/// consumes only this function's output, never the phone's raw axes
/// directly.
///
/// Convention (fixed, not configurable — matches how a driver actually
/// experiences these forces):
///  * `x` (longitudinal): positive = accelerating forward, negative = braking.
///  * `y` (lateral): positive = turning right, negative = turning left.
///  * `z` (vertical): positive = upward force (a lift/bump), negative =
///    downward (a dip/compression). Computed and returned for future use,
///    but the g-force dial's own current rendering only plots `x`/`y`.
///
/// This is a single linear map per [orientation] — never a per-scenario
/// rule. Real driving is a superposition of these forces (e.g. braking
/// while turning), and because the transform is linear, the composed
/// output already falls out correctly with no special-casing: transforming
/// (forward-force + right-force) gives exactly the sum of transforming
/// each alone.
///
/// ### Derivation
/// [phoneZ] never changes role under any of the four [orientation]s (they're
/// all rotations about the phone's own Z axis, screen always facing the
/// driver): Android's `TYPE_LINEAR_ACCELERATION` convention is that the
/// reported value equals the device's true coordinate acceleration in its
/// own body frame (confirmed from the platform's own documented example: a
/// phone at rest reads `+9.81` on whichever raw axis opposes gravity, i.e.
/// points "up"). With the phone mounted screen-facing-the-driver, native +Z
/// points out of the screen toward the driver — roughly the *rear* of the
/// vehicle, not the front. A real forward acceleration is therefore a
/// *negative* native Z reading (the device accelerates opposite to where
/// its own +Z axis points), hence `x: -phoneZ`, unconditionally.
///
/// For lateral/vertical, [portraitUpright]'s mapping (`y: phoneX, z: phoneY`,
/// both direct) is the one hardware-validated in earlier rounds — [phoneY]
/// (pointing to the top of the phone) reads +g at rest, confirming native
/// +Y = up, hence `z: phoneY`; a rightward vehicle acceleration reads
/// positive on native X (same `a_device` convention above, combined with
/// the already hardware-confirmed fact that native +X points physically
/// right — see [pitchRollDegreesFromAccelerometer]'s own roll-formula
/// derivation), hence `y: phoneX`. The other three orientations are each a
/// 90°-multiple rotation of this same reference about the shared Z axis:
/// rotating the *physical phone* by θ rotates its native axes by θ in the
/// world frame, so "which native axis now reads as up/right" rotates
/// correspondingly. Working out each remaining case (right = 90° clockwise
/// from up, as seen facing the screen — a fixed geometric fact independent
/// of any single case) gives:
///  * [portraitUpsideDown] (180° from upright): `y: -phoneX, z: -phoneY`.
///  * [landscapeCounterClockwise]: `y: -phoneY, z: phoneX`. This is the
///    landscape case already hardware-validated in earlier rounds (it
///    reproduces the pre-existing, tested `lateral: -y, vertical: x`
///    formula exactly), confirming this derivation method against known-good
///    hardware data before extending it to the previously-unhandled
///    [landscapeClockwise] case below.
///  * [landscapeClockwise] (the mount rotation earlier rounds left
///    unhandled — silently reused [landscapeCounterClockwise]'s formula,
///    which is backwards for this specific mount): `y: phoneY, z: -phoneX`.
({double x, double y, double z}) vehicleAxesFromPhone(
  double phoneX,
  double phoneY,
  double phoneZ, {
  required PhoneMountOrientation orientation,
}) {
  final (double y, double z) lateralVertical = switch (orientation) {
    PhoneMountOrientation.portraitUpright => (phoneX, phoneY),
    PhoneMountOrientation.portraitUpsideDown => (-phoneX, -phoneY),
    PhoneMountOrientation.landscapeCounterClockwise => (-phoneY, phoneX),
    PhoneMountOrientation.landscapeClockwise => (phoneY, -phoneX),
  };
  return (x: -phoneZ, y: lateralVertical.$1, z: lateralVertical.$2);
}

/// Pairs every [values] emission with the [PhoneMountOrientation] most
/// recently reported by [gravitySource] — the mount only actually changes
/// on a rare, deliberate physical rotation, so sampling [gravitySource]'s
/// latest known reading (via [pairedWithLatest]) on every [values] tick is
/// all the g-force axis correction needs. [values] is expected to be
/// gravity-removed (user acceleration); [gravitySource] must include
/// gravity — only the latter has a dominant axis to self-detect the mount
/// from. Defaults to [PhoneMountOrientation.portraitUpright] before
/// [gravitySource]'s first emission.
///
/// The raw per-sample [detectMountOrientation] reading is debounced,
/// requiring [confirmSamples] consecutive agreeing readings before the
/// *confirmed* orientation actually changes — the same "candidate streak"
/// idiom `line_chart.dart` already uses to debounce its trend arrow.
/// Without this, a single noisy [gravitySource] sample can flip the
/// confirmed orientation: [gravitySource] is the *raw* (gravity-included)
/// accelerometer, so a large transient dynamic g-force (hard braking, a
/// sharp corner — precisely the moments this signal matters most) adds to
/// gravity in the same raw X/Y reading [detectMountOrientation] compares,
/// and can transiently tip a mount that's normally clearly on one side of a
/// classification boundary. An un-debounced flip silently swaps the
/// lateral/vertical axis mapping for that one sample, producing a visibly
/// wrong direction for an instant. A real physical rotation is slow (at
/// least several hundred milliseconds for a human to turn the mount)
/// compared to [confirmSamples]'s default window, so genuine rotations are
/// still detected quickly.
Stream<(PhoneMountOrientation orientation, VectorReading value)> pairedWithMountOrientation(
  Stream<VectorReading> values,
  Stream<VectorReading> gravitySource, {
  int confirmSamples = 8,
}) {
  var confirmed = PhoneMountOrientation.portraitUpright;
  PhoneMountOrientation? candidate;
  var candidateStreak = 0;
  return pairedWithLatest(values, gravitySource).map((sample) {
    final (value, gravity) = sample;
    if (gravity != null) {
      final reading = detectMountOrientation(gravity.x, gravity.y);
      if (reading == candidate) {
        candidateStreak++;
      } else {
        candidate = reading;
        candidateStreak = 1;
      }
      if (candidateStreak >= confirmSamples) confirmed = reading;
    }
    return (confirmed, value);
  });
}
