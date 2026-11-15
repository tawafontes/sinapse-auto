import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The OBD cards' drawing kit (owner request, 2026-11-15: the first panels
/// were "small text in a box"): colour scales that go green → orange → red,
/// an arc gauge, a scale bar and a sparkline. Pure painting,
/// no packages.

const obdGreen = Color(0xFF43A047);
const obdOrange = Color(0xFFFB8C00);
const obdRed = Color(0xFFE53935);
const obdBlue = Color(0xFF1E88E5);

/// A colour scale: (value, colour) pairs in increasing value; between two
/// stops the colour blends.
typedef ObdColorStop = (double, Color);

Color obdColorAt(List<ObdColorStop> stops, double v) {
  if (v <= stops.first.$1) return stops.first.$2;
  for (var i = 1; i < stops.length; i++) {
    final (b, cb) = stops[i];
    if (v <= b) {
      final (a, ca) = stops[i - 1];
      return Color.lerp(ca, cb, b == a ? 1 : (v - a) / (b - a))!;
    }
  }
  return stops.last.$2;
}

/// The scales the cards use, in the value's own unit.
abstract final class ObdScales {
  /// Tank %: red near empty, orange on reserve, green from a quarter up.
  static const fuel = <ObdColorStop>[(0, obdRed), (12, obdRed), (25, obdOrange), (40, obdGreen), (100, obdGreen)];

  /// Coolant °C: blue cold, green at working temperature, red overheating.
  static const coolant = <ObdColorStop>[(40, obdBlue), (65, obdBlue), (80, obdGreen), (104, obdGreen), (110, obdOrange), (118, obdRed)];

  /// Intake air °C: heat soak shows as orange/red.
  static const intake = <ObdColorStop>[(-10, obdBlue), (5, obdGreen), (45, obdGreen), (60, obdOrange), (75, obdRed)];

  /// Ambient °C.
  static const ambient = <ObdColorStop>[(-10, obdBlue), (10, obdBlue), (18, obdGreen), (32, obdGreen), (38, obdOrange), (45, obdRed)];

  /// Catalyst °C: cold (not yet working) blue, working green, hot red.
  static const catalyst = <ObdColorStop>[(0, obdBlue), (250, obdBlue), (400, obdGreen), (800, obdGreen), (900, obdOrange), (1000, obdRed)];

  /// Engine load and pedal %.
  static const load = <ObdColorStop>[(0, obdGreen), (55, obdGreen), (75, obdOrange), (95, obdRed)];

  /// Intake manifold kPa: vacuum (light load) green, near atmospheric orange,
  /// boost red.
  static const manifold = <ObdColorStop>[(20, obdGreen), (60, obdGreen), (95, obdOrange), (130, obdRed)];

  /// 12 V system volts.
  static const battery = <ObdColorStop>[(10.5, obdRed), (11.8, obdRed), (12.2, obdOrange), (12.4, obdGreen), (14.8, obdGreen), (15.2, obdOrange), (15.8, obdRed)];
}

/// A horizontal (or vertical) bar on a colour scale: the whole scale faint,
/// the part up to the value solid, a marker at the value.
class ObdScaleBar extends StatelessWidget {
  const ObdScaleBar({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.stops,
    this.thickness = 10,
    this.vertical = false,
    this.dimmed = false,
  });

  final double? value;
  final double min;
  final double max;
  final List<ObdColorStop> stops;
  final double thickness;
  final bool vertical;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    return SizedBox(
      width: vertical ? thickness : double.infinity,
      height: vertical ? double.infinity : thickness,
      child: CustomPaint(
        painter: _ScaleBarPainter(value: value, min: min, max: max, stops: stops, vertical: vertical, dimmed: dimmed, track: track),
      ),
    );
  }
}

class _ScaleBarPainter extends CustomPainter {
  _ScaleBarPainter({required this.value, required this.min, required this.max, required this.stops, required this.vertical, required this.dimmed, required this.track});

  final double? value;
  final double min;
  final double max;
  final List<ObdColorStop> stops;
  final bool vertical;
  final bool dimmed;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final length = vertical ? size.height : size.width;
    final thick = vertical ? size.width : size.height;
    final radius = Radius.circular(thick / 2);
    final whole = RRect.fromRectAndRadius(Offset.zero & size, radius);
    final positions = [for (final s in stops) ((s.$1 - min) / (max - min)).clamp(0.0, 1.0)];
    final gradient = LinearGradient(
      begin: vertical ? Alignment.bottomCenter : Alignment.centerLeft,
      end: vertical ? Alignment.topCenter : Alignment.centerRight,
      colors: [for (final s in stops) s.$2],
      stops: positions,
    );
    canvas.drawRRect(whole, Paint()..color = track);
    canvas.drawRRect(whole, Paint()..shader = gradient.createShader(Offset.zero & size)..color = Colors.black.withValues(alpha: 0.3));
    final v = value;
    if (v == null) return;
    final f = ((v - min) / (max - min)).clamp(0.0, 1.0);
    final filled = vertical ? Rect.fromLTWH(0, size.height * (1 - f), size.width, size.height * f) : Rect.fromLTWH(0, 0, size.width * f, size.height);
    canvas.save();
    canvas.clipRRect(whole);
    canvas.drawRect(filled, Paint()..shader = gradient.createShader(Offset.zero & size)..color = Colors.black.withValues(alpha: dimmed ? 0.4 : 1));
    canvas.restore();
    // The marker: a white-edged dot at the value.
    final at = length * f;
    final c = vertical ? Offset(size.width / 2, size.height - at) : Offset(at, size.height / 2);
    final markerColor = obdColorAt(stops, v);
    canvas.drawCircle(c, thick * 0.75, Paint()..color = Colors.white);
    canvas.drawCircle(c, thick * 0.55, Paint()..color = dimmed ? markerColor.withValues(alpha: 0.5) : markerColor);
  }

  @override
  bool shouldRepaint(_ScaleBarPainter old) => old.value != value || old.dimmed != dimmed || old.track != track || old.min != min || old.max != max;
}

/// A 240° arc gauge on a colour scale, with the needle and [child] (the
/// number) in the middle — the tank and the engine load.
class ObdArcGauge extends StatelessWidget {
  const ObdArcGauge({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.stops,
    required this.child,
    this.ticks = 4,
    this.startLabel,
    this.endLabel,
    this.dimmed = false,
  });

  final double? value;
  final double min;
  final double max;
  final List<ObdColorStop> stops;
  final Widget child;
  final int ticks;
  final String? startLabel;
  final String? endLabel;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _ArcGaugePainter(
          value: value,
          min: min,
          max: max,
          stops: stops,
          ticks: ticks,
          dimmed: dimmed,
          track: theme.colorScheme.surfaceContainerHighest,
          needle: theme.colorScheme.onSurface,
        ),
        child: Stack(
          children: [
            Center(child: FractionallySizedBox(widthFactor: 0.62, heightFactor: 0.5, child: FittedBox(child: child))),
            if (startLabel != null || endLabel != null)
              Align(
                alignment: const Alignment(0, 0.92),
                child: FractionallySizedBox(
                  widthFactor: 0.62,
                  heightFactor: 0.14,
                  child: FittedBox(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(startLabel ?? '', style: theme.textTheme.labelLarge?.copyWith(color: obdColorAt(stops, min), fontWeight: FontWeight.w700)),
                        const SizedBox(width: 48),
                        Text(endLabel ?? '', style: theme.textTheme.labelLarge?.copyWith(color: obdColorAt(stops, max), fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ArcGaugePainter extends CustomPainter {
  _ArcGaugePainter({
    required this.value,
    required this.min,
    required this.max,
    required this.stops,
    required this.ticks,
    required this.dimmed,
    required this.track,
    required this.needle,
  });

  final double? value;
  final double min;
  final double max;
  final List<ObdColorStop> stops;
  final int ticks;
  final bool dimmed;
  final Color track;
  final Color needle;

  static const _start = math.pi * 5 / 6;
  static const _sweep = math.pi * 4 / 3;
  static const _segments = 72;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 * 0.88;
    final stroke = radius * 0.16;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final f = value == null ? 0.0 : ((value! - min) / (max - min)).clamp(0.0, 1.0);

    canvas.drawArc(rect, _start, _sweep, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke);
    // The scale, faint all along and solid up to the value, drawn in short
    // segments so each takes its own colour.
    final seg = _sweep / _segments;
    for (var i = 0; i < _segments; i++) {
      final mid = (i + 0.5) / _segments;
      final color = obdColorAt(stops, min + (max - min) * mid);
      final lit = value != null && mid <= f;
      canvas.drawArc(
        rect,
        _start + seg * i,
        seg * 1.04,
        false,
        Paint()
          ..color = color.withValues(alpha: lit ? (dimmed ? 0.45 : 1) : 0.22)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
    }
    final tick = Paint()
      ..color = needle.withValues(alpha: 0.45)
      ..strokeWidth = stroke * 0.14;
    for (var i = 0; i <= ticks; i++) {
      final a = _start + _sweep * i / ticks;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + dir * (radius - stroke * 0.7), center + dir * (radius - stroke * 1.25), tick);
    }
    if (value == null) return;
    final a = _start + _sweep * f;
    final dir = Offset(math.cos(a), math.sin(a));
    final tip = center + dir * radius;
    canvas.drawCircle(tip, stroke * 0.72, Paint()..color = Colors.white);
    canvas.drawCircle(tip, stroke * 0.52, Paint()..color = obdColorAt(stops, value!).withValues(alpha: dimmed ? 0.5 : 1));
  }

  @override
  bool shouldRepaint(_ArcGaugePainter old) => old.value != value || old.dimmed != dimmed || old.track != track || old.needle != needle;
}

/// A small line chart over a time window: area under the line shaded, the
/// newest point marked. [points] are (seconds before now, value).
class ObdSparkline extends StatelessWidget {
  const ObdSparkline({super.key, required this.points, required this.window, this.color, this.minTop = 1});

  final List<(double, double)> points;
  final double window;
  final Color? color;

  /// The chart's top is at least this, so an idling engine does not fill it.
  final double minTop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomPaint(
      key: const ValueKey('obdSparkline'),
      painter: _SparklinePainter(
        points: points,
        window: window,
        color: color ?? theme.colorScheme.primary,
        grid: theme.colorScheme.outlineVariant,
        minTop: minTop,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.points, required this.window, required this.color, required this.grid, required this.minTop});

  final List<(double, double)> points;
  final double window;
  final Color color;
  final Color grid;
  final double minTop;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      final y = size.height * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint..color = grid.withValues(alpha: f == 1 ? 0.9 : 0.4));
    }
    if (points.length < 2) return;
    final top = math.max(minTop, points.map((p) => p.$2).reduce(math.max) * 1.15);
    Offset at((double, double) p) => Offset(size.width * (1 - (p.$1 / window).clamp(0.0, 1.0)), size.height * (1 - (p.$2 / top).clamp(0.0, 1.0)));
    final line = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      final o = at(p);
      line.lineTo(o.dx, o.dy);
    }
    final area = Path.from(line)
      ..lineTo(at(points.last).dx, size.height)
      ..lineTo(at(points.first).dx, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round,
    );
    final last = at(points.last);
    canvas.drawCircle(last, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => true;
}
