import 'package:flutter_test/flutter_test.dart';

import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/dashboard_layout_engine.dart';

SensorWidgetConfig _config(
  SensorType type,
  DisplayStyle style, {
  double x = -1,
  double y = -1,
  double w = 1,
  double h = 1,
}) {
  return SensorWidgetConfig(
    sensorType: type,
    displayStyle: style,
    position: WidgetPosition(x: x, y: y),
    size: WidgetSize(width: w, height: h),
  );
}

void main() {
  const landscape = (columns: 6, rows: 4);
  const portrait = (columns: 4, rows: 6);

  group('CellRect geometry', () {
    test('overlaps detects intersection', () {
      const a = (x: 0, y: 0, width: 2, height: 2);
      const b = (x: 1, y: 1, width: 2, height: 2);
      const c = (x: 2, y: 0, width: 2, height: 2);
      expect(a.overlaps(b), isTrue);
      expect(a.overlaps(c), isFalse);
    });

    test('fitsWithin respects grid bounds', () {
      const tooWide = (x: 5, y: 0, width: 2, height: 1);
      expect(tooWide.fitsWithin(landscape), isFalse);
      const exactFit = (x: 4, y: 0, width: 2, height: 1);
      expect(exactFit.fitsWithin(landscape), isTrue);
    });
  });

  group('dragEdgeHoverDirection', () {
    const viewportWidth = 400.0;
    const zoneWidth = 50.0;

    test('a point well within the left edge zone hovers previous (-1)', () {
      expect(dragEdgeHoverDirection(globalX: 10, viewportWidth: viewportWidth, zoneWidth: zoneWidth), -1);
    });

    test('a point well within the right edge zone hovers next (1)', () {
      expect(dragEdgeHoverDirection(globalX: 390, viewportWidth: viewportWidth, zoneWidth: zoneWidth), 1);
    });

    test('a point in the middle of the viewport hovers nowhere', () {
      expect(dragEdgeHoverDirection(globalX: 200, viewportWidth: viewportWidth, zoneWidth: zoneWidth), isNull);
    });

    test('exactly at the zone boundary does not count as hovering yet', () {
      expect(dragEdgeHoverDirection(globalX: zoneWidth, viewportWidth: viewportWidth, zoneWidth: zoneWidth), isNull);
      expect(
        dragEdgeHoverDirection(globalX: viewportWidth - zoneWidth, viewportWidth: viewportWidth, zoneWidth: zoneWidth),
        isNull,
      );
    });

    test('just inside each boundary counts as hovering', () {
      expect(dragEdgeHoverDirection(globalX: zoneWidth - 1, viewportWidth: viewportWidth, zoneWidth: zoneWidth), -1);
      expect(
        dragEdgeHoverDirection(
          globalX: viewportWidth - zoneWidth + 1,
          viewportWidth: viewportWidth,
          zoneWidth: zoneWidth,
        ),
        1,
      );
    });
  });

  group('dragEdgeHoverProximity', () {
    const viewportWidth = 400.0;
    const zoneWidth = 50.0;

    test('outside the zone entirely is null, on both sides', () {
      expect(dragEdgeHoverProximity(globalX: 200, viewportWidth: viewportWidth, zoneWidth: zoneWidth), isNull);
      expect(dragEdgeHoverProximity(globalX: zoneWidth, viewportWidth: viewportWidth, zoneWidth: zoneWidth), isNull);
      expect(
        dragEdgeHoverProximity(globalX: viewportWidth - zoneWidth, viewportWidth: viewportWidth, zoneWidth: zoneWidth),
        isNull,
      );
    });

    test('right at the physical edge is 1.0, on both sides', () {
      expect(dragEdgeHoverProximity(globalX: 0, viewportWidth: viewportWidth, zoneWidth: zoneWidth), 1.0);
      expect(dragEdgeHoverProximity(globalX: viewportWidth, viewportWidth: viewportWidth, zoneWidth: zoneWidth), 1.0);
    });

    test('the midpoint of the zone reads as roughly half proximity, on both sides', () {
      final left = dragEdgeHoverProximity(globalX: zoneWidth / 2, viewportWidth: viewportWidth, zoneWidth: zoneWidth)!;
      expect(left, closeTo(0.5, 1e-9));
      final right = dragEdgeHoverProximity(
        globalX: viewportWidth - zoneWidth / 2,
        viewportWidth: viewportWidth,
        zoneWidth: zoneWidth,
      )!;
      expect(right, closeTo(0.5, 1e-9));
    });

    test('proximity increases monotonically the closer the pointer gets to the true edge', () {
      final farther = dragEdgeHoverProximity(globalX: zoneWidth - 5, viewportWidth: viewportWidth, zoneWidth: zoneWidth)!;
      final closer = dragEdgeHoverProximity(globalX: zoneWidth - 40, viewportWidth: viewportWidth, zoneWidth: zoneWidth)!;
      expect(closer, greaterThan(farther));
    });
  });

  group('firstFit', () {
    test('finds the first free row-major slot', () {
      const occupied = [(x: 0, y: 0, width: 1, height: 1)];
      final placed = firstFit(occupied: occupied, grid: landscape, width: 1, height: 1);
      expect(placed, (x: 1, y: 0, width: 1, height: 1));
    });

    test('returns null when nothing fits', () {
      final occupied = <CellRect>[
        for (var y = 0; y < landscape.rows; y++)
          for (var x = 0; x < landscape.columns; x++) (x: x, y: y, width: 1, height: 1),
      ];
      final placed = firstFit(occupied: occupied, grid: landscape, width: 1, height: 1);
      expect(placed, isNull);
    });
  });

  group('reconcileLayout', () {
    test('places brand-new (sentinel position) widgets without overlap', () {
      final configs = [
        _config(SensorType.speed, DisplayStyle.numericWithHistory),
        _config(SensorType.inclination, DisplayStyle.artificialHorizon, w: 2, h: 2),
      ];
      final result = reconcileLayout(configs: configs, grid: landscape);
      expect(result.length, 2);
      final rects = result.values.toList();
      expect(rects[0].overlaps(rects[1]), isFalse);
      for (final rect in rects) {
        expect(rect.fitsWithin(landscape), isTrue);
      }
    });

    test('keeps an already-valid placed widget untouched', () {
      final configs = [
        _config(SensorType.speed, DisplayStyle.numericWithHistory, x: 3, y: 2, w: 1, h: 1),
      ];
      final result = reconcileLayout(configs: configs, grid: landscape);
      expect(result[SensorType.speed], (x: 3, y: 2, width: 1, height: 1));
    });

    test('re-places a widget that no longer fits after an orientation change', () {
      // Valid in landscape (6 cols) but x=5,width=2 overflows portrait's 4.
      final configs = [
        _config(SensorType.speed, DisplayStyle.numericWithHistory, x: 5, y: 0, w: 2, h: 1),
      ];
      final result = reconcileLayout(configs: configs, grid: portrait);
      expect(result[SensorType.speed]!.fitsWithin(portrait), isTrue);
    });

    test('resolves a collision between two already-placed widgets', () {
      final configs = [
        _config(SensorType.speed, DisplayStyle.numericWithHistory, x: 0, y: 0, w: 2, h: 2),
        _config(SensorType.inclination, DisplayStyle.artificialHorizon, x: 1, y: 1, w: 2, h: 2),
      ];
      final result = reconcileLayout(configs: configs, grid: landscape);
      expect(result[SensorType.speed]!.overlaps(result[SensorType.inclination]!), isFalse);
    });

    test('falls back to an overlapping placement when the grid has no room left', () {
      const tinyGrid = (columns: 1, rows: 1);
      final configs = [
        _config(SensorType.speed, DisplayStyle.numericWithHistory),
        _config(SensorType.inclination, DisplayStyle.artificialHorizon),
      ];
      final result = reconcileLayout(configs: configs, grid: tinyGrid);
      expect(result.length, 2);
      expect(result[SensorType.inclination], (x: 0, y: 0, width: 1, height: 1));
    });
  });

  group('resolveDragReflow', () {
    test('a widget the dragged rect does not overlap is left completely untouched', () {
      final others = [
        _config(SensorType.inclination, DisplayStyle.artificialHorizon, x: 3, y: 3, w: 1, h: 1),
      ];
      final result = resolveDragReflow(
        draggedRect: (x: 0, y: 0, width: 1, height: 1),
        draggedType: SensorType.speed,
        others: others,
        grid: landscape,
      );
      // Only the dragged tile and anything it actually displaces appear in
      // the result — an untouched widget is simply absent, not echoed back
      // with its unchanged rect (callers fall back to the persisted rect
      // for any sensor type missing from this map).
      expect(result, {SensorType.speed: (x: 0, y: 0, width: 1, height: 1)});
    });

    test('dragging onto one occupied tile relocates it to the nearest free cell', () {
      final others = [
        _config(SensorType.inclination, DisplayStyle.artificialHorizon, x: 0, y: 0, w: 1, h: 1),
      ];
      final result = resolveDragReflow(
        draggedRect: (x: 0, y: 0, width: 1, height: 1),
        draggedType: SensorType.speed,
        others: others,
        grid: landscape,
      );
      expect(result![SensorType.speed], (x: 0, y: 0, width: 1, height: 1));
      // Relocated to the first free row-major cell, not overlapping the dragged rect.
      expect(result[SensorType.inclination], (x: 1, y: 0, width: 1, height: 1));
    });

    test('dragging onto two overlapped tiles relocates both, deterministically top-to-bottom/left-to-right', () {
      final others = [
        _config(SensorType.inclination, DisplayStyle.artificialHorizon, x: 1, y: 0, w: 1, h: 1),
        _config(SensorType.altitude, DisplayStyle.lineChart, x: 0, y: 0, w: 1, h: 1),
      ];
      // A 2x1 dragged rect at (0,0) overlaps both single-cell tiles above.
      final result = resolveDragReflow(
        draggedRect: (x: 0, y: 0, width: 2, height: 1),
        draggedType: SensorType.speed,
        others: others,
        grid: landscape,
      );
      expect(result, isNotNull);
      // altitude sits at (0,0), earlier in row-major order, so it's placed first.
      expect(result![SensorType.altitude], (x: 2, y: 0, width: 1, height: 1));
      expect(result[SensorType.inclination], (x: 3, y: 0, width: 1, height: 1));
    });

    test('returns null when a displaced widget has nowhere left to go', () {
      const tinyGrid = (columns: 1, rows: 1);
      final others = [
        _config(SensorType.inclination, DisplayStyle.artificialHorizon, x: 0, y: 0, w: 1, h: 1),
      ];
      final result = resolveDragReflow(
        draggedRect: (x: 0, y: 0, width: 1, height: 1),
        draggedType: SensorType.speed,
        others: others,
        grid: tinyGrid,
      );
      expect(result, isNull);
    });

    test('returns null when draggedRect itself does not fit the grid', () {
      final result = resolveDragReflow(
        draggedRect: (x: 5, y: 0, width: 2, height: 1),
        draggedType: SensorType.speed,
        others: const [],
        grid: landscape,
      );
      expect(result, isNull);
    });
  });

  group('placeAcrossPages', () {
    // Exactly one default-create-sized (2x2) widget fits per page.
    const onePerPageGrid = (columns: 2, rows: 2);

    test('overflows onto the next page when the current one is full', () {
      final page0Full = [_config(SensorType.speed, DisplayStyle.numericWithHistory, x: 0, y: 0, w: 2, h: 2)];
      final newConfig = _config(SensorType.gForce, DisplayStyle.gForceMeter);

      final result = placeAcrossPages(allConfigs: [...page0Full, newConfig], grid: onePerPageGrid, maxPages: 5);

      expect(result.unplaced, isEmpty);
      expect(result.placed[SensorType.gForce], (page: 1, rect: (x: 0, y: 0, width: 2, height: 2)));
    });

    test('tries preferredPage first, still overflowing past it if that page is also full', () {
      final full = [
        _config(SensorType.speed, DisplayStyle.numericWithHistory, x: 0, y: 0, w: 2, h: 2)..page = 0,
        _config(SensorType.inclination, DisplayStyle.artificialHorizon, x: 0, y: 0, w: 2, h: 2)..page = 2,
      ];
      final newConfig = _config(SensorType.gForce, DisplayStyle.gForceMeter);

      final result = placeAcrossPages(
        allConfigs: [...full, newConfig],
        grid: onePerPageGrid,
        maxPages: 5,
        preferredPage: 2,
      );

      // Page 2 (preferred) is full, page 0 is full too — lands on page 1,
      // the first free one once preferredPage is tried first.
      expect(result.placed[SensorType.gForce]!.page, 1);
    });

    test('leaves a config unplaced without crashing once every page is full', () {
      final fullPages = [
        for (var p = 0; p < 3; p++)
          _config(SensorType.speed, DisplayStyle.numericWithHistory, x: 0, y: 0, w: 2, h: 2)..page = p,
      ];
      final newConfig = _config(SensorType.inclination, DisplayStyle.artificialHorizon);

      final result = placeAcrossPages(allConfigs: [...fullPages, newConfig], grid: onePerPageGrid, maxPages: 3);

      expect(result.placed, isEmpty);
      expect(result.unplaced, [SensorType.inclination]);
    });
  });

  group('restore original size (2026-11-11)', () {
    const portrait = (columns: 4, rows: 6);
    const landscape = (columns: 6, rows: 4);

    test('the original size is the 2x2 a new widget gets', () {
      expect(defaultWidgetSize(portrait), (width: 2, height: 2));
      expect(defaultWidgetSize(landscape), (width: 2, height: 2));
      expect(hasDefaultWidgetSize((x: 1, y: 3, width: 2, height: 2), portrait), isTrue);
      expect(hasDefaultWidgetSize((x: 0, y: 0, width: 4, height: 2), portrait), isFalse);
      expect(hasDefaultWidgetSize((x: 0, y: 0, width: 2, height: 3), portrait), isFalse);
    });

    test('restoring keeps the top-left corner', () {
      expect(restoredDefaultRect(current: (x: 1, y: 2, width: 3, height: 4), grid: portrait, others: const []), (x: 1, y: 2, width: 2, height: 2));
    });

    test('a corner that would leave the grid is pulled back inside', () {
      expect(restoredDefaultRect(current: (x: 3, y: 5, width: 1, height: 1), grid: portrait, others: const []), (x: 2, y: 4, width: 2, height: 2));
    });

    test('it never moves another widget: an overlap is refused (null)', () {
      expect(restoredDefaultRect(current: (x: 0, y: 0, width: 1, height: 1), grid: portrait, others: const [(x: 1, y: 1, width: 2, height: 2)]), isNull);
      expect(restoredDefaultRect(current: (x: 0, y: 0, width: 4, height: 4), grid: portrait, others: const [(x: 0, y: 4, width: 2, height: 2)]), (x: 0, y: 0, width: 2, height: 2),
          reason: 'shrinking never overlaps');
    });
  });
}
