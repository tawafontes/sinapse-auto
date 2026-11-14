import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/screens/settings/obd_phase0_screen.dart';
import 'package:synapse_auto/services/obd/elm327_decode.dart';
import 'package:synapse_auto/services/obd/obd_bridge.dart';
import 'package:synapse_auto/services/obd/obd_phase0_runner.dart';

/// A scripted ELM327 on a CAN car: answers like the real adapter does with
/// echo/spaces/headers off. Unknown commands get `NO DATA`, an unknown AT `?`.
class FakeCar implements ObdBridge {
  final sent = <String>[];
  bool connected = false;

  static const answers = {
    'ATZ': '\r\rELM327 v2.3\r\r',
    'ATI': 'ELM327 v2.3\r\r',
    'AT@1': 'OBDII to RS232 Interpreter\r\r',
    'ATRV': '12.6V\r\r',
    'ATDP': 'AUTO, ISO 15765-4 (CAN 11/500)\r\r',
    'ATDPN': 'A6\r\r',
    'ATSH7E0': 'OK\r\r',
    'ATSH7DF': 'OK\r\r',
    // 01 03 04 05 06 07 0C 0D 0E 0F 10 11 13 15 1C 1F 20
    '0100': 'SEARCHING...\r41 00 BE 3F A8 13\r\r',
    // 21 2F 31 33 40
    '0120': '4120A0028001\r\r',
    // 42 51 5B
    '0140': '414040008020\r\r',
    '0101': '410100076100\r\r',
    '0105': '41057B\r\r',
    '010C': '410C1AF8\r\r',
    '010D': '410D20\r\r',
    '0104': '41047F\r\r',
    '0110': '41100155\r\r',
    '012F': '412F80\r\r',
    '0142': '414236B0\r\r',
    '0151': '415101\r\r',
    '015B': '415BCC\r\r',
    '0900': '49 00 54 40 00 00\r\r',
    '0902': '014\r0:490201314734\r1:4A433534343452\r2:37323532333637\r\r',
    '03': '430101330000\r\r',
    '07': '4300\r\r',
    '0A': '4A00\r\r',
  };

  @override
  Future<List<PairedDevice>> pairedDevices() async => [
        (name: 'Fone', address: '00:11:22:33:44:55'),
        (name: 'V-LINK', address: 'AA:BB:CC:DD:EE:FF'),
      ];

  @override
  Future<ObdConnection> connect(String address) async {
    connected = true;
    return (method: 'secure', millis: 812);
  }

  @override
  Future<ObdReply> send(String command, {Duration timeout = const Duration(seconds: 2)}) async {
    sent.add(command);
    if (!connected) throw const ObdBridgeException('not_connected', 'not connected');
    final answer = answers[command] ??
        (command.startsWith('AT') ? (command.length <= 5 ? 'OK\r\r' : '?\r\r') : (command.startsWith('010C0D') ? '410C1AF80D20\r\r' : 'NO DATA\r\r'));
    return (response: answer, millis: 48, timedOut: false);
  }

  @override
  Future<void> disconnect() async => connected = false;
}

void main() {
  group('ELM327 decoding', () {
    test('mode 01 data, with or without spaces, past the SEARCHING notice', () {
      expect(mode01Data('SEARCHING...\r41 0C 1A F8\r', 0x0C), [0x1A, 0xF8]);
      expect(mode01Data('410C1AF8', 0x0C), [0x1A, 0xF8]);
      expect(mode01Data('NO DATA', 0x0C), isNull);
      expect(describeMode01('410C1AF8', 0x0C), 'rotação 1726 rpm');
      expect(describeMode01('41057B', 0x05), 'motor 83 °C');
      expect(describeMode01('410D20', 0x0D), 'velocidade 32 km/h');
      expect(describeMode01('410100076100', 0x01), 'luz de injeção apagada, 0 código(s)');
      expect(describeMode01('410181076100', 0x01), 'luz de injeção ACESA, 1 código(s)');
    });

    test('the supported-PIDs bitmap', () {
      expect(supportedPids('41 00 BE 3F A8 13', 0x00), [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20]);
      expect(supportedPids('UNABLE TO CONNECT', 0x00), isNull);
    });

    test('the VIN of a multi-frame CAN answer', () {
      expect(vinFrom('014\r0:490201314734\r1:4A433534343452\r2:37323532333637\r'), '1G4JC5444R7252367');
      expect(vinFrom('NO DATA'), isNull);
    });

    test('errors and trouble codes', () {
      expect(elmError('SEARCHING...\rUNABLE TO CONNECT\r'), 'UNABLE TO CONNECT');
      expect(elmError('?'), '?');
      expect(elmError('410C1AF8'), isNull);
      expect(troubleCodes('430101330000', 0x43), ['P0133']);
      expect(troubleCodes('4300', 0x43), isEmpty);
      expect(troubleCodes('43 01 33 C1 23 00 00', 0x43), ['P0133', 'U0123']);
    });
  });

  group('phase 0 runner against a scripted car', () {
    test('the full sequence: set-up, search, PID map chain, VIN, codes, timing — read-only', () async {
      final car = FakeCar();
      final lines = <String>[];
      final runner = ObdPhase0Runner(car, write: lines.add);
      await runner.connect((name: 'V-LINK', address: 'AA:BB:CC:DD:EE:FF'));
      final r = await runner.runSequence();

      expect(car.sent.take(5), ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0']);
      expect(car.sent, containsAllInOrder(['ATSP0', '0100', 'ATDP', 'ATDPN', '0120', '0140']));
      expect(car.sent, isNot(contains('0160')), reason: '0x60 is not in the 0140 bitmap');
      expect(car.sent.where((c) => c.startsWith('04')), isEmpty, reason: 'never clears codes');
      expect(car.sent.every((c) => c.startsWith('AT') || RegExp(r'^(01|03|07|09|0A)').hasMatch(c)), isTrue);
      // The headers step runs last and leaves the adapter as the live run expects it.
      expect(car.sent, containsAllInOrder(['ATH1', '0100', '010C', 'ATSH7E0', '010C', 'ATSH7DF', 'ATH0']));
      expect(car.sent.last, 'ATH0');

      expect(r.connectMethod, 'secure');
      expect(r.adapterVersion, 'ELM327 v2.3');
      expect(r.batteryVoltage, '12.6V');
      expect(r.protocol, 'AUTO, ISO 15765-4 (CAN 11/500)');
      expect(r.searchResult, 'ok');
      expect(r.supported, containsAll([0x0C, 0x0D, 0x05, 0x2F, 0x42, 0x51, 0x5B]));
      expect(r.vin, '1G4JC5444R7252367');
      expect(r.mil, 'luz de injeção apagada, 0 código(s)');
      expect(r.troubleCodes['armazenados'], ['P0133']);
      expect(r.singlePidLatency, (min: 48, avg: 48, max: 48, count: 20));
      expect(r.multiPid['010C0D'], '6 bytes');

      expect(lines.any((l) => l.contains('> 010C') ), isTrue);
      expect(lines.any((l) => l.contains('< 410C1AF8 (48 ms)  => rotação 1726 rpm')), isTrue);
      expect(lines.any((l) => l.contains('PIDs do modo 01 suportados:')), isTrue);
    });

    test('the live loop reads the fast PIDs every cycle and stops when asked', () async {
      final car = FakeCar()..connected = true;
      final runner = ObdPhase0Runner(car, write: (_) {});
      runner.report.supported.addAll([0x0C, 0x0D, 0x05]);
      final values = <String, String>{};
      var cycles = 0;
      await runner.runLive(
        duration: const Duration(minutes: 5),
        cancelled: () => ++cycles > 12,
        onValue: (k, v) => values[k] = v,
      );
      expect(values['0C'], 'rotação 1726 rpm');
      expect(values['ATRV'], 'bateria 12.6V');
      expect(car.sent, contains('0105'));
    });

    test('without a link the sequence logs the error once and sends nothing more', () async {
      final car = FakeCar(); // never connected: every send fails
      final lines = <String>[];
      final runner = ObdPhase0Runner(car, write: lines.add);
      final r = await runner.runSequence();
      expect(lines.where((l) => l.contains('! erro not_connected')), hasLength(1));
      expect(car.sent, ['ATZ']);
      expect(runner.linkLost, isTrue);
      expect(r.supported, isEmpty);
    });

    test('a link dropped mid-trip ends the live loop at once, and a reconnect resumes', () async {
      final car = FakeCar();
      final lines = <String>[];
      final runner = ObdPhase0Runner(car, write: lines.add);
      const device = (name: 'V-LINK', address: 'AA:BB:CC:DD:EE:FF');
      await runner.connect(device);
      runner.report.supported.addAll([0x0C, 0x0D, 0x05]);
      var cycles = 0;
      final watch = Stopwatch()..start();
      await runner.runLive(
        duration: const Duration(minutes: 5),
        cancelled: () {
          // The adapter goes away after a few reads, as when it is unplugged.
          if (++cycles == 5) car.connected = false;
          return false;
        },
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'no spinning until the 5 minutes end');
      expect(lines.where((l) => l.contains('! erro')), hasLength(1));
      expect(lines.where((l) => l.contains('conexão perdida')), hasLength(1));
      expect(lines.last, contains('leitura contínua encerrada'));

      final sentBefore = car.sent.length;
      await runner.connect(device);
      expect(runner.linkLost, isFalse);
      await runner.probeCar();
      expect(car.sent.sublist(sentBefore), ['ATRV', '0100']);
    });
  });

  testWidgets('the screen picks the adapter, connects, runs the sequence and writes the transcript file', (tester) async {
    final dir = Directory.systemTemp.createTempSync('obd_phase0_screen');
    addTearDown(() => dir.deleteSync(recursive: true));
    final car = FakeCar();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: ObdPhase0Screen(bridge: car, directory: dir)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.textContaining('V-LINK · AA:BB:CC:DD:EE:FF'), findsOneWidget, reason: 'the likely adapter is preselected');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('obd0_connect')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(car.connected, isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('obd0_sequence')));
      for (var i = 0; i < 20 && !car.sent.contains('010C0D'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    final files = dir.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    final text = files.single.readAsStringSync();
    expect(text, startsWith('# Synapse Auto — OBD-II fase 0'));
    expect(text, contains('conectado pelo método secure em 812 ms'));
    expect(text, contains('# resumo: versão ELM327 v2.3'));
    expect(text, contains('VIN 1G4JC5444R7252367'));

    // The adapter goes away: the next action finds out, and "Conectar" is back.
    car.connected = false;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('obd0_probe')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('obd0_connect')), findsOneWidget);
    expect(find.byKey(const ValueKey('obd0_disconnect')), findsNothing);
  });
}
