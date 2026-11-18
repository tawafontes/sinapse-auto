import '../../../../models/diagnostic_report.dart';
import '../../elm327_decode.dart';
import '../../obd_service.dart';
import '../diagnostic_report_repository.dart';
import '../obd_modes.dart';
import '../report_runner.dart';

/// One ECU in the health report: who it is and its codes.
class EcuHealth {
  EcuHealth(this.id);

  final int id;
  String? name;
  List<String> calibrationIds = [];
  List<String> cvns = [];
  List<String> stored = [];
  List<String> pending = [];
  List<String> permanent = [];
  MonitorStatus? monitors;

  /// Whether it answered the code requests at all.
  bool codesRead = false;

  int get codeCount => {...stored, ...pending, ...permanent}.length;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'calibrationIds': calibrationIds,
        'cvns': cvns,
        'stored': stored,
        'pending': pending,
        'permanent': permanent,
        'monitors': monitors?.toJson(),
        'codesRead': codesRead,
      };

  factory EcuHealth.fromJson(Map<String, Object?> j) => EcuHealth(j['id'] as int)
    ..name = j['name'] as String?
    ..calibrationIds = (j['calibrationIds'] as List? ?? const []).cast<String>()
    ..cvns = (j['cvns'] as List? ?? const []).cast<String>()
    ..stored = (j['stored'] as List? ?? const []).cast<String>()
    ..pending = (j['pending'] as List? ?? const []).cast<String>()
    ..permanent = (j['permanent'] as List? ?? const []).cast<String>()
    ..monitors = j['monitors'] == null ? null : MonitorStatus.fromJson((j['monitors'] as Map).cast<String, Object?>())
    ..codesRead = j['codesRead'] as bool? ?? false;
}

/// The instant the engine stored a code: what it was doing.
class FreezeFrame {
  FreezeFrame(this.ecu, this.dtc);

  final int ecu;
  final String? dtc;
  final Map<int, double> values = {};

  Map<String, Object?> toJson() => {
        'ecu': ecu,
        'dtc': dtc,
        'values': {for (final e in values.entries) '${e.key}': e.value},
      };

  factory FreezeFrame.fromJson(Map<String, Object?> j) {
    final frame = FreezeFrame(j['ecu'] as int, j['dtc'] as String?);
    (j['values'] as Map? ?? const {}).forEach((k, v) => frame.values[int.parse(k as String)] = (v as num).toDouble());
    return frame;
  }
}

/// What the health report read (§7.1): identification, usage, codes per ECU,
/// freeze frame, readiness.
class HealthResult {
  HealthResult();

  String? vin;
  double? adapterVolts;
  final Map<int, double> usage = {};
  final List<EcuHealth> ecus = [];
  FreezeFrame? freezeFrame;

  /// The ECU the codes are cleared from (the engine, when known).
  int? engineEcu;

  EcuHealth ecu(int id) {
    final found = ecus.where((e) => e.id == id).firstOrNull;
    if (found != null) return found;
    final added = EcuHealth(id);
    ecus.add(added);
    return added;
  }

  EcuHealth? get engine => engineEcu == null ? ecus.firstOrNull : ecus.where((e) => e.id == engineEcu).firstOrNull;

  bool get mil => ecus.any((e) => e.monitors?.mil ?? false);

  Set<String> get allCodes => {for (final e in ecus) ...e.stored, for (final e in ecus) ...e.pending, for (final e in ecus) ...e.permanent};

  ReportLevel get level {
    if (ecus.isEmpty) return ReportLevel.unknown;
    if (mil || ecus.any((e) => e.stored.isNotEmpty || e.permanent.isNotEmpty)) return ReportLevel.problem;
    if (ecus.any((e) => e.pending.isNotEmpty)) return ReportLevel.attention;
    return ReportLevel.ok;
  }

  String get summary {
    if (ecus.isEmpty) return 'Nenhuma central respondeu';
    final count = allCodes.length;
    final codes = count == 0 ? 'Sem códigos de falha' : (count == 1 ? '1 código' : '$count códigos');
    return [codes, if (mil) 'luz de injeção acesa'].join(' · ');
  }

  Map<String, Object?> toJson() => {
        'vin': vin,
        'adapterVolts': adapterVolts,
        'usage': {for (final e in usage.entries) '${e.key}': e.value},
        'ecus': [for (final e in ecus) e.toJson()],
        'freezeFrame': freezeFrame?.toJson(),
        'engineEcu': engineEcu,
      };

  factory HealthResult.fromJson(Map<String, Object?> j) {
    final r = HealthResult()
      ..vin = j['vin'] as String?
      ..adapterVolts = (j['adapterVolts'] as num?)?.toDouble()
      ..engineEcu = j['engineEcu'] as int?
      ..freezeFrame = j['freezeFrame'] == null ? null : FreezeFrame.fromJson((j['freezeFrame'] as Map).cast<String, Object?>());
    (j['usage'] as Map? ?? const {}).forEach((k, v) => r.usage[int.parse(k as String)] = (v as num).toDouble());
    for (final e in (j['ecus'] as List? ?? const [])) {
      r.ecus.add(EcuHealth.fromJson((e as Map).cast<String, Object?>()));
    }
    return r;
  }
}

/// The codes that appeared and went away since [before].
({Set<String> added, Set<String> resolved}) compareHealth(HealthResult before, HealthResult after) => (
      added: after.allCodes.difference(before.allCodes),
      resolved: before.allCodes.difference(after.allCodes),
    );

/// Reads the health report (§7.1) and saves it. [beforeId]: the report made
/// before clearing the codes, when this one checks the result.
Future<DiagnosticReport> runHealthReport(
  ObdService obd, {
  DiagnosticCancelToken? cancel,
  DiagnosticProgress? onProgress,
  String? beforeId,
}) async {
  final result = HealthResult()..engineEcu = obd.info.engineEcu;
  final token = cancel ?? DiagnosticCancelToken();
  void step(String text) {
    token.check();
    onProgress?.call(text);
  }

  final end = await runDiagnosticSteps(obd, (link) async {
    step('Preparando o adaptador…');
    await listenToAllEcus(link);

    step('Lendo a identificação…');
    final supported09 = <int, Set<int>>{};
    (await askAllEcus(link, '0900')).forEach((id, messages) {
      for (final m in messages) {
        // `49 00` and the bitmap: mode 09's PID 00 has no count byte.
        if (m.length < 6 || m[0] != 0x49 || m[1] != 0x00) continue;
        final set = supported09.putIfAbsent(id, () => <int>{});
        final bitmap = m.sublist(m.length - 4);
        for (var i = 0; i < 32; i++) {
          if (bitmap[i ~/ 8] & (0x80 >> (i % 8)) != 0) set.add(i + 1);
        }
        result.ecu(id);
      }
    });
    bool any09(int type) => supported09.isEmpty || supported09.values.any((s) => s.contains(type));
    if (any09(0x02)) {
      (await askAllEcus(link, '0902', timeout: const Duration(seconds: 3))).forEach((id, messages) {
        for (final m in messages) {
          result.vin ??= vinFromMessage(m);
        }
      });
    }
    if (any09(0x0A)) {
      (await askAllEcus(link, '090A', timeout: const Duration(seconds: 3))).forEach((id, messages) {
        for (final m in messages) {
          final name = ecuName(m);
          if (name != null) result.ecu(id).name = name;
        }
      });
    }
    if (any09(0x04)) {
      (await askAllEcus(link, '0904', timeout: const Duration(seconds: 3))).forEach((id, messages) {
        for (final m in messages) {
          final ids = calibrationIds(m);
          if (ids.isNotEmpty) result.ecu(id).calibrationIds = ids;
        }
      });
    }
    if (any09(0x06)) {
      (await askAllEcus(link, '0906', timeout: const Duration(seconds: 3))).forEach((id, messages) {
        for (final m in messages) {
          final cvns = calibrationVerificationNumbers(m);
          if (cvns.isNotEmpty) result.ecu(id).cvns = cvns;
        }
      });
    }
    final volts = await link.send('ATRV');
    result.adapterVolts = volts == null ? null : adapterVoltage(volts);

    step('Lendo o estado da luz de injeção…');
    (await askAllEcus(link, '0101')).forEach((id, messages) {
      for (final m in messages) {
        final d = mode01FromMessage(m, 0x01);
        if (d != null) result.ecu(id).monitors = monitorStatus(d);
      }
    });

    step('Lendo o uso do carro…');
    final engineId = result.engineEcu;
    final enginePids = obd.info.supportedPids ?? const <int>{};
    for (final pid in usagePids.keys) {
      if (!enginePids.contains(pid)) continue;
      final hex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
      final answers = await askAllEcus(link, '01$hex');
      final messages = answers[engineId] ?? answers.values.firstOrNull ?? const [];
      for (final m in messages) {
        final d = mode01FromMessage(m, pid);
        final v = d == null ? null : usageValue(pid, d);
        if (v != null) result.usage[pid] = v;
      }
    }

    for (final (mode, label) in [(0x03, 'armazenados'), (0x07, 'pendentes'), (0x0A, 'permanentes')]) {
      step('Lendo os códigos $label…');
      final hex = mode.toRadixString(16).padLeft(2, '0').toUpperCase();
      (await askAllEcus(link, hex, timeout: const Duration(seconds: 3))).forEach((id, messages) {
        for (final m in messages) {
          final codes = dtcsFromMessage(m, mode);
          if (codes == null) continue;
          final ecu = result.ecu(id)..codesRead = true;
          switch (mode) {
            case 0x03:
              ecu.stored = codes;
            case 0x07:
              ecu.pending = codes;
            default:
              ecu.permanent = codes;
          }
        }
      });
    }

    step('Lendo o instantâneo da falha (freeze frame)…');
    int? frameEcu;
    String? frameDtc;
    (await askAllEcus(link, '020200')).forEach((id, messages) {
      for (final m in messages) {
        final d = mode02FromMessage(m, 0x02);
        if (d == null || d.length < 2 || (d[0] == 0 && d[1] == 0)) continue;
        if (frameEcu == null || id == engineId) {
          frameEcu = id;
          frameDtc = dtcFromBytes(d[0], d[1]);
        }
      }
    });
    if (frameEcu != null) {
      final frame = result.freezeFrame = FreezeFrame(frameEcu!, frameDtc);
      final declared = <int>{};
      for (final m in (await askAllEcus(link, '020000'))[frameEcu] ?? const <List<int>>[]) {
        final d = mode02FromMessage(m, 0x00);
        if (d == null || d.length < 4) continue;
        for (var i = 0; i < 32; i++) {
          if (d[i ~/ 8] & (0x80 >> (i % 8)) != 0) declared.add(i + 1);
        }
      }
      for (final pid in freezeFramePids.keys) {
        if (declared.isNotEmpty && !declared.contains(pid)) continue;
        token.check();
        final hex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
        for (final m in (await askAllEcus(link, '02${hex}00'))[frameEcu] ?? const <List<int>>[]) {
          final d = mode02FromMessage(m, pid);
          final v = d == null ? null : mode01Physical(pid, d);
          if (v != null) frame.values[pid] = v;
        }
      }
    }
  });

  final odometer = obd.readings[ObdSignal.odometer]?.value ?? result.usage[0xA6];
  final report = DiagnosticReport(
    id: DiagnosticReportRepository.newId(),
    type: DiagnosticReportType.health,
    at: DateTime.now(),
    status: end.status,
    statusDetail: end.detail,
    level: result.level,
    summary: result.summary,
    result: result.toJson(),
    vin: result.vin,
    odometerKm: odometer,
    raw: end.raw,
    beforeId: beforeId,
  );
  await DiagnosticReportRepository.save(report);
  if (beforeId != null) {
    final before = DiagnosticReportRepository.byId(beforeId);
    if (before != null) await DiagnosticReportRepository.save(before.copyWith(afterId: report.id));
  }
  return report;
}

/// How "Apagar códigos do motor" went.
enum ClearCodesOutcome { cleared, refusedMoving, refusedEngineRunning, refusedRecording, noEngine, carRefused, noAnswer }

typedef ClearCodesResult = ({ClearCodesOutcome outcome, String message});

/// Mode 04 to the engine (§7.6), after the locks: speed 0, engine off (rpm 0),
/// ignition on (the engine answers), no session recording — checked here,
/// right before sending. The caller saved a complete health report first and
/// got the user's confirmation.
Future<ClearCodesResult> clearEngineCodes(ObdService obd, {required bool recording}) async {
  if (recording) {
    return (outcome: ClearCodesOutcome.refusedRecording, message: 'Pare a gravação da viagem antes de apagar os códigos.');
  }
  ClearCodesResult? result;
  final end = await runDiagnosticSteps(obd, (link) async {
    final engine = link.info.engineEcu;
    if (engine == null) {
      result = (outcome: ClearCodesOutcome.noEngine, message: 'A central do motor não foi identificada; nada foi apagado.');
      return;
    }
    // The locks, read from the engine right now (polling's addressing).
    final raw = await link.send('010C0D', timeout: const Duration(seconds: 2));
    final values = raw == null ? const <int, List<int>>{} : mode01Values(raw, const [0x0C, 0x0D], command: '010C0D');
    final rpm = values[0x0C] == null ? null : mode01Physical(0x0C, values[0x0C]!);
    final speed = values[0x0D] == null ? null : mode01Physical(0x0D, values[0x0D]!);
    if (rpm == null && speed == null) {
      result = (outcome: ClearCodesOutcome.noAnswer, message: 'O motor não respondeu. Ligue a ignição, sem dar a partida.');
      return;
    }
    if ((speed ?? 0) > 0) {
      result = (outcome: ClearCodesOutcome.refusedMoving, message: 'O carro precisa estar parado.');
      return;
    }
    if ((rpm ?? 0) > 0) {
      result = (outcome: ClearCodesOutcome.refusedEngineRunning, message: 'Desligue o motor e deixe só a ignição ligada.');
      return;
    }
    final answer = await link.clearEngineCodes();
    final messages = answer == null ? const <List<int>>[] : canMessages(answer)[engine] ?? const <List<int>>[];
    if (messages.any((m) => m.isNotEmpty && m[0] == 0x44)) {
      result = (outcome: ClearCodesOutcome.cleared, message: 'Códigos do motor apagados.');
      return;
    }
    final refusal = messages.map((m) => negativeResponse(m, 0x04)).nonNulls.firstOrNull;
    result = refusal == null
        ? (outcome: ClearCodesOutcome.noAnswer, message: 'A central do motor não confirmou. Os códigos podem não ter sido apagados.')
        : (
            outcome: ClearCodesOutcome.carRefused,
            message: refusal == 0x22
                ? 'A central do motor recusou agora (condições incorretas): confira se o motor está desligado.'
                : 'A central do motor recusou o pedido (código ${refusal.toRadixString(16).toUpperCase()}). Nada foi apagado.',
          );
  });
  return result ??
      (outcome: ClearCodesOutcome.noAnswer, message: end.detail ?? 'Não foi possível confirmar o resultado.');
}
