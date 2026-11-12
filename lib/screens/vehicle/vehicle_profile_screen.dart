import 'package:flutter/material.dart';

import '../../models/vehicle_profile.dart';
import '../../services/fuel_consumption.dart';
import '../../services/vehicle_repository.dart';

/// "Meu veículo" (owner decision, 2026-11-11): the minimal single-vehicle
/// profile — what the car burns, the tank capacity and the reference
/// consumption per fuel. No make/model/year.
class VehicleProfileScreen extends StatefulWidget {
  const VehicleProfileScreen({super.key});

  @override
  State<VehicleProfileScreen> createState() => _VehicleProfileScreenState();
}

/// A number for a form field, as typed back: "50", "47,5", "6,299" (up to three
/// decimals — pump prices have three — and no trailing zeros).
String editableNumber(double? value) {
  if (value == null) return '';
  return value == value.roundToDouble() ? value.toStringAsFixed(0) : formatDecimal(value, decimals: 3).replaceAll(RegExp(r'0+$'), '');
}

class _VehicleProfileScreenState extends State<VehicleProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nickname;
  late final TextEditingController _tank;
  late final Map<FuelType, TextEditingController> _reference;
  late VehicleFuelSystem _fuelSystem;
  late FuelType _defaultFuel;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final profile = VehicleRepository.profile;
    _nickname = TextEditingController(text: profile?.nickname ?? '');
    _tank = TextEditingController(text: editableNumber(profile?.tankCapacityLiters));
    _reference = {
      for (final fuel in FuelType.values) fuel: TextEditingController(text: editableNumber(profile?.referenceKmPerLiter(fuel))),
    };
    _fuelSystem = profile?.fuelSystem ?? VehicleFuelSystem.flex;
    _defaultFuel = profile?.defaultFuel ?? _fuelSystem.fuels.first;
  }

  @override
  void dispose() {
    _nickname.dispose();
    _tank.dispose();
    for (final c in _reference.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _setFuelSystem(VehicleFuelSystem system) {
    setState(() {
      _fuelSystem = system;
      if (!system.fuels.contains(_defaultFuel)) _defaultFuel = system.fuels.first;
    });
  }

  String? _validateTank(String? text) {
    final value = parseDecimal(text ?? '');
    if (value == null) return 'Informe a capacidade do tanque em litros.';
    if (value < 5 || value > 300) return 'Use um valor entre 5 e 300 litros.';
    return null;
  }

  String? _validateReference(String? text) {
    final value = parseDecimal(text ?? '');
    if (value == null) return 'Informe o consumo em km/L.';
    if (value < 1 || value > 60) return 'Use um valor entre 1 e 60 km/L.';
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    double? reference(FuelType fuel) => _fuelSystem.fuels.contains(fuel) ? parseDecimal(_reference[fuel]!.text) : null;
    final nickname = _nickname.text.trim();
    await VehicleRepository.save(VehicleProfile(
      nickname: nickname.isEmpty ? null : nickname,
      fuelSystem: _fuelSystem,
      tankCapacityLiters: parseDecimal(_tank.text)!,
      kmPerLiterGasoline: reference(FuelType.gasoline),
      kmPerLiterEthanol: reference(FuelType.ethanol),
      kmPerLiterDiesel: reference(FuelType.diesel),
      defaultFuel: _defaultFuel,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Veículo salvo.')));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const numberKeyboard = TextInputType.numberWithOptions(decimal: true);
    return Scaffold(
      appBar: AppBar(title: const Text('Meu veículo')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                key: const ValueKey('vehicle_nickname'),
                controller: _nickname,
                decoration: const InputDecoration(labelText: 'Apelido (opcional)', hintText: 'Meu carro', border: OutlineInputBorder()),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 20),
              Text('Combustível do veículo', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<VehicleFuelSystem>(
                key: const ValueKey('vehicle_fuelSystem'),
                segments: [
                  for (final system in VehicleFuelSystem.values)
                    ButtonSegment(value: system, label: Text(vehicleFuelSystemLabels[system]!)),
                ],
                selected: {_fuelSystem},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _setFuelSystem(s.single),
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: const ValueKey('vehicle_tank'),
                controller: _tank,
                decoration: const InputDecoration(labelText: 'Capacidade do tanque', suffixText: 'L', border: OutlineInputBorder()),
                keyboardType: numberKeyboard,
                validator: _validateTank,
              ),
              const SizedBox(height: 20),
              Text('Consumo de referência', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Está na etiqueta do INMETRO ou no manual do veículo. Use a média entre cidade e estrada. '
                'O app compara com o consumo que você medir nos abastecimentos e usa este valor para estimar a '
                'autonomia até ter as suas próprias medições.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final fuel in _fuelSystem.fuels) ...[
                TextFormField(
                  key: ValueKey('vehicle_reference_${fuel.name}'),
                  controller: _reference[fuel],
                  decoration: InputDecoration(
                    labelText: 'Com ${fuelTypeLabels[fuel]!.toLowerCase()}',
                    suffixText: 'km/L',
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: numberKeyboard,
                  validator: _validateReference,
                ),
                const SizedBox(height: 12),
              ],
              if (_fuelSystem == VehicleFuelSystem.flex) ...[
                const SizedBox(height: 8),
                Text('Combustível padrão', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'O abastecimento já começa com este combustível. Se você registrar outro, ele passa a ser o padrão.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SegmentedButton<FuelType>(
                  key: const ValueKey('vehicle_defaultFuel'),
                  segments: [
                    for (final fuel in _fuelSystem.fuels) ButtonSegment(value: fuel, label: Text(fuelTypeLabels[fuel]!)),
                  ],
                  selected: {_defaultFuel},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _defaultFuel = s.single),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('vehicle_save'),
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
