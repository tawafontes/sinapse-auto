import '../../../../models/diagnostic_report.dart';
import '../../obd_service.dart';
import '../diagnostic_report_repository.dart';
import '../obd_modes.dart';
import '../report_runner.dart';

/// One ECU's readiness: since the codes were cleared (PID 01) and this drive
/// cycle (PID 41).
class EcuReadiness {
  EcuReadiness(this.id);

  final int id;
  MonitorStatus? sinceClear;
  MonitorStatus? thisCycle;

  Map<String, Object?> toJson() => {'id': id, 'sinceClear': sinceClear?.toJson(), 'thisCycle': thisCycle?.toJson()};

  factory EcuReadiness.fromJson(Map<String, Object?> j) => EcuReadiness(j['id'] as int)
    ..sinceClear = j['sinceClear'] == null ? null : MonitorStatus.fromJson((j['sinceClear'] as Map).cast<String, Object?>())
    ..thisCycle = j['thisCycle'] == null ? null : MonitorStatus.fromJson((j['thisCycle'] as Map).cast<String, Object?>());
}

/// What the emissions report read (§7.3, monitors; mode 06 comes later).
class EmissionsResult {
  EmissionsResult();

  final List<EcuReadiness> ecus = [];
  final Map<int, double> usage = {};
  int? engineEcu;

  EcuReadiness ecu(int id) {
    final found = ecus.where((e) => e.id == id).firstOrNull;
    if (found != null) return found;
    final added = EcuReadiness(id);
    ecus.add(added);
    return added;
  }

  EcuReadiness? get engine => ecus.where((e) => e.id == engineEcu).firstOrNull ?? ecus.where((e) => e.sinceClear != null).firstOrNull;

  bool get mil => ecus.any((e) => e.sinceClear?.mil ?? false);

  /// The engine's monitors that have not run since the codes were cleared.
  List<ObdMonitor> get incomplete => engine?.sinceClear?.incomplete.toList() ?? const [];

  bool get readyForInspection => engine?.sinceClear != null && incomplete.isEmpty && !mil;

  ReportLevel get level {
    if (engine?.sinceClear == null) return ReportLevel.unknown;
    if (mil) return ReportLevel.problem;
    return incomplete.isEmpty ? ReportLevel.ok : ReportLevel.attention;
  }

  String get summary {
    if (engine?.sinceClear == null) return 'O motor não informou os monitores';
    if (mil) return 'Luz de injeção acesa';
    if (incomplete.isEmpty) return 'Pronto para inspeção';
    return incomplete.length == 1 ? '1 monitor incompleto' : '${incomplete.length} monitores incompletos';
  }

  /// What to do about it, in words.
  String get advice {
    if (engine?.sinceClear == null) return 'Ligue a ignição e tente de novo.';
    if (mil) return 'A luz de injeção está acesa: veja os códigos no relatório de saúde do veículo.';
    if (incomplete.isEmpty) return 'Todos os monitores do motor concluíram os testes desde a última vez que os códigos foram apagados.';
    final km = usage[0x31];
    final since = km == null ? '' : ' Desde que os códigos foram apagados, o carro rodou ${ptNumber(km, 0)} km.';
    return 'Rode alguns ciclos de direção mista, com partida a frio, trechos de cidade e de estrada em velocidade constante, '
        'até os monitores concluírem.$since';
  }

  Map<String, Object?> toJson() => {
        'ecus': [for (final e in ecus) e.toJson()],
        'usage': {for (final e in usage.entries) '${e.key}': e.value},
        'engineEcu': engineEcu,
      };

  factory EmissionsResult.fromJson(Map<String, Object?> j) {
    final r = EmissionsResult()..engineEcu = j['engineEcu'] as int?;
    for (final e in (j['ecus'] as List? ?? const [])) {
      r.ecus.add(EcuReadiness.fromJson((e as Map).cast<String, Object?>()));
    }
    (j['usage'] as Map? ?? const {}).forEach((k, v) => r.usage[int.parse(k as String)] = (v as num).toDouble());
    return r;
  }
}

/// Reads the emissions and readiness report and saves it.
Future<DiagnosticReport> runEmissionsReport(ObdService obd, {DiagnosticCancelToken? cancel, DiagnosticProgress? onProgress}) async {
  final result = EmissionsResult()..engineEcu = obd.info.engineEcu;
  final token = cancel ?? DiagnosticCancelToken();
  void step(String text) {
    token.check();
    onProgress?.call(text);
  }

  String? vin;
  final end = await runDiagnosticSteps(obd, (link) async {
    step('Preparando o adaptador…');
    await listenToAllEcus(link);
    step('Lendo os monitores desde o último apagamento…');
    (await askAllEcus(link, '0101')).forEach((id, messages) {
      for (final m in messages) {
        final d = mode01FromMessage(m, 0x01);
        if (d != null) result.ecu(id).sinceClear = monitorStatus(d);
      }
    });
    final pids = obd.info.supportedPids ?? const <int>{};
    if (pids.contains(0x41)) {
      step('Lendo os monitores deste ciclo…');
      (await askAllEcus(link, '0141')).forEach((id, messages) {
        for (final m in messages) {
          final d = mode01FromMessage(m, 0x41);
          if (d != null) result.ecu(id).thisCycle = monitorStatus(d, thisCycle: true);
        }
      });
    }
    step('Lendo o uso desde o último apagamento…');
    for (final pid in const [0x31, 0x30, 0x4E, 0x21]) {
      if (!pids.contains(pid)) continue;
      token.check();
      final answers = await askAllEcus(link, '01${pid.toRadixString(16).toUpperCase()}');
      for (final m in answers[result.engineEcu] ?? answers.values.firstOrNull ?? const <List<int>>[]) {
        final d = mode01FromMessage(m, pid);
        final v = d == null ? null : usageValue(pid, d);
        if (v != null) result.usage[pid] = v;
      }
    }
    (await askAllEcus(link, '0902', timeout: const Duration(seconds: 3))).forEach((id, messages) {
      for (final m in messages) {
        vin ??= vinFromMessage(m);
      }
    });
  });

  final report = DiagnosticReport(
    id: DiagnosticReportRepository.newId(),
    type: DiagnosticReportType.emissions,
    at: DateTime.now(),
    status: end.status,
    statusDetail: end.detail,
    level: result.level,
    summary: result.summary,
    result: result.toJson(),
    vin: vin ?? DiagnosticReportRepository.lastVin,
    odometerKm: obd.readings[ObdSignal.odometer]?.value,
    raw: end.raw,
  );
  await DiagnosticReportRepository.save(report);
  return report;
}
