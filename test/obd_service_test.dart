import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/obd/elm327_decode.dart';
import 'package:synapse_auto/services/obd/obd_preferences.dart';
import 'package:synapse_auto/services/obd/obd_service.dart';

import 'support/fake_obd_car.dart';

/// The engine's real PID map on the Nivus (rodada 22:58, ATSH7E0).
const nivusEngine = {
  0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x13, 0x14, 0x15, 0x1C, 0x1F, 0x20, //
  0x21, 0x23, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x3C, 0x40, //
  0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x49, 0x4A, 0x4C, 0x51, 0x52,
};

void main() {
  group('decoding (real Nivus answers)', () {
    test('a two-frame multi-PID answer, headers off', () {
      // rodada 22:51, 010C0D050411 — two ECUs, the first one's answer counts.
      const raw = '00C\r0:410C0F4A0D00\r1:0579042C1129AA\r00C\r0:410C0F480D00\r1:0579042B112900\r\r';
      final values = mode01Values(raw, [0x0C, 0x0D, 0x05, 0x04, 0x11]);
      expect(values.keys, [0x0C, 0x0D, 0x05, 0x04, 0x11]);
      expect(mode01Physical(0x0C, values[0x0C]!), 978.5);
      expect(mode01Physical(0x05, values[0x05]!), 81);
      expect(mode01Physical(0x04, values[0x04]!)!.round(), 17);
    });

    test('a PID the ECU leaves out is just absent, padding stops the walk', () {
      final values = mode01Values('410C0F580D00\r', [0x0C, 0x0D, 0x11]);
      expect(values.keys, [0x0C, 0x0D]);
    });

    test('the engine is the ECU with the biggest 0100 bitmap', () {
      expect(engineEcuFrom('7E906410098188001\r7E8064100BE3EB813\r\r'), 0x7E8);
      expect(engineEcuFrom('7E8064100BE3EB813\r7E906410098188001\r\r'), 0x7E8);
      expect(engineEcuFrom('NO DATA\r\r'), isNull);
      expect(engineEcuFrom('410098188001\r'), isNull, reason: 'headers off: no CAN id to tell');
    });

    test('ATRV', () {
      expect(adapterVoltage('ATRV\r13.3V\r\r'), 13.3);
      expect(adapterVoltage('?\r'), isNull);
    });
  });

  group('ObdService against the scripted Nivus', () {
    late FakeObdCar car;
    late ObdPreferences prefs;
    late ObdService service;

    setUp(() async {
      Hive.init('unused');
      await Hive.openBox(HiveBoxNames.appSettings, bytes: Uint8List(0));
      car = FakeObdCar();
      prefs = ObdPreferences();
    });

    tearDown(() async {
      await Hive.close();
    });

    Future<void> start(WidgetTester tester, {bool autoConnect = true}) async {
      await prefs.setAdapter(address: '10:21:3E:4C:3A:AF', name: 'V-LINK');
      await prefs.setAutoConnect(autoConnect);
      service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
      service.resume();
    }

    Future<void> finish(WidgetTester tester) async {
      service.dispose();
      await tester.pump(const Duration(seconds: 12));
    }

    testWidgets('connects, sets the adapter up, addresses the engine and polls it', (tester) async {
      await start(tester);
      expect(service.state, ObdLinkState.connecting);
      await tester.pump(const Duration(seconds: 3));

      expect(service.state, ObdLinkState.receiving);
      expect(car.sent.take(6), ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0']);
      expect(car.sent, containsAllInOrder(['ATH1', '0100', 'ATH0', 'ATSH7E0', '0100', '0120', '0140']));
      expect(service.info.engineEcu, 0x7E8);
      expect(service.info.connectMethod, 'secure');
      expect(service.info.elmVersion, 'ELM327 v2.3');
      expect(service.info.protocol, 'A6');
      expect(service.info.supportedPids, nivusEngine, reason: 'only the engine\'s map, never the other ECU\'s');
      expect(car.sent, isNot(contains('0160')), reason: 'not announced by 0140');

      await tester.pump(const Duration(seconds: 2));
      expect(car.sent, contains('010C040D11'), reason: 'the fast group in one request');
      expect(car.sent, contains('0105422F'), reason: 'coolant, module voltage, fuel level');
      expect(car.sent.where((c) => c.startsWith('04')), isEmpty, reason: 'never clears codes');
      expect(service.readings[ObdSignal.rpm]!.value, 982);
      expect(service.readings[ObdSignal.coolant]!.value, 81);
      expect(service.readings[ObdSignal.fuelLevel]!.value.round(), 50);
      expect(service.readings[ObdSignal.adapterVoltage]!.value, 13.3);
      expect(service.isFresh(ObdSignal.rpm), isTrue);
      expect(service.supports(ObdSignal.fuelLevel), isTrue);

      // Twice a second (owner decision).
      final before = car.sent.where((c) => c == '010C040D11').length;
      await tester.pump(const Duration(seconds: 10));
      final perSecond = (car.sent.where((c) => c == '010C040D11').length - before) / 10;
      expect(perSecond, inInclusiveRange(1.7, 2.1));

      car.rpm = 2500;
      await tester.pump(const Duration(seconds: 1));
      expect(service.readings[ObdSignal.rpm]!.value, 2500);
      await finish(tester);
    });

    testWidgets('ignition off: waits for the car with the link up, then picks it up', (tester) async {
      car.ignition = FakeIgnition.off;
      await start(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.waitingForCar);
      expect(service.readings[ObdSignal.adapterVoltage]!.value, 11.8);
      expect(service.isFresh(ObdSignal.adapterVoltage), isTrue);

      await tester.pump(const Duration(minutes: 4));
      expect(service.state, ObdLinkState.waitingForCar, reason: 'on the Nivus nothing slept in 4 min');
      expect(car.connects, 1);

      car.ignition = FakeIgnition.on;
      await tester.pump(const Duration(seconds: 5));
      expect(service.state, ObdLinkState.receiving);
      expect(service.info.engineEcu, 0x7E8);
      await tester.pump(const Duration(seconds: 1));
      expect(service.readings[ObdSignal.rpm]!.value, 0, reason: 'ignition on, engine stopped');
      expect(car.connects, 1);
      await finish(tester);
    });

    testWidgets('the car switched off mid-drive: back to waiting, last values kept but not live', (tester) async {
      await start(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(service.state, ObdLinkState.receiving);

      car.ignition = FakeIgnition.off;
      await tester.pump(const Duration(seconds: 2));
      expect(service.state, ObdLinkState.waitingForCar);
      expect(service.readings[ObdSignal.rpm]!.value, 982, reason: 'the last value stays for the widget');
      expect(service.isFresh(ObdSignal.rpm), isFalse);
      expect(car.connects, 1, reason: 'not a link failure');
      await finish(tester);
    });

    testWidgets('adapter pulled mid-drive: lost in ~1.5 s, retried, set up again from scratch', (tester) async {
      await start(tester);
      await tester.pump(const Duration(seconds: 5));
      car.unplug();
      final pulledAt = tester.binding.clock.now();
      while (service.state != ObdLinkState.reconnecting) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final detected = tester.binding.clock.now().difference(pulledAt);
      expect(detected, lessThan(const Duration(milliseconds: 2500)), reason: 'three unanswered 500 ms requests');
      expect(service.detail, 'Sem resposta do adaptador');
      expect(service.readings[ObdSignal.rpm], isNotNull);
      expect(service.isFresh(ObdSignal.rpm), isFalse);

      // Still pulled at the first retry (5 s): the next wait is 15 s.
      await tester.pump(const Duration(seconds: 6));
      expect(car.connects, 2);
      expect(service.state, ObdLinkState.reconnecting);
      expect(service.reconnectAttempt, 2);

      car.plugIn();
      final sentBefore = car.sent.length;
      await tester.pump(const Duration(seconds: 18));
      expect(service.state, ObdLinkState.receiving);
      expect(car.connects, 3);
      final again = car.sent.sublist(sentBefore);
      expect(again.take(6), ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0'], reason: 'it came back with factory defaults');
      expect(again, contains('ATSH7E0'));
      expect(service.isFresh(ObdSignal.rpm), isTrue);
      await finish(tester);
    });

    testWidgets('adapter absent: retries after 5, 15, 30 and then every 60 s', (tester) async {
      car.unplug();
      await start(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(service.state, ObdLinkState.reconnecting);
      expect(service.detail, 'Adaptador não encontrado (desligado ou fora de alcance)');
      final times = <int>[];
      var last = car.connects;
      for (var s = 1; s <= 200; s++) {
        await tester.pump(const Duration(seconds: 1));
        if (car.connects != last) {
          last = car.connects;
          times.add(s);
        }
      }
      // The first retry 5 s after the first failure, then 15, 30, 60, 60 s
      // apart — give or take the ~0.45 s each attempt spends in connect().
      expect(times.first, 5);
      final gaps = [for (var i = 1; i < 5; i++) times[i] - times[i - 1]];
      for (final (gap, wanted) in [for (var i = 0; i < 4; i++) (gaps[i], [15, 30, 60, 60][i])]) {
        expect(gap, inInclusiveRange(wanted, wanted + 1));
      }
      await finish(tester);
    });

    testWidgets('a car answering one PID per request: falls back to single requests', (tester) async {
      car.acceptsMultiPid = false;
      await start(tester);
      await tester.pump(const Duration(seconds: 6));
      expect(service.info.multiPid, isFalse);
      expect(car.sent, contains('0104'));
      expect(service.readings[ObdSignal.engineLoad], isNotNull);
      expect(service.state, ObdLinkState.receiving);
      await finish(tester);
    });

    testWidgets('Desconectar stays off on resume until Conectar', (tester) async {
      await start(tester);
      await tester.pump(const Duration(seconds: 3));
      await service.disconnect();
      expect(service.state, ObdLinkState.off);
      expect(car.connected, isFalse);
      service.resume();
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.off);
      service.connect();
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.receiving);
      await finish(tester);
    });

    testWidgets('background release (pause) and resume', (tester) async {
      await start(tester);
      await tester.pump(const Duration(seconds: 3));
      await service.pause();
      expect(service.state, ObdLinkState.off);
      expect(car.connected, isFalse);
      service.resume();
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.receiving);
      await finish(tester);
    });

    testWidgets('automatic connection off: resume does nothing, Conectar works', (tester) async {
      await start(tester, autoConnect: false);
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.off);
      expect(car.connects, 0);
      service.connect();
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.receiving);
      await finish(tester);
    });

    testWidgets('no adapter chosen, then one is', (tester) async {
      service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
      expect(service.state, ObdLinkState.noAdapter);
      service.resume();
      await tester.pump(const Duration(seconds: 1));
      expect(car.connects, 0);
      await prefs.setAdapter(address: '10:21:3E:4C:3A:AF', name: 'V-LINK');
      expect(service.state, ObdLinkState.off);
      service.resume();
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.receiving);
      await prefs.clearAdapter();
      await tester.pump();
      expect(service.state, ObdLinkState.noAdapter);
      await finish(tester);
    });
  });
}
