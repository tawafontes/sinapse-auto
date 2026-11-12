import 'package:flutter/material.dart';

import '../../models/vehicle_profile.dart';
import '../../services/vehicle_repository.dart';
import 'consumption_report_screen.dart';
import 'refuel_list_screen.dart';
import 'vehicle_profile_screen.dart';

/// The vehicle/OBD-II menu (owner decision, 2026-11-11: "Relatórios" lives in
/// a menu of its own, with Meu veículo and Abastecimentos). The OBD-II adapter
/// connection joins it once phase 0 has run on the real car.
class VehicleMenuScreen extends StatelessWidget {
  const VehicleMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Veículo')),
      body: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: VehicleRepository.listenable(),
          builder: (context, _, _) {
            final profile = VehicleRepository.profile;
            return ListView(
              children: [
                ListTile(
                  key: const ValueKey('vehicleMenu_profile'),
                  leading: const Icon(Icons.directions_car_outlined),
                  title: const Text('Meu veículo'),
                  subtitle: Text(
                    profile == null
                        ? 'Cadastre o tanque e o consumo de referência'
                        : '${profile.displayName} · ${vehicleFuelSystemLabels[profile.fuelSystem]} · '
                            '${editableNumber(profile.tankCapacityLiters)} L',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VehicleProfileScreen())),
                ),
                ListTile(
                  key: const ValueKey('vehicleMenu_refuels'),
                  leading: const Icon(Icons.local_gas_station_outlined),
                  title: const Text('Abastecimentos'),
                  subtitle: const Text('Registrar e corrigir abastecimentos'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RefuelListScreen())),
                ),
                ListTile(
                  key: const ValueKey('vehicleMenu_reports'),
                  leading: const Icon(Icons.assessment_outlined),
                  title: const Text('Relatórios'),
                  subtitle: const Text('Consumo entre abastecimentos e gastos'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReportsMenuScreen())),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// "Relatórios". Only consumption for now; the trip, diagnostic and engine
/// health reports come with the OBD-II phases.
class ReportsMenuScreen extends StatelessWidget {
  const ReportsMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Relatórios')),
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              key: const ValueKey('reportsMenu_consumption'),
              leading: const Icon(Icons.local_gas_station_outlined),
              title: const Text('Consumo'),
              subtitle: const Text('km/L entre abastecimentos, custo por km, gastos por mês'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConsumptionReportScreen())),
            ),
          ],
        ),
      ),
    );
  }
}
