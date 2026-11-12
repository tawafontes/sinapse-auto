import 'package:flutter/material.dart';

import '../../models/refuel_record.dart';
import '../../models/vehicle_profile.dart';
import '../../services/fuel_consumption.dart';
import '../../services/vehicle_repository.dart';
import 'vehicle_profile_screen.dart';

/// Registers (or corrects, given [editing]) one refuel — owner decisions of
/// 2026-11-11: the date comes filled in, the odometer is typed with a
/// suggestion (the last refuel's odometer plus the kilometres the app recorded
/// since), the litres and price per litre come from the pump and the total is
/// computed, the fuel starts at the vehicle's default, and "Completei o tanque"
/// marks the refuels the full-to-full consumption is measured between.
///
/// Needs the vehicle profile (the fuels it takes, the tank capacity); without
/// one it offers to create it instead.
class RefuelFormScreen extends StatefulWidget {
  const RefuelFormScreen({super.key, this.editing});

  final RefuelRecord? editing;

  @override
  State<RefuelFormScreen> createState() => _RefuelFormScreenState();
}

class _RefuelFormScreenState extends State<RefuelFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _odometer;
  late final TextEditingController _liters;
  late final TextEditingController _price;
  late DateTime _date;
  late bool _fullTank;
  FuelType? _fuel;
  double? _suggestion;
  double _appKmSinceLast = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    final profile = VehicleRepository.profile;
    _date = editing?.date ?? DateTime.now();
    _fullTank = editing?.fullTank ?? true;
    _fuel = editing?.fuel ?? profile?.defaultFuel;
    if (editing == null) {
      final refuels = RefuelRepository.chronological;
      final last = refuels.isEmpty ? null : refuels.last;
      if (last != null) _appKmSinceLast = appDistanceKmSince(last.date, RefuelRepository.sessions);
      _suggestion = suggestedOdometerKm(last, _appKmSinceLast);
    }
    _odometer = TextEditingController(text: editableNumber(editing?.odometerKm ?? _suggestion));
    _liters = TextEditingController(text: editableNumber(editing?.liters));
    _price = TextEditingController(text: editableNumber(editing?.pricePerLiter));
    _liters.addListener(_onAmountsChanged);
    _price.addListener(_onAmountsChanged);
  }

  @override
  void dispose() {
    _odometer.dispose();
    _liters.dispose();
    _price.dispose();
    super.dispose();
  }

  void _onAmountsChanged() => setState(() {});

  double? get _total {
    final liters = parseDecimal(_liters.text);
    final price = parseDecimal(_price.text);
    return liters == null || price == null ? null : liters * price;
  }

  Iterable<RefuelRecord> get _others => RefuelRepository.chronological.where((r) => r.id != widget.editing?.id);

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isAfter(now) ? now : _date,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    // Keeps the time of day, so two refuels on one day stay in order.
    setState(() => _date = DateTime(picked.year, picked.month, picked.day, _date.hour, _date.minute, _date.second));
  }

  String? _validateOdometer(String? text) {
    final value = parseDecimal(text ?? '', dotGroupsThousands: true);
    if (value == null) return 'Informe o hodômetro do painel, em km.';
    if (value < 0 || value > 3000000) return 'Valor de hodômetro inválido.';
    return odometerConflict(value, _date, _others);
  }

  String? _validateLiters(String? text) {
    final value = parseDecimal(text ?? '');
    if (value == null || value <= 0) return 'Informe quantos litros foram abastecidos.';
    final capacity = VehicleRepository.profile?.tankCapacityLiters;
    // A margin over the nominal capacity: tanks take a little more than the
    // manual says, and the filler neck holds some too.
    if (capacity != null && value > capacity * 1.2) {
      return 'Mais do que cabe no tanque (${formatLiters(capacity)}). Confira o valor.';
    }
    return null;
  }

  String? _validatePrice(String? text) {
    final value = parseDecimal(text ?? '');
    if (value == null || value <= 0) return 'Informe o preço por litro.';
    if (value > 50) return 'Preço por litro inválido.';
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final fuel = _fuel;
    if (fuel == null) return;
    setState(() => _saving = true);
    await RefuelRepository.save(RefuelRecord(
      id: widget.editing?.id ?? RefuelRepository.newId(),
      date: _date,
      odometerKm: parseDecimal(_odometer.text, dotGroupsThousands: true)!,
      liters: parseDecimal(_liters.text)!,
      pricePerLiter: parseDecimal(_price.text)!,
      fuel: fuel,
      fullTank: _fullTank,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.editing == null ? 'Abastecimento registrado.' : 'Abastecimento atualizado.')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final profile = VehicleRepository.profile;
    final title = widget.editing == null ? 'Registrar abastecimento' : 'Editar abastecimento';
    if (profile == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Antes do primeiro abastecimento, cadastre o tanque e o consumo de referência do seu veículo.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VehicleProfileScreen()));
                      if (!mounted) return;
                      setState(() => _fuel ??= VehicleRepository.profile?.defaultFuel);
                    },
                    icon: const Icon(Icons.directions_car_outlined),
                    label: const Text('Cadastrar meu veículo'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final fuels = profile.fuelSystem.fuels;
    // An old refuel may carry a fuel the profile no longer lists; keep it
    // selectable so editing never silently changes it.
    final offered = [...fuels, if (_fuel != null && !fuels.contains(_fuel)) _fuel!];
    final fuel = _fuel != null && offered.contains(_fuel) ? _fuel! : offered.first;
    _fuel = fuel;
    final total = _total;
    const numberKeyboard = TextInputType.numberWithOptions(decimal: true);
    final suggestion = _suggestion;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                key: const ValueKey('refuel_date'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(formatDate(_date)),
                subtitle: const Text('Data do abastecimento'),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _pickDate,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('refuel_odometer'),
                controller: _odometer,
                decoration: InputDecoration(
                  labelText: 'Hodômetro',
                  suffixText: 'km',
                  border: const OutlineInputBorder(),
                  helperMaxLines: 3,
                  helperText: suggestion == null
                      ? 'Digite o valor que aparece no painel do carro.'
                      : 'Sugestão: último abastecimento + ${formatKm(_appKmSinceLast)} registrados pelo app. '
                          'Confira no painel do carro.',
                ),
                keyboardType: TextInputType.number,
                validator: _validateOdometer,
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('refuel_liters'),
                      controller: _liters,
                      decoration: const InputDecoration(labelText: 'Litros', suffixText: 'L', border: OutlineInputBorder()),
                      keyboardType: numberKeyboard,
                      validator: _validateLiters,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('refuel_price'),
                      controller: _price,
                      decoration: const InputDecoration(labelText: 'Preço por litro', prefixText: 'R\$ ', border: OutlineInputBorder()),
                      keyboardType: numberKeyboard,
                      validator: _validatePrice,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  title: const Text('Total'),
                  subtitle: const Text('Calculado: litros × preço por litro'),
                  trailing: Text(
                    total == null ? '—' : formatMoney(total),
                    key: const ValueKey('refuel_total'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (offered.length > 1) ...[
                Text('Combustível', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<FuelType>(
                  key: const ValueKey('refuel_fuel'),
                  segments: [for (final f in offered) ButtonSegment(value: f, label: Text(fuelTypeLabels[f]!))],
                  selected: {fuel},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _fuel = s.single),
                ),
                const SizedBox(height: 8),
              ] else
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.local_gas_station_outlined),
                  title: Text(fuelTypeLabels[fuel]!),
                  subtitle: const Text('Combustível'),
                ),
              SwitchListTile(
                key: const ValueKey('refuel_fullTank'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Completei o tanque'),
                subtitle: const Text('O consumo é medido entre dois abastecimentos com o tanque cheio.'),
                value: _fullTank,
                onChanged: (v) => setState(() => _fullTank = v),
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('refuel_save'),
                onPressed: _saving ? null : _save,
                child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Salvar')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
