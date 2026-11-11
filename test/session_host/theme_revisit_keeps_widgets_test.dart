// Settings → Tema → Concluir AFTER the onboarding never adds widgets: only the first "Concluir"
// fills the dashboard, so a widget the user deleted stays deleted. Through the real app over
// platform fakes (support/app_harness.dart). One test per file.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('revisiting Tema → Concluir after the onboarding leaves an emptied dashboard empty', (tester) async {
    final app = AppHarness(tester);
    try {
      await app.run(() async {
        await app.boot();
        expect(SensorWidgetRepository.all, isEmpty, reason: 'setup: onboarding done, every widget deleted');

        await app.tapThemeConclude();
        await app.settleDashboardTransition();
        await app.drive(const Duration(milliseconds: 500));

        expect(SensorWidgetRepository.all, isEmpty);
      });
    } finally {
      await app.teardown();
    }
  });
}
