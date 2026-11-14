import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/driving_session_host.dart';
import 'package:synapse_auto/services/obd/obd_service.dart';

import '../support/app_harness.dart';
import '../support/fake_obd_car.dart';

/// Configurações → Veículo → Adaptador OBD-II in the REAL app over the
/// scripted Nivus: no adapter at first, the paired list with the V-LINK on
/// top, connecting to it, what the link learned about the car, and the
/// Desconectar/Conectar button and automatic connection switch.
void main() {
  testWidgets('the OBD-II adapter screen', (tester) async {
    final app = AppHarness(tester);
    final car = FakeObdCar();
    DrivingSessionHost.debugObdBridgeOverride = car;
    try {
      await app.run(() async {
        await app.boot();
        final obd = app.host.obd!;
        expect(obd.state, ObdLinkState.noAdapter);
        expect(car.connects, 0, reason: 'nothing to connect to yet');

        await app.openSettings();
        await app.tapText('Veículo');
        await app.driveUntil(() => app.shows('Adaptador OBD-II'), label: 'vehicle menu entry');
        expect(app.shows('Escolher o adaptador e conectar ao carro'), isTrue);
        await app.tapText('Adaptador OBD-II');
        await app.tapText('Escolher adaptador');

        // The paired list: the adapter first, the phone's other device after.
        await app.driveUntil(() => app.shows('Aparelhos pareados'), label: 'paired list');
        final vlink = tester.getTopLeft(find.byKey(const ValueKey('obdDevice_10:21:3E:4C:3A:AF')));
        final phone = tester.getTopLeft(find.byKey(const ValueKey('obdDevice_00:11:22:33:44:55')));
        expect(vlink.dy, lessThan(phone.dy));
        await app.tapText('V-LINK');

        await app.driveUntil(() => obd.state == ObdLinkState.receiving, label: 'connected to the car');
        await app.driveUntil(() => app.shows('Recebendo dados'), label: 'state shown');
        String info(String label) => tester.widget<Text>(find.byKey(ValueKey('obdAdapter_info_$label'))).data!;
        expect(info('Adaptador'), 'ELM327 v2.3');
        expect(info('Central do motor'), '7E8');
        expect(info('Protocolo'), 'ISO 15765-4 CAN (11 bits, 500 kbps)');
        expect(info('PIDs suportados'), startsWith('39: 01 03 04 05'));

        await tester.tap(find.byKey(const ValueKey('obdAdapter_connectButton')));
        await app.driveUntil(() => obd.state == ObdLinkState.off, label: 'disconnected');
        await app.driveUntil(() => app.shows('Conectar'), label: 'the button now says Conectar');
        await tester.tap(find.byKey(const ValueKey('obdAdapter_connectButton')));
        await app.driveUntil(() => obd.state == ObdLinkState.receiving, label: 'connected again');

        await tester.tap(find.byKey(const ValueKey('obdAdapter_autoConnect')));
        await app.drive(const Duration(milliseconds: 300));
        expect(obd.preferences.autoConnect, isFalse);
        expect(obd.state, ObdLinkState.receiving, reason: 'turning automatic off keeps the current link');
      });
    } finally {
      DrivingSessionHost.debugObdBridgeOverride = null;
      await app.teardown();
    }
  });
}
