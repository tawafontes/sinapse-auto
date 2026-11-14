import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_type_metadata.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/driving_session_host.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/obd/obd_service.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

import '../support/app_harness.dart';
import '../support/fake_obd_car.dart';

/// OBD-II phase 1 end to end, in the REAL app over the scripted Nivus: the
/// host connects on its own, the dashboard's rev counter and coolant cards
/// follow the link, the snapshot carries live engine values, "Iniciar sessão
/// quando o carro ligar" starts a session when the engine turns (not when the
/// ignition alone answers), a pulled adapter turns the card border red with
/// the last value, and a session stopped by hand is not restarted while the
/// engine still runs.
void main() {
  testWidgets('OBD-II phase 1 in the real app', (tester) async {
    final app = AppHarness(tester);
    final car = FakeObdCar()..ignition = FakeIgnition.off;
    DrivingSessionHost.debugObdBridgeOverride = car;
    try {
      await app.run(() async {
        await app.boot(
          seedTiles: const {SensorType.engineRpm: DisplayStyle.tachometer, SensorType.engineCoolant: DisplayStyle.obdValue},
          beforeBootstrap: () async {
            final box = Hive.box(HiveBoxNames.appSettings);
            await box.put('obdAdapterAddress', '10:21:3E:4C:3A:AF');
            await box.put('obdAdapterName', 'V-LINK');
            await box.put('obdAutoStartSession', true);
          },
        );
        final obd = app.host.obd!;
        final recorder = app.host.recorder;
        DashboardTile tile(SensorType type) => tester.widget<DashboardTile>(
              find.byWidgetPredicate((w) => w is DashboardTile && w.label == sensorTypeMetadata[type]!.label),
            );
        bool tileShows(SensorType type, String text) => find
            .descendant(of: find.byWidgetPredicate((w) => w is DashboardTile && w.label == sensorTypeMetadata[type]!.label), matching: find.text(text))
            .evaluate()
            .isNotEmpty;

        // Connected on its own; the car is off.
        await app.driveUntil(() => obd.state == ObdLinkState.waitingForCar, label: 'waiting for the car');
        expect(find.byKey(const ValueKey('obdStatusIcon')), findsOneWidget);
        expect(tileShows(SensorType.engineRpm, 'Ligue o carro'), isTrue);

        // Ignition on, engine stopped: the ECUs answer, but no session.
        car.ignition = FakeIgnition.on;
        await app.driveUntil(() => obd.state == ObdLinkState.receiving, label: 'receiving');
        await app.drive(const Duration(seconds: 2));
        expect(recorder.state, DrivingSessionRecorderState.idle, reason: 'the ignition alone does not start a session');
        expect(tileShows(SensorType.engineRpm, '0'), isTrue);

        // The engine starts: the session starts by itself.
        car.ignition = FakeIgnition.running;
        await app.driveUntil(() => recorder.state == DrivingSessionRecorderState.recording, label: 'session started by the car');
        await app.driveUntil(() => tileShows(SensorType.engineRpm, '982'), label: 'rpm on the rev counter');
        await app.driveUntil(() => tileShows(SensorType.engineCoolant, '81'), label: 'coolant on its card');
        final snapshot = await app.driveFuture(app.host.streams.snapshot.firstWhere((s) => s.engineRpm != null));
        expect(snapshot.engineRpm, 982);
        expect(snapshot.obdLinkState, ObdLinkState.receiving);
        expect(tile(SensorType.engineRpm).alertColor, isNull);

        // The adapter is pulled: last value, red border; then it comes back.
        car.unplug();
        await app.driveUntil(() => obd.state == ObdLinkState.reconnecting, label: 'link lost');
        await app.driveUntil(() => tile(SensorType.engineCoolant).alertColor != null, label: 'red border');
        expect(tileShows(SensorType.engineCoolant, '81'), isTrue, reason: 'the last value stays');
        final stale = await app.driveFuture(app.host.streams.snapshot.first);
        expect(stale.engineRpm, isNull, reason: 'the snapshot carries live values only');
        car.plugIn();
        await app.driveUntil(() => obd.state == ObdLinkState.receiving, timeout: const Duration(seconds: 40), label: 'reconnected');
        await app.driveUntil(() => tile(SensorType.engineCoolant).alertColor == null, label: 'border back to normal');

        // Stopped by hand while the engine runs: not restarted.
        await app.stopSessionViaUi();
        await app.drive(const Duration(seconds: 3));
        expect(recorder.state, DrivingSessionRecorderState.idle);
      });
    } finally {
      DrivingSessionHost.debugObdBridgeOverride = null;
      await app.teardown();
    }
  });
}
