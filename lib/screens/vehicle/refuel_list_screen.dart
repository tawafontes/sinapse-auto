import 'package:flutter/material.dart';

import '../../models/refuel_record.dart';
import '../../models/vehicle_profile.dart';
import '../../services/fuel_consumption.dart';
import '../../services/vehicle_repository.dart';
import 'refuel_form_screen.dart';

/// "Abastecimentos": every registered refuel, newest first. A tap corrects one,
/// the trash icon deletes it (after confirming), and each full refuel that
/// closes a full-to-full interval shows the consumption measured over it.
class RefuelListScreen extends StatelessWidget {
  const RefuelListScreen({super.key});

  Future<void> _confirmDelete(BuildContext context, RefuelRecord refuel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir abastecimento?'),
        content: Text(
          'O abastecimento de ${formatDate(refuel.date)} (${formatLiters(refuel.liters)}) será apagado e o consumo '
          'será recalculado sem ele.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Excluir')),
        ],
      ),
    );
    if (confirmed == true) await RefuelRepository.delete(refuel);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Abastecimentos')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('refuelList_add'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RefuelFormScreen())),
        icon: const Icon(Icons.add),
        label: const Text('Registrar'),
      ),
      body: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: RefuelRepository.listenable(),
          builder: (context, _, _) {
            final summary = ConsumptionSummary.of(RefuelRepository.chronological);
            if (summary.refuels.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Nenhum abastecimento registrado.\n\nToque em "Registrar" sempre que abastecer. Com dois '
                    'abastecimentos de tanque cheio, o app calcula o consumo real do seu carro.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final closing = {for (final i in summary.intervals) i.to.id: i};
            final newestFirst = summary.refuels.reversed.toList();
            return ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: newestFirst.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final refuel = newestFirst[index];
                final interval = closing[refuel.id];
                return ListTile(
                  key: ValueKey('refuelList_${refuel.id}'),
                  leading: Icon(refuel.fullTank ? Icons.local_gas_station : Icons.local_gas_station_outlined),
                  title: Text('${formatDate(refuel.date)} · ${fuelTypeLabels[refuel.fuel]}'),
                  subtitle: Text(
                    [
                      '${formatLiters(refuel.liters)} × ${formatPricePerLiter(refuel.pricePerLiter)} = '
                          '${formatMoney(refuel.totalPrice)}',
                      [
                        formatKm(refuel.odometerKm),
                        refuel.fullTank ? 'Tanque cheio' : 'Parcial',
                      ].join(' · '),
                      if (interval != null)
                        '${formatKmPerLiter(interval.kmPerLiter)} em ${formatKm(interval.distanceKm)}',
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => RefuelFormScreen(editing: refuel)),
                  ),
                  trailing: IconButton(
                    key: ValueKey('refuelList_delete_${refuel.id}'),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Excluir',
                    onPressed: () => _confirmDelete(context, refuel),
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
