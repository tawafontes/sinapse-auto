import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'altitude_extremes.dart';

/// Direction a rolling series of values (e.g. altitude) is trending, over a
/// window of recent measurements rather than just the latest one, so a
/// single noisy sample can't flip it — see [trendSlope]/
/// [trendDirectionFromSlope].
enum TrendDirection { rising, falling, stable }

/// Least-squares slope of [recentValues] against their index (0..n-1) —
/// units are "value per sample". Returns `0.0` for fewer than 2 points,
/// where a slope is undefined (and would otherwise divide by zero).
@visibleForTesting
double trendSlope(List<double> recentValues) {
  final n = recentValues.length;
  if (n < 2) return 0.0;
  final meanX = (n - 1) / 2.0;
  final meanY = recentValues.reduce((a, b) => a + b) / n;
  var numerator = 0.0;
  var denominator = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = i - meanX;
    numerator += dx * (recentValues[i] - meanY);
    denominator += dx * dx;
  }
  return denominator == 0 ? 0.0 : numerator / denominator;
}

@visibleForTesting
TrendDirection trendDirectionFromSlope(double slope, {required double threshold}) {
  if (slope > threshold) return TrendDirection.rising;
  if (slope < -threshold) return TrendDirection.falling;
  return TrendDirection.stable;
}

String _trendGlyph(TrendDirection trend) {
  switch (trend) {
    case TrendDirection.rising:
      return '▲';
    case TrendDirection.falling:
      return '▼';
    case TrendDirection.stable:
      return '►';
  }
}

/// How fast the *average* speed for the current trip has been, classifying
/// it into a small, glanceable scale — see [speedAverageBandFor]/
/// [speedAverageBandColor]. Only meaningful while [LineChart.trackAverage]
/// is true (speed); altitude has no equivalent concept.
enum SpeedAverageBand { low, moderate, high, veryHigh }

/// Threshold (km/h) below which the session average still counts as [low]
/// (green) — typical urban/economical driving.
const double kSpeedAverageLowMaxKmh = 40;

/// Threshold below which the average counts as [moderate] (amber) — normal
/// city-avenue flow.
const double kSpeedAverageModerateMaxKmh = 70;

/// Threshold below which the average counts as [high] (orange) — fast
/// urban expressway / moderate rodovia pace. At or above this, it's
/// [SpeedAverageBand.veryHigh] (red).
const double kSpeedAverageHighMaxKmh = 100;

/// Classifies [averageKmh] into a [SpeedAverageBand] using the thresholds
/// above — pulled out as a plain function (like [trendDirectionFromSlope])
/// so the banding itself can be unit-tested directly, without a real
/// stream/widget behind it. The three constants are the only place these
/// numbers are defined; nothing else in the codebase repeats them.
@visibleForTesting
SpeedAverageBand speedAverageBandFor(double averageKmh) {
  if (averageKmh < kSpeedAverageLowMaxKmh) return SpeedAverageBand.low;
  if (averageKmh < kSpeedAverageModerateMaxKmh) return SpeedAverageBand.moderate;
  if (averageKmh < kSpeedAverageHighMaxKmh) return SpeedAverageBand.high;
  return SpeedAverageBand.veryHigh;
}

/// The MÉD badge's fill color for [band] — deliberately not brightness-split
/// like [altitudeExtremeStyleFor]: these are solid-fill pills with white
/// text painted directly on top (see `_LineChartPainter._paintLabel`), so
/// what matters for contrast is this color against white, not against the
/// app's own light/dark surface. [SpeedAverageBand.moderate] uses a deep
/// amber (rather than a brighter, more "yellow" tone) specifically because
/// pure/bright yellow reads poorly under white text at any reasonable
/// saturation — this is the darkest shade that still reads as amber/gold
/// rather than brown.
Color speedAverageBandColor(SpeedAverageBand band) {
  switch (band) {
    case SpeedAverageBand.low:
      return const Color(0xFF43A047); // green
    case SpeedAverageBand.moderate:
      return const Color(0xFFFF6F00); // deep amber/gold
    case SpeedAverageBand.high:
      return const Color(0xFFF4511E); // deep orange
    case SpeedAverageBand.veryHigh:
      return const Color(0xFFF44336); // red — matches the app's existing alert red
  }
}

/// How long a badge color transition (see [speedAverageBandColor]) takes to
/// animate between bands — short and deliberately centralized so it can be
/// tuned in one place without touching the animation wiring itself. Shared
/// by both the MÁX and MÉD badges (see [_AnimatedSeverityBadgeColors]) —
/// there is exactly one transition duration, not two that could drift apart.
const Duration kSpeedAverageColorTransitionDuration = Duration(milliseconds: 400);

/// The single place both the MÁX and MÉD badges get their color from —
/// same classification ([speedAverageBandFor]), same color mapping
/// ([speedAverageBandColor]), same animation (one [TweenAnimationBuilder]
/// per badge, identical duration/curve). The two badges differ only in
/// *which* value they classify: [topValueKmh] (the session's highest
/// reading so far) for MÁX, [bottomValueKmh] (the running average) for
/// MÉD — everything about turning "a speed" into "an animated color" lives
/// here, once, rather than once per badge.
class _AnimatedSeverityBadgeColors extends StatelessWidget {
  const _AnimatedSeverityBadgeColors({
    required this.topValueKmh,
    required this.bottomValueKmh,
    required this.builder,
  });

  final double? topValueKmh;
  final double? bottomValueKmh;
  final Widget Function(BuildContext context, Color topColor, Color bottomColor) builder;

  static Color _colorFor(double? valueKmh) => speedAverageBandColor(speedAverageBandFor(valueKmh ?? 0));

  @override
  Widget build(BuildContext context) {
    final targetTop = _colorFor(topValueKmh);
    final targetBottom = _colorFor(bottomValueKmh);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: targetTop),
      duration: kSpeedAverageColorTransitionDuration,
      curve: Curves.easeInOut,
      builder: (context, topColor, child) => TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: targetBottom),
        duration: kSpeedAverageColorTransitionDuration,
        curve: Curves.easeInOut,
        builder: (context, bottomColor, child) =>
            builder(context, topColor ?? targetTop, bottomColor ?? targetBottom),
      ),
    );
  }
}

/// Rolling line chart of recent values (e.g. altitude/speed over time), with
/// horizontal reference lines for the tracked stats and a reset trigger
/// (see [onResetRequested]) — shared by altitude and speed (see
/// [trackAverage] for how the bottom badge differs between them) rather
/// than forked into two near-identical widgets.
///
/// [min]/[max] are optional: pass them for a fixed scale (e.g. the mock
/// preview's 100-400m), or omit them to auto-scale from the tracked
/// min/max — the right choice for real altitude/speed, which can each range
/// widely depending on the user's trip, and which also guarantees the
/// reference lines always land inside the chart (the tracked range can
/// never be narrower than whatever's on screen).
///
/// The tracked min/max survive app restarts by way of [initialSessionMin]/
/// [initialSessionMax] (the caller's responsibility to source, e.g. from
/// Hive — this widget stays unaware of persistence itself) and
/// [onSessionExtremesChanged] (called on every new extreme, and once more
/// after a long-press reset, as the caller's hook to persist it). Leaving
/// them null starts tracking fresh from the first live reading, same as
/// before this became persistable — which is what the onboarding preview
/// does, so mock data never touches a real persisted record.
class LineChart extends StatefulWidget {
  const LineChart({
    super.key,
    required this.valueStream,
    required this.unit,
    this.min,
    this.max,
    this.historyLength = 60,
    this.initialSessionMin,
    this.initialSessionMax,
    this.onSessionExtremesChanged,
    this.onResetRequested,
    this.onImmediateResetRequested,
    this.trackAverage = false,
    this.initialSessionAverage,
    this.initialAverageSampleCount = 0,
    this.onSessionAverageChanged,
    this.resetDialogTitle,
    this.resetDialogConfirmLabel,
    this.displayTransform,
  });

  final Stream<double> valueStream;
  final double? min;
  final double? max;
  final String unit;

  /// Converts a value already in this widget's canonical internal unit
  /// (whatever [valueStream] carries — km/h for speed, meters for altitude)
  /// to whatever unit [unit] actually labels, applied only at the final
  /// render step. `null` (the default) means no conversion — every
  /// existing call site keeps behaving exactly as before this parameter
  /// existed. Internal state ([initialSessionMin]/[initialSessionMax]/
  /// [onSessionExtremesChanged]/the running average) always stays in the
  /// canonical unit regardless, so persisted records and this engine's own
  /// filter thresholds never need to know which display unit is active —
  /// see `lib/models/unit_system.dart`, the single place the actual
  /// conversion math lives.
  final double Function(double)? displayTransform;
  final int historyLength;
  final double? initialSessionMin;
  final double? initialSessionMax;
  final void Function(double min, double max)? onSessionExtremesChanged;

  /// Called once, in `initState`, with a tear-off of this widget's own
  /// reset-confirmation dialog — see [GForceMeter.onResetRequested] for the
  /// full rationale (same pattern, shared across all three sensor widgets
  /// with a resettable record).
  final ValueChanged<VoidCallback>? onResetRequested;

  /// Called once, in `initState`, with a tear-off of the bare reset logic
  /// (no confirmation dialog) — used by the dashboard's global "Resetar e
  /// calibrar sistema" button, which shows exactly one confirmation of its
  /// own and then needs to run every widget's reset without popping up this
  /// widget's individual dialog too. Mirrors [onResetRequested] exactly,
  /// just without the dialog in front of it.
  final ValueChanged<VoidCallback>? onImmediateResetRequested;

  /// When true, the bottom badge/reference line shows a running **average**
  /// ("MÉD") instead of the running minimum ("MÍN") — the true session
  /// minimum is still tracked internally regardless (the curve's vertical
  /// scale needs it to avoid clipping whenever a reading dips below the
  /// average), it's simply not displayed. Speed uses this (average speed is
  /// the more useful figure while driving); altitude leaves it false
  /// (unchanged from before this parameter existed).
  final bool trackAverage;
  final double? initialSessionAverage;

  /// How many readings [initialSessionAverage] was already computed from —
  /// required alongside it (mirrors [initialSessionMin]/[initialSessionMax]'s
  /// own persistence contract) so the running mean keeps weighting new
  /// readings correctly after a restart, instead of letting a single
  /// post-restart reading outweigh an entire prior session.
  final int initialAverageSampleCount;

  /// Called on every new reading once [trackAverage] and a session average
  /// exist, so the caller can persist both the average and the sample count
  /// backing it — same shape as [onSessionExtremesChanged].
  final void Function(double average, int sampleCount)? onSessionAverageChanged;

  /// Overrides for [confirmResetAltitudeExtremes]'s dialog text — null keeps
  /// its own altitude-flavored defaults. Speed passes both, since its stats
  /// are no longer "mínimo e máximo" once [trackAverage] is true.
  final String? resetDialogTitle;
  final String? resetDialogConfirmLabel;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  // Trend: a short recent sub-window of _history (separate from the full
  // chart history), classified into a candidate direction on every new
  // value; only committed to _trend once the same candidate has held for
  // _trendConfirmCount updates in a row — a debounce against single-sample
  // GPS noise, independent of the MÁX/MÍN session reset.
  static const _trendWindowSize = 6;
  static const _trendSlopeThreshold = 0.4;
  static const _trendConfirmCount = 3;

  final List<double> _history = [];
  StreamSubscription<double>? _sub;
  double? _current;
  double? _sessionMin;
  double? _sessionMax;
  double? _sessionAverage;
  int _averageSampleCount = 0;
  TrendDirection _trend = TrendDirection.stable;
  TrendDirection? _trendCandidate;
  int _trendCandidateStreak = 0;

  @override
  void initState() {
    super.initState();
    _sessionMin = widget.initialSessionMin;
    _sessionMax = widget.initialSessionMax;
    _sessionAverage = widget.initialSessionAverage;
    _averageSampleCount = widget.initialAverageSampleCount;
    _listen(widget.valueStream);
    widget.onResetRequested?.call(_confirmReset);
    widget.onImmediateResetRequested?.call(_performReset);
  }

  @override
  void didUpdateWidget(covariant LineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueStream != widget.valueStream) {
      _listen(widget.valueStream);
    }
  }

  void _listen(Stream<double> stream) {
    unawaited(_sub?.cancel());
    _sub = stream.listen((value) {
      // Guards the running average against a spurious/invalid sample
      // slipping through — the min/max/curve logic below already tolerates
      // this implicitly (a NaN would just never win a math.min/max
      // comparison), but folding NaN into the incremental mean would
      // permanently poison it (every later average becomes NaN too).
      if (value.isNaN || value.isInfinite) return;
      setState(() {
        _current = value;
        _history.add(value);
        if (_history.length > widget.historyLength) {
          _history.removeAt(0);
        }
        final newMin = _sessionMin == null ? value : math.min(_sessionMin!, value);
        final newMax = _sessionMax == null ? value : math.max(_sessionMax!, value);
        if (newMin != _sessionMin || newMax != _sessionMax) {
          _sessionMin = newMin;
          _sessionMax = newMax;
          widget.onSessionExtremesChanged?.call(newMin, newMax);
        }
        if (widget.trackAverage) {
          _averageSampleCount += 1;
          // Incremental mean (Welford's running-average update): folds in
          // each new reading without needing the full history of samples,
          // and — seeded from the persisted average/count — stays correct
          // across an app restart instead of restarting the weighting
          // fresh.
          _sessionAverage = _sessionAverage == null
              ? value
              : _sessionAverage! + (value - _sessionAverage!) / _averageSampleCount;
          widget.onSessionAverageChanged?.call(_sessionAverage!, _averageSampleCount);
        }
        _updateTrend();
      });
    });
  }

  void _updateTrend() {
    final window = _history.length <= _trendWindowSize
        ? _history
        : _history.sublist(_history.length - _trendWindowSize);
    final candidate = trendDirectionFromSlope(trendSlope(window), threshold: _trendSlopeThreshold);
    if (candidate == _trendCandidate) {
      _trendCandidateStreak++;
    } else {
      _trendCandidate = candidate;
      _trendCandidateStreak = 1;
    }
    if (_trendCandidateStreak >= _trendConfirmCount) {
      _trend = candidate;
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _confirmReset() async {
    final confirmed = await confirmResetAltitudeExtremes(
      context,
      title: widget.resetDialogTitle ?? 'Resetar mínimo e máximo de altitude?',
      confirmLabel: widget.resetDialogConfirmLabel ?? 'Resetar mínimo e máximo',
    );
    if (confirmed && mounted) {
      _performReset();
    }
  }

  /// The actual reset logic, with no confirmation dialog of its own — see
  /// [LineChart.onImmediateResetRequested].
  void _performReset() {
    final current = _current;
    setState(() {
      _sessionMin = current;
      _sessionMax = current;
      if (widget.trackAverage) {
        _sessionAverage = current;
        _averageSampleCount = current == null ? 0 : 1;
      }
    });
    if (current != null) {
      widget.onSessionExtremesChanged?.call(current, current);
      if (widget.trackAverage) widget.onSessionAverageChanged?.call(current, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = _current;
    final colorScheme = Theme.of(context).colorScheme;
    final defaultStyle = altitudeExtremeStyleFor(Theme.of(context).brightness);

    // A linear unit conversion (km/h->mph, m->ft) applied uniformly to the
    // curve, its min/max scale, and both reference values preserves the
    // curve's shape exactly (only rescales the y-axis) — so it's safe to
    // apply here, at render time only, without touching _history/session
    // state itself (which stays in the canonical unit for persistence).
    final transform = widget.displayTransform;
    double? t(double? v) => v == null ? null : (transform == null ? v : transform(v));
    List<double> tHistory(List<double> values) => transform == null ? values : values.map(transform).toList();

    Widget chart(Color topColor, Color bottomColor) => CustomPaint(
      size: Size.infinite,
      painter: _LineChartPainter(
        values: tHistory(_history),
        min: t(widget.min ?? _sessionMin),
        max: t(widget.max ?? _sessionMax),
        topValue: t(_sessionMax),
        bottomValue: t(widget.trackAverage ? _sessionAverage : _sessionMin),
        bottomLabel: widget.trackAverage ? 'MÉD' : 'MÍN',
        topColor: topColor,
        bottomColor: bottomColor,
        lineColor: colorScheme.primary,
        fillColor: colorScheme.primary.withValues(alpha: 0.15),
        unit: widget.unit,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.all(8),
            // Both badges' colors are a live classification of a speed
            // value (see speedAverageBandFor) — MÁX classifies _sessionMax,
            // MÉD classifies _sessionAverage, through the exact same
            // _AnimatedSeverityBadgeColors, so they use identical bands,
            // identical color mapping and identical transition timing.
            // Re-supplying the *same* color (still the same band) on every
            // rebuild is a no-op for TweenAnimationBuilder, so this never
            // restarts/glitches on every GPS tick, only on an actual band
            // change. Altitude (real, non-banded min/max) skips this
            // machinery entirely — unchanged from before it existed.
            child: widget.trackAverage
                ? _AnimatedSeverityBadgeColors(
                    topValueKmh: _sessionMax,
                    bottomValueKmh: _sessionAverage,
                    builder: (context, topColor, bottomColor) => chart(topColor, bottomColor),
                  )
                : chart(defaultStyle.max, defaultStyle.min),
          ),
        ),
        // The value is the primary visual element here — a big, bold number
        // with the trend glyph and unit as secondary context, all scaled
        // together by FittedBox so it fills whatever space is available
        // (a small dashboard tile or a fullscreen view) without overflowing.
        Expanded(
          flex: 1,
          child: FittedBox(
            fit: BoxFit.contain,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _trendGlyph(_trend),
                  key: const ValueKey('lineChartTrendArrow'),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 10),
                Text(
                  value == null ? '--' : t(value)!.toStringAsFixed(0),
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                ),
                const SizedBox(width: 6),
                Text(
                  widget.unit,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Vertical layout for the curve's plot area and the MÁX/MÍN labels, in
/// canvas-space pixels. Pure geometry (no [Canvas]/[TextPainter] involved)
/// so it can be unit-tested directly against known min/max/height
/// combinations — see `computeLineChartExtremeLayout`.
@visibleForTesting
class LineChartExtremeLayout {
  const LineChartExtremeLayout({
    required this.plotTop,
    required this.plotBottom,
    this.maxLabelTop,
    this.maxLabelHeight,
    this.minLabelTop,
    this.minLabelHeight,
  });

  /// Top of the region the curve/fill/reference lines are drawn in.
  final double plotTop;

  /// Bottom of the region the curve/fill/reference lines are drawn in.
  final double plotBottom;

  final double? maxLabelTop;
  final double? maxLabelHeight;
  final double? minLabelTop;
  final double? minLabelHeight;

  double? get maxLabelBottom => maxLabelTop == null ? null : maxLabelTop! + maxLabelHeight!;
  double? get minLabelBottom => minLabelTop == null ? null : minLabelTop! + minLabelHeight!;
}

/// Computes where the MÁX/MÍN labels sit and how much vertical room the
/// curve itself gets, given the canvas height and each label's real
/// (measured) height.
///
/// Rather than drawing the curve across the full canvas and then reactively
/// dodging it with an "above, else flip below" placement — which still
/// collides whenever a reference line sits at/near the canvas edge, exactly
/// where the curve reaches that same extreme, and can still collide with
/// the *other* label whenever min/max are close together — this reserves a
/// dedicated band above and below the plot area, sized to fit each label,
/// and anchors each label inside its own band regardless of exactly where
/// its reference line falls within the plot. The curve's own coordinate
/// mapping is compressed to stay within [plotTop, plotBottom] (see
/// `paint`'s `yFor`), so it can never reach into either band, and the two
/// bands sit on opposite ends of the canvas so the labels can never reach
/// each other either. In the steady state both this app's callers actually
/// produce — the real altitude widget auto-scales so the tracked extremes
/// *are* the plot's edges, and the mock preview's session quickly locks onto
/// its fixed 100–400m bounds — each label ends up snug against its line
/// exactly as before; the only change is that a label is never asked to
/// dodge the curve reactively, which is what let the two collide.
///
/// When both bands together would be taller than the canvas itself (a
/// pathologically short chart), they're scaled down proportionally so
/// nothing is asked to occupy negative space.
@visibleForTesting
LineChartExtremeLayout computeLineChartExtremeLayout({
  required double canvasHeight,
  double? maxLabelHeight,
  double? minLabelHeight,
  double gap = 2.0,
}) {
  final hasMax = maxLabelHeight != null;
  final hasMin = minLabelHeight != null;

  final topInset = hasMax ? maxLabelHeight + gap : 0.0;
  final bottomInset = hasMin ? minLabelHeight + gap : 0.0;
  final totalInset = topInset + bottomInset;
  final insetScale = (totalInset > canvasHeight && totalInset > 0) ? canvasHeight / totalInset : 1.0;
  final plotTop = topInset * insetScale;
  final plotBottom = canvasHeight - bottomInset * insetScale;

  return LineChartExtremeLayout(
    plotTop: plotTop,
    plotBottom: plotBottom,
    maxLabelTop: hasMax ? 0.0 : null,
    maxLabelHeight: hasMax ? maxLabelHeight : null,
    minLabelTop: hasMin ? (canvasHeight - minLabelHeight).clamp(0.0, canvasHeight) : null,
    minLabelHeight: hasMin ? minLabelHeight : null,
  );
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.values,
    required this.min,
    required this.max,
    required this.topValue,
    required this.bottomValue,
    required this.bottomLabel,
    required this.topColor,
    required this.bottomColor,
    required this.lineColor,
    required this.fillColor,
    required this.unit,
  });

  final List<double> values;
  final double? min;
  final double? max;

  /// The MÁX badge/reference line's value — always the true session
  /// maximum, regardless of caller.
  final double? topValue;

  /// The bottom badge/reference line's value — the true session minimum for
  /// altitude, or the running average for speed (see [LineChart.trackAverage]).
  /// Independent of [min]/[max]'s own scale, which always still reflects the
  /// true min/max so the curve itself never clips.
  final double? bottomValue;

  /// "MÍN" or "MÉD" — whatever [bottomValue] actually represents.
  final String bottomLabel;
  final Color topColor;
  final Color bottomColor;
  final Color lineColor;
  final Color fillColor;
  final String unit;

  static const _labelTextStyle = TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold);
  static const _labelPaddingH = 4.0;
  static const _labelPaddingV = 2.0;

  TextPainter _layoutLabel(String text) =>
      TextPainter(text: TextSpan(text: text, style: _labelTextStyle), textDirection: TextDirection.ltr)..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final effectiveMin = min ?? values.reduce((a, b) => a < b ? a : b);
    final effectiveMax = max ?? values.reduce((a, b) => a > b ? a : b);

    final maxLabelPainter =
        topValue != null ? _layoutLabel('MÁX: ${topValue!.toStringAsFixed(0)} $unit') : null;
    final minLabelPainter =
        bottomValue != null ? _layoutLabel('$bottomLabel: ${bottomValue!.toStringAsFixed(0)} $unit') : null;

    final layout = computeLineChartExtremeLayout(
      canvasHeight: size.height,
      maxLabelHeight: maxLabelPainter == null ? null : maxLabelPainter.height + _labelPaddingV * 2,
      minLabelHeight: minLabelPainter == null ? null : minLabelPainter.height + _labelPaddingV * 2,
    );
    final plotHeight = layout.plotBottom - layout.plotTop;
    final range = (effectiveMax - effectiveMin).abs() < 1e-9 ? 1.0 : effectiveMax - effectiveMin;

    double yFor(double value) {
      final fraction = ((value - effectiveMin) / range).clamp(0.0, 1.0);
      return layout.plotTop + plotHeight * (1 - fraction);
    }

    Offset pointAt(int i) => Offset(size.width * i / (values.length - 1), yFor(values[i]));

    // Reference lines painted first so the curve (below) draws over them;
    // their text labels are painted last, in the reserved bands computed
    // above, so the curve can never render on top of and obscure them.
    if (topValue != null) {
      canvas.drawLine(
        Offset(0, yFor(topValue!)),
        Offset(size.width, yFor(topValue!)),
        Paint()
          ..color = topColor
          ..strokeWidth = 1,
      );
    }
    if (bottomValue != null) {
      canvas.drawLine(
        Offset(0, yFor(bottomValue!)),
        Offset(size.width, yFor(bottomValue!)),
        Paint()
          ..color = bottomColor
          ..strokeWidth = 1,
      );
    }

    final linePath = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < values.length; i++) {
      final p = pointAt(i);
      linePath.lineTo(p.dx, p.dy);
    }

    final fillPath = Path.from(linePath)
      ..lineTo(size.width, layout.plotBottom)
      ..lineTo(0, layout.plotBottom)
      ..close();
    canvas.drawPath(fillPath, Paint()..color = fillColor);
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    if (maxLabelPainter != null && layout.maxLabelTop != null) {
      _paintLabel(canvas, size, layout.maxLabelTop!, maxLabelPainter, topColor);
    }
    if (minLabelPainter != null && layout.minLabelTop != null) {
      _paintLabel(canvas, size, layout.minLabelTop!, minLabelPainter, bottomColor);
    }
  }

  void _paintLabel(Canvas canvas, Size size, double top, TextPainter textPainter, Color color) {
    final labelWidth = textPainter.width + _labelPaddingH * 2;
    final labelHeight = textPainter.height + _labelPaddingV * 2;
    final labelRect = Rect.fromLTWH(size.width - labelWidth, top, labelWidth, labelHeight);
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
      Paint()..color = color,
    );
    textPainter.paint(canvas, Offset(labelRect.left + _labelPaddingH, labelRect.top + _labelPaddingV));
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) => true;
}
