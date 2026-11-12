import 'package:flutter/material.dart';

import '../../models/vehicle_profile.dart';
import '../../services/fuel_consumption.dart';
import '../../services/vehicle_repository.dart';

/// "Consumo entre abastecimentos": the consumption measured by the
/// full-to-full method over the refuel log — the averages per fuel against the
/// profile's reference, cost per km, the ethanol/gasoline break-even from the
/// user's own figures (flex cars), spending per month and every interval.
class ConsumptionReportScreen extends StatelessWidget {
  const ConsumptionReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Consumo')),
      body: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: RefuelRepository.listenable(),
          builder: (context, _, _) {
            final summary = ConsumptionSummary.of(RefuelRepository.chronological);
            return _ConsumptionReport(summary: summary, profile: VehicleRepository.profile);
          },
        ),
      ),
    );
  }
}

class _ConsumptionReport extends StatelessWidget {
  const _ConsumptionReport({required this.summary, required this.profile});

  final ConsumptionSummary summary;
  final VehicleProfile? profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = this.profile;
    final fuels = <FuelType>{
      ...?profile?.fuelSystem.fuels,
      for (final i in summary.intervals)
        if (i.fuel != null) i.fuel!,
    };
    final breakEven = ethanolBreakEven(summary, profile);
    final costPerKm = summary.costPerKm;
    final overall = summary.averageKmPerLiter();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (summary.intervals.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                summary.refuels.isEmpty
                    ? 'Ainda não há abastecimentos. Registre cada abastecimento em "Abastecimentos"; com dois de '
                        'tanque cheio, o consumo real aparece aqui.'
                    : 'O consumo é medido entre dois abastecimentos com o tanque cheio. Registre o próximo '
                        'abastecimento completando o tanque para ver o primeiro resultado.',
              ),
            ),
          )
        else ...[
          _Section(title: 'Consumo medido', children: [
            if (overall != null)
              _Row(label: 'Média geral', value: formatKmPerLiter(overall), valueKey: const ValueKey('report_overall')),
            for (final fuel in fuels) _fuelRow(context, fuel),
            if (costPerKm != null) _Row(label: 'Custo por km', value: formatMoney(costPerKm)),
          ]),
          if (breakEven != null) _breakEvenSection(context, breakEven),
        ],
        if (summary.refuels.isNotEmpty) ...[
          _Section(title: 'Gastos', children: [
            _Row(label: 'Total gasto', value: formatMoney(summary.totalSpent)),
            _Row(label: 'Total abastecido', value: formatLiters(summary.totalLiters)),
            for (final month in summary.monthly)
              _Row(label: _capitalize(formatMonth(month.month)), value: '${formatMoney(month.spent)} · ${formatLiters(month.liters)}'),
          ]),
        ],
        if (summary.intervals.isNotEmpty)
          _Section(title: 'Entre abastecimentos', children: [
            for (final interval in summary.intervals.reversed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${formatDate(interval.from.date)} → ${formatDate(interval.to.date)}'),
                subtitle: Text(
                  '${formatKm(interval.distanceKm)} · ${formatLiters(interval.liters)} · '
                  '${interval.fuel == null ? 'Misto' : fuelTypeLabels[interval.fuel]} · '
                  '${formatMoney(interval.costPerKm)}/km',
                ),
                trailing: Text(formatKmPerLiter(interval.kmPerLiter), style: theme.textTheme.titleMedium),
              ),
          ]),
      ],
    );
  }

  Widget _fuelRow(BuildContext context, FuelType fuel) {
    final measured = summary.averageKmPerLiter(fuel);
    final reference = profile?.referenceKmPerLiter(fuel);
    final label = 'Com ${fuelTypeLabels[fuel]!.toLowerCase()}';
    if (measured == null) {
      return _Row(
        label: label,
        value: 'sem medição',
        detail: reference == null ? null : 'Referência: ${formatKmPerLiter(reference)}',
      );
    }
    String? detail;
    if (reference != null && reference > 0) {
      final diff = (measured / reference - 1) * 100;
      final comparison = diff.abs() < 0.5
          ? 'igual à referência'
          : '${formatDecimal(diff.abs(), decimals: 0)}% ${diff > 0 ? 'acima' : 'abaixo'} da referência';
      detail = 'Referência: ${formatKmPerLiter(reference)} · $comparison';
    }
    return _Row(label: label, value: formatKmPerLiter(measured), detail: detail, valueKey: ValueKey('report_fuel_${fuel.name}'));
  }

  Widget _breakEvenSection(BuildContext context, EthanolBreakEven breakEven) {
    final percent = formatDecimal(breakEven.ratio * 100, decimals: 0);
    final ethanolPrice = summary.lastPricePerLiter(FuelType.ethanol);
    final gasolinePrice = summary.lastPricePerLiter(FuelType.gasoline);
    String? verdict;
    if (ethanolPrice != null && gasolinePrice != null && gasolinePrice > 0) {
      final ratio = ethanolPrice / gasolinePrice;
      verdict = 'Últimos preços: etanol ${formatPricePerLiter(ethanolPrice)} e gasolina '
          '${formatPricePerLiter(gasolinePrice)} (${formatDecimal(ratio * 100, decimals: 0)}%) — '
          '${ratio <= breakEven.ratio ? 'o etanol compensa.' : 'a gasolina compensa.'}';
    }
    return _Section(title: 'Etanol ou gasolina?', children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'No seu carro, o etanol compensa enquanto custar até $percent% do preço da gasolina '
          '(${breakEven.measured ? 'pelo consumo que você mediu' : 'pelo consumo de referência — vale o medido quando houver abastecimentos com cada um'}).',
          key: const ValueKey('report_breakEven'),
        ),
      ),
      if (verdict != null) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(verdict)),
    ]);
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.detail, this.valueKey});

  final String label;
  final String value;
  final String? detail;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(value, key: valueKey, style: theme.textTheme.titleSmall),
            ],
          ),
          if (detail != null) Text(detail!, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
