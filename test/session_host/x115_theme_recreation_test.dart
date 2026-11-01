// Fase 16.2-R4.3-R2.6.8 — X115. See recreation_checks.dart.
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import 'recreation_checks.dart';

void main() {
  testWidgets(
    'X115 Tema → Concluir while recording: the dashboard is replaced but session A, its recorder, '
    'controller and pipeline are the same, A keeps collecting, and its STOP stores every sample and clip',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot();
          await expectRecreationKeepsSession(app, app.tapThemeConclude);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
