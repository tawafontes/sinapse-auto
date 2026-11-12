// Turning the phone (owner request, 2026-11-12): in landscape the widgets used to
// be the portrait layout squashed onto a short 6x4 grid — twice as wide as tall.
// Landscape now has a layout of its own on an 8x3 grid: each widget full height,
// four side by side, in the portrait order; and turning back restores the
// portrait layout exactly. Through the real app over platform fakes
// (support/app_harness.dart), at an S23 Ultra's size. One test per file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('landscape lays the widgets out full height, four across, and portrait comes back unchanged', (tester) async {
    final app = AppHarness(tester);
    try {
      await app.run(() async {
        await app.boot(seedTiles: const {
          SensorType.speed: DisplayStyle.numericWithHistory,
          SensorType.inclination: DisplayStyle.artificialHorizon,
          SensorType.altitude: DisplayStyle.lineChart,
          SensorType.gForce: DisplayStyle.gForceMeter,
          SensorType.refuel: DisplayStyle.refuelSummary,
        });
        // S23 Ultra, portrait: 1080 x 2316 px at 2.625 → ~411 x 882 dp.
        tester.view.devicePixelRatio = 2.625;
        tester.view.physicalSize = const Size(1080, 2316);
        bool allPlaced() => SensorWidgetRepository.all.every((c) => c.position.x >= 0);
        await app.driveUntil(allPlaced, label: 'portrait placement');
        await app.drive(const Duration(milliseconds: 300));
        final portrait = {
          for (final c in SensorWidgetRepository.all) c.sensorType: (c.position.x, c.position.y, c.size.width, c.size.height, c.page),
        };

        // Sideways.
        tester.view.physicalSize = const Size(2316, 1080);
        bool allPlacedInLandscape() => SensorWidgetRepository.all.every((c) => c.landscapePosition != null);
        await app.driveUntil(allPlacedInLandscape, label: 'landscape placement');
        await app.drive(const Duration(milliseconds: 300));

        final landscape = {
          for (final c in SensorWidgetRepository.all)
            c.sensorType: (c.landscapePosition!.x, c.landscapePosition!.y, c.landscapeSize!.width, c.landscapeSize!.height, c.landscapePage),
        };
        // The portrait reading order (speed, inclination / altitude, gForce /
        // refuel), four per landscape page, each 2 columns x the full 3 rows.
        expect(landscape, {
          SensorType.speed: (0.0, 0.0, 2.0, 3.0, 0),
          SensorType.inclination: (2.0, 0.0, 2.0, 3.0, 0),
          SensorType.altitude: (4.0, 0.0, 2.0, 3.0, 0),
          SensorType.gForce: (6.0, 0.0, 2.0, 3.0, 0),
          SensorType.refuel: (0.0, 0.0, 2.0, 3.0, 1),
        });
        expect({for (final c in SensorWidgetRepository.all) c.sensorType: (c.position.x, c.position.y, c.size.width, c.size.height, c.page)},
            portrait, reason: 'the portrait layout is not touched by landscape');

        final shown = find.byType(DashboardTile).hitTestable();
        expect(shown, findsNWidgets(4), reason: 'four side by side on the first landscape page');
        for (final element in shown.evaluate()) {
          final size = tester.getSize(find.byWidget(element.widget));
          expect(size.height, greaterThan(size.width), reason: 'not squashed: taller than wide, like in portrait (got $size)');
        }

        // Upright again.
        tester.view.physicalSize = const Size(1080, 2316);
        await app.drive(const Duration(milliseconds: 600));
        final tiles = {for (final t in tester.widgetList<DashboardTile>(find.byType(DashboardTile))) t.label: t.rect};
        expect(tiles['Velocidade'], (x: portrait[SensorType.speed]!.$1.round(), y: portrait[SensorType.speed]!.$2.round(), width: 2, height: 2));
        expect({for (final c in SensorWidgetRepository.all) c.sensorType: (c.position.x, c.position.y, c.size.width, c.size.height, c.page)},
            portrait, reason: 'back to exactly the portrait layout');
      });
    } finally {
      await app.teardown();
    }
  });
}
