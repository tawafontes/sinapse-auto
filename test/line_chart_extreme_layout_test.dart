import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/sensors/line_chart.dart';

void main() {
  const canvasHeight = 200.0;
  const maxLabelHeight = 17.0;
  const minLabelHeight = 17.0;

  void expectNoClipping(LineChartExtremeLayout layout) {
    if (layout.maxLabelTop != null) {
      expect(layout.maxLabelTop!, greaterThanOrEqualTo(0));
      expect(layout.maxLabelBottom!, lessThanOrEqualTo(canvasHeight));
    }
    if (layout.minLabelTop != null) {
      expect(layout.minLabelTop!, greaterThanOrEqualTo(0));
      expect(layout.minLabelBottom!, lessThanOrEqualTo(canvasHeight));
    }
  }

  void expectLabelsDontOverlapEachOther(LineChartExtremeLayout layout) {
    if (layout.maxLabelBottom == null || layout.minLabelTop == null) return;
    expect(
      layout.maxLabelBottom!,
      lessThanOrEqualTo(layout.minLabelTop!),
      reason: 'MÁX label (${layout.maxLabelTop}-${layout.maxLabelBottom}) must not overlap '
          'MÍN label (${layout.minLabelTop}-${layout.minLabelBottom})',
    );
  }

  /// The curve/fill/reference lines are confined to [plotTop, plotBottom]
  /// (see `_LineChartPainter.paint`'s `yFor`), so a label overlaps the
  /// curve's drawable area only if it reaches inside that band — regardless
  /// of where the underlying session value that produced the label sits.
  void expectLabelsDontOverlapCurve(LineChartExtremeLayout layout) {
    if (layout.maxLabelBottom != null) {
      expect(layout.maxLabelBottom!, lessThanOrEqualTo(layout.plotTop));
    }
    if (layout.minLabelTop != null) {
      expect(layout.minLabelTop!, greaterThanOrEqualTo(layout.plotBottom));
    }
  }

  test('scenario 1: session max near the top of the chart', () {
    // "Near the top" is exactly what makes a reference line's y approach 0
    // in the first place: the tracked value is close to (or at) the
    // scale's ceiling. The label must stay above the plot band regardless.
    final layout = computeLineChartExtremeLayout(
      canvasHeight: canvasHeight,
      maxLabelHeight: maxLabelHeight,
      minLabelHeight: minLabelHeight,
    );

    expectNoClipping(layout);
    expectLabelsDontOverlapCurve(layout);
    expectLabelsDontOverlapEachOther(layout);
    expect(layout.maxLabelTop, 0.0);
  });

  test('scenario 2: session min near the base of the chart', () {
    final layout = computeLineChartExtremeLayout(
      canvasHeight: canvasHeight,
      maxLabelHeight: maxLabelHeight,
      minLabelHeight: minLabelHeight,
    );

    expectNoClipping(layout);
    expectLabelsDontOverlapCurve(layout);
    expectLabelsDontOverlapEachOther(layout);
    expect(layout.minLabelBottom, canvasHeight);
  });

  test('scenario 3: session min and max close together (low amplitude)', () {
    // Low amplitude used to make a reactive "flip to the other side if it
    // doesn't fit" placement put both labels in the same cramped middle
    // band. Labels are now anchored to fixed top/bottom bands independent
    // of how close the two reference lines are to each other, so the bands
    // themselves — not the (here, tiny) gap between the lines — decide
    // whether the labels collide.
    final layout = computeLineChartExtremeLayout(
      canvasHeight: canvasHeight,
      maxLabelHeight: maxLabelHeight,
      minLabelHeight: minLabelHeight,
    );

    expectNoClipping(layout);
    expectLabelsDontOverlapCurve(layout);
    expectLabelsDontOverlapEachOther(layout);
  });

  test('degenerate: canvas too short for both labels never produces out-of-bounds rects', () {
    final layout = computeLineChartExtremeLayout(
      canvasHeight: 20,
      maxLabelHeight: maxLabelHeight,
      minLabelHeight: minLabelHeight,
    );

    expectNoClipping(layout);
  });

  test('only a max label present: min side is left entirely unreserved', () {
    final layout = computeLineChartExtremeLayout(
      canvasHeight: canvasHeight,
      maxLabelHeight: maxLabelHeight,
      minLabelHeight: null,
    );

    expect(layout.minLabelTop, isNull);
    expect(layout.plotBottom, canvasHeight);
    expectNoClipping(layout);
    expectLabelsDontOverlapCurve(layout);
  });

  test('neither label present: the whole canvas is usable as plot area', () {
    final layout = computeLineChartExtremeLayout(canvasHeight: canvasHeight);

    expect(layout.plotTop, 0.0);
    expect(layout.plotBottom, canvasHeight);
    expect(layout.maxLabelTop, isNull);
    expect(layout.minLabelTop, isNull);
  });
}
