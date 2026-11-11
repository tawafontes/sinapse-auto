import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// How far into risk territory a pitch/roll reading is. Ordered from safest
/// to most severe so `.index` doubles as a severity ranking (see
/// [moreSevereZone]).
enum InclinationRiskZone { safe, risk, highRisk, veryHighRisk }

/// Pitch risk zone for `|pitchDeg|`: safe to 20°, risk to 25°, high risk to
/// 30°, very high risk beyond — symmetric for nose-up and nose-down.
@visibleForTesting
InclinationRiskZone pitchRiskZone(double pitchDeg) {
  final abs = pitchDeg.abs();
  if (abs <= 20) return InclinationRiskZone.safe;
  if (abs <= 25) return InclinationRiskZone.risk;
  if (abs <= 30) return InclinationRiskZone.highRisk;
  return InclinationRiskZone.veryHighRisk;
}

/// Roll risk zone for `|rollDeg|`: safe to 15°, risk to 20°, high risk to
/// 25°, very high risk beyond — symmetric left/right.
@visibleForTesting
InclinationRiskZone rollRiskZone(double rollDeg) {
  final abs = rollDeg.abs();
  if (abs <= 15) return InclinationRiskZone.safe;
  if (abs <= 20) return InclinationRiskZone.risk;
  if (abs <= 25) return InclinationRiskZone.highRisk;
  return InclinationRiskZone.veryHighRisk;
}

/// The worse of two zones — used to pick the card alert's color when pitch
/// and roll are in different zones simultaneously.
@visibleForTesting
InclinationRiskZone moreSevereZone(InclinationRiskZone a, InclinationRiskZone b) =>
    a.index >= b.index ? a : b;

typedef _RiskColors = ({Color safe, Color risk, Color highRisk, Color veryHighRisk});

/// Tuned per brightness like the other sensor widgets' zone colors
/// (altitude, G-force meter): dark mode gets lighter, more saturated tones
/// so they don't wash out over a near-black background.
_RiskColors _riskColorsFor(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return (
      safe: const Color(0xFF81C784),
      risk: const Color(0xFFFFD54F),
      highRisk: const Color(0xFFFFB74D),
      veryHighRisk: const Color(0xFFE57373),
    );
  }
  return (
    safe: const Color(0xFF4CAF50),
    risk: const Color(0xFFFFC107),
    highRisk: const Color(0xFFFF9800),
    veryHighRisk: const Color(0xFFF44336),
  );
}

Color riskZoneColor(InclinationRiskZone zone, Brightness brightness) {
  final colors = _riskColorsFor(brightness);
  switch (zone) {
    case InclinationRiskZone.safe:
      return colors.safe;
    case InclinationRiskZone.risk:
      return colors.risk;
    case InclinationRiskZone.highRisk:
      return colors.highRisk;
    case InclinationRiskZone.veryHighRisk:
      return colors.veryHighRisk;
  }
}

const _aircraftColor = Color(0xFFFFD600);

/// Formats a pitch/roll degree value with an explicit sign — `+10`/`-10` —
/// everywhere the widget shows one numerically (the pitch ladder marks, the
/// PITCH/ROLL footer labels; callers append their own `°` where they already
/// did). Rounds first so a value that only reads as zero after rounding
/// (e.g. -0.3) never prints a stray "-0": [round] on a [double] returns a
/// plain [int], which has no negative-zero of its own to leak into the
/// string.
@visibleForTesting
String formatSignedDegrees(double degrees) {
  final rounded = degrees.round();
  if (rounded == 0) return '0';
  return rounded > 0 ? '+$rounded' : '$rounded';
}

/// Artificial horizon (attitude indicator), "outside view" variant: a
/// sky/ground ball that stays level and only slides vertically with pitch —
/// it never rotates for roll, unlike the traditional aviation instrument.
/// Roll instead rotates the vehicle symbol itself (paired rigidly with the
/// roll pointer that slides along the fixed bezel), so the picture reads as
/// watching the vehicle bank from outside rather than a pilot's-eye view
/// where the horizon tilts and the aircraft stays level. A roll scale bezel
/// across the top and a pitch ladder painted on the ball stay fixed either
/// way. Pitch/roll risk zones color both scales and the two footer labels.
///
/// The card-wide blinking alert (border + translucent overlay over the
/// *entire* dashboard tile, not just this widget's own content area) is
/// owned by [DashboardTile] — reachable only from there, not from a widget
/// nested inside its content padding. This widget just computes the current
/// alert color (null when safe) and reports it via [onAlertColorChanged]
/// whenever it changes; the tile does the actual blinking.
///
/// [onResetRequested] hands the caller a trigger for a calibration dialog
/// that zeroes both axes to the device's current attitude — the offset it
/// produces is handed back via [onCalibrated] rather than written to
/// storage directly, so this widget stays unaware of Hive/persistence
/// (mirrors [LineChart]'s initial-value-plus-callback pattern for
/// altitude's session extremes).
class ArtificialHorizon extends StatefulWidget {
  const ArtificialHorizon({
    super.key,
    required this.pitchRollStream,
    this.initialPitchOffsetDeg = 0.0,
    this.initialRollOffsetDeg = 0.0,
    this.onCalibrated,
    this.onAlertColorChanged,
    this.onResetRequested,
    this.onImmediateResetRequested,
  });

  /// Raw (uncalibrated) pitch/roll in degrees: dx = pitch, dy = roll.
  final Stream<Offset> pitchRollStream;
  final double initialPitchOffsetDeg;
  final double initialRollOffsetDeg;
  final void Function(double pitchOffsetDeg, double rollOffsetDeg)? onCalibrated;

  /// Called with the color of the more severe of pitch/roll's risk zones
  /// whenever it changes — null when both are safe. The caller (see
  /// [DashboardTile.alertColor]) is expected to blink the whole card in
  /// this color while it's non-null.
  final ValueChanged<Color?>? onAlertColorChanged;

  /// Called once, in `initState`, with a tear-off of this widget's own
  /// calibration dialog — see [GForceMeter.onResetRequested] for the full
  /// rationale (same pattern, shared across all three sensor widgets with a
  /// resettable record; here "reset" means recalibrating pitch/roll to
  /// zero). Unrelated to [onAlertColorChanged].
  final ValueChanged<VoidCallback>? onResetRequested;

  /// Called once, in `initState`, with a tear-off of the bare calibration
  /// logic (no confirmation dialog, no "calibrado" SnackBar of its own) —
  /// see [LineChart.onImmediateResetRequested] for the full rationale. The
  /// dashboard's global button shows one consolidated confirmation and
  /// success message of its own, so this path must not surface either.
  final ValueChanged<VoidCallback>? onImmediateResetRequested;

  @override
  State<ArtificialHorizon> createState() => _ArtificialHorizonState();
}

class _ArtificialHorizonState extends State<ArtificialHorizon> {
  StreamSubscription<Offset>? _sub;
  double _rawPitch = 0;
  double _rawRoll = 0;
  late double _pitchOffset;
  late double _rollOffset;
  Color? _lastReportedAlertColor;

  double get _pitch => _rawPitch - _pitchOffset;
  double get _roll => _rawRoll - _rollOffset;

  @override
  void initState() {
    super.initState();
    _pitchOffset = widget.initialPitchOffsetDeg;
    _rollOffset = widget.initialRollOffsetDeg;
    _listen(widget.pitchRollStream);
    widget.onResetRequested?.call(_showCalibrationDialog);
    widget.onImmediateResetRequested?.call(_performCalibration);
  }

  @override
  void didUpdateWidget(covariant ArtificialHorizon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pitchRollStream != widget.pitchRollStream) {
      _listen(widget.pitchRollStream);
    }
  }

  void _listen(Stream<Offset> stream) {
    unawaited(_sub?.cancel());
    _sub = stream.listen((value) {
      setState(() {
        _rawPitch = value.dx;
        _rawRoll = value.dy;
      });
      _reportAlertColor();
    });
  }

  /// Recomputes the alert color and forwards it to [ArtificialHorizon.
  /// onAlertColorChanged] only when it actually changed, so the card's
  /// blink isn't restarted on every single reading.
  void _reportAlertColor() {
    final zone = moreSevereZone(pitchRiskZone(_pitch), rollRiskZone(_roll));
    final color = zone == InclinationRiskZone.safe ? null : riskZoneColor(zone, Theme.of(context).brightness);
    if (color == _lastReportedAlertColor) return;
    _lastReportedAlertColor = color;
    widget.onAlertColorChanged?.call(color);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _showCalibrationDialog() async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calibrar horizonte artificial?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A posição atual do aparelho será definida como o novo zero de pitch e roll.',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: colorScheme.onErrorContainer, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Garanta que o veículo está parado sobre uma superfície nivelada antes de confirmar.',
                      style: TextStyle(color: colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Calibrar agora'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _performCalibration();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Horizonte artificial calibrado.'), duration: Duration(seconds: 2)),
    );
  }

  /// The actual calibration logic, with no confirmation dialog and no
  /// SnackBar of its own — see [ArtificialHorizon.onImmediateResetRequested].
  void _performCalibration() {
    setState(() {
      _pitchOffset = _rawPitch;
      _rollOffset = _rawRoll;
    });
    _reportAlertColor();
    widget.onCalibrated?.call(_pitchOffset, _rollOffset);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final pitch = _pitch;
    final roll = _roll;
    final pitchZone = pitchRiskZone(pitch);
    final rollZone = rollRiskZone(roll);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: CustomPaint(
            painter: _ArtificialHorizonPainter(pitchDeg: pitch, rollDeg: roll, brightness: brightness),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _ExtremeLabel(
              text: 'PITCH ${formatSignedDegrees(pitch)}°',
              color: pitchZone == InclinationRiskZone.safe
                  ? colorScheme.onSurfaceVariant
                  : riskZoneColor(pitchZone, brightness),
              highlighted: pitchZone != InclinationRiskZone.safe,
            ),
            _ExtremeLabel(
              text: 'ROLL ${formatSignedDegrees(roll)}°',
              color: rollZone == InclinationRiskZone.safe
                  ? colorScheme.onSurfaceVariant
                  : riskZoneColor(rollZone, brightness),
              highlighted: rollZone != InclinationRiskZone.safe,
            ),
          ],
        ),
      ],
    );
  }
}

class _ExtremeLabel extends StatelessWidget {
  const _ExtremeLabel({required this.text, required this.color, required this.highlighted});

  final String text;
  final Color color;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: highlighted ? FontWeight.bold : FontWeight.w500),
    );
  }
}

class _ArtificialHorizonPainter extends CustomPainter {
  _ArtificialHorizonPainter({required this.pitchDeg, required this.rollDeg, required this.brightness});

  final double pitchDeg;
  final double rollDeg;
  final Brightness brightness;

  /// Full ball radius == 45° of pitch, so a moderate climb/dive still reads
  /// clearly instead of the ladder crawling by too fast or too slow.
  static const _pitchDegreesPerRadius = 45.0;

  /// Roll-scale zone boundaries, degrees from center — mirrored both sides.
  static const _rollZoneBoundaries = [15.0, 20.0, 25.0];

  @override
  void paint(Canvas canvas, Size size) {
    // Biased slightly up to leave room below for the roll scale's bottom arc
    // and, more importantly, so the sphere doesn't crowd the footer labels.
    final center = Offset(size.width / 2, size.height / 2 - 4);
    final maxRadius = math.min(size.width, size.height) / 2;
    final sphereRadius = maxRadius - 20;
    if (sphereRadius <= 0) return;

    _paintSphere(canvas, center, sphereRadius);
    canvas.drawCircle(
      center,
      sphereRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black.withValues(alpha: 0.45),
    );
    _paintRollScale(canvas, center, sphereRadius);
    _paintRollZeroMark(canvas, center, sphereRadius);
    _paintAircraftAndRollPointer(canvas, center, sphereRadius);
  }

  /// Sky/ground/horizon-line and the pitch ladder — level at all times (no
  /// roll rotation: see the class doc comment), only ever translated
  /// vertically for pitch.
  void _paintSphere(Canvas canvas, Offset center, double radius) {
    final pixelsPerDegree = radius / _pitchDegreesPerRadius;
    final pitchPixels = pitchDeg * pixelsPerDegree;

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius)));
    canvas.translate(center.dx, center.dy);
    canvas.translate(0, pitchPixels);

    // Oversized well past the clip so even a large pitch offset never
    // reveals a gap at the circle's edge.
    final big = radius * 3;
    final skyColor = brightness == Brightness.dark ? const Color(0xFF1565C0) : const Color(0xFF4FC3F7);
    final groundColor = brightness == Brightness.dark ? const Color(0xFF4E342E) : const Color(0xFF8D6E63);
    canvas.drawRect(Rect.fromLTRB(-big, -big, big, 0), Paint()..color = skyColor);
    canvas.drawRect(Rect.fromLTRB(-big, 0, big, big), Paint()..color = groundColor);
    canvas.drawLine(
      Offset(-big, 0),
      Offset(big, 0),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );

    _paintPitchLadder(canvas, pixelsPerDegree, radius);

    canvas.restore();
  }

  /// Rungs every 10° out to 90°, colored by [pitchRiskZone] for the angle
  /// they represent — a fixed reference on the scale, independent of the
  /// current pitch — with the degree value labeled at both ends.
  void _paintPitchLadder(Canvas canvas, double pixelsPerDegree, double radius) {
    for (var mark = -90; mark <= 90; mark += 10) {
      if (mark == 0) continue; // the horizon line itself already marks zero.
      final absMark = mark.abs();
      final color = riskZoneColor(pitchRiskZone(absMark.toDouble()), brightness);
      final halfWidth = absMark % 30 == 0 ? radius * 0.32 : radius * 0.2;
      final y = -mark * pixelsPerDegree;

      canvas.drawLine(
        Offset(-halfWidth, y),
        Offset(halfWidth, y),
        Paint()
          ..color = color
          ..strokeWidth = 2,
      );
      final label = formatSignedDegrees(mark.toDouble());
      _paintCenteredText(canvas, label, Offset(-halfWidth - 12, y), color);
      _paintCenteredText(canvas, label, Offset(halfWidth + 12, y), color);
    }
  }

  /// Converts a roll-scale angle (0° = straight up, 90° = right, -90° =
  /// left) to the radians [Canvas.drawArc]/trig functions expect (0 = 3
  /// o'clock, increasing clockwise in this y-down coordinate system).
  static double _canvasAngle(double rollScaleDegrees) => (rollScaleDegrees - 90) * math.pi / 180;

  void _paintRollScale(Canvas canvas, Offset center, double sphereRadius) {
    final arcRadius = sphereRadius + 10;
    final zoneRanges = <(double, double, InclinationRiskZone)>[
      (0, _rollZoneBoundaries[0], InclinationRiskZone.safe),
      (_rollZoneBoundaries[0], _rollZoneBoundaries[1], InclinationRiskZone.risk),
      (_rollZoneBoundaries[1], _rollZoneBoundaries[2], InclinationRiskZone.highRisk),
      (_rollZoneBoundaries[2], 90, InclinationRiskZone.veryHighRisk),
    ];
    final rect = Rect.fromCircle(center: center, radius: arcRadius);
    for (final (start, end, zone) in zoneRanges) {
      final color = riskZoneColor(zone, brightness);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = color;
      for (final sign in [1, -1]) {
        final a1 = math.min(start * sign, end * sign);
        final a2 = math.max(start * sign, end * sign);
        canvas.drawArc(rect, _canvasAngle(a1), (a2 - a1) * math.pi / 180, false, paint);
      }
    }

    // Ticks every 10° plus the zone-boundary angles (15/20/25), colored to
    // match their own zone rather than left black — a boundary tick must
    // never sit uncolored on top of a colored arc segment.
    final tickAngles = <double>{for (var d = 10.0; d <= 90; d += 10) d, ..._rollZoneBoundaries};
    for (final tick in tickAngles) {
      for (final sign in [1, -1]) {
        final angle = tick * sign;
        final color = riskZoneColor(rollRiskZone(angle.abs()), brightness);
        final angleRad = _canvasAngle(angle);
        final dir = Offset(math.cos(angleRad), math.sin(angleRad));
        canvas.drawLine(
          center + dir * (sphereRadius + 4),
          center + dir * (sphereRadius + 18),
          Paint()
            ..color = color
            ..strokeWidth = 2.5,
        );
      }
    }
  }

  /// Fixed dark triangle at the very top of the arc marking roll = 0° — the
  /// reference the rotating [_paintRollPointer] triangle points back at.
  void _paintRollZeroMark(Canvas canvas, Offset center, double sphereRadius) {
    final tipY = center.dy - (sphereRadius + 8);
    final baseY = center.dy - (sphereRadius + 22);
    final path = Path()
      ..moveTo(center.dx, tipY)
      ..lineTo(center.dx - 6, baseY)
      ..lineTo(center.dx + 6, baseY)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.black87);
  }

  /// The vehicle symbol (two wing bars + center triangle) and the roll
  /// pointer (small triangle out near the fixed bezel), rotated together as
  /// a single rigid unit by the current roll angle — this is what gives the
  /// "outside view" effect (see the class doc comment) instead of the
  /// traditional pilot's-eye one. Sharing one `save`/`rotate`/`restore`
  /// block, rather than each shape computing its own rotation, is what
  /// guarantees they always share the exact same angle; painted last so
  /// nothing from the level ball or the fixed bezel covers them.
  ///
  /// The rotation sign (`+rollDeg`) makes the group visually bank right for
  /// roll right and left for roll left, confirmed against real hardware.
  /// This looks the same on screen as an earlier version that used
  /// `-rollDeg` on top of [pitchRollDegreesFromAccelerometer]'s *old*,
  /// since-corrected roll sign — that pairing was two wrongs cancelling
  /// out visually while the numeric value (read directly by the footer
  /// label, with no rendering transform to hide behind) stayed backwards.
  /// Now that [pitchRollDegreesFromAccelerometer] itself returns the
  /// correct sign, this rotation no longer needs its own compensating
  /// negation — plain `rollDeg` reproduces the exact same, already-correct
  /// picture.
  void _paintAircraftAndRollPointer(Canvas canvas, Offset center, double sphereRadius) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rollDeg * math.pi / 180);
    _paintRollPointer(canvas, sphereRadius);
    _paintAircraftSymbol(canvas, sphereRadius);
    canvas.restore();
  }

  /// Yellow triangle pointing outward at the fixed scale, indicating the
  /// current roll angle against [_paintRollZeroMark]'s stationary
  /// reference. Drawn in the local space [_paintAircraftAndRollPointer]
  /// already translated to the center and rotated by roll.
  void _paintRollPointer(Canvas canvas, double sphereRadius) {
    final tipY = -(sphereRadius - 2);
    final baseY = -(sphereRadius - 14);
    final path = Path()
      ..moveTo(0, tipY)
      ..lineTo(-7, baseY)
      ..lineTo(7, baseY)
      ..close();
    canvas.drawPath(path, Paint()..color = _aircraftColor);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black87,
    );
  }

  /// The vehicle reference: two horizontal bars and a center triangle,
  /// drawn in the local space [_paintAircraftAndRollPointer] already
  /// translated to the center and rotated by roll — at roll = 0 this still
  /// renders pointing straight up, exactly as when it was unrotated.
  void _paintAircraftSymbol(Canvas canvas, double sphereRadius) {
    final wingLength = sphereRadius * 0.55;
    const gap = 10.0;
    for (final paint in [
      Paint()
        ..color = Colors.black87
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
      Paint()
        ..color = _aircraftColor
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    ]) {
      canvas.drawLine(Offset(-wingLength, 0), const Offset(-gap, 0), paint);
      canvas.drawLine(const Offset(gap, 0), Offset(wingLength, 0), paint);
    }

    final trianglePath = Path()
      ..moveTo(0, -8)
      ..lineTo(-7, 4)
      ..lineTo(7, 4)
      ..close();
    canvas.drawPath(trianglePath, Paint()..color = _aircraftColor);
    canvas.drawPath(
      trianglePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.black87,
    );
  }

  void _paintCenteredText(Canvas canvas, String text, Offset center, Color color) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ArtificialHorizonPainter oldDelegate) =>
      oldDelegate.pitchDeg != pitchDeg || oldDelegate.rollDeg != rollDeg || oldDelegate.brightness != brightness;
}
