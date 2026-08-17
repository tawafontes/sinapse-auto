import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'altitude_extremes.dart';

const _greenZone = Color(0xFF4CAF50);
const _amberZone = Color(0xFFFFC107);
const _redZone = Color(0xFFF44336);

typedef _ZoneStyle = ({Color green, Color amber, Color red, double alpha});

/// Colors/opacity for the dial's translucent zone rings, tuned per
/// brightness: a fixed alpha blended over a near-black dark-theme
/// background reads as dim, muddy brown/olive instead of green/amber/red,
/// so dark mode gets lighter tones and a higher alpha to compensate.
_ZoneStyle _zoneStyleFor(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return (
      green: const Color(0xFF81C784),
      amber: const Color(0xFFFFCA28),
      red: const Color(0xFFE57373),
      alpha: 0.4,
    );
  }
  return (green: _greenZone, amber: _amberZone, red: _redZone, alpha: 0.22);
}

/// G-force meter: a dial with concentric green/amber/red intensity zones and
/// a dot for the current lateral/longitudinal offset (normalized to -1..1),
/// trailing a 5-second fading line behind it; beside it, a vertical
/// "thermometer" bar covers the one axis the dial doesn't (vertical G —
/// bumps, dips, jumps); below both, a bar tracks the current magnitude
/// against the recorded peak, with the current reading and the peak badge as
/// a mirrored pair underneath. Every peak/extreme survives app restarts (see
/// [initialMaxMagnitude]/[onMaxMagnitudeChanged],
/// [initialVerticalGMin]/[initialVerticalGMax]/[onVerticalGExtremesChanged])
/// — long-press resets all of them together to the current reading.
///
/// Stateful (not a plain `StreamBuilder`) because the trail and peaks are
/// accumulated history, not just the latest sample.
class GForceMeter extends StatefulWidget {
  const GForceMeter({
    super.key,
    required this.offsetStream,
    required this.magnitudeStream,
    required this.verticalStream,
    this.initialMaxMagnitude,
    this.onMaxMagnitudeChanged,
    this.initialVerticalGMin,
    this.initialVerticalGMax,
    this.onVerticalGExtremesChanged,
    this.onResetRequested,
    this.onImmediateResetRequested,
  });

  final Stream<Offset> offsetStream;
  final Stream<double> magnitudeStream;

  /// Vertical (up/down) G — feeds the vertical thermometer bar. This is the
  /// one component [offsetStream] doesn't cover (that one's lateral/
  /// longitudinal only). Already corrected for the current mount
  /// orientation by the stream's source (see
  /// `DashboardSensorStreams.gForceVertical`) — this widget has no
  /// orientation awareness of its own.
  final Stream<double> verticalStream;

  /// Peak magnitude to start from — the caller's responsibility to source
  /// (e.g. from Hive), so this widget stays unaware of persistence itself.
  /// Null (the default) starts the peak at the first live reading, same as
  /// before this became persistable.
  final double? initialMaxMagnitude;

  /// Called with the new peak every time it increases, and once more after
  /// a reset — the caller's hook for persisting it.
  final ValueChanged<double>? onMaxMagnitudeChanged;

  /// Deepest dip / highest lift to start from — same sourcing contract as
  /// [initialMaxMagnitude]. Null starts both at the first live reading.
  final double? initialVerticalGMin;
  final double? initialVerticalGMax;

  /// Called with the new (min, max) pair whenever either extreme changes,
  /// and once more after a reset.
  final void Function(double min, double max)? onVerticalGExtremesChanged;

  /// Called once, in `initState`, with a tear-off of this widget's own
  /// reset-confirmation dialog — the dashboard tile's long-press menu uses
  /// this to trigger "Resetar registros" without needing to know this is a
  /// G-force meter specifically. A tear-off of an instance method always
  /// resolves against the live `State`, so it stays correct across rebuilds
  /// without re-registering.
  final ValueChanged<VoidCallback>? onResetRequested;

  /// Called once, in `initState`, with a tear-off of the bare reset logic
  /// (no confirmation dialog) — see [LineChart.onImmediateResetRequested]
  /// for the full rationale (same pattern, shared across all three sensor
  /// widgets with a resettable record).
  final ValueChanged<VoidCallback>? onImmediateResetRequested;

  @override
  State<GForceMeter> createState() => _GForceMeterState();
}

typedef _TrailPoint = ({Offset offset, DateTime timestamp});

class _GForceMeterState extends State<GForceMeter> {
  static const _trailDuration = Duration(seconds: 5);
  static const _barMaxG = 2.0;

  // The dot itself (_offset) redraws on every single emission, however fast
  // the accelerometer delivers — that's the whole point of the sample-rate
  // fix this widget's data source now gets (see SensorService's doc
  // comment). The trail (a 5-second fading ghost of recent positions) is a
  // different concern: it doesn't need one point per sample to look smooth
  // (a handful of points per second is visually indistinguishable from
  // one per sample, since each is just a short straight segment), so its
  // own accumulation is decimated to _trailMinInterval independently of the
  // stream's actual emission rate — avoiding an unbounded, wasted 5-second
  // buffer of e.g. 250 points at 50Hz when ~50-100 already look identical.
  static const _trailMinInterval = Duration(milliseconds: 50);

  StreamSubscription<Offset>? _offsetSub;
  StreamSubscription<double>? _magnitudeSub;
  StreamSubscription<double>? _verticalSub;
  final List<_TrailPoint> _trail = [];
  DateTime? _lastTrailPointAt;
  Offset _offset = Offset.zero;
  double _magnitude = 0;
  double _maxMagnitude = 0;
  double _verticalG = 0;
  double? _verticalGMin;
  double? _verticalGMax;

  @override
  void initState() {
    super.initState();
    _maxMagnitude = widget.initialMaxMagnitude ?? 0.0;
    _verticalGMin = widget.initialVerticalGMin;
    _verticalGMax = widget.initialVerticalGMax;
    _listenOffset(widget.offsetStream);
    _listenMagnitude(widget.magnitudeStream);
    _listenVertical(widget.verticalStream);
    widget.onResetRequested?.call(_confirmResetMax);
    widget.onImmediateResetRequested?.call(_performResetMax);
  }

  @override
  void didUpdateWidget(covariant GForceMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    // DashboardSensorStreams's streams are memoized (stable identity for
    // the life of the dashboard session), so in practice these streams
    // rarely if ever change under an existing GForceMeter instance — this
    // guards the general StreamBuilder-like contract (never assume a
    // widget's stream parameter is immutable) rather than a scenario that
    // currently happens. _trail/_maxMagnitude/_verticalGMin/_verticalGMax
    // live on State, so they're untouched by this.
    if (oldWidget.offsetStream != widget.offsetStream) {
      _listenOffset(widget.offsetStream);
    }
    if (oldWidget.magnitudeStream != widget.magnitudeStream) {
      _listenMagnitude(widget.magnitudeStream);
    }
    if (oldWidget.verticalStream != widget.verticalStream) {
      _listenVertical(widget.verticalStream);
    }
  }

  void _listenOffset(Stream<Offset> stream) {
    unawaited(_offsetSub?.cancel());
    _offsetSub = stream.listen((value) {
      final now = DateTime.now();
      setState(() {
        _offset = value;
        final lastTrailPointAt = _lastTrailPointAt;
        if (lastTrailPointAt == null || now.difference(lastTrailPointAt) >= _trailMinInterval) {
          _lastTrailPointAt = now;
          _trail.add((offset: value, timestamp: now));
          _trail.removeWhere((p) => now.difference(p.timestamp) > _trailDuration);
        }
      });
    });
  }

  void _listenMagnitude(Stream<double> stream) {
    unawaited(_magnitudeSub?.cancel());
    _magnitudeSub = stream.listen((value) {
      setState(() {
        _magnitude = value;
        if (value > _maxMagnitude) {
          _maxMagnitude = value;
          widget.onMaxMagnitudeChanged?.call(_maxMagnitude);
        }
      });
    });
  }

  void _listenVertical(Stream<double> stream) {
    unawaited(_verticalSub?.cancel());
    _verticalSub = stream.listen((value) {
      setState(() {
        _verticalG = value;
        final newMin = _verticalGMin == null ? value : math.min(_verticalGMin!, value);
        final newMax = _verticalGMax == null ? value : math.max(_verticalGMax!, value);
        if (newMin != _verticalGMin || newMax != _verticalGMax) {
          _verticalGMin = newMin;
          _verticalGMax = newMax;
          widget.onVerticalGExtremesChanged?.call(newMin, newMax);
        }
      });
    });
  }

  @override
  void dispose() {
    unawaited(_offsetSub?.cancel());
    unawaited(_magnitudeSub?.cancel());
    unawaited(_verticalSub?.cancel());
    super.dispose();
  }

  Future<void> _confirmResetMax() async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resetar força G máxima?'),
        content: const Text(
          'Os valores máximos registrados (incluindo a força vertical) serão substituídos pela leitura atual.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Resetar força G máxima'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _performResetMax();
    }
  }

  /// The actual reset logic, with no confirmation dialog of its own — see
  /// [GForceMeter.onImmediateResetRequested].
  void _performResetMax() {
    setState(() {
      _maxMagnitude = _magnitude;
      _verticalGMin = _verticalG;
      _verticalGMax = _verticalG;
    });
    widget.onMaxMagnitudeChanged?.call(_maxMagnitude);
    widget.onVerticalGExtremesChanged?.call(_verticalGMin!, _verticalGMax!);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: CustomPaint(
                  painter: _GForcePainter(
                    offset: _offset,
                    trail: _trail,
                    now: DateTime.now(),
                    ringColor: colorScheme.outlineVariant,
                    dotColor: colorScheme.onSurface,
                    zoneStyle: _zoneStyleFor(brightness),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 12,
                child: _VerticalGBar(
                  value: _verticalG,
                  peakUp: _verticalGMax,
                  peakDown: _verticalGMin,
                  maxG: _barMaxG,
                  style: altitudeExtremeStyleFor(brightness),
                  trackColor: colorScheme.outlineVariant.withValues(alpha: 0.25),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _GForceBar(magnitude: _magnitude, maxMagnitude: _maxMagnitude, maxG: _barMaxG),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Mirrors the MÁX badge on the opposite side, but plain — it's
            // the current reading, not a record, so it doesn't get the
            // same filled treatment.
            Text(
              '${_magnitude.toStringAsFixed(1)}G',
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: _redZone, borderRadius: BorderRadius.circular(4)),
              child: Text(
                'MÁX ${_maxMagnitude.toStringAsFixed(1)}G',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Vertical "thermometer" bar for vertical G (bumps/dips/jumps): the center
/// is 0G, fill grows up from center for a positive (lift) reading and down
/// from center for a negative (dip/compression) one, colored via [style] —
/// the same blue-is-higher/red-is-lower convention the altitude widget uses
/// ([AltitudeExtremeStyle]). Thin lines mark 0G and the peak recorded so far
/// in each direction ([peakUp]/[peakDown]).
class _VerticalGBar extends StatelessWidget {
  const _VerticalGBar({
    required this.value,
    required this.peakUp,
    required this.peakDown,
    required this.maxG,
    required this.style,
    required this.trackColor,
  });

  final double value;
  final double? peakUp;
  final double? peakDown;
  final double maxG;
  final AltitudeExtremeStyle style;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final center = height / 2;
        double yFor(double g) => (center - (g / maxG).clamp(-1.0, 1.0) * center).clamp(0.0, height);

        final valueY = yFor(value);
        final fillTop = value >= 0 ? valueY : center;
        final fillHeight = (center - valueY).abs();

        Widget tick(double g, Color color) => Positioned(
          top: (yFor(g) - 1).clamp(0.0, math.max(height - 2, 0.0)),
          left: -3,
          right: -3,
          child: Container(height: 2, color: color),
        );

        return Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Stack(
                children: [
                  Positioned.fill(child: Container(color: trackColor)),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: fillTop,
                    height: fillHeight,
                    child: Container(color: value >= 0 ? style.max : style.min),
                  ),
                ],
              ),
            ),
            // 0G center line.
            Positioned(
              left: -3,
              right: -3,
              top: center - 0.75,
              child: Container(height: 1.5, color: Colors.black.withValues(alpha: 0.4)),
            ),
            if (peakUp != null) tick(peakUp!, style.max),
            if (peakDown != null) tick(peakDown!, style.min),
          ],
        );
      },
    );
  }
}

/// Horizontal green→amber→red gradient track with a thin marker at the
/// current magnitude and a small flag at this session's peak.
class _GForceBar extends StatelessWidget {
  const _GForceBar({required this.magnitude, required this.maxMagnitude, required this.maxG});

  final double magnitude;
  final double maxMagnitude;
  final double maxG;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 10,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final currentX = (magnitude / maxG).clamp(0.0, 1.0) * width;
          final maxX = (maxMagnitude / maxG).clamp(0.0, 1.0) * width;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  gradient: const LinearGradient(colors: [_greenZone, _amberZone, _redZone]),
                ),
              ),
              Positioned(
                left: (currentX - 1).clamp(0.0, math.max(width - 2, 0.0)),
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: colorScheme.onSurface),
              ),
              Positioned(
                left: (maxX - 8).clamp(0.0, math.max(width - 16, 0.0)),
                top: -10,
                child: const Icon(Icons.arrow_drop_down, size: 16, color: _redZone),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GForcePainter extends CustomPainter {
  _GForcePainter({
    required this.offset,
    required this.trail,
    required this.now,
    required this.ringColor,
    required this.dotColor,
    required this.zoneStyle,
  });

  final Offset offset;
  final List<_TrailPoint> trail;
  final DateTime now;
  final Color ringColor;
  final Color dotColor;
  final _ZoneStyle zoneStyle;

  static const _trailDurationMs = 5000;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 8;

    // Concentric intensity markers: thin, translucent rings — not filled
    // discs — so most of the dial's interior still shows the card
    // background; the colors are a scale reference, not the dominant
    // visual element.
    final ringThickness = radius * 0.2;
    _paintZoneRing(canvas, center, radius * 0.43, ringThickness, zoneStyle.green);
    _paintZoneRing(canvas, center, radius * 0.68, ringThickness, zoneStyle.amber);
    _paintZoneRing(canvas, center, radius * 0.93, ringThickness, zoneStyle.red);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    _paintTrail(canvas, center, radius);

    final clamped = Offset(offset.dx.clamp(-1.0, 1.0), offset.dy.clamp(-1.0, 1.0));
    final dotCenter = center + Offset(clamped.dx * radius, clamped.dy * radius);
    canvas.drawCircle(dotCenter, radius * 0.09, Paint()..color = dotColor);
  }

  void _paintZoneRing(Canvas canvas, Offset center, double ringRadius, double thickness, Color color) {
    canvas.drawCircle(
      center,
      ringRadius,
      Paint()
        ..color = color.withValues(alpha: zoneStyle.alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness,
    );
  }

  void _paintTrail(Canvas canvas, Offset center, double radius) {
    if (trail.length < 2) return;
    final points = [
      for (final p in trail)
        center +
            Offset(
              p.offset.dx.clamp(-1.0, 1.0) * radius,
              p.offset.dy.clamp(-1.0, 1.0) * radius,
            ),
    ];

    // Two passes over the same segments: a wide, translucent "halo" first,
    // then a thin, more opaque line on top — both fading with age.
    for (final pass in [(width: 8.0, alpha: 0.18), (width: 2.0, alpha: 0.55)]) {
      for (var i = 1; i < points.length; i++) {
        final ageMs = now.difference(trail[i].timestamp).inMilliseconds;
        final fade = (1 - ageMs / _trailDurationMs).clamp(0.0, 1.0);
        if (fade <= 0) continue;
        final paint = Paint()
          ..color = dotColor.withValues(alpha: pass.alpha * fade)
          ..strokeWidth = pass.width
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(points[i - 1], points[i], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GForcePainter oldDelegate) => true;
}
