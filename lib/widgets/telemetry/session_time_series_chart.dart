import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/driving_session_event.dart';
import '../../models/driving_session_sample.dart';
import 'decimate.dart';

/// Time-series chart of one signal (speed, altitude, longitudinal/lateral
/// acceleration, pitch, roll) across a driving session, plotted against
/// each sample's own real [DrivingSessionSample.timestamp] — never assumed
/// evenly spaced, unlike the dashboard's live rolling `LineChart`. Pan/zoom
/// is provided by the official [InteractiveViewer] widget (reused, not a
/// hand-rolled gesture implementation); tapping a point shows its exact
/// value, elapsed time, and — since every [DrivingSessionSample] is a
/// single time-aligned snapshot — whichever other signals that same sample
/// also carries (Fase 12 §10/§19/§23's "sincronização temporal": one shared
/// per-sample readout instead of independently-scrolling charts).
///
/// Downsamples to [_maxRenderedPoints] via [minMaxBucketIndices] (not a
/// plain stride) before painting — an hour-long session at 1Hz is 3600
/// samples, far more path segments than this chart's own pixel width could
/// ever meaningfully distinguish, but a plain stride can silently skip
/// straight past the signal's real peak or trough. Bucketed min/max
/// selection keeps every rendered chart honest about the session's true
/// extremes (Fase 12 §18/§29/§47) — and [highlightMaxValue]/
/// [highlightAverageValue] are supplied by the caller from the
/// *undecimated* session summary for the same reason: the true peak must
/// never depend on which points survived downsampling.
class SessionTimeSeriesChart extends StatefulWidget {
  const SessionTimeSeriesChart({
    super.key,
    required this.samples,
    required this.valueOf,
    required this.unit,
    required this.color,
    this.events = const [],
    this.highlightMaxValue,
    this.highlightMaxLabel = 'MÁX',
    this.highlightAverageValue,
    this.highlightAverageLabel = 'MÉD',
    this.initialSelectedTimestamp,
  });

  final List<DrivingSessionSample> samples;

  /// Extracts the signal this chart plots from one sample — null where
  /// that sample has no reading for it (gap in the line, not a false 0).
  final double? Function(DrivingSessionSample) valueOf;
  final String unit;
  final Color color;

  /// Session events to mark along the time axis (Fase 12 §21) — drawn
  /// regardless of which signal is plotted, since every event shares the
  /// same session timeline. Empty by default, so existing call sites are
  /// unaffected.
  final List<DrivingSessionEvent> events;

  /// The true session-wide maximum for this signal, already in whatever
  /// unit [unit] labels — drawn as a reference marker (Fase 12 §9),
  /// mirroring the dashboard `LineChart`'s own MÁX badge. Supplied by the
  /// caller rather than recomputed here, specifically so it reflects the
  /// full session rather than whatever survived downsampling.
  final double? highlightMaxValue;
  final String highlightMaxLabel;

  /// Same contract as [highlightMaxValue], for the session average.
  final double? highlightAverageValue;
  final String highlightAverageLabel;

  /// Pre-selects the point nearest this timestamp once, when the widget is
  /// first built or when this changes to a new non-null value — the hook
  /// `SessionDetailScreen` uses to jump a chart to a tapped event's instant
  /// (Fase 12 §21) without this widget needing to know anything about
  /// events or tabs itself.
  final DateTime? initialSelectedTimestamp;

  @override
  State<SessionTimeSeriesChart> createState() => _SessionTimeSeriesChartState();
}

class _SessionTimeSeriesChartState extends State<SessionTimeSeriesChart> {
  static const _maxRenderedPoints = 300;

  int? _selectedIndex;
  late List<ChartPoint> _points;
  late List<double> _eventElapsedSeconds;

  @override
  void initState() {
    super.initState();
    _points = _buildPoints();
    _eventElapsedSeconds = _buildEventElapsedSeconds();
    _selectedIndex = _indexNearestTimestamp(widget.initialSelectedTimestamp);
  }

  @override
  void didUpdateWidget(covariant SessionTimeSeriesChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.samples != widget.samples) {
      _points = _buildPoints();
      _selectedIndex = null;
    }
    if (oldWidget.events != widget.events || oldWidget.samples != widget.samples) {
      _eventElapsedSeconds = _buildEventElapsedSeconds();
    }
    final target = widget.initialSelectedTimestamp;
    if (target != null && target != oldWidget.initialSelectedTimestamp) {
      final index = _indexNearestTimestamp(target);
      if (index != null) _selectedIndex = index;
    }
  }

  List<ChartPoint> _buildPoints() {
    if (widget.samples.isEmpty) return const [];
    final indices = minMaxBucketIndices(
      widget.samples.length,
      maxPoints: _maxRenderedPoints,
      valueOf: (i) => widget.valueOf(widget.samples[i]),
    );
    final start = widget.samples.first.timestamp;
    return indices.map((i) {
      final s = widget.samples[i];
      return ChartPoint(elapsedSeconds: s.timestamp.difference(start).inMilliseconds / 1000.0, value: widget.valueOf(s), sample: s);
    }).toList();
  }

  List<double> _buildEventElapsedSeconds() {
    if (widget.samples.isEmpty || widget.events.isEmpty) return const [];
    final start = widget.samples.first.timestamp;
    return widget.events.map((e) => e.timestamp.difference(start).inMilliseconds / 1000.0).toList();
  }

  int? _indexNearestTimestamp(DateTime? timestamp) {
    if (timestamp == null || widget.samples.isEmpty || _points.isEmpty) return null;
    final start = widget.samples.first.timestamp;
    final targetSeconds = timestamp.difference(start).inMilliseconds / 1000.0;
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < _points.length; i++) {
      final distance = (_points[i].elapsedSeconds - targetSeconds).abs();
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    return nearest;
  }

  void _handleTapUp(TapUpDetails details, Size size) {
    if (_points.isEmpty) return;
    final layout = computeChartLayout(_points, size: size);
    if (layout == null) return;
    final tappedSeconds =
        layout.xMin + (details.localPosition.dx / size.width) * (layout.xMax - layout.xMin);
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < _points.length; i++) {
      final distance = (_points[i].elapsedSeconds - tappedSeconds).abs();
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    setState(() => _selectedIndex = nearest);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedIndex == null || _selectedIndex! >= _points.length ? null : _points[_selectedIndex!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selected != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_readoutText(selected), style: TextStyle(fontWeight: FontWeight.bold, color: widget.color)),
          ),
        SizedBox(
          height: 180,
          child: _points.length < 2
              ? const Center(child: Text('Dados insuficientes para exibir o gráfico.'))
              : InteractiveViewer(
                  maxScale: 8,
                  minScale: 1,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = Size(constraints.maxWidth, constraints.maxHeight);
                      return GestureDetector(
                        onTapUp: (details) => _handleTapUp(details, size),
                        child: CustomPaint(
                          size: size,
                          painter: _TimeSeriesPainter(
                            points: _points,
                            color: widget.color,
                            selectedIndex: _selectedIndex,
                            eventElapsedSeconds: _eventElapsedSeconds,
                            maxValue: widget.highlightMaxValue,
                            maxLabel: widget.highlightMaxLabel,
                            averageValue: widget.highlightAverageValue,
                            averageLabel: widget.highlightAverageLabel,
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// Elapsed time + this chart's own value + (Fase 12 §10/§23) whatever
  /// correlated speed/altitude/G-force the same underlying sample carries —
  /// heading is deliberately never shown here: it isn't one of the fields
  /// `DrivingSessionRecorder` stores per-sample (only the session's
  /// initial/final heading is), and this screen never invents a value it
  /// doesn't actually have (Fase 12 §35/§70).
  String _readoutText(ChartPoint point) {
    final parts = <String>[
      '${point.elapsedSeconds.toStringAsFixed(0)}s',
      point.value == null ? '—' : '${point.value!.toStringAsFixed(1)} ${widget.unit}',
    ];
    final sample = point.sample;
    if (sample != null) {
      if (sample.speedKmh != null) parts.add('${sample.speedKmh!.toStringAsFixed(0)} km/h');
      if (sample.altitudeMeters != null) parts.add('${sample.altitudeMeters!.toStringAsFixed(0)} m');
      final resultantG = resultantGForSample(sample);
      if (resultantG != null) parts.add('${resultantG.toStringAsFixed(2)} g');
    }
    return parts.join(' · ');
  }
}

/// Vector magnitude of whatever axes [sample] actually has a reading for —
/// null only when none of the three do, matching this codebase's
/// established "absent axis contributes 0, total absence is null"
/// convention (see `TelemetrySnapshot.gForceMagnitude`'s own computation).
@visibleForTesting
double? resultantGForSample(DrivingSessionSample sample) {
  final long = sample.longitudinalG;
  final lat = sample.lateralG;
  final vert = sample.verticalG;
  if (long == null && lat == null && vert == null) return null;
  final sumSquares = (long ?? 0) * (long ?? 0) + (lat ?? 0) * (lat ?? 0) + (vert ?? 0) * (vert ?? 0);
  return math.sqrt(sumSquares);
}

/// One plotted (elapsed time, value) pair — public (not private) since
/// [computeChartLayout] is a testing seam external test files call directly.
/// [sample] (optional, defaults to null so existing test call sites that
/// construct a bare point keep working unchanged) carries the originating
/// [DrivingSessionSample], the hook the tap readout uses to show correlated
/// signals from the exact same instant.
@visibleForTesting
class ChartPoint {
  const ChartPoint({required this.elapsedSeconds, required this.value, this.sample});
  final double elapsedSeconds;
  final double? value;
  final DrivingSessionSample? sample;
}

/// Pure layout math — the value range and time range a [_TimeSeriesPainter]
/// (or the tap-to-select handler, which needs the same time axis mapping)
/// needs. Pulled out so the coordinate mapping itself is independently
/// testable. `null` when there's nothing plottable (no point has a
/// non-null value).
@visibleForTesting
class ChartLayout {
  const ChartLayout({required this.xMin, required this.xMax, required this.yMin, required this.yMax});
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
}

@visibleForTesting
ChartLayout? computeChartLayout(List<ChartPoint> points, {required Size size}) {
  if (points.isEmpty) return null;
  final xMin = points.first.elapsedSeconds;
  final xMax = points.last.elapsedSeconds;
  final values = points.map((p) => p.value).whereType<double>().toList();
  if (values.isEmpty) return null;
  var yMin = values.reduce((a, b) => a < b ? a : b);
  var yMax = values.reduce((a, b) => a > b ? a : b);
  if ((yMax - yMin).abs() < 1e-9) {
    // A perfectly flat signal still needs a non-zero range to divide by —
    // pad symmetrically so the flat line renders centered, not at an edge.
    yMin -= 1;
    yMax += 1;
  }
  return ChartLayout(xMin: xMin, xMax: xMax == xMin ? xMin + 1 : xMax, yMin: yMin, yMax: yMax);
}

class _TimeSeriesPainter extends CustomPainter {
  _TimeSeriesPainter({
    required this.points,
    required this.color,
    required this.selectedIndex,
    required this.eventElapsedSeconds,
    required this.maxValue,
    required this.maxLabel,
    required this.averageValue,
    required this.averageLabel,
  });

  final List<ChartPoint> points;
  final Color color;
  final int? selectedIndex;
  final List<double> eventElapsedSeconds;
  final double? maxValue;
  final String maxLabel;
  final double? averageValue;
  final String averageLabel;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = computeChartLayout(points, size: size);
    if (layout == null) return;

    double xFor(double seconds) => (seconds - layout.xMin) / (layout.xMax - layout.xMin) * size.width;
    double yFor(double value) => size.height - (value - layout.yMin) / (layout.yMax - layout.yMin) * size.height;

    // Average reference line (Fase 12 §9), drawn first so the signal's own
    // curve (below) renders over it — same layering `LineChart` already
    // uses for its own reference lines.
    if (averageValue != null && averageValue! >= layout.yMin && averageValue! <= layout.yMax) {
      _drawDashedLine(canvas, size.width, yFor(averageValue!), color.withValues(alpha: 0.55));
      _paintText(canvas, '$averageLabel ${averageValue!.toStringAsFixed(0)}', Offset(4, yFor(averageValue!) - 13), color.withValues(alpha: 0.85));
    }

    // Built as separate sub-paths (not one continuous line) so a gap — a
    // sample with no reading for this signal — breaks the line instead of
    // drawing a misleading straight segment across the missing data.
    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final segments = <Path>[];
    Path? segment;
    for (final point in points) {
      if (point.value == null) {
        segment = null;
        continue;
      }
      final offset = Offset(xFor(point.elapsedSeconds), yFor(point.value!));
      if (segment == null) {
        segment = Path()..moveTo(offset.dx, offset.dy);
        segments.add(segment);
      } else {
        segment.lineTo(offset.dx, offset.dy);
      }
    }
    for (final s in segments) {
      canvas.drawPath(s, linePaint);
    }

    // Event markers (Fase 12 §21) — small ticks along the top edge,
    // independent of which signal is charted, since every event shares the
    // same session timeline.
    final eventPaint = Paint()..color = Colors.amber.shade800;
    for (final seconds in eventElapsedSeconds) {
      if (seconds < layout.xMin || seconds > layout.xMax) continue;
      final x = xFor(seconds);
      canvas.drawPath(
        Path()
          ..moveTo(x - 4, 0)
          ..lineTo(x + 4, 0)
          ..lineTo(x, 7)
          ..close(),
        eventPaint,
      );
    }

    // Peak marker (Fase 12 §9).
    if (maxValue != null && maxValue! >= layout.yMin && maxValue! <= layout.yMax) {
      final y = yFor(maxValue!);
      canvas.drawCircle(Offset(xFor(layout.xMax), y), 3.5, Paint()..color = color);
      _paintText(canvas, '$maxLabel ${maxValue!.toStringAsFixed(0)}', Offset(4, y - 13), color);
    }

    if (selectedIndex != null && selectedIndex! < points.length) {
      final selected = points[selectedIndex!];
      if (selected.value != null) {
        final offset = Offset(xFor(selected.elapsedSeconds), yFor(selected.value!));
        canvas.drawLine(Offset(offset.dx, 0), Offset(offset.dx, size.height), Paint()..color = color.withValues(alpha: 0.3));
        canvas.drawCircle(offset, 4, Paint()..color = color);
      }
    }
  }

  void _drawDashedLine(Canvas canvas, double width, double y, Color lineColor) {
    const dashWidth = 4.0;
    const dashGap = 3.0;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    var x = 0.0;
    while (x < width) {
      final end = math.min(x + dashWidth, width);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += dashWidth + dashGap;
    }
  }

  void _paintText(Canvas canvas, String text, Offset offset, Color textColor) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: textColor, fontSize: 10, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _TimeSeriesPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.eventElapsedSeconds != eventElapsedSeconds ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.averageValue != averageValue;
}
