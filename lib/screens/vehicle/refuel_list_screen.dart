import 'package:flutter/material.dart';

import '../../models/charge_record.dart';
import '../../models/refuel_record.dart';
import '../../models/vehicle_profile.dart';
import '../../services/fuel_consumption.dart';
import '../../services/hybrid_consumption.dart';
import '../../services/vehicle_repository.dart';
import 'charge_form_screen.dart';
import 'refuel_form_screen.dart';

/// "Abastecimentos" — "Abastecimentos e recargas" on a plug-in hybrid: every
/// record, newest first, in one timeline. A tap corrects one, the trash icon
/// deletes it (after confirming). A full refuel that closes a full-to-full
/// interval shows the consumption measured over it — on a plug-in the km/L of
/// the engine, from the combustion kilometres, since most kilometres are
/// electric; a recharge shows the km/kWh measured since the previous one.
class RefuelListScreen extends StatefulWidget {
  const RefuelListScreen({super.key});

  @override
  State<RefuelListScreen> createState() => _RefuelListScreenState();
}

class _RefuelListScreenState extends State<RefuelListScreen> {
  late final Listenable _changes = Listenable.merge([
    RefuelRepository.listenable(),
    ChargeRepository.listenable(),
    VehicleRepository.listenable(),
  ]);

  Future<void> _confirmDelete(OdometerRecord record) async {
    final (title, what) = switch (record) {
      RefuelRecord r => ('Excluir abastecimento?', 'O abastecimento de ${formatDate(r.date)} (${formatLiters(r.liters)})'),
      ChargeRecord c => ('Excluir recarga?', 'A recarga de ${formatDate(c.date)} (${formatPercent(c.startPercent)} → ${formatPercent(c.endPercent)})'),
      _ => ('Excluir?', 'O registro'),
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text('$what será apagado e o consumo será recalculado sem ele.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Excluir')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (record is RefuelRecord) await RefuelRepository.delete(record);
    if (record is ChargeRecord) await ChargeRepository.delete(record);
  }

  @override
  Widget build(BuildContext context) {
    final plugIn = VehicleRepository.profile?.isPlugIn ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(plugIn ? 'Abastecimentos e recargas' : 'Abastecimentos')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('refuelList_add'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RefuelFormScreen())),
        icon: const Icon(Icons.add),
        label: const Text('Registrar'),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _changes,
          builder: (context, _) {
            final profile = VehicleRepository.profile;
            final refuels = RefuelRepository.chronological;
            final charges = ChargeRepository.chronological;
            if (refuels.isEmpty && charges.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    profile?.isPlugIn ?? false
                        ? 'Nenhum registro.\n\nToque em "Registrar" sempre que abastecer ou recarregar. O app separa os '
                            'km elétricos dos km a combustão e calcula o custo real por km.'
                        : 'Nenhum abastecimento registrado.\n\nToque em "Registrar" sempre que abastecer. Com dois '
                            'abastecimentos de tanque cheio, o app calcula o consumo real do seu carro.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final hybrid = profile != null && profile.isPlugIn
                ? HybridSummary.of(profile: profile, refuels: refuels, charges: charges)
                : null;
            final closingFuel = {for (final i in ConsumptionSummary.of(refuels).intervals) i.to.id: i};
            final engineByClosing = {for (final e in hybrid?.engineIntervals ?? const <EngineInterval>[]) e.interval.to.id: e};
            final measurementByClosing = {for (final m in hybrid?.electricMeasurements ?? const <ElectricMeasurement>[]) m.closedBy.id: m};
            final newestFirst = vehicleTimeline(refuels, charges).reversed.toList();
            return ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: newestFirst.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final record = newestFirst[index];
                final List<String> lines;
                final Widget leading;
                final String title;
                final Widget editor;
                if (record is RefuelRecord) {
                  leading = Icon(record.fullTank ? Icons.local_gas_station : Icons.local_gas_station_outlined);
                  title = '${formatDate(record.date)} · ${fuelTypeLabels[record.fuel]}';
                  editor = RefuelFormScreen(editing: record);
                  final engine = engineByClosing[record.id];
                  final interval = closingFuel[record.id];
                  lines = [
                    '${formatLiters(record.liters)} × ${formatPricePerLiter(record.pricePerLiter)} = '
                        '${formatMoney(record.totalPrice)}',
                    [formatKm(record.odometerKm), record.fullTank ? 'Tanque cheio' : 'Parcial'].join(' · '),
                    if (hybrid == null && interval != null)
                      '${formatKmPerLiter(interval.kmPerLiter)} em ${formatKm(interval.distanceKm)}'
                    else if (engine != null && engine.fuelKm > 0)
                      'Motor: ${formatKmPerLiter(engine.fuelKm / engine.interval.liters)} em ${formatKm(engine.fuelKm)} a combustão (estimado)',
                  ];
                } else {
                  final charge = record as ChargeRecord;
                  leading = const Icon(Icons.ev_station);
                  title = '${formatDate(charge.date)} · Recarga';
                  editor = ChargeFormScreen(editing: charge);
                  final measurement = measurementByClosing[charge.id];
                  lines = [
                    '${formatPercent(charge.startPercent)} → ${formatPercent(charge.endPercent)} · '
                        '${formatKwh(charge.wallKwh)}${charge.chargerKwh == null ? ' (estimado)' : ''} = ${formatMoney(charge.totalPrice)}',
                    [formatKm(charge.odometerKm), if (charge.usedFuelSinceLast) 'usou combustível'].join(' · '),
                    if (measurement != null)
                      '${formatKmPerKwh(measurement.kmPerKwh)} em ${formatKm(measurement.km)} elétricos'
                          '${measurement.intervals.length > 1 ? ' (${measurement.intervals.length} recargas somadas)' : ''}',
                  ];
                }
                return ListTile(
                  key: ValueKey('refuelList_${record.id}'),
                  leading: leading,
                  title: Text(title),
                  subtitle: Text(lines.join('\n')),
                  isThreeLine: true,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => editor)),
                  trailing: IconButton(
                    key: ValueKey('refuelList_delete_${record.id}'),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Excluir',
                    onPressed: () => _confirmDelete(record),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
