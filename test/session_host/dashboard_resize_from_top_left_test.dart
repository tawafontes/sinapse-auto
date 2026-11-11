// Resizing from the top-left handle grows the widget up and left, as its preview shows — the
// dashboard used to keep the old position on release, so it grew right/down instead (owner report,
// 2026-11-11). Through the real app over platform fakes (support/app_harness.dart). One test per file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('dragging the top-left handle one cell up-left grows the widget up and left, and saves that', (tester) async {
    final app = AppHarness(tester);
    try {
      await app.run(() async {
        await app.boot(seedTiles: const {SensorType.speed: DisplayStyle.numericWithHistory});
        final config = SensorWidgetRepository.forSensor(SensorType.speed)!;
        // Away from the grid's top-left corner, so there is room up and left.
        await app.driveFuture(
          SensorWidgetRepository.updateLayout(config, position: WidgetPosition(x: 1, y: 1), size: WidgetSize(width: 2, height: 2)),
        );
        // Rebuild the dashboard so it shows the moved widget.
        app.pushReplacingDashboard();
        await app.settleDashboardTransition();
        final tile = find.byType(DashboardTile);
        expect(tester.widget<DashboardTile>(tile).rect, (x: 1, y: 1, width: 2, height: 2), reason: 'setup');

        await tester.longPress(tile);
        await app.drive(const Duration(milliseconds: 300));
        final cell = tester.widget<DashboardTile>(tile).cellSize;
        await tester.drag(find.byKey(const ValueKey('resizeHandle_topLeft')), Offset(-cell.width, -cell.height));
        await app.drive(const Duration(milliseconds: 300));

        final saved = SensorWidgetRepository.forSensor(SensorType.speed)!;
        expect((x: saved.position.x, y: saved.position.y, w: saved.size.width, h: saved.size.height), (x: 0.0, y: 0.0, w: 3.0, h: 3.0),
            reason: 'grown up and left: the right/bottom edges stay where they were');
        expect(tester.widget<DashboardTile>(tile).rect, (x: 0, y: 0, width: 3, height: 3));
      });
    } finally {
      await app.teardown();
    }
  });
}
