import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/diagnostic_report.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/obd/diagnostic/diagnostic_policy.dart';
import 'package:synapse_auto/services/obd/diagnostic/diagnostic_report_repository.dart';
import 'package:synapse_auto/services/obd/diagnostic/dtc_catalog.dart';
import 'package:synapse_auto/services/obd/diagnostic/obd_modes.dart';
import 'package:synapse_auto/services/obd/diagnostic/report_runner.dart';
import 'package:synapse_auto/services/obd/diagnostic/reports/battery_report.dart';
import 'package:synapse_auto/services/obd/diagnostic/reports/emissions_report.dart';
import 'package:synapse_auto/services/obd/diagnostic/reports/health_report.dart';
import 'package:synapse_auto/services/obd/elm327_decode.dart';
import 'package:synapse_auto/services/obd/obd_preferences.dart';
import 'package:synapse_auto/services/obd/obd_service.dart';

import 'support/fake_obd_car.dart';

void main() {
  group('the command policy', () {
    test('reads pass', () {
      for (final c in ['ATRV', 'ATSH7DF', 'ATSH7E0', 'ATCRA7E8', 'ATAR', 'ATH1', 'ATH0', 'ATDPN', 'ATST32', '0100', '010C0D', '03', '07', '0A', '020200', '0902', '0600', '3E00', '1001', '22F190', '1902FF']) {
        expect(() => DiagnosticCommandPolicy.check(c), returnsNormally, reason: c);
      }
    });

    test('writes, resets and the dangerous sessions are refused', () {
      for (final c in ['04', '1003', '1002', '1101', '14FFFFFF', '2701', '2E F190 00', '2F0101', '3101FF00', '3401', '85 02', '28 00', '22F1A0', 'ATMA', 'ATZ', 'ATPP0C', 'ATWS', 'hello']) {
        expect(() => DiagnosticCommandPolicy.check(c), throwsA(isA<DiagnosticCommandRefused>()), reason: c);
      }
    });

    test('mode 04 only on the guarded path, and alone', () {
      expect(() => DiagnosticCommandPolicy.check('04', clearingEngine: true), returnsNormally);
      expect(() => DiagnosticCommandPolicy.check('0401', clearingEngine: true), throwsA(isA<DiagnosticCommandRefused>()));
      expect(() => DiagnosticCommandPolicy.check('1101', clearingEngine: true), throwsA(isA<DiagnosticCommandRefused>()));
    });
  });

  group('decoding', () {
    test('ISO-TP messages by ECU, headers on', () {
      const raw = '7E81008430303010171\r7E82102005555555555\r7E9024300\r\r';
      final messages = canMessages(raw);
      expect(messages[0x7E8]!.single, [0x43, 0x03, 0x03, 0x01, 0x01, 0x71, 0x02, 0x00]);
      expect(dtcsFromMessage(messages[0x7E8]!.single, 0x03), ['P0301', 'P0171', 'P0200']);
      expect(dtcsFromMessage(messages[0x7E9]!.single, 0x03), isEmpty);
    });

    test('codes of every letter', () {
      expect(dtcFromBytes(0x03, 0x01), 'P0301');
      expect(dtcFromBytes(0x0A, 0x94), 'P0A94');
      expect(dtcFromBytes(0x41, 0x23), 'C0123');
      expect(dtcFromBytes(0x91, 0x00), 'B1100');
      expect(dtcFromBytes(0xC1, 0x00), 'U0100');
    });

    test('the monitors of PID 01', () {
      final status = monitorStatus([0x82, 0x07, 0x65, 0x04])!;
      expect(status.mil, isTrue);
      expect(status.dtcCount, 2);
      expect(status.compression, isFalse);
      expect(status.supported.map((m) => m.key), containsAll(['misfire', 'fuel', 'components', 'catalyst', 'evap', 'o2Sensor', 'o2Heater']));
      expect(status.incomplete.map((m) => m.key), ['evap']);
    });

    test('identification: VIN, the ECU name, the mask', () {
      final vinMessage = [0x49, 0x02, 0x01, ...'9BWZZZ5Z0MP012345'.codeUnits];
      expect(vinFromMessage(vinMessage), '9BWZZZ5Z0MP012345');
      expect(maskVin('9BWZZZ5Z0MP012345'), '9BW••••••••••2345');
      expect(manufacturerFromVin('9BWZZZ5Z0MP012345'), 'Volkswagen (Brasil)');
      final name = [0x49, 0x0A, 0x01, ...'ECM'.codeUnits, 0, ...'-EngineControl'.codeUnits, 0, 0];
      expect(ecuName(name), 'ECM-EngineControl');
    });

    test('the code table: described, the system only, the maker', () {
      final json = jsonDecode(File('assets/obd/dtc_generic_pt.json').readAsStringSync()) as Map;
      final catalog = DtcCatalog.fromJson(json.cast<String, Object?>());
      expect(catalog.length, greaterThan(700));
      expect(catalog.knowledge('P0301'), DtcKnowledge.described);
      expect(catalog.describe('P0301'), contains('cilindro 1'));
      expect(catalog.knowledge('P1234'), DtcKnowledge.manufacturer);
      expect(catalog.describe('U1234'), startsWith('Código do fabricante'));
      expect(catalog.knowledge('P0A94'), DtcKnowledge.described);
    });
  });

  group('the battery verdicts', () {
    BatteryStep withSamples(String kind, List<double> volts, {String? phase, List<double?>? rpm, int stepMs = 100}) {
      final step = BatteryStep(kind, phase: phase);
      for (var i = 0; i < volts.length; i++) {
        step.samples.add((ms: i * stepMs, volts: volts[i], rpm: rpm?[i]));
      }
      return step;
    }

    test('rest', () {
      for (final (v, level) in [(12.7, ReportLevel.ok), (12.45, ReportLevel.ok), (12.2, ReportLevel.attention), (11.8, ReportLevel.problem)]) {
        final step = BatteryStep('rest')..values['volts'] = v;
        BatteryVerdicts.rest(step, hybrid: false);
        expect(step.level, level, reason: '$v V');
      }
    });

    test('cranking: the minimum, and no dip means no crank seen', () {
      final good = withSamples('crank', [12.5, 12.4, 10.1, 10.4, 11.8, 13.6, 14.1, 14.2]);
      BatteryVerdicts.crank(good);
      expect(good.level, ReportLevel.ok);
      expect(good.values['min'], 10.1);
      final weak = withSamples('crank', [12.3, 8.7, 9.5, 13.8]);
      BatteryVerdicts.crank(weak);
      expect(weak.level, ReportLevel.problem);
      final none = withSamples('crank', [12.5, 12.4, 12.5]);
      BatteryVerdicts.crank(none);
      expect(none.level, ReportLevel.unknown);
    });

    test('a hybrid going READY: the dip, then the DC-DC within 5 s, or not', () {
      final ok = withSamples('activation', [12.5, 12.5, 12.1, 11.9, 12.0, 14.0, 14.1, 14.1, 14.0, 14.1, 14.1, 14.0, 14.1], stepMs: 500);
      BatteryVerdicts.activation(ok);
      expect(ok.level, ReportLevel.ok);
      expect(ok.values['dip'], 11.9);
      expect(ok.values['dcdc'], closeTo(14.06, 0.05));
      final noDcdc = withSamples('activation', [12.5, 12.0, 11.9, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0, 12.0], stepMs: 500);
      BatteryVerdicts.activation(noDcdc);
      expect(noDcdc.level, ReportLevel.problem);
      expect(noDcdc.verdict, contains('DC-DC'));
    });

    test('charging: normal, low, and the engine starting on a hybrid', () {
      final normal = withSamples('charge', List.filled(40, 14.1), phase: 'idle', rpm: List.filled(40, 800));
      BatteryVerdicts.charge(normal, hybrid: false);
      expect(normal.level, ReportLevel.ok);
      final low = withSamples('charge', List.filled(40, 12.9), phase: 'idle', rpm: List.filled(40, 800));
      BatteryVerdicts.charge(low, hybrid: false);
      expect(low.level, ReportLevel.attention);
      final dip = withSamples('charge', [...List.filled(30, 14.0), 12.6, 13.9, ...List.filled(10, 14.0)],
          phase: 'engine', rpm: [...List.filled(30, 0.0), ...List.filled(12, 1100.0)], stepMs: 500);
      BatteryVerdicts.charge(dip, hybrid: true);
      expect(dip.values['engineStartDip'], closeTo(1.4, 0.01));
      expect(dip.level, ReportLevel.attention);
    });
  });

  group('the reports against the scripted car', () {
    late FakeObdCar car;
    late ObdPreferences prefs;
    late ObdService service;

    setUp(() async {
      Hive.init('unused');
      await Hive.openBox(HiveBoxNames.appSettings, bytes: Uint8List(0));
      await Hive.openBox(HiveBoxNames.obdDiagnosticReports, bytes: Uint8List(0));
      car = FakeObdCar();
      prefs = ObdPreferences();
    });

    tearDown(() async {
      await Hive.close();
    });

    Future<void> start(WidgetTester tester) async {
      await prefs.setAdapter(address: '10:21:3E:4C:3A:AF', name: 'V-LINK');
      await prefs.setAutoConnect(true);
      service = ObdService(bridge: car, preferences: prefs, now: () => tester.binding.clock.now());
      service.resume();
      await tester.pump(const Duration(seconds: 6));
    }

    Future<void> finish(WidgetTester tester) async {
      service.dispose();
      await tester.pump(const Duration(seconds: 12));
    }

    /// Pumps the fake clock until [future] completes.
    Future<T> drive<T>(WidgetTester tester, Future<T> future, {int maxSteps = 900}) async {
      var done = false;
      T? value;
      Object? error;
      future.then((v) {
        value = v;
        done = true;
      }, onError: (Object e) {
        error = e;
        done = true;
      });
      for (var i = 0; i < maxSteps && !done; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done, isTrue, reason: 'never finished');
      if (error != null) throw error!;
      return value as T;
    }

    testWidgets('health: codes per ECU, the freeze frame, the identification; polling goes on', (tester) async {
      car.withEngineCodes();
      car.gearbox.pending = ['P0700'];
      await start(tester);
      expect(service.state, ObdLinkState.receiving);
      final steps = <String>[];
      final report = await drive(tester, runHealthReport(service, onProgress: steps.add));
      expect(report.status, DiagnosticReportStatus.complete);
      expect(report.vin, car.vin);
      final health = HealthResult.fromJson(report.result);
      final engine = health.ecus.firstWhere((e) => e.id == 0x7E8);
      expect(engine.stored, ['P0301']);
      expect(engine.pending, ['P0171']);
      expect(engine.name, 'ECM-EngineControl');
      expect(engine.calibrationIds, ['04C906032BA']);
      expect(engine.cvns, ['1A2B3C4D']);
      expect(engine.monitors!.mil, isTrue);
      expect(health.ecus.firstWhere((e) => e.id == 0x7E9).pending, ['P0700']);
      expect(health.freezeFrame!.dtc, 'P0301');
      expect(health.freezeFrame!.values[0x0C], 982);
      expect(health.freezeFrame!.values[0x05], 81);
      expect(health.usage[0x31], 4321);
      expect(health.usage[0x21], 42);
      expect(report.level, ReportLevel.problem);
      expect(report.summary, contains('luz de injeção acesa'));
      expect(steps, contains('Lendo os códigos armazenados…'));
      expect(report.raw.any((e) => e.command == '03'), isTrue, reason: 'the raw answers are kept');
      expect(DiagnosticReportRepository.newestFirst.single.id, report.id, reason: 'saved');

      // Back to polling, the engine addressed alone again.
      car.rpm = 1500;
      await tester.pump(const Duration(seconds: 2));
      final after = car.sent.lastIndexOf('03');
      expect(car.sent.sublist(after), containsAllInOrder(['ATAR', 'ATH0', 'ATSH7E0']));
      expect(service.readings[ObdSignal.rpm]!.value, 1500);
      expect(service.isFresh(ObdSignal.rpm), isTrue);
      await finish(tester);
    });

    testWidgets('the Haval: the engine reached through the filter again afterwards', (tester) async {
      car.haval();
      await start(tester);
      await drive(tester, runHealthReport(service));
      await tester.pump(const Duration(seconds: 2));
      final after = car.sent.lastIndexOf('0A');
      expect(car.sent.sublist(after), containsAllInOrder(['ATAR', 'ATH0', 'ATSH7DF', 'ATCRA7E8']));
      expect(service.isFresh(ObdSignal.rpm), isTrue);
      await finish(tester);
    });

    testWidgets('clearing the codes: refused with the engine running, then done with the ignition on, before and after linked', (tester) async {
      car.withEngineCodes();
      await start(tester);
      final before = await drive(tester, runHealthReport(service));

      var outcome = await drive(tester, clearEngineCodes(service, recording: false));
      expect(outcome.outcome, ClearCodesOutcome.refusedEngineRunning);
      expect(car.sent, isNot(contains('04')));

      outcome = await drive(tester, clearEngineCodes(service, recording: true));
      expect(outcome.outcome, ClearCodesOutcome.refusedRecording);

      car.ignition = FakeIgnition.on; // engine off, ignition on: rpm 0
      await tester.pump(const Duration(seconds: 1));
      outcome = await drive(tester, clearEngineCodes(service, recording: false));
      expect(outcome.outcome, ClearCodesOutcome.cleared, reason: outcome.message);
      expect(car.sent.sublist(car.sent.lastIndexOf('04') - 1, car.sent.lastIndexOf('04') + 1), ['ATSH7E0', '04'], reason: 'to the engine alone');
      expect(car.gearbox.cleared, isFalse);

      final afterReport = await drive(tester, runHealthReport(service, beforeId: before.id));
      expect(HealthResult.fromJson(afterReport.result).allCodes, isEmpty);
      expect(afterReport.beforeId, before.id);
      expect(DiagnosticReportRepository.byId(before.id)!.afterId, afterReport.id);
      final diff = compareHealth(HealthResult.fromJson(before.result), HealthResult.fromJson(afterReport.result));
      expect(diff.resolved, {'P0301', 'P0171'});

      final emissions = await drive(tester, runEmissionsReport(service));
      expect(emissions.level, ReportLevel.attention, reason: 'the monitors start over after a clear');
      expect(EmissionsResult.fromJson(emissions.result).incomplete.map((m) => m.key), containsAll(['catalyst', 'evap']));
      await finish(tester);
    });

    testWidgets('emissions: ready for inspection', (tester) async {
      await start(tester);
      final report = await drive(tester, runEmissionsReport(service));
      final result = EmissionsResult.fromJson(report.result);
      expect(result.readyForInspection, isTrue);
      expect(report.summary, 'Pronto para inspeção');
      expect(result.engine!.thisCycle!.incomplete.map((m) => m.key), ['evap']);
      await finish(tester);
    });

    testWidgets('the link dropping midway: the report is incomplete, the link comes back', (tester) async {
      car.withEngineCodes();
      await start(tester);
      final future = runHealthReport(service, onProgress: (step) {
        if (step.startsWith('Lendo os códigos armazenados')) car.unplug();
      });
      final report = await drive(tester, future);
      expect(report.status, DiagnosticReportStatus.incomplete);
      expect(report.statusDetail, contains('conexão caiu'));
      expect(HealthResult.fromJson(report.result).vin, car.vin, reason: 'what was read before is kept');
      car.plugIn();
      for (var i = 0; i < 400 && service.state != ObdLinkState.receiving; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(service.state, ObdLinkState.receiving);
      await finish(tester);
    });

    testWidgets('cancelling, and not starting without the car', (tester) async {
      await start(tester);
      final token = DiagnosticCancelToken();
      final report = await drive(tester, runHealthReport(service, cancel: token, onProgress: (step) {
        if (step.startsWith('Lendo o uso')) token.cancel();
      }));
      expect(report.status, DiagnosticReportStatus.cancelled);
      await tester.pump(const Duration(seconds: 2));
      expect(service.isFresh(ObdSignal.rpm), isTrue, reason: 'polling resumed');

      car.ignition = FakeIgnition.off;
      await tester.pump(const Duration(seconds: 3));
      expect(service.state, ObdLinkState.waitingForCar);
      expect(service.diagnosticUnavailableReason(), 'Ligue a ignição');
      expect(service.diagnosticUnavailableReason(needsCar: false), isNull);
      Object? refused;
      try {
        await drive(tester, runHealthReport(service));
      } on DiagnosticUnavailable catch (e) {
        refused = e;
      }
      expect(refused, isA<DiagnosticUnavailable>());
      await finish(tester);
    });

    testWidgets('the battery with the car off: rest and cranking, then the charge', (tester) async {
      car.ignition = FakeIgnition.off;
      await start(tester);
      expect(service.state, ObdLinkState.waitingForCar);
      final session = BatteryReportSession(service, hybrid: false);
      car.voltageQueue.addAll([12.6, 12.6, 12.7]);
      final rest = await drive(tester, session.rest(minutesOff: 120));
      expect(rest.values['volts'], 12.6);
      expect(rest.level, ReportLevel.ok);

      car.voltageQueue.addAll([12.5, 12.5, 10.2, 9.9, 10.6, 12.0, 13.6, 14.1, for (var i = 0; i < 40; i++) 14.2]);
      final crank = await drive(tester, session.crank());
      expect(crank.values['min'], 9.9);
      expect(crank.level, ReportLevel.ok);

      car.ignition = FakeIgnition.running;
      for (var i = 0; i < 100 && service.state != ObdLinkState.receiving; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final charge = await drive(tester, session.charge('idle', duration: const Duration(seconds: 10)));
      expect(charge.values['avg'], closeTo(13.3, 0.05));
      expect(charge.level, ReportLevel.ok);
      final report = (await drive(tester, session.save()))!;
      expect(report.type, DiagnosticReportType.battery);
      expect(report.summary, 'Repouso 12,6 V · partida 9,9 V · carga 13,3 V');
      await finish(tester);
    });

    testWidgets('a hybrid going READY: the DC-DC seen', (tester) async {
      car.haval();
      car.ignition = FakeIgnition.off;
      await start(tester);
      final session = BatteryReportSession(service, hybrid: true);
      car.voltageQueue.addAll([12.5, 12.5, 12.0, 11.8, 12.1, 13.9, for (var i = 0; i < 60; i++) 14.1]);
      final step = await drive(tester, session.activation());
      expect(step.level, ReportLevel.ok, reason: step.verdict);
      expect(step.values['dip'], 11.8);
      expect(step.values['dcdc'], closeTo(14.1, 0.01));

      // Tapped again with the car already READY (seen in the Haval): it says
      // so, stops early and keeps the good measurement.
      car.voltageQueue
        ..clear()
        ..addAll([for (var i = 0; i < 60; i++) 13.4]);
      final retry = await drive(tester, session.activation());
      expect(retry.level, ReportLevel.unknown);
      expect(retry.verdict, contains('já estava ligado (13,4 V)'));
      expect(retry.samples.length, 3);
      expect(session.kept(retry), isFalse);
      expect(session.kept(step), isTrue);
      expect(session.result.steps.where((s) => s.kind == 'activation').single.level, ReportLevel.ok);
      await finish(tester);
    });

    test('the history keeps 200, the starred ones always', () async {
      for (var i = 0; i < 205; i++) {
        await DiagnosticReportRepository.save(DiagnosticReport(
          id: 'r$i',
          type: DiagnosticReportType.health,
          at: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          status: DiagnosticReportStatus.complete,
          level: ReportLevel.ok,
          summary: '',
          result: const {},
          starred: i == 0,
        ));
      }
      final ids = DiagnosticReportRepository.newestFirst.map((r) => r.id).toSet();
      expect(ids.length, 200);
      expect(ids, contains('r0'), reason: 'starred');
      expect(ids, isNot(contains('r1')));
      expect(ids, contains('r204'));
    });
  });
}
