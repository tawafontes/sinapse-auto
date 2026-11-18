import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/diagnostic_report.dart';
import '../../../services/obd/diagnostic/diagnostic_report_repository.dart';
import '../../../services/obd/diagnostic/dtc_catalog.dart';
import '../../../services/obd/diagnostic/obd_modes.dart';
import 'report_views.dart';

/// "Histórico de relatórios" (§8): newest first, filtered by type and by car
/// (VIN); a star keeps a report when the history is trimmed; delete one by
/// one or several at once (long press to select).
class DiagnosticHistoryScreen extends StatefulWidget {
  const DiagnosticHistoryScreen({super.key});

  @override
  State<DiagnosticHistoryScreen> createState() => _DiagnosticHistoryScreenState();
}

class _DiagnosticHistoryScreenState extends State<DiagnosticHistoryScreen> {
  DiagnosticReportType? _type;
  String? _vin;
  final Set<String> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

  Future<void> _delete(List<String> ids) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ids.length == 1 ? 'Excluir o relatório?' : 'Excluir ${ids.length} relatórios?'),
        content: const Text('Não dá para desfazer.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    await DiagnosticReportRepository.delete(ids);
    if (mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: DiagnosticReportRepository.listenable(),
      builder: (context, _, _) {
        final all = DiagnosticReportRepository.newestFirst;
        final vins = {for (final r in all) ?r.vin};
        final shown = all.where((r) => (_type == null || r.type == _type) && (_vin == null || r.vin == _vin)).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(_selecting ? '${_selected.length} selecionado(s)' : 'Histórico de relatórios'),
            leading: _selecting ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)) : null,
            actions: [
              if (_selecting)
                IconButton(
                  key: const ValueKey('diagHistory_deleteSelected'),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Excluir selecionados',
                  onPressed: () => _delete(_selected.toList()),
                ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      for (final type in [null, ...DiagnosticReportType.values])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            key: ValueKey('diagHistory_filter_${type?.name ?? 'all'}'),
                            label: Text(type == null ? 'Todos' : diagnosticReportTypeLabels[type]!),
                            selected: _type == type,
                            onSelected: (_) => setState(() => _type = type),
                          ),
                        ),
                      if (vins.length > 1)
                        for (final vin in [null, ...vins])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: Text(vin == null ? 'Todos os carros' : maskVin(vin)),
                              selected: _vin == vin,
                              onSelected: (_) => setState(() => _vin = vin),
                            ),
                          ),
                    ],
                  ),
                ),
                Expanded(
                  child: shown.isEmpty
                      ? const Center(child: Text('Nenhum relatório ainda.'))
                      : ListView.separated(
                          itemCount: shown.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final r = shown[i];
                            final scheme = Theme.of(context).colorScheme;
                            final selected = _selected.contains(r.id);
                            return ListTile(
                              key: ValueKey('diagHistory_${r.id}'),
                              selected: selected,
                              leading: _selecting
                                  ? Icon(selected ? Icons.check_box : Icons.check_box_outline_blank)
                                  : Icon(diagnosticLevelIcon(r.level), color: diagnosticLevelColor(r.level, scheme)),
                              title: Text(diagnosticReportTypeLabels[r.type]!),
                              subtitle: Text([
                                '${formatReportTime(r.at)} · ${r.summary}',
                                if (r.status != DiagnosticReportStatus.complete) diagnosticReportStatusLabels[r.status]!,
                                if (r.beforeId != null) 'Depois de apagar os códigos',
                              ].join('\n')),
                              isThreeLine: r.status != DiagnosticReportStatus.complete || r.beforeId != null,
                              trailing: _selecting
                                  ? null
                                  : IconButton(
                                      key: ValueKey('diagHistory_star_${r.id}'),
                                      icon: Icon(r.starred ? Icons.star : Icons.star_border),
                                      tooltip: r.starred ? 'Tirar a estrela' : 'Guardar com estrela',
                                      onPressed: () => DiagnosticReportRepository.setStarred(r, !r.starred),
                                    ),
                              onLongPress: () => setState(() => selected ? _selected.remove(r.id) : _selected.add(r.id)),
                              onTap: _selecting
                                  ? () => setState(() => selected ? _selected.remove(r.id) : _selected.add(r.id))
                                  : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DiagnosticReportDetailScreen(reportId: r.id))),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One saved report, compared with the one before it of the same type and car;
/// "Antes e depois" links when it was part of clearing the codes.
class DiagnosticReportDetailScreen extends StatefulWidget {
  const DiagnosticReportDetailScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<DiagnosticReportDetailScreen> createState() => _DiagnosticReportDetailScreenState();
}

class _DiagnosticReportDetailScreenState extends State<DiagnosticReportDetailScreen> {
  DtcCatalog? _catalog;

  @override
  void initState() {
    super.initState();
    unawaited(DtcCatalog.load().then((c) {
      if (mounted) setState(() => _catalog = c);
    }, onError: (Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    final report = DiagnosticReportRepository.byId(widget.reportId);
    if (report == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Relatório excluído.')));
    }
    final linked = report.beforeId ?? report.afterId;
    return Scaffold(
      appBar: AppBar(
        title: Text(diagnosticReportTypeLabels[report.type]!),
        actions: [
          IconButton(
            key: const ValueKey('diagDetail_delete'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Excluir',
            onPressed: () async {
              final navigator = Navigator.of(context);
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Excluir o relatório?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
                    FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Excluir')),
                  ],
                ),
              );
              if (ok != true) return;
              await DiagnosticReportRepository.delete([report.id]);
              navigator.pop();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            if (linked != null && DiagnosticReportRepository.byId(linked) != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  key: const ValueKey('diagDetail_linked'),
                  icon: const Icon(Icons.compare_arrows),
                  label: Text(report.beforeId != null ? 'Ver o relatório de antes de apagar' : 'Ver o relatório de depois de apagar'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DiagnosticReportDetailScreen(reportId: linked))),
                ),
              ),
            DiagnosticReportView(
              report: report,
              catalog: _catalog,
              previous: report.beforeId != null ? DiagnosticReportRepository.byId(report.beforeId!) : DiagnosticReportRepository.previous(report),
            ),
          ],
        ),
      ),
    );
  }
}
