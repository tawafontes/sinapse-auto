import 'package:flutter/material.dart';

import '../../models/vehicle_profile.dart';
import '../../services/fuel_consumption.dart';
import '../../services/hybrid_consumption.dart';
import '../../services/vehicle_repository.dart';

/// "Consumo entre abastecimentos": the consumption measured by the
/// full-to-full method over the refuel log — the averages per fuel against the
/// profile's reference, cost per km, the ethanol/gasoline break-even from the
/// user's own figures (flex cars), spending per month and every interval.
class ConsumptionReportScreen extends StatefulWidget {
  const ConsumptionReportScreen({super.key});

  @override
  State<ConsumptionReportScreen> createState() => _ConsumptionReportScreenState();
}

class _ConsumptionReportScreenState extends State<ConsumptionReportScreen> {
  late final Listenable _changes = Listenable.merge([
    RefuelRepository.listenable(),
    ChargeRepository.listenable(),
    VehicleRepository.listenable(),
  ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Consumo')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _changes,
          builder: (context, _) {
            final profile = VehicleRepository.profile;
            final summary = ConsumptionSummary.of(RefuelRepository.chronological);
            if (profile != null && profile.isPlugIn) {
              return _HybridReport(
                summary: summary,
                hybrid: HybridSummary.of(profile: profile, refuels: summary.refuels, charges: ChargeRepository.chronological),
              );
            }
            return _ConsumptionReport(summary: summary, profile: profile);
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
    final reference = summary.referenceKmPerLiter(fuel, profile);
    final referenceLabel = summary.referenceIsMeasured(fuel, profile) ? 'Referência (suas últimas medições)' : 'Referência';
    final label = 'Com ${fuelTypeLabels[fuel]!.toLowerCase()}';
    if (measured == null) {
      return _Row(
        label: label,
        value: 'sem medição',
        detail: reference == null ? null : '$referenceLabel: ${formatKmPerLiter(reference)}',
      );
    }
    String? detail;
    if (reference != null && reference > 0) {
      final diff = (measured / reference - 1) * 100;
      final comparison = diff.abs() < 0.5
          ? 'igual à referência'
          : '${formatDecimal(diff.abs(), decimals: 0)}% ${diff > 0 ? 'acima' : 'abaixo'} da referência';
      detail = '$referenceLabel: ${formatKmPerLiter(reference)} · $comparison';
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

/// The report of a plug-in hybrid (owner decisions, 2026-11-12): what it
/// really costs per km — fuel and energy together, exact — then the electric
/// and the combustion side, with the kilometres split by the panel's fuel
/// range (estimated), and the spending.
class _HybridReport extends StatelessWidget {
  const _HybridReport({required this.summary, required this.hybrid});

  final ConsumptionSummary summary;
  final HybridSummary hybrid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = hybrid.profile;
    final costPerKm = hybrid.combinedCostPerKm;
    final share = hybrid.electricShare;
    final measuredKmPerKwh = hybrid.measuredKmPerKwh;
    final kmPerKwhReference = hybrid.kmPerKwhReference;
    final capacity = hybrid.capacityKwh;
    final learnedCapacity = profile.autoUpdateReferences && hybrid.learnedCapacityKwh != null;
    final referenceLearned = profile.autoUpdateReferences && hybrid.electricMeasurements.isNotEmpty;
    final monthly = <DateTime, ({double fuel, double energy})>{};
    for (final r in hybrid.refuels) {
      final m = DateTime(r.date.year, r.date.month);
      final p = monthly[m] ?? (fuel: 0.0, energy: 0.0);
      monthly[m] = (fuel: p.fuel + r.totalPrice, energy: p.energy);
    }
    for (final c in hybrid.charges) {
      final m = DateTime(c.date.year, c.date.month);
      final p = monthly[m] ?? (fuel: 0.0, energy: 0.0);
      monthly[m] = (fuel: p.fuel, energy: p.energy + c.totalPrice);
    }
    final months = monthly.keys.toList()..sort((a, b) => b.compareTo(a));

    if (hybrid.timeline.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: const [
        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Ainda não há registros. Registre cada recarga e cada abastecimento em "Abastecimentos e recargas"; '
              'o custo real por km aparece a partir do segundo registro.',
            ),
          ),
        ),
      ]);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(title: 'Custo real', children: [
          if (costPerKm != null)
            _Row(
              label: 'Custo por km (combustível + energia)',
              value: formatMoney(costPerKm),
              valueKey: const ValueKey('report_hybrid_costPerKm'),
            ),
          _Row(label: 'Distância registrada', value: formatKm(hybrid.spanKm)),
          if (share != null)
            _Row(
              label: 'Feitos no elétrico',
              value: formatPercent(share * 100),
              detail: 'Estimado: o resto é a queda da autonomia a combustão do painel.',
              valueKey: const ValueKey('report_hybrid_share'),
            ),
        ]),
        _Section(title: 'Elétrico', children: [
          _Row(
            label: 'Consumo medido',
            value: measuredKmPerKwh == null ? 'sem medição' : formatKmPerKwh(measuredKmPerKwh),
            detail: measuredKmPerKwh == null
                ? 'Medido entre recargas sem uso de combustível; recargas curtas se somam.'
                : '${formatDecimal(100 / measuredKmPerKwh)} kWh a cada 100 km',
            valueKey: const ValueKey('report_hybrid_kmPerKwh'),
          ),
          if (kmPerKwhReference != null)
            _Row(
              label: referenceLearned ? 'Referência (suas últimas medições)' : 'Referência',
              value: formatKmPerKwh(kmPerKwhReference),
            ),
          if (capacity != null)
            _Row(
              label: 'Bateria em uso',
              value: formatKwh(capacity),
              detail: learnedCapacity ? 'Ajustada pelas recargas com o kWh do carregador.' : 'O valor de Meu veículo.',
            ),
          _Row(label: 'Energia recarregada', value: '${formatKwh(hybrid.wallKwh)} · ${formatMoney(hybrid.energySpent)}'),
        ]),
        _Section(title: 'Combustão', children: [
          _Row(
            label: 'km a combustão',
            value: formatKm(hybrid.fuelKm),
            detail: 'Estimado pela queda da autonomia do painel.',
            valueKey: const ValueKey('report_hybrid_fuelKm'),
          ),
          for (final fuel in profile.fuelSystem.fuels) _engineRow(fuel),
          _Row(label: 'Combustível', value: '${formatLiters(hybrid.liters)} · ${formatMoney(hybrid.fuelSpent)}'),
        ]),
        if (months.isNotEmpty)
          _Section(title: 'Gastos por mês', children: [
            for (final m in months)
              _Row(
                label: _ConsumptionReport._capitalize(formatMonth(m)),
                value: formatMoney(monthly[m]!.fuel + monthly[m]!.energy),
                detail: 'Combustível ${formatMoney(monthly[m]!.fuel)} · energia ${formatMoney(monthly[m]!.energy)}',
              ),
          ]),
        Text(
          'Com o adaptador OBD-II (fase 2), o app passa a medir os km elétricos e a combustão direto do motor.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _engineRow(FuelType fuel) {
    final measured = hybrid.engineKmPerLiter(fuel);
    final reference = hybrid.engineKmPerLiterReference(fuel);
    return _Row(
      label: 'Motor com ${fuelTypeLabels[fuel]!.toLowerCase()}',
      value: measured == null ? 'sem medição' : '${formatKmPerLiter(measured)} (estimado)',
      detail: reference == null ? null : 'Referência: ${formatKmPerLiter(reference)}',
    );
  }
}
