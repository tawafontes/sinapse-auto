import 'package:flutter/material.dart';

import '../../../models/vehicle_profile.dart';
import '../../../services/driving_session_host.dart';
import '../../../services/obd/diagnostic/report_runner.dart';
import '../../../services/obd/diagnostic/reports/battery_report.dart';
import '../../../services/obd/obd_service.dart';
import '../../../services/vehicle_repository.dart';
import 'report_views.dart';

/// "Bateria, partida e carga" (§7.2): a three-step assistant, always with the
/// car stopped — rest, cranking (or, on a hybrid, going READY) and charging.
/// Each step saves the report again, so leaving midway keeps what was done.
class BatteryReportScreen extends StatefulWidget {
  const BatteryReportScreen({super.key});

  @override
  State<BatteryReportScreen> createState() => _BatteryReportScreenState();
}

class _BatteryReportScreenState extends State<BatteryReportScreen> {
  BatteryReportSession? _session;
  String? _busy;
  DiagnosticCancelToken? _token;
  VoltageSample? _live;
  String? _problem;
  double? _minutesOff;
  bool _minutesKnown = false;

  bool get _hybrid {
    final propulsion = VehicleRepository.profile?.propulsion;
    return propulsion != null && propulsion != VehiclePropulsion.combustion;
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  BatteryReportSession _sessionFor(ObdService obd) => _session ??= BatteryReportSession(obd, hybrid: _hybrid);

  Future<void> _run(String label, Future<BatteryStep> Function(BatteryReportSession s, DiagnosticCancelToken token) step, ObdService obd) async {
    final token = DiagnosticCancelToken();
    setState(() {
      _busy = label;
      _token = token;
      _live = null;
      _problem = null;
    });
    try {
      final session = _sessionFor(obd);
      final measured = await step(session, token);
      await session.save();
      if (!session.kept(measured) && mounted) {
        // A failed retry: the earlier measurement stays; say why this one failed.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          key: const ValueKey('diagBattery_retryFailed'),
          duration: const Duration(seconds: 8),
          content: Text('${measured.verdict} A medida anterior foi mantida.'),
        ));
      }
    } on DiagnosticUnavailable catch (e) {
      if (mounted) setState(() => _problem = e.reason);
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _token = null;
        });
      }
    }
  }

  void _onSample(VoltageSample s) {
    if (mounted) setState(() => _live = s);
  }

  @override
  Widget build(BuildContext context) {
    final obd = DrivingSessionScope.maybeOf(context)?.obd;
    return Scaffold(
      appBar: AppBar(title: const Text('Bateria, partida e carga')),
      body: SafeArea(
        child: obd == null
            ? const Center(child: Text('OBD-II indisponível neste aparelho'))
            : ListenableBuilder(listenable: obd, builder: (context, _) => _body(context, obd)),
      ),
    );
  }

  Widget _body(BuildContext context, ObdService obd) {
    final hybrid = _session?.hybrid ?? _hybrid;
    final result = _session?.result;
    final offReason = obd.diagnosticUnavailableReason(needsCar: false);
    final onReason = obd.diagnosticUnavailableReason();
    final idle = _busy == null;
    Widget button(String key, String label, String? reason, VoidCallback run) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FilledButton.tonal(key: ValueKey(key), onPressed: idle && reason == null ? run : null, child: Text(label)),
              if (reason != null && idle)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(reason, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        );
    BatteryStep? done(String kind, [String? phase]) => result?.step(kind, phase);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      children: [
        if (hybrid)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Num híbrido, a bateria de 12 V não aciona motor de partida: ela liga os módulos e fecha os contatores da bateria '
              'de alta tensão. Quem a carrega é o conversor DC-DC.',
            ),
          ),
        if (_busy != null)
          ReportCard(
            title: _busy!,
            icon: Icons.bolt,
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(_live == null ? 'Lendo…' : '${ptNumber(_live!.volts, 2)} V${_live!.rpm == null ? '' : ' · ${_live!.rpm!.round()} rpm'}',
                  key: const ValueKey('diagBattery_live'), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => _token?.cancel(), child: const Text('Cancelar')),
            ],
          ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ReportCard(
          title: '1. Repouso',
          icon: Icons.battery_std,
          children: [
            const Text('Com o carro desligado, de preferência há pelo menos 1 hora. O adaptador mede a bateria de 12 V.'),
            const SizedBox(height: 8),
            DropdownButton<double?>(
              key: const ValueKey('diagBattery_minutesOff'),
              isExpanded: true,
              value: _minutesKnown ? _minutesOff : -1,
              items: const [
                DropdownMenuItem(value: -1, child: Text('Há quanto tempo está desligado? Não sei')),
                DropdownMenuItem(value: 30, child: Text('Menos de 1 hora')),
                DropdownMenuItem(value: 120, child: Text('1 hora ou mais')),
              ],
              onChanged: (v) => setState(() {
                _minutesKnown = v != -1;
                _minutesOff = v == -1 ? null : v;
              }),
            ),
            button('diagBattery_rest', 'Medir', offReason, () => _run('Repouso', (s, _) => s.rest(minutesOff: _minutesOff), obd)),
          ],
        ),
        if (done('rest') case final step?) BatteryStepCard(step: step, hybrid: hybrid),
        if (hybrid)
          ReportCard(
            title: '2. Ativação (READY)',
            icon: Icons.power_settings_new,
            children: [
              const Text('Toque em “Vou ligar o carro” e, em seguida, aperte o botão de partida até o carro ficar READY. '
                  'O app mede a queda e a entrada do DC-DC.'),
              button('diagBattery_activation', 'Vou ligar o carro', offReason,
                  () => _run('Ativação', (s, t) => s.activation(cancel: t, onSample: _onSample), obd)),
            ],
          )
        else
          ReportCard(
            title: '2. Partida',
            icon: Icons.key,
            children: [
              const Text('Com a ignição desligada, toque em “Vou dar a partida” e dê a partida em até 15 segundos.'),
              button('diagBattery_crank', 'Vou dar a partida', offReason, () => _run('Partida', (s, t) => s.crank(cancel: t, onSample: _onSample), obd)),
            ],
          ),
        if (done(hybrid ? 'activation' : 'crank') case final step?) BatteryStepCard(step: step, hybrid: hybrid),
        ReportCard(
          title: '3. Carga',
          icon: Icons.electrical_services,
          children: [
            Text(hybrid
                ? 'Em READY, carro parado: primeiro só elétrico. Depois, se quiser, com o motor a combustão funcionando (force o modo de recarga ou HEV).'
                : 'Com o motor em marcha lenta, carro parado. Depois, se quiser, mantenha 2.000 rpm por 10 segundos.'),
            if (hybrid) ...[
              button('diagBattery_chargeElectric', 'Medir só elétrico (30 s)', onReason,
                  () => _run('Carga, só elétrico', (s, t) => s.charge('electric', cancel: t, onSample: _onSample), obd)),
              button('diagBattery_chargeEngine', 'Medir com o motor (30 s)', onReason,
                  () => _run('Carga com o motor', (s, t) => s.charge('engine', cancel: t, onSample: _onSample), obd)),
            ] else ...[
              button('diagBattery_chargeIdle', 'Medir em marcha lenta (30 s)', onReason,
                  () => _run('Carga em marcha lenta', (s, t) => s.charge('idle', cancel: t, onSample: _onSample), obd)),
              button('diagBattery_charge2000', 'Medir a 2.000 rpm (10 s)', onReason,
                  () => _run('Carga a 2.000 rpm', (s, t) => s.charge('rpm2000', duration: const Duration(seconds: 10), cancel: t, onSample: _onSample), obd)),
            ],
          ],
        ),
        for (final phase in hybrid ? const ['electric', 'engine'] : const ['idle', 'rpm2000'])
          if (done('charge', phase) case final step?) BatteryStepCard(step: step, hybrid: hybrid),
        if (_session?.saved case final saved?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('Salvo no histórico: ${saved.summary}', key: const ValueKey('diagBattery_saved')),
          ),
      ],
    );
  }
}
