import 'package:flutter/material.dart';

import '../../../models/diagnostic_report.dart';
import '../../../services/fuel_consumption.dart';
import '../../../services/obd/diagnostic/dtc_catalog.dart';
import '../../../services/obd/diagnostic/obd_modes.dart';
import '../../../services/obd/diagnostic/report_runner.dart';
import '../../../services/obd/diagnostic/reports/battery_report.dart';
import '../../../services/obd/diagnostic/reports/emissions_report.dart';
import '../../../services/obd/diagnostic/reports/health_report.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// `15/11/2026 14:32`.
String formatReportTime(DateTime at) => '${_two(at.day)}/${_two(at.month)}/${at.year} ${_two(at.hour)}:${_two(at.minute)}';

/// `15/11`.
String formatReportDay(DateTime at) => '${_two(at.day)}/${_two(at.month)}';

/// The traffic light's colours: green, amber, red, grey.
Color diagnosticLevelColor(ReportLevel level, ColorScheme scheme) => switch (level) {
      ReportLevel.ok => const Color(0xFF43A047),
      ReportLevel.attention => const Color(0xFFFFA000),
      ReportLevel.problem => scheme.error,
      ReportLevel.unknown => scheme.onSurfaceVariant,
    };

IconData diagnosticLevelIcon(ReportLevel level) => switch (level) {
      ReportLevel.ok => Icons.check_circle,
      ReportLevel.attention => Icons.warning_amber_rounded,
      ReportLevel.problem => Icons.error,
      ReportLevel.unknown => Icons.help_outline,
    };

/// A card with a title and rows, the look of the Diagnóstico screen.
class ReportCard extends StatelessWidget {
  const ReportCard({super.key, required this.title, this.icon, this.level, required this.children});

  final String title;
  final IconData? icon;
  final ReportLevel? level;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final level = this.level;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (level != null)
                  Icon(diagnosticLevelIcon(level), color: diagnosticLevelColor(level, scheme), size: 20)
                else if (icon != null)
                  Icon(icon, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ],
            ),
            const Divider(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A label and its value on one line.
class ReportRow extends StatelessWidget {
  const ReportRow(this.label, this.value, {super.key, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value, textAlign: TextAlign.end, style: style?.copyWith(fontWeight: FontWeight.w600, color: color)),
          ),
        ],
      ),
    );
  }
}

/// The verdict at the top of a report: the light, the summary, how it ended.
class ReportVerdict extends StatelessWidget {
  const ReportVerdict(this.report, {super.key});

  final DiagnosticReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = diagnosticLevelColor(report.level, scheme);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(diagnosticLevelIcon(report.level), color: color, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(report.summary, key: const ValueKey('diagReport_summary'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    [
                      formatReportTime(report.at),
                      if (report.vin != null) maskVin(report.vin!),
                      if (report.odometerKm != null) formatKm(report.odometerKm!),
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (report.status != DiagnosticReportStatus.complete)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${diagnosticReportStatusLabels[report.status]}: ${report.statusDetail ?? ''}',
                        key: const ValueKey('diagReport_status'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The whole report, by type, plus the raw answers folded away.
class DiagnosticReportView extends StatelessWidget {
  const DiagnosticReportView({super.key, required this.report, this.catalog, this.previous});

  final DiagnosticReport report;
  final DtcCatalog? catalog;

  /// The report of the same type before this one, to compare with.
  final DiagnosticReport? previous;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportVerdict(report),
        ...switch (report.type) {
          DiagnosticReportType.health => _health(context, HealthResult.fromJson(report.result)),
          DiagnosticReportType.emissions => _emissions(context, EmissionsResult.fromJson(report.result)),
          DiagnosticReportType.battery => _battery(context, BatteryResult.fromJson(report.result)),
        },
        _RawDetails(report),
      ],
    );
  }

  List<Widget> _health(BuildContext context, HealthResult r) {
    final scheme = Theme.of(context).colorScheme;
    final previous = this.previous;
    final diff = previous == null ? null : compareHealth(HealthResult.fromJson(previous.result), r);
    String describe(String code) => catalog?.describe(code) ?? '';
    Widget code(String code, String kind, ReportLevel level) => ListTile(
          key: ValueKey('diagReport_code_${code}_$kind'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(diagnosticLevelIcon(level), color: diagnosticLevelColor(level, scheme)),
          title: Text('$code · $kind'),
          subtitle: Text(describe(code)),
        );
    return [
      if (diff != null && (diff.added.isNotEmpty || diff.resolved.isNotEmpty || previous != null))
        ReportCard(
          title: 'Comparado ao relatório de ${formatReportDay(previous!.at)}',
          icon: Icons.compare_arrows,
          children: [
            ReportRow('Códigos novos', diff.added.isEmpty ? 'nenhum' : (diff.added.toList()..sort()).join(', '),
                color: diff.added.isEmpty ? null : scheme.error),
            ReportRow('Códigos resolvidos', diff.resolved.isEmpty ? 'nenhum' : (diff.resolved.toList()..sort()).join(', ')),
          ],
        ),
      ReportCard(
        title: 'Identificação',
        icon: Icons.badge_outlined,
        children: [
          ReportRow('VIN', r.vin == null ? 'não informado' : maskVin(r.vin!)),
          if (r.vin != null) ReportRow('Fabricante', manufacturerFromVin(r.vin!) ?? 'não identificado (${r.vin!.substring(0, 3)})'),
          if (r.adapterVolts != null) ReportRow('Tensão no conector', '${ptNumber(r.adapterVolts!)} V'),
          ReportRow('Centrais que responderam', r.ecus.isEmpty ? 'nenhuma' : r.ecus.map((e) => e.id.toRadixString(16).toUpperCase()).join(', ')),
        ],
      ),
      for (final ecu in r.ecus)
        ReportCard(
          title: '${ecuRole(ecu.id)} (${ecu.id.toRadixString(16).toUpperCase()})',
          level: ecu.stored.isNotEmpty || ecu.permanent.isNotEmpty || (ecu.monitors?.mil ?? false)
              ? ReportLevel.problem
              : ecu.pending.isNotEmpty
                  ? ReportLevel.attention
                  : (ecu.codesRead ? ReportLevel.ok : ReportLevel.unknown),
          children: [
            if (ecu.name != null) ReportRow('Nome', ecu.name!),
            if (ecu.calibrationIds.isNotEmpty) ReportRow('Calibração', ecu.calibrationIds.join(', ')),
            if (ecu.cvns.isNotEmpty) ReportRow('CVN', ecu.cvns.join(', ')),
            if (ecu.monitors?.mil != null)
              ReportRow('Luz de injeção', ecu.monitors!.mil! ? 'acesa' : 'apagada', color: ecu.monitors!.mil! ? scheme.error : null),
            if (!ecu.codesRead) const ReportRow('Códigos', 'não respondeu'),
            if (ecu.codesRead && ecu.codeCount == 0) const ReportRow('Códigos', 'nenhum'),
            for (final c in ecu.stored) code(c, 'armazenado', ReportLevel.problem),
            for (final c in ecu.permanent) code(c, 'permanente', ReportLevel.problem),
            for (final c in ecu.pending) code(c, 'pendente', ReportLevel.attention),
          ],
        ),
      if (r.freezeFrame case final frame?)
        ReportCard(
          title: 'Instantâneo da falha${frame.dtc == null ? '' : ' (${frame.dtc})'}',
          icon: Icons.photo_camera_outlined,
          children: [
            Text('O que o motor fazia quando guardou o código.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            for (final e in frame.values.entries)
              if (freezeFramePids[e.key] case (final name, final unit))
                ReportRow(name, '${ptNumber(e.value, e.key == 0x42 || e.key == 0x10 ? 1 : 0)}${unit.isEmpty ? '' : ' $unit'}'),
          ],
        ),
      if (r.usage.isNotEmpty)
        ReportCard(
          title: 'Uso',
          icon: Icons.route_outlined,
          children: [
            for (final e in r.usage.entries)
              if (usagePids[e.key] case (final name, final unit))
                ReportRow(name, '${ptNumber(e.value, e.key == 0xA6 ? 1 : 0)}${unit.isEmpty ? '' : ' $unit'}'),
          ],
        ),
      if (r.engine?.monitors case final monitors?)
        ReportCard(
          title: 'Prontidão (monitores do motor)',
          icon: Icons.fact_check_outlined,
          children: [
            ReportRow('Monitores suportados', '${monitors.supported.length}'),
            ReportRow('Incompletos', monitors.incomplete.isEmpty ? 'nenhum' : monitors.incomplete.map((m) => m.name).join(', ')),
            Text('O detalhe fica no relatório de emissões e prontidão.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
    ];
  }

  List<Widget> _emissions(BuildContext context, EmissionsResult r) {
    final scheme = Theme.of(context).colorScheme;
    Widget monitors(String title, MonitorStatus status) => ReportCard(
          title: title,
          icon: Icons.fact_check_outlined,
          children: [
            for (final m in status.monitors.where((m) => m.supported))
              ReportRow(
                m.name,
                m.complete ? 'completo' : 'incompleto',
                color: m.complete ? diagnosticLevelColor(ReportLevel.ok, scheme) : diagnosticLevelColor(ReportLevel.attention, scheme),
              ),
            if (status.supported.isEmpty) const ReportRow('Monitores', 'nenhum informado'),
          ],
        );
    final engine = r.engine;
    return [
      ReportCard(
        title: r.readyForInspection ? 'Pronto para inspeção' : 'Ainda não está pronto',
        level: r.level,
        children: [Text(r.advice, key: const ValueKey('diagReport_advice'))],
      ),
      if (engine?.sinceClear case final s?) monitors('Desde que os códigos foram apagados', s),
      if (engine?.thisCycle case final s?) monitors('Neste ciclo de direção', s),
      for (final e in r.ecus.where((e) => e != engine && e.sinceClear != null && e.sinceClear!.supported.isNotEmpty))
        monitors('${ecuRole(e.id)} (${e.id.toRadixString(16).toUpperCase()})', e.sinceClear!),
      if (r.usage.isNotEmpty)
        ReportCard(
          title: 'Desde o último apagamento',
          icon: Icons.route_outlined,
          children: [
            for (final e in r.usage.entries)
              if (usagePids[e.key] case (final name, final unit)) ReportRow(name, '${ptNumber(e.value, 0)}${unit.isEmpty ? '' : ' $unit'}'),
          ],
        ),
    ];
  }

  List<Widget> _battery(BuildContext context, BatteryResult r) => [for (final step in r.steps) BatteryStepCard(step: step, hybrid: r.hybrid)];
}

String batteryStepTitle(BatteryStep step, {required bool hybrid}) => switch ((step.kind, step.phase)) {
      ('rest', _) => 'Repouso',
      ('crank', _) => 'Partida',
      ('activation', _) => 'Ativação (READY)',
      ('charge', 'idle') => 'Carga em marcha lenta',
      ('charge', 'rpm2000') => 'Carga a 2.000 rpm',
      ('charge', 'electric') => 'Carga em READY, só elétrico',
      ('charge', 'engine') => 'Carga com o motor a combustão',
      _ => 'Carga',
    };

/// One battery step: its verdict, its numbers and the voltage curve.
class BatteryStepCard extends StatelessWidget {
  const BatteryStepCard({super.key, required this.step, required this.hybrid});

  final BatteryStep step;
  final bool hybrid;

  @override
  Widget build(BuildContext context) {
    String v(String key) => '${ptNumber(step.values[key]!)} V';
    final rows = <Widget>[
      if (step.values.containsKey('volts')) ReportRow('Tensão', v('volts')),
      if (step.values.containsKey('min')) ReportRow('Mínima na partida', v('min')),
      if (step.values.containsKey('recoveryMs')) ReportRow('Voltou a 13 V em', '${ptNumber(step.values['recoveryMs']! / 1000)} s'),
      if (step.values.containsKey('dip')) ReportRow('Mínima na ativação', v('dip')),
      if (step.values.containsKey('dcdc')) ReportRow('Tensão do DC-DC', v('dcdc')),
      if (step.values.containsKey('dcdcMs')) ReportRow('DC-DC entrou em', '${ptNumber(step.values['dcdcMs']! / 1000)} s'),
      if (step.values.containsKey('avg')) ReportRow('Média', v('avg')),
      if (step.values.containsKey('ripple')) ReportRow('Oscilação', v('ripple')),
      if (step.values.containsKey('engineStartDip')) ReportRow('Queda na entrada do motor', v('engineStartDip')),
    ];
    return ReportCard(
      key: ValueKey('diagBatteryStep_${step.kind}${step.phase == null ? '' : '_${step.phase}'}'),
      title: batteryStepTitle(step, hybrid: hybrid),
      level: step.level,
      children: [
        if (step.verdict.isNotEmpty) Text(step.verdict),
        ...rows,
        if (step.samples.length >= 3) ...[
          const SizedBox(height: 8),
          SizedBox(height: 90, child: VoltageCurve(samples: step.samples)),
        ],
      ],
    );
  }
}

/// The voltage over a step, with the 12 V and 13 V guides.
class VoltageCurve extends StatelessWidget {
  const VoltageCurve({super.key, required this.samples});

  final List<VoltageSample> samples;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _CurvePainter(samples, line: scheme.primary, guide: scheme.outlineVariant, text: scheme.onSurfaceVariant),
      size: Size.infinite,
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.samples, {required this.line, required this.guide, required this.text});

  final List<VoltageSample> samples;
  final Color line;
  final Color guide;
  final Color text;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || size.width <= 0) return;
    var lo = samples.map((s) => s.volts).reduce((a, b) => a < b ? a : b);
    var hi = samples.map((s) => s.volts).reduce((a, b) => a > b ? a : b);
    lo = (lo < 11.5 ? lo : 11.5) - 0.2;
    hi = (hi > 14.5 ? hi : 14.5) + 0.2;
    final t0 = samples.first.ms, t1 = samples.last.ms == t0 ? t0 + 1 : samples.last.ms;
    Offset at(VoltageSample s) => Offset((s.ms - t0) / (t1 - t0) * size.width, size.height - (s.volts - lo) / (hi - lo) * size.height);
    final guidePaint = Paint()
      ..color = guide
      ..strokeWidth = 1;
    for (final g in [12.0, 13.0, 14.0]) {
      final y = size.height - (g - lo) / (hi - lo) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guidePaint);
      final tp = TextPainter(
        text: TextSpan(text: '${g.toStringAsFixed(0)} V', style: TextStyle(fontSize: 9, color: text)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y - tp.height));
    }
    final path = Path()..moveTo(at(samples.first).dx, at(samples.first).dy);
    for (final s in samples.skip(1)) {
      path.lineTo(at(s).dx, at(s).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) => old.samples != samples || old.samples.length != samples.length;
}

/// "Detalhes técnicos": every command and its raw answer, folded away.
class _RawDetails extends StatelessWidget {
  const _RawDetails(this.report);

  final DiagnosticReport report;

  @override
  Widget build(BuildContext context) {
    if (report.raw.isEmpty) return const SizedBox.shrink();
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ExpansionTile(
        key: const ValueKey('diagReport_raw'),
        title: const Text('Detalhes técnicos'),
        subtitle: Text('${report.raw.length} comandos e as respostas brutas'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SelectableText(
              [
                for (final e in report.raw)
                  '> ${e.command}\n${_shown(e).trim().replaceAll(RegExp('[\r\n]+'), '\n')}',
              ].join('\n'),
              style: mono,
            ),
          ),
        ],
      ),
    );
  }

  /// The raw `0902` answer is the VIN in hex: hidden here, as the VIN is
  /// shown masked everywhere on screen (it stays whole in the saved report).
  String _shown(({String command, String? response}) e) {
    if (e.response == null) return '(sem resposta)';
    if (e.command == '0902') return '(resposta com o VIN, oculta na tela)';
    return e.response!;
  }
}
