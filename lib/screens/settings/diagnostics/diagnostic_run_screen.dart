import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/diagnostic_report.dart';
import '../../../services/driving_session_host.dart';
import '../../../services/driving_session_recorder.dart';
import '../../../services/obd/diagnostic/diagnostic_report_repository.dart';
import '../../../services/obd/diagnostic/dtc_catalog.dart';
import '../../../services/obd/diagnostic/report_runner.dart';
import '../../../services/obd/diagnostic/reports/emissions_report.dart';
import '../../../services/obd/diagnostic/reports/health_report.dart';
import '../../../services/obd/obd_service.dart';
import 'report_views.dart';

/// "Saúde do veículo" or "Emissões e prontidão": the Executar button (off,
/// with the reason, without a link), progress and Cancelar while it runs,
/// then the report — already saved in the history. The health report also
/// offers "Apagar códigos do motor" (§7.6).
class DiagnosticRunScreen extends StatefulWidget {
  const DiagnosticRunScreen({super.key, required this.type});

  final DiagnosticReportType type;

  @override
  State<DiagnosticRunScreen> createState() => _DiagnosticRunScreenState();
}

class _DiagnosticRunScreenState extends State<DiagnosticRunScreen> {
  DtcCatalog? _catalog;
  DiagnosticCancelToken? _token;
  String? _progress;
  DiagnosticReport? _report;
  DiagnosticReport? _previous;
  String? _problem;
  bool _clearing = false;

  bool get _running => _token != null;

  @override
  void initState() {
    super.initState();
    unawaited(DtcCatalog.load().then((c) {
      if (mounted) setState(() => _catalog = c);
    }, onError: (Object _) {}));
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  DrivingSessionHost? get _host => DrivingSessionScope.maybeOf(context);

  bool get _recording => _host?.recorder.state == DrivingSessionRecorderState.recording;

  Future<void> _execute(ObdService obd, {String? beforeId}) async {
    final token = DiagnosticCancelToken();
    setState(() {
      _token = token;
      _progress = 'Aguardando o adaptador…';
      _problem = null;
    });
    try {
      void progress(String step) {
        if (mounted) setState(() => _progress = step);
      }

      final report = widget.type == DiagnosticReportType.health
          ? await runHealthReport(obd, cancel: token, onProgress: progress, beforeId: beforeId)
          : await runEmissionsReport(obd, cancel: token, onProgress: progress);
      if (!mounted) return;
      setState(() {
        _report = report;
        _previous = DiagnosticReportRepository.previous(report);
      });
    } on DiagnosticUnavailable catch (e) {
      if (mounted) setState(() => _problem = e.reason);
    } finally {
      if (mounted) {
        setState(() {
          _token = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _clear(ObdService obd) async {
    final before = _report!;
    final confirmed = await showDialog<bool>(context: context, builder: (_) => const _ClearCodesDialog());
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    ClearCodesResult? result;
    try {
      result = await clearEngineCodes(obd, recording: _recording);
    } on DiagnosticUnavailable catch (e) {
      result = (outcome: ClearCodesOutcome.noAnswer, message: e.reason);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
    // Checked by a new report, linked to the one before ("antes e depois").
    if (result.outcome == ClearCodesOutcome.cleared) await _execute(obd, beforeId: before.id);
  }

  @override
  Widget build(BuildContext context) {
    final obd = _host?.obd;
    final title = diagnosticReportTypeLabels[widget.type]!;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: obd == null
            ? const Center(child: Text('OBD-II indisponível neste aparelho'))
            : ListenableBuilder(
                listenable: obd,
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 32),
                  children: [
                    _intro(context, obd),
                    if (_report case final report?) ...[
                      if (report.beforeId != null)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Text('Depois de apagar os códigos:'),
                        ),
                      DiagnosticReportView(report: report, catalog: _catalog, previous: _previous),
                      if (_canClear(report, obd))
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: OutlinedButton.icon(
                            key: const ValueKey('diagRun_clear'),
                            onPressed: _clearing || _running ? null : () => _clear(obd),
                            icon: _clearing
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.cleaning_services_outlined),
                            label: const Text('Apagar códigos do motor'),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  bool _canClear(DiagnosticReport report, ObdService obd) {
    if (widget.type != DiagnosticReportType.health || report.status != DiagnosticReportStatus.complete) return false;
    if (obd.info.engineEcu == null) return false;
    final engine = HealthResult.fromJson(report.result).engine;
    return engine != null && (engine.codeCount > 0 || (engine.monitors?.mil ?? false));
  }

  Widget _intro(BuildContext context, ObdService obd) {
    final reason = obd.diagnosticUnavailableReason();
    final text = widget.type == DiagnosticReportType.health
        ? 'Lê a identificação do carro, os códigos de falha de cada central (armazenados, pendentes e permanentes), '
            'o instantâneo da falha e a prontidão. Leva alguns segundos; o painel pausa enquanto isso.'
        : 'Lê os monitores de emissões: quais testes de bordo o carro já concluiu desde que os códigos foram apagados '
            'e neste ciclo de direção, e se ele está pronto para uma inspeção.';
    return ReportCard(
      title: 'Executar',
      icon: Icons.play_circle_outline,
      children: [
        Text(text),
        const SizedBox(height: 12),
        if (_running) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(_progress ?? '', key: const ValueKey('diagRun_progress')),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('diagRun_cancel'),
            onPressed: () => _token?.cancel(),
            child: const Text('Cancelar'),
          ),
        ] else ...[
          FilledButton.icon(
            key: const ValueKey('diagRun_execute'),
            onPressed: reason == null && !_clearing ? () => _execute(obd) : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(_report == null ? 'Executar' : 'Executar de novo'),
          ),
          if (reason != null || _problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(reason ?? _problem!, key: const ValueKey('diagRun_reason'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ],
    );
  }
}

/// The explanation before clearing, and a button to hold for 2 s: one tap is
/// not enough (§7.6).
class _ClearCodesDialog extends StatelessWidget {
  const _ClearCodesDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Apagar os códigos do motor?'),
      content: const SingleChildScrollView(
        child: Text(
          'Este relatório já ficou salvo no histórico, com os códigos e o instantâneo da falha.\n\n'
          '• A luz de injeção apaga, mas volta se o defeito continuar.\n'
          '• Os monitores de prontidão voltam a “incompleto”: o carro pode não passar numa inspeção até rodar alguns ciclos.\n'
          '• Em alguns carros, as adaptações de marcha lenta e de mistura recomeçam.\n\n'
          'Carro parado, motor desligado e ignição ligada. Segure o botão para confirmar.',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Voltar')),
        HoldToConfirmButton(
          key: const ValueKey('diagRun_holdToClear'),
          label: 'Segure para apagar',
          onConfirmed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

/// A button that fires only after being held for [hold].
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({super.key, required this.label, required this.onConfirmed, this.hold = const Duration(seconds: 2)});

  final String label;
  final VoidCallback onConfirmed;
  final Duration hold;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(vsync: this, duration: widget.hold)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onConfirmed();
    });

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _release() {
    if (_progress.status != AnimationStatus.completed) _progress.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => _progress.forward(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: AnimatedBuilder(
        animation: _progress,
        builder: (context, _) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [scheme.error, scheme.error, scheme.error.withValues(alpha: 0.35), scheme.error.withValues(alpha: 0.35)],
              stops: [0, _progress.value, _progress.value, 1],
            ),
          ),
          child: Text(widget.label, style: TextStyle(color: scheme.onError, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
