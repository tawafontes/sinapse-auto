// Holding a widget for 5 s offers "Restaurar tamanho original" when it is not at its original
// (default) size, and restores it keeping its top-left corner (2026-11-11). Through the real app over
// platform fakes (support/app_harness.dart). One test per file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('a 5 s hold on a grown widget offers the original size and restores it', (tester) async {
    final app = AppHarness(tester);
    try {
      await app.run(() async {
        await app.boot(seedTiles: const {SensorType.speed: DisplayStyle.numericWithHistory});
        final config = SensorWidgetRepository.forSensor(SensorType.speed)!;
        await app.driveFuture(
          SensorWidgetRepository.updateLayout(config, position: WidgetPosition(x: 1, y: 1), size: WidgetSize(width: 3, height: 3)),
        );
        app.pushReplacingDashboard();
        await app.settleDashboardTransition();
        final tile = find.byType(DashboardTile);
        expect(tester.widget<DashboardTile>(tile).rect, (x: 1, y: 1, width: 3, height: 3), reason: 'setup: grown');

        final gesture = await tester.startGesture(tester.getCenter(tile));
        await tester.pump(DashboardTile.longHoldDuration + const Duration(milliseconds: 100));
        await gesture.up();
        await app.drive(const Duration(milliseconds: 500));
        expect(find.text('Restaurar tamanho original'), findsOneWidget);
        expect(find.text('Excluir'), findsNothing, reason: 'the hold menu has only that option');
        expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsNothing, reason: 'edit mode ended');

        await tester.tap(find.text('Restaurar tamanho original'));
        await app.drive(const Duration(milliseconds: 500));
        final saved = SensorWidgetRepository.forSensor(SensorType.speed)!;
        expect((x: saved.position.x, y: saved.position.y, w: saved.size.width, h: saved.size.height), (x: 1.0, y: 1.0, w: 2.0, h: 2.0));
        expect(tester.widget<DashboardTile>(tile).rect, (x: 1, y: 1, width: 2, height: 2));

        // At its original size, a tap's menu no longer offers it either.
        await tester.tap(tile);
        await app.drive(const Duration(milliseconds: 600));
        expect(find.text('Colocar em tela cheia'), findsOneWidget, reason: 'the tap menu is open');
        expect(find.text('Restaurar tamanho original'), findsNothing);
      });
    } finally {
      await app.teardown();
    }
  });
}
