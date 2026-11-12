// The refuel widget (2026-11-12) on the real dashboard, through the real app over
// platform fakes (support/app_harness.dart): its button works inside a tile whose
// own tap/double-tap gestures surround it, it follows the vehicle profile and the
// refuel log live, and Configurações → Veículo reaches the vehicle menu. One test
// per file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/refuel_record.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/models/vehicle_profile.dart';
import 'package:synapse_auto/screens/vehicle/vehicle_menu_screen.dart';
import 'package:synapse_auto/screens/vehicle/vehicle_profile_screen.dart';
import 'package:synapse_auto/services/vehicle_repository.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('the refuel tile opens Meu veículo, then shows the range once refuels exist; settings reach Veículo', (tester) async {
    final app = AppHarness(tester);
    try {
      await app.run(() async {
        await app.boot(seedTiles: const {SensorType.refuel: DisplayStyle.refuelSummary});
        final tile = find.byWidgetPredicate((w) => w is DashboardTile && w.label == 'Abastecimento');
        expect(tile.hitTestable(), findsOneWidget);

        final setUp = find.descendant(of: tile, matching: find.byKey(const ValueKey('refuelWidget_setUpVehicle')));
        expect(setUp, findsOneWidget, reason: 'no vehicle yet');
        await tester.tap(setUp);
        // The tile's double-tap recognizer holds the arena for kDoubleTapTimeout
        // before the button's tap is accepted.
        await app.driveUntil(() => find.byType(VehicleProfileScreen).evaluate().isNotEmpty, label: 'Meu veículo opened');
        await app.backToDashboard();

        await app.driveFuture(VehicleRepository.save(VehicleProfile(
          fuelSystem: VehicleFuelSystem.flex,
          tankCapacityLiters: 50,
          kmPerLiterGasoline: 12,
          kmPerLiterEthanol: 8.4,
          defaultFuel: FuelType.gasoline,
        )));
        await app.drive(const Duration(milliseconds: 100));
        expect(find.descendant(of: tile, matching: find.text('Nenhum abastecimento registrado')), findsOneWidget);

        final now = DateTime.now();
        for (final (id, days, odometer) in [('1', 3, 1000.0), ('2', 1, 1400.0)]) {
          await app.driveFuture(RefuelRepository.save(RefuelRecord(
            id: id,
            date: now.subtract(Duration(days: days)),
            odometerKm: odometer,
            liters: 40,
            pricePerLiter: 6,
            fuel: FuelType.gasoline,
            fullTank: true,
          )));
        }
        await app.drive(const Duration(milliseconds: 100));
        final range = find.descendant(of: tile, matching: find.byKey(const ValueKey('refuelWidget_range')));
        expect(tester.widget<Text>(range).data, '~500 km', reason: '400 km / 40 L = 10 km/L × a full 50 L tank');

        await app.openSettings();
        await app.tapText('Veículo');
        await app.driveUntil(() => find.byType(VehicleMenuScreen).evaluate().isNotEmpty, label: 'vehicle menu');
        expect(app.shows('Abastecimentos'), isTrue);
        expect(app.shows('Relatórios'), isTrue);
        // The framework's own texts (the refuel form's date picker among them)
        // are in Brazilian Portuguese.
        final localizations = MaterialLocalizations.of(tester.element(find.byType(VehicleMenuScreen)));
        expect((localizations.cancelButtonLabel, localizations.formatMonthYear(DateTime(2026, 11))), ('Cancelar', 'novembro de 2026'));
      });
    } finally {
      await app.teardown();
    }
  });
}
