import 'dart:math' as math;

import '../../../../models/diagnostic_report.dart';
import '../../elm327_decode.dart';
import '../../obd_service.dart';
import '../diagnostic_report_repository.dart';
import '../report_runner.dart';

/// One voltage reading of a step: milliseconds since it started, the 12 V
/// battery's voltage (ATRV) and, when read, the engine's rpm.
typedef VoltageSample = ({int ms, double volts, double? rpm});

Map<String, Object?> _sampleJson(VoltageSample s) => {'t': s.ms, 'v': s.volts, if (s.rpm != null) 'r': s.rpm};
VoltageSample _sampleFrom(Map j) => (ms: j['t'] as int, volts: (j['v'] as num).toDouble(), rpm: (j['r'] as num?)?.toDouble());

/// One step of the battery assistant (§7.2) and its verdict.
class BatteryStep {
  BatteryStep(this.kind, {this.phase});

  /// `rest`, `crank`, `activation` or `charge`.
  final String kind;

  /// For `charge`: `idle`, `rpm2000` (combustion), `electric`, `engine` (hybrid).
  final String? phase;
  final List<VoltageSample> samples = [];
  ReportLevel level = ReportLevel.unknown;
  String verdict = '';
  final Map<String, double> values = {};

  Map<String, Object?> toJson() => {
        'kind': kind,
        'phase': phase,
        'level': level.name,
        'verdict': verdict,
        'values': values,
        'samples': [for (final s in _thin(samples, 240)) _sampleJson(s)],
      };

  factory BatteryStep.fromJson(Map<String, Object?> j) {
    final step = BatteryStep(j['kind'] as String, phase: j['phase'] as String?)
      ..level = ReportLevel.values.byName(j['level'] as String)
      ..verdict = j['verdict'] as String? ?? '';
    (j['values'] as Map? ?? const {}).forEach((k, v) => step.values[k as String] = (v as num).toDouble());
    for (final s in (j['samples'] as List? ?? const [])) {
      step.samples.add(_sampleFrom(s as Map));
    }
    return step;
  }
}

/// Every [n]th sample so a saved step stays small, the minimum always kept.
List<VoltageSample> _thin(List<VoltageSample> samples, int max) {
  if (samples.length <= max) return samples;
  final minIndex = _minIndex(samples);
  final stride = samples.length / max;
  final kept = <int>{for (var i = 0; i < max; i++) (i * stride).floor(), minIndex, samples.length - 1};
  return [for (final i in kept.toList()..sort()) samples[i]];
}

int _minIndex(List<VoltageSample> s) {
  var best = 0;
  for (var i = 1; i < s.length; i++) {
    if (s[i].volts < s[best].volts) best = i;
  }
  return best;
}

/// What the battery report holds: the steps done, in order.
class BatteryResult {
  BatteryResult({required this.hybrid});

  /// A hybrid or plug-in: activation (READY) instead of cranking, the DC-DC
  /// instead of an alternator.
  final bool hybrid;
  final List<BatteryStep> steps = [];

  BatteryStep? step(String kind, [String? phase]) => steps.where((s) => s.kind == kind && (phase == null || s.phase == phase)).lastOrNull;

  ReportLevel get level => worstLevel(steps.map((s) => s.level));

  String get summary {
    String? v(String kind, String key, String label) {
      final value = step(kind)?.values[key];
      return value == null ? null : '$label ${ptNumber(value)} V';
    }

    final parts = [
      v('rest', 'volts', 'repouso'),
      hybrid ? v('activation', 'dip', 'ativação') : v('crank', 'min', 'partida'),
      v('charge', 'avg', 'carga'),
    ].nonNulls.toList();
    if (parts.isEmpty) return 'Nenhum passo concluído';
    final text = parts.join(' · ');
    return text[0].toUpperCase() + text.substring(1);
  }

  Map<String, Object?> toJson() => {'hybrid': hybrid, 'steps': [for (final s in steps) s.toJson()]};

  factory BatteryResult.fromJson(Map<String, Object?> j) {
    final r = BatteryResult(hybrid: j['hybrid'] as bool? ?? false);
    for (final s in (j['steps'] as List? ?? const [])) {
      r.steps.add(BatteryStep.fromJson((s as Map).cast<String, Object?>()));
    }
    return r;
  }
}

/// Judging each step (§7.2) — pure, so the thresholds are tested on their own.
class BatteryVerdicts {
  BatteryVerdicts._();

  static void rest(BatteryStep step, {required bool hybrid}) {
    final v = step.values['volts'];
    if (v == null) {
      step
        ..level = ReportLevel.unknown
        ..verdict = 'O adaptador não informou a tensão.';
      return;
    }
    final ready = hybrid ? ' Num híbrido, é ela que deixa o carro ficar READY.' : '';
    if (v >= 12.6) {
      step
        ..level = ReportLevel.ok
        ..verdict = 'Bateria carregada.';
    } else if (v >= 12.4) {
      step
        ..level = ReportLevel.ok
        ..verdict = 'Cerca de 75 % de carga.';
    } else if (v >= 12.0) {
      step
        ..level = ReportLevel.attention
        ..verdict = 'Cerca de ${v >= 12.2 ? 50 : 25} % de carga: vale rodar mais ou carregar a bateria.$ready';
    } else {
      step
        ..level = ReportLevel.problem
        ..verdict = 'Bateria descarregada.$ready';
    }
    if (step.values['minutesOff'] case final minutes? when minutes < 60) {
      step.verdict += ' O carro estava desligado havia menos de 1 hora: a leitura pode estar alta.';
    }
  }

  /// A first reading this high means the alternator or the DC-DC is already
  /// charging: the car was on before the crank/activation step started.
  static bool alreadyRunning(double baseline) => baseline >= 13.0;

  static void crank(BatteryStep step) {
    final s = step.samples;
    if (s.isEmpty) {
      step.verdict = 'Nenhuma leitura durante a partida.';
      return;
    }
    final baseline = s.first.volts;
    final minIndex = _minIndex(s);
    final min = s[minIndex].volts;
    step.values['baseline'] = baseline;
    step.values['min'] = min;
    if (alreadyRunning(baseline)) {
      step
        ..level = ReportLevel.unknown
        ..verdict = 'O motor já estava ligado (${ptNumber(baseline)} V) quando a medida começou. '
            'Desligue o carro, toque em “Vou dar a partida” e só então dê a partida.';
      return;
    }
    if (baseline - min < 0.8) {
      step
        ..level = ReportLevel.unknown
        ..verdict = 'Não percebi a partida. Tente de novo e dê a partida logo depois de tocar no botão.';
      return;
    }
    final recovered = s.skip(minIndex).where((x) => x.volts >= 13.0).firstOrNull;
    if (recovered != null) step.values['recoveryMs'] = (recovered.ms - s[minIndex].ms).toDouble();
    if (min >= 9.6) {
      step
        ..level = ReportLevel.ok
        ..verdict = 'A tensão mínima na partida foi boa.';
    } else if (min >= 9.0) {
      step
        ..level = ReportLevel.attention
        ..verdict = 'A tensão caiu bastante na partida: a bateria pode estar fraca.';
    } else {
      step
        ..level = ReportLevel.problem
        ..verdict = 'A tensão caiu demais na partida: bateria fraca ou problema no motor de partida.';
    }
    if (recovered == null) step.verdict += ' A tensão não passou de 13 V depois: confira o alternador no passo de carga.';
  }

  /// The hybrid's activation: the dip as the modules wake and the contactors
  /// close, then the DC-DC's jump (≥ 13,3 V) within 5 s of the dip.
  static void activation(BatteryStep step) {
    final s = step.samples;
    if (s.isEmpty) {
      step.verdict = 'Nenhuma leitura durante a ativação.';
      return;
    }
    final baseline = s.first.volts;
    step.values['baseline'] = baseline;
    if (alreadyRunning(baseline)) {
      step
        ..level = ReportLevel.unknown
        ..verdict = 'O carro já estava ligado (${ptNumber(baseline)} V) quando a medida começou. '
            'Desligue o carro, espere a tensão ficar abaixo de 13 V e toque em “Vou ligar o carro” antes de apertar o botão de partida.';
      return;
    }
    final start = s.where((x) => (x.volts - baseline).abs() >= 0.15).firstOrNull;
    if (start == null) {
      step
        ..level = ReportLevel.unknown
        ..verdict = 'Não percebi a ativação. Tente de novo e aperte o botão de partida logo depois de tocar em “Vou ligar o carro”.';
      return;
    }
    final jump = s.where((x) => x.ms >= start.ms && x.volts >= 13.3).firstOrNull;
    final beforeJump = s.where((x) => x.ms >= start.ms && (jump == null || x.ms <= jump.ms)).map((x) => x.volts);
    final dip = beforeJump.isEmpty ? baseline : beforeJump.reduce(math.min);
    step.values['dip'] = math.min(dip, baseline);
    final levels = <ReportLevel>[];
    final words = <String>[];
    if (dip >= 11.5) {
      levels.add(ReportLevel.ok);
      words.add('Queda pequena na ativação.');
    } else if (dip >= 11.0) {
      levels.add(ReportLevel.attention);
      words.add('A tensão caiu mais que o esperado na ativação.');
    } else {
      levels.add(ReportLevel.problem);
      words.add('A tensão caiu demais na ativação: bateria de 12 V fraca.');
    }
    if (jump == null || jump.ms - start.ms > 5000) {
      levels.add(ReportLevel.problem);
      words.add('O conversor DC-DC não está carregando a bateria de 12 V (a tensão não subiu em 5 s).');
    } else {
      step.values['dcdcMs'] = (jump.ms - start.ms).toDouble();
      final after = s.where((x) => x.ms >= jump.ms + 1000).map((x) => x.volts).toList();
      final dcdc = after.isEmpty ? jump.volts : after.reduce((a, b) => a + b) / after.length;
      step.values['dcdc'] = dcdc;
      levels.add(ReportLevel.ok);
      words.add('O DC-DC entrou em ${ptNumber((jump.ms - start.ms) / 1000)} s, com ${ptNumber(dcdc)} V.');
    }
    step
      ..level = worstLevel(levels)
      ..verdict = words.join(' ');
  }

  /// The charging voltage: the alternator (combustion) or the DC-DC (hybrid).
  static void charge(BatteryStep step, {required bool hybrid}) {
    final s = step.samples;
    final running = s.any((x) => (x.rpm ?? 0) > 0);
    if (s.length < 3) {
      step.verdict = 'Poucas leituras para avaliar a carga.';
      return;
    }
    if (!hybrid && !running) {
      step
        ..level = ReportLevel.unknown
        ..verdict = 'O motor estava desligado: dê a partida para medir a carga.';
      return;
    }
    if (hybrid && step.phase == 'engine' && !running) {
      step
        ..level = ReportLevel.unknown
        ..verdict = 'O motor a combustão não entrou: force o modo de recarga ou HEV e tente de novo.';
      return;
    }
    // The first 2 s settle.
    final steady = s.where((x) => x.ms >= 2000).map((x) => x.volts).toList();
    final values = steady.length >= 3 ? steady : s.map((x) => x.volts).toList();
    final avg = values.reduce((a, b) => a + b) / values.length;
    final ripple = values.reduce(math.max) - values.reduce(math.min);
    step.values['avg'] = avg;
    step.values['ripple'] = ripple;
    final levels = <ReportLevel>[];
    final words = <String>[];
    final source = hybrid ? 'O DC-DC' : 'O alternador';
    if (avg >= 13.2 && avg <= 14.8) {
      levels.add(ReportLevel.ok);
      words.add('$source está carregando normalmente.');
    } else if (avg > 14.8) {
      levels.add(ReportLevel.problem);
      words.add('Tensão de carga alta demais: pode danificar a bateria.');
    } else if (!hybrid && avg >= 12.8) {
      levels.add(ReportLevel.attention);
      words.add('Tensão de carga baixa. Num carro com alternador inteligente (como o Nivus) isso pode ser normal com a bateria cheia.');
    } else {
      levels.add(ReportLevel.problem);
      words.add('$source não está carregando a bateria de 12 V.');
    }
    if (ripple > 0.5) {
      levels.add(ReportLevel.attention);
      words.add('A tensão oscilou ${ptNumber(ripple)} V em regime estável.');
    }
    if (hybrid && step.phase == 'engine') {
      // The combustion engine starting should not show on the 12 V network.
      for (var i = 1; i < s.length; i++) {
        if ((s[i - 1].rpm ?? 0) == 0 && (s[i].rpm ?? 0) > 0) {
          final before = s.sublist(math.max(0, i - 3), i).map((x) => x.volts).toList();
          final ref = before.reduce((a, b) => a + b) / before.length;
          final after = s.where((x) => x.ms >= s[i].ms - 500 && x.ms <= s[i].ms + 2000).map((x) => x.volts);
          final dip = ref - after.reduce(math.min);
          step.values['engineStartDip'] = dip;
          if (dip > 1.0) {
            levels.add(ReportLevel.attention);
            words.add('A tensão caiu ${ptNumber(dip)} V quando o motor a combustão entrou; num híbrido sadio, isso não aparece no 12 V.');
          }
          break;
        }
      }
    }
    step
      ..level = worstLevel(levels)
      ..verdict = words.join(' ');
  }
}

/// The battery assistant (§7.2): each step is its own short diagnostic run,
/// the result is saved when the user finishes (or leaves with a step done).
class BatteryReportSession {
  BatteryReportSession(this.obd, {required bool hybrid}) : result = BatteryResult(hybrid: hybrid);

  final ObdService obd;
  final BatteryResult result;
  final List<({String command, String? response})> _raw = [];
  DiagnosticReportStatus _status = DiagnosticReportStatus.complete;
  String? _detail;
  DiagnosticReport? saved;

  bool get hybrid => result.hybrid;

  /// Puts [step] in the result in place of the same kind (and phase), unless
  /// [step] measured nothing (level unknown) and the one there did: a failed
  /// retry never replaces a good measurement.
  void _replace(BatteryStep step) {
    final existing = result.steps.where((s) => s.kind == step.kind && s.phase == step.phase).firstOrNull;
    if (existing != null && step.level == ReportLevel.unknown && existing.level != ReportLevel.unknown) return;
    result.steps.removeWhere((s) => s.kind == step.kind && s.phase == step.phase);
    result.steps.add(step);
  }

  /// Whether [step] (the last one run) is the one in the result.
  bool kept(BatteryStep step) => result.steps.contains(step);

  Future<double?> _volts(DiagnosticLink link) async {
    final raw = await link.send('ATRV', timeout: const Duration(milliseconds: 1500));
    return raw == null ? null : adapterVoltage(raw);
  }

  Future<BatteryStep> _run(BatteryStep step, Future<void> Function(DiagnosticLink link) body, {required bool needsCar}) async {
    final end = await runDiagnosticSteps(obd, body, needsCar: needsCar);
    _raw.addAll(end.raw);
    if (end.status != DiagnosticReportStatus.complete) {
      _status = end.status;
      _detail = end.detail;
      step.verdict = [if (step.verdict.isNotEmpty) step.verdict, end.detail].nonNulls.join(' ');
    }
    _replace(step);
    return step;
  }

  /// Step 1: the resting voltage, three ATRV readings (median). Works with
  /// the car off. [minutesOff]: how long the user says it has been off.
  Future<BatteryStep> rest({double? minutesOff}) {
    final step = BatteryStep('rest');
    if (minutesOff != null) step.values['minutesOff'] = minutesOff;
    return _run(step, (link) async {
      final readings = <double>[];
      for (var i = 0; i < 3; i++) {
        final v = await _volts(link);
        if (v != null) readings.add(v);
      }
      if (readings.isNotEmpty) {
        readings.sort();
        step.values['volts'] = readings[readings.length ~/ 2];
      }
      BatteryVerdicts.rest(step, hybrid: hybrid);
    }, needsCar: false);
  }

  /// Step 2 (combustion): ATRV as fast as it comes while the user cranks — up
  /// to [window], or until 1,5 s after the voltage is back above 13 V.
  Future<BatteryStep> crank({DiagnosticCancelToken? cancel, void Function(VoltageSample)? onSample, Duration window = const Duration(seconds: 20)}) {
    final step = BatteryStep('crank');
    return _run(step, (link) async {
      await _sampleUntil(link, step, window, cancel, onSample, done: (s, base) {
        if (BatteryVerdicts.alreadyRunning(base) && s.length >= 3) return true;
        final min = s.map((x) => x.volts).reduce(math.min);
        if (base - min < 0.8) return false;
        final above = s.lastWhere((x) => x.volts < 13.0, orElse: () => s.first);
        return s.last.volts >= 13.0 && s.last.ms - above.ms >= 1500;
      });
      BatteryVerdicts.crank(step);
    }, needsCar: false);
  }

  /// Step 2 (hybrid): ATRV as fast as it comes while the car goes READY — up
  /// to [window], or until 3 s after the DC-DC's jump.
  Future<BatteryStep> activation({DiagnosticCancelToken? cancel, void Function(VoltageSample)? onSample, Duration window = const Duration(seconds: 25)}) {
    final step = BatteryStep('activation');
    return _run(step, (link) async {
      await _sampleUntil(link, step, window, cancel, onSample, done: (s, base) {
        if (BatteryVerdicts.alreadyRunning(base) && s.length >= 3) return true;
        final jump = s.where((x) => x.volts >= 13.3).firstOrNull;
        return jump != null && s.last.ms - jump.ms >= 3000;
      });
      BatteryVerdicts.activation(step);
    }, needsCar: false);
  }

  Future<void> _sampleUntil(
    DiagnosticLink link,
    BatteryStep step,
    Duration window,
    DiagnosticCancelToken? cancel,
    void Function(VoltageSample)? onSample, {
    required bool Function(List<VoltageSample> samples, double baseline) done,
  }) async {
    final started = link.now();
    int elapsed() => link.now().difference(started).inMilliseconds;
    while (elapsed() < window.inMilliseconds) {
      cancel?.check();
      final v = await _volts(link);
      if (v == null) continue;
      final sample = (ms: elapsed(), volts: v, rpm: null);
      step.samples.add(sample);
      onSample?.call(sample);
      if (done(step.samples, step.samples.first.volts)) break;
    }
  }

  /// Step 3: the charging voltage for [duration], with the rpm — [phase]
  /// `idle`/`rpm2000` (combustion) or `electric`/`engine` (hybrid).
  Future<BatteryStep> charge(String phase, {Duration duration = const Duration(seconds: 30), DiagnosticCancelToken? cancel, void Function(VoltageSample)? onSample}) {
    final step = BatteryStep('charge', phase: phase);
    return _run(step, (link) async {
      final started = link.now();
      int elapsed() => link.now().difference(started).inMilliseconds;
      while (elapsed() < duration.inMilliseconds) {
        cancel?.check();
        final v = await _volts(link);
        final raw = await link.send('010C', timeout: const Duration(milliseconds: 1500));
        final data = raw == null ? null : mode01Values(raw, const [0x0C], command: '010C')[0x0C];
        final rpm = data == null ? null : mode01Physical(0x0C, data);
        if (v == null) continue;
        final sample = (ms: elapsed(), volts: v, rpm: rpm);
        step.samples.add(sample);
        onSample?.call(sample);
      }
      BatteryVerdicts.charge(step, hybrid: hybrid);
    }, needsCar: true);
  }

  /// Saves the report (again, under the same id, if already saved).
  Future<DiagnosticReport?> save() async {
    if (result.steps.isEmpty) return null;
    final report = DiagnosticReport(
      id: saved?.id ?? DiagnosticReportRepository.newId(),
      type: DiagnosticReportType.battery,
      at: saved?.at ?? DateTime.now(),
      status: _status,
      statusDetail: _detail,
      level: result.level,
      summary: result.summary,
      result: result.toJson(),
      vin: DiagnosticReportRepository.lastVin,
      odometerKm: obd.readings[ObdSignal.odometer]?.value,
      raw: List.of(_raw),
    );
    await DiagnosticReportRepository.save(report);
    return saved = report;
  }
}
