import 'package:flutter/material.dart';

import '../../models/vehicle_profile.dart';
import '../../screens/vehicle/refuel_form_screen.dart';
import '../../screens/vehicle/vehicle_profile_screen.dart';
import '../../services/fuel_consumption.dart';
import '../../services/vehicle_repository.dart';

/// The dashboard's refuel widget (owner decision, 2026-11-11: the shortcut to
/// register a refuel lives on the dashboard, added through "+"). Shows the
/// estimated range and tank level, the last measured consumption and the
/// kilometres recorded since the last refuel, with a button that opens the
/// refuel form.
///
/// Fed by the refuel log, the vehicle profile and the driving sessions' recorded
/// distances in Hive — not by the telemetry pipeline: none of it is a live
/// sensor value, so this is not a second telemetry consumer (CLAUDE.md §4).
class RefuelSummaryWidget extends StatefulWidget {
  const RefuelSummaryWidget({super.key});

  @override
  State<RefuelSummaryWidget> createState() => _RefuelSummaryWidgetState();
}

class _RefuelSummaryWidgetState extends State<RefuelSummaryWidget> {
  // Created once: each `Box.listenable()` call is a new listenable, so creating
  // them in build would resubscribe on every rebuild.
  late final Listenable _changes = Listenable.merge([
    VehicleRepository.listenable(),
    RefuelRepository.listenable(),
    RefuelRepository.sessionsListenable(),
  ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) {
        final profile = VehicleRepository.profile;
        final refuels = RefuelRepository.chronological;
        return RefuelSummaryView(
          profile: profile,
          hasRefuels: refuels.isNotEmpty,
          overview: RefuelOverview.compute(profile: profile, refuels: refuels, sessions: RefuelRepository.sessions),
          onRegister: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RefuelFormScreen())),
          onSetUpVehicle: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VehicleProfileScreen())),
        );
      },
    );
  }
}

/// What [RefuelSummaryWidget] draws, from plain values — also the onboarding
/// style preview's mock ([RefuelSummaryView.preview]).
class RefuelSummaryView extends StatelessWidget {
  const RefuelSummaryView({
    super.key,
    required this.profile,
    required this.hasRefuels,
    required this.overview,
    this.onRegister,
    this.onSetUpVehicle,
  });

  /// A mocked widget for the style picker — never real data.
  factory RefuelSummaryView.preview() => RefuelSummaryView(
        profile: VehicleProfile(
          fuelSystem: VehicleFuelSystem.flex,
          tankCapacityLiters: 50,
          kmPerLiterGasoline: 12,
          kmPerLiterEthanol: 8.4,
          defaultFuel: FuelType.gasoline,
        ),
        hasRefuels: true,
        overview: const RefuelOverview(
          lastRefuel: null,
          lastInterval: null,
          kmSinceLastRefuel: 184,
          estimatedLiters: 34.6,
          rangeKm: 415,
        ),
      );

  final VehicleProfile? profile;
  final bool hasRefuels;
  final RefuelOverview overview;
  final VoidCallback? onRegister;
  final VoidCallback? onSetUpVehicle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = this.profile;
    final Widget body;
    if (profile == null) {
      body = _message(
        context,
        text: 'Cadastre seu veículo para registrar abastecimentos',
        button: FilledButton.tonalIcon(
          key: const ValueKey('refuelWidget_setUpVehicle'),
          onPressed: onSetUpVehicle,
          icon: const Icon(Icons.directions_car_outlined),
          label: const Text('Meu veículo'),
        ),
      );
    } else if (!hasRefuels) {
      body = _message(context, text: 'Nenhum abastecimento registrado', button: _registerButton());
    } else {
      final liters = overview.estimatedLiters;
      final range = overview.rangeKm;
      final lastKmPerLiter = overview.lastInterval?.kmPerLiter;
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Autonomia estimada', style: theme.textTheme.labelMedium),
          Text(
            range == null ? '—' : '~${formatKm(range)}',
            key: const ValueKey('refuelWidget_range'),
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (liters != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: 160,
              child: LinearProgressIndicator(
                value: (liters / profile.tankCapacityLiters).clamp(0.0, 1.0),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 2),
            Text('${formatLiters(liters)} no tanque', style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 4),
          Text(
            [
              if (lastKmPerLiter != null) formatKmPerLiter(lastKmPerLiter),
              '${formatKm(overview.kmSinceLastRefuel)} desde o abastecimento',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          _registerButton(),
        ],
      );
    }
    // Scaled down, never clipped, on a small tile; natural size on a large
    // one or in fullscreen.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FittedBox(fit: BoxFit.scaleDown, child: body),
      ),
    );
  }

  Widget _registerButton() => FilledButton.tonalIcon(
        key: const ValueKey('refuelWidget_register'),
        onPressed: onRegister,
        icon: const Icon(Icons.local_gas_station),
        label: const Text('Abastecer'),
      );

  Widget _message(BuildContext context, {required String text, required Widget button}) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 180,
            child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(height: 8),
          button,
        ],
      );
}
