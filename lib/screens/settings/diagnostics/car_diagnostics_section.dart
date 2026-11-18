import 'package:flutter/material.dart';

import '../../../models/diagnostic_report.dart';
import '../../../services/driving_session_host.dart';
import '../../../services/obd/diagnostic/diagnostic_report_repository.dart';
import '../../vehicle/obd_adapter_screen.dart';
import 'battery_report_screen.dart';
import 'diagnostic_history_screen.dart';
import 'diagnostic_run_screen.dart';
import 'report_views.dart';

/// "Diagnóstico do carro", further down the Diagnóstico screen (owner
/// decision, 2026-11-14): the OBD link's state, the reports with their last
/// result, and the history.
class CarDiagnosticsSection extends StatelessWidget {
  const CarDiagnosticsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final obd = DrivingSessionScope.maybeOf(context)?.obd;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('carDiagnostics'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ValueListenableBuilder(
          valueListenable: DiagnosticReportRepository.listenable(),
          builder: (context, _, _) {
            final reports = DiagnosticReportRepository.newestFirst;
            String last(DiagnosticReportType type) {
              final r = reports.where((r) => r.type == type).firstOrNull;
              return r == null ? 'último: —' : 'último: ${formatReportDay(r.at)} · ${r.summary}';
            }

            Widget item(String key, IconData icon, String title, String subtitle, Widget Function()? screen) => ListTile(
                  key: ValueKey(key),
                  leading: Icon(icon),
                  title: Text(title),
                  subtitle: Text(subtitle),
                  enabled: screen != null,
                  trailing: screen == null ? null : const Icon(Icons.chevron_right),
                  onTap: screen == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen())),
                );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(Icons.car_repair, color: scheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text('Diagnóstico do carro', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                ),
                if (obd != null)
                  ListenableBuilder(
                    listenable: obd,
                    builder: (context, _) => Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        children: [
                          Icon(Icons.circle, size: 12, color: obdLinkStateColor(obd.state, scheme)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              obd.diagnosing ? 'Diagnóstico em andamento' : obdLinkStateLabels[obd.state]!,
                              key: const ValueKey('carDiagnostics_state'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text('OBD-II indisponível neste aparelho'),
                  ),
                const Divider(height: 20),
                item('carDiagnostics_health', Icons.health_and_safety_outlined, 'Saúde do veículo', last(DiagnosticReportType.health),
                    obd == null ? null : () => const DiagnosticRunScreen(type: DiagnosticReportType.health)),
                item('carDiagnostics_battery', Icons.battery_charging_full, 'Bateria, partida e carga', last(DiagnosticReportType.battery),
                    obd == null ? null : () => const BatteryReportScreen()),
                item('carDiagnostics_emissions', Icons.eco_outlined, 'Emissões e prontidão', last(DiagnosticReportType.emissions),
                    obd == null ? null : () => const DiagnosticRunScreen(type: DiagnosticReportType.emissions)),
                item('carDiagnostics_recordings', Icons.timeline, 'Gravações OBD', 'Em breve, com a gravação dos sinais', null),
                item('carDiagnostics_modules', Icons.hub_outlined, 'Outros módulos', 'Experimental, em breve', null),
                item('carDiagnostics_history', Icons.history, 'Histórico de relatórios',
                    reports.length == 1 ? '1 relatório' : '${reports.length} relatórios', () => const DiagnosticHistoryScreen()),
              ],
            );
          },
        ),
      ),
    );
  }
}
