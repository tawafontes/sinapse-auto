import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/driving_session_sample.dart';
import 'decimate.dart';

/// G-G diagram: every sample's longitudinal G (X — acceleration right of
/// center, braking left) plotted against its lateral G (Y — right turn
/// above center, left turn below), showing the combined longitudinal +
/// lateral force the vehicle experienced at each moment — the classic
/// "friction circle" visualization. Concentric rings at fixed g intervals
/// give a visual scale; the single point with the largest combined
/// magnitude is highlighted; tapping any point selects it (Fase 12 §19)
/// and shows its exact G components plus, when the originating sample has
/// them, its timestamp/speed/altitude.
///
/// Downsamples via [minMaxBucketIndices] on each point's magnitude before
/// painting (Fase 12 §18/§28) — a long session's G-G scatter can otherwise
/// mean thousands of circles redrawn on every frame, and a plain stride
/// downsample risks throwing away the exact peak this widget exists to
/// highlight. Bucketed min/max selection guarantees the true global peak
/// survives (it is, by construction, the max of whichever bucket it falls
/// in), so [indexOfPeakMagnitude] over the downsampled set still finds the
/// session's real most-extreme moment.
class GGDiagram extends StatefulWidget {
  const GGDiagram({super.key, required this.samples, this.ringIntervalG = 0.2, this.maxRingsG = 1.0, this.initialSelectedTimestamp});

  final List<DrivingSessionSample> samples;
  final double ringIntervalG;
  final double maxRingsG;

  /// Pre-selects the point nearest this timestamp once, when the widget is
  /// first built or when this changes to a new non-null value — the hook
  /// `SessionDetailScreen` uses to jump here from a tapped event (Fase 13
  /// §37: "evento → G-G"), mirroring `SessionTimeSeriesChart`'s own
  /// `initialSelectedTimestamp`.
  final DateTime? initialSelectedTimestamp;

  @override
  State<GGDiagram> createState() => _GGDiagramState();
}

class _GGDiagramState extends State<GGDiagram> {
  static const _maxRenderedPoints = 400;

  int? _selectedIndex;
  late List<Offset> _points;
  late List<DrivingSessionSample> _pointSamples;

  @override
  void initState() {
    super.initState();
    _rebuild();
    _selectedIndex = _indexNearestTimestamp(widget.initialSelectedTimestamp);
  }

  @override
  void didUpdateWidget(covariant GGDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.samples != widget.samples) {
      _rebuild();
      _selectedIndex = null;
    }
    final target = widget.initialSelectedTimestamp;
    if (target != null && target != oldWidget.initialSelectedTimestamp) {
      final index = _indexNearestTimestamp(target);
      if (index != null) _selectedIndex = index;
    }
  }

  void _rebuild() {
    final allPoints = ggPoints(widget.samples);
    final allSamples = ggSamples(widget.samples);
    final indices = minMaxBucketIndices(allPoints.length, maxPoints: _maxRenderedPoints, valueOf: (i) => allPoints[i].distance);
    _points = indices.map((i) => allPoints[i]).toList();
    _pointSamples = indices.map((i) => allSamples[i]).toList();
  }

  int? _indexNearestTimestamp(DateTime? timestamp) {
    if (timestamp == null || _pointSamples.isEmpty) return null;
    var nearest = 0;
    var nearestDistance = timestamp.difference(_pointSamples.first.timestamp).abs();
    for (var i = 1; i < _pointSamples.length; i++) {
      final distance = timestamp.difference(_pointSamples[i].timestamp).abs();
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    return nearest;
  }

  void _handleTapUp(TapUpDetails details, Size size) {
    if (_points.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final pixelsPerG = computeGGPixelsPerG(_points, maxRingsG: widget.maxRingsG, size: size);
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < _points.length; i++) {
      final canvasPoint = center + Offset(_points[i].dx * pixelsPerG, -_points[i].dy * pixelsPerG);
      final distance = (canvasPoint - details.localPosition).distance;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    setState(() => _selectedIndex = nearest);
  }

  String _readoutText(Offset point, DrivingSessionSample sample) {
    final parts = <String>[
      'Long ${point.dx.toStringAsFixed(2)} g',
      'Lat ${point.dy.toStringAsFixed(2)} g',
      'Resultante ${point.distance.toStringAsFixed(2)} g',
      _formatTime(sample.timestamp),
    ];
    if (sample.speedKmh != null) parts.add('${sample.speedKmh!.toStringAsFixed(0)} km/h');
    if (sample.altitudeMeters != null) parts.add('${sample.altitudeMeters!.toStringAsFixed(0)} m');
    return parts.join(' · ');
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (_points.isEmpty) {
      return const SizedBox(
        height: 220,
        child: Center(child: Text('Nenhum dado de aceleração registrado para esta sessão.')),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final selectedIndex = _selectedIndex != null && _selectedIndex! < _points.length ? _selectedIndex : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selectedIndex != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _readoutText(_points[selectedIndex], _pointSamples[selectedIndex]),
              style: TextStyle(fontWeight: FontWeight.bold, color: colorScheme.primary),
            ),
          ),
        AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              return GestureDetector(
                onTapUp: (details) => _handleTapUp(details, size),
                child: CustomPaint(
                  size: size,
                  painter: _GGDiagramPainter(
                    points: _points,
                    ringIntervalG: widget.ringIntervalG,
                    maxRingsG: widget.maxRingsG,
                    pointColor: colorScheme.primary,
                    peakColor: colorScheme.error,
                    selectedColor: colorScheme.tertiary,
                    gridColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    selectedIndex: selectedIndex,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Pure extraction: every sample with both longitudinal and lateral G
/// present, as (x: longitudinal, y: lateral) pairs — independently
/// unit-testable without a widget tree.
@visibleForTesting
List<Offset> ggPoints(List<DrivingSessionSample> samples) {
  return samples
      .where((s) => s.longitudinalG != null && s.lateralG != null)
      .map((s) => Offset(s.longitudinalG!, s.lateralG!))
      .toList();
}

/// Same filter, same order as [ggPoints] — index `i` here is the sample
/// [ggPoints]'s index `i` was derived from, the correlation the tap-to-select
/// readout (Fase 12 §19) uses to show a selected point's timestamp/speed/
/// altitude alongside its G components.
@visibleForTesting
List<DrivingSessionSample> ggSamples(List<DrivingSessionSample> samples) {
  return samples.where((s) => s.longitudinalG != null && s.lateralG != null).toList();
}

/// Index of the point with the largest combined (longitudinal+lateral)
/// magnitude — the single most extreme moment of the session, highlighted
/// distinctly from the rest of the scatter.
@visibleForTesting
int indexOfPeakMagnitude(List<Offset> points) {
  var peakIndex = 0;
  var peakMagnitude = -1.0;
  for (var i = 0; i < points.length; i++) {
    final magnitude = points[i].distance;
    if (magnitude > peakMagnitude) {
      peakMagnitude = magnitude;
      peakIndex = i;
    }
  }
  return peakIndex;
}

/// Scale so [maxRingsG] worth of G reaches the shorter canvas dimension's
/// edge, with a small margin — but never smaller than the largest actual
/// reading, so a session that genuinely exceeds [maxRingsG] isn't clipped
/// (Fase 12 §16: scale adequate to the session's own data, not a fixed,
/// arbitrary one). Shared by the painter and the tap hit-test so they can
/// never disagree about where a point actually renders.
@visibleForTesting
double computeGGPixelsPerG(List<Offset> points, {required double maxRingsG, required Size size}) {
  final largestMagnitude = points.isEmpty ? 0.0 : points.map((p) => p.distance).reduce(math.max);
  final scaleRangeG = math.max(maxRingsG, largestMagnitude);
  return (math.min(size.width, size.height) / 2 - 12) / scaleRangeG;
}

class _GGDiagramPainter extends CustomPainter {
  _GGDiagramPainter({
    required this.points,
    required this.ringIntervalG,
    required this.maxRingsG,
    required this.pointColor,
    required this.peakColor,
    required this.selectedColor,
    required this.gridColor,
    required this.selectedIndex,
  });

  final List<Offset> points;
  final double ringIntervalG;
  final double maxRingsG;
  final Color pointColor;
  final Color peakColor;
  final Color selectedColor;
  final Color gridColor;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final pixelsPerG = computeGGPixelsPerG(points, maxRingsG: maxRingsG, size: size);
    final largestMagnitude = points.isEmpty ? 0.0 : points.map((p) => p.distance).reduce(math.max);
    final scaleRangeG = math.max(maxRingsG, largestMagnitude);

    final gridPaint = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var g = ringIntervalG; g <= scaleRangeG + 1e-9; g += ringIntervalG) {
      canvas.drawCircle(center, g * pixelsPerG, gridPaint);
    }
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), gridPaint);
    canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), gridPaint);

    final pointPaint = Paint()..color = pointColor.withValues(alpha: 0.55);
    for (final point in points) {
      final canvasPoint = center + Offset(point.dx * pixelsPerG, -point.dy * pixelsPerG);
      canvas.drawCircle(canvasPoint, 2.5, pointPaint);
    }

    if (points.isNotEmpty) {
      final peak = points[indexOfPeakMagnitude(points)];
      final peakCanvasPoint = center + Offset(peak.dx * pixelsPerG, -peak.dy * pixelsPerG);
      canvas.drawCircle(peakCanvasPoint, 5, Paint()..color = peakColor);
    }

    final selected = selectedIndex;
    if (selected != null && selected < points.length) {
      final point = points[selected];
      final canvasPoint = center + Offset(point.dx * pixelsPerG, -point.dy * pixelsPerG);
      canvas.drawCircle(canvasPoint, 7, Paint()..color = selectedColor.withValues(alpha: 0.35));
      canvas.drawCircle(
        canvasPoint,
        7,
        Paint()
          ..color = selectedColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GGDiagramPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.selectedIndex != selectedIndex;
}
