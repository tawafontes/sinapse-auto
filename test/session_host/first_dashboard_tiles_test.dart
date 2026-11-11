// The first dashboard after the REAL onboarding (Configurar → Pular por agora → Concluir) shows every
// widget in its default style — it used to open empty, by design of an earlier round. Through the
// real app over platform fakes (support/app_harness.dart). One test per file.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/display_style_metadata.dart';
import 'package:synapse_auto/models/sensor_type_metadata.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('the onboarding ends on a dashboard showing every widget, each in its default style', (tester) async {
    final app = AppHarness(tester);
    try {
      await app.run(() async {
        await app.boot(onboardingDone: false);
        expect(SensorWidgetRepository.all, isEmpty, reason: 'setup: a fresh install');

        await app.tapText('Configurar');
        await app.tapText('Pular por agora');
        await app.driveUntil(() => app.shows('Concluir'), label: 'theme step');
        await tester.tap(find.text('Concluir').hitTestable().last);
        await app.settleDashboardTransition();
        await app.drive(const Duration(milliseconds: 500));

        final configs = SensorWidgetRepository.all;
        expect({for (final c in configs) c.sensorType}, sensorTypeMetadata.keys.toSet());
        for (final c in configs) {
          expect(c.displayStyle, validDisplayStylesForSensor[c.sensorType]!.first, reason: '${c.sensorType} in its default style');
          expect(c.position.x, greaterThanOrEqualTo(0), reason: '${c.sensorType} placed on the grid');
        }
        expect(find.byType(DashboardTile).hitTestable().evaluate(), hasLength(sensorTypeMetadata.length), reason: 'every widget on screen');
      });
    } finally {
      await app.teardown();
    }
  });
}
