import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/display_style_metadata.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/obd/obd_preferences.dart';
import 'package:synapse_auto/services/obd/obd_service.dart';
import 'package:synapse_auto/widgets/sensors/obd_widgets.dart';

import 'support/fake_obd_car.dart';

void main() {
  late FakeObdCar car;
  late ObdPreferences prefs;

  setUp(() async {
    Hive.init('unused');
    await Hive.openBox(HiveBoxNames.appSettings, bytes: Uint8List(0));
    car = FakeObdCar();
    prefs = ObdPreferences();
  });

  tearDown(() async {
    await Hive.close();
  });

  Future<(ObdService, List<Color?>)> mount(WidgetTester tester, {ObdSignal signal = ObdSignal.rpm, bool tachometer = false, bool adapter = true}) async {
    if (adapter) await prefs.setAdapter(address: '10:21:3E:4C:3A:AF', name: 'V-LINK');
    final service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
    final alerts = <Color?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 220,
          height: 220,
          child: ObdSignalView(signal: signal, service: service, unit: 'rpm', tachometer: tachometer, onAlertColorChanged: alerts.add),
        ),
      ),
    ));
    return (service, alerts);
  }

  Future<void> unmount(WidgetTester tester, ObdService service) async {
    await tester.pumpWidget(const SizedBox());
    service.dispose();
    await tester.pump(const Duration(seconds: 12));
  }

  testWidgets('says what the link does while there is no value', (tester) async {
    final (service, _) = await mount(tester, adapter: false);
    expect(find.text('Configurar adaptador'), findsOneWidget);
    await prefs.setAdapter(address: '10:21:3E:4C:3A:AF', name: 'V-LINK');
    await tester.pump();
    expect(find.text('OBD desligado'), findsOneWidget);

    car.ignition = FakeIgnition.off;
    service.connect();
    await tester.pump();
    expect(find.text('Conectando…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Ligue o carro'), findsOneWidget);
    await unmount(tester, service);
  });

  testWidgets('live value, then after a drop the last value with a red border', (tester) async {
    final (service, alerts) = await mount(tester, signal: ObdSignal.coolant);
    service.connect();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('81'), findsOneWidget);
    expect(alerts.whereType<Color>(), isEmpty, reason: 'live: no alert');

    car.unplug();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(service.state, ObdLinkState.reconnecting);
    expect(find.text('81'), findsOneWidget, reason: 'the last value stays');
    expect(find.text('Reconectando…'), findsOneWidget);
    expect(alerts.last, isNotNull, reason: 'the card border turns red');
    expect(alerts.last!.r, greaterThan(alerts.last!.g), reason: 'red');

    car.plugIn();
    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 1));
    expect(service.state, ObdLinkState.receiving);
    expect(alerts.last, isNull, reason: 'live again: the border is back to normal');
    await unmount(tester, service);
  });

  testWidgets('a value the car does not report', (tester) async {
    // Take coolant (05) out of the engine's map: a car that does not report it.
    car.engine.bitmaps[0x00] = [0xB6, 0x3E, 0xB8, 0x13]; // bit for 05 cleared
    final (service, _) = await mount(tester, signal: ObdSignal.coolant);
    service.connect();
    await tester.pump(const Duration(seconds: 4));
    expect(service.supports(ObdSignal.coolant), isFalse);
    expect(find.text('Seu carro não informa este dado'), findsOneWidget);
    await unmount(tester, service);
  });

  testWidgets('the rev counter draws and shows the rpm', (tester) async {
    final (service, _) = await mount(tester, tachometer: true);
    service.connect();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('obdTachometer')), findsOneWidget);
    expect(find.text('982'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester, service);
  });

  test('every OBD sensor has a style, rpm offers the rev counter first', () {
    expect(validDisplayStylesForSensor[SensorType.engineRpm]!.first, DisplayStyle.tachometer);
    for (final type in obdSignalForSensor.keys) {
      expect(validDisplayStylesForSensor[type], isNotEmpty);
    }
  });
}
