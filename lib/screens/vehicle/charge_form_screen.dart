import 'package:flutter/material.dart';

import '../../models/charge_record.dart';
import '../../models/refuel_record.dart';
import '../../services/fuel_consumption.dart';
import '../../services/hybrid_consumption.dart';
import '../../services/vehicle_repository.dart';
import 'refuel_form_screen.dart';
import 'vehicle_profile_screen.dart';

/// "Abastecer | Recarregar" at the top of the register form of a plug-in hybrid
/// (owner decision, 2026-11-12): switches between the refuel and the recharge
/// form in place (no transition), so the one "Abastecer" button of the
/// dashboard widget serves both.
class EnergyKindToggle extends StatelessWidget {
  const EnergyKindToggle({super.key, required this.charging});

  final bool charging;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      key: const ValueKey('energyKind'),
      segments: const [
        ButtonSegment(value: false, label: Text('Abastecer'), icon: Icon(Icons.local_gas_station_outlined)),
        ButtonSegment(value: true, label: Text('Recarregar'), icon: Icon(Icons.ev_station_outlined)),
      ],
      selected: {charging},
      onSelectionChanged: (s) {
        if (s.single == charging) return;
        Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => s.single ? const ChargeFormScreen() : const RefuelFormScreen(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ));
      },
    );
  }
}

/// Registers (or corrects, given [editing]) one recharge of a plug-in hybrid —
/// see [ChargeRecord] for what each field is for.
class ChargeFormScreen extends StatefulWidget {
  const ChargeFormScreen({super.key, this.editing});

  final ChargeRecord? editing;

  @override
  State<ChargeFormScreen> createState() => _ChargeFormScreenState();
}

class _ChargeFormScreenState extends State<ChargeFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _odometer;
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _kwh;
  late final TextEditingController _price;
  late final TextEditingController _range;
  late DateTime _date;
  late bool _usedFuel;
  double? _suggestion;
  double _appKmSinceLast = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    _date = editing?.date ?? DateTime.now();
    _usedFuel = editing?.usedFuelSinceLast ?? false;
    if (editing == null) {
      final last = latestRecord(allVehicleRecords());
      if (last != null) _appKmSinceLast = appDistanceKmSince(last.date, RefuelRepository.sessions);
      _suggestion = suggestedOdometerKm(last, _appKmSinceLast);
    }
    _odometer = TextEditingController(text: editableNumber(editing?.odometerKm ?? _suggestion));
    _start = TextEditingController(text: editableNumber(editing?.startPercent));
    _end = TextEditingController(text: editableNumber(editing?.endPercent ?? (editing == null ? 100 : null)));
    _kwh = TextEditingController(text: editableNumber(editing?.chargerKwh));
    _price = TextEditingController(
      text: editableNumber(editing?.pricePerKwh ?? VehicleRepository.profile?.defaultPricePerKwh ?? _lastPricePerKwh()),
    );
    _range = TextEditingController(text: editableNumber(editing?.panelFuelRangeKm));
    for (final c in [_start, _end, _kwh, _price]) {
      c.addListener(() => setState(() {}));
    }
  }

  /// Without a default price in Meu veículo, the price of the last recharge.
  static double? _lastPricePerKwh() {
    final charges = ChargeRepository.chronological;
    return charges.isEmpty ? null : charges.last.pricePerKwh;
  }

  @override
  void dispose() {
    for (final c in [_odometer, _start, _end, _kwh, _price, _range]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The capacity in use (typed, or learned from the recharges with the
  /// switch on) — what a % span is converted with.
  double? get _capacity {
    final profile = VehicleRepository.profile;
    if (profile == null) return null;
    final others = ChargeRepository.chronological.where((c) => c.id != widget.editing?.id);
    return HybridSummary.of(profile: profile, refuels: RefuelRepository.chronological, charges: others).capacityKwh;
  }

  /// The energy the cost is computed from, and whether it is the charger's
  /// (exact) or estimated from the % span with the loss margin.
  ({double kwh, bool measured})? get _wallEnergy {
    final kwh = _kwh.text.trim().isEmpty ? null : parseDecimal(_kwh.text);
    if (kwh != null) return (kwh: kwh, measured: true);
    final start = parseDecimal(_start.text);
    final end = parseDecimal(_end.text);
    final capacity = _capacity;
    if (start == null || end == null || capacity == null || end <= start) return null;
    return (kwh: wallKwhFromPercent(startPercent: start, endPercent: end, capacityKwh: capacity), measured: false);
  }

  Iterable<OdometerRecord> get _others => allVehicleRecords().where((r) => r.id != widget.editing?.id);

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isAfter(now) ? now : _date,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    setState(() => _date = DateTime(picked.year, picked.month, picked.day, _date.hour, _date.minute, _date.second));
  }

  String? _validateOdometer(String? text) {
    final value = parseDecimal(text ?? '', dotGroupsThousands: true);
    if (value == null) return 'Informe o hodômetro do painel, em km.';
    if (value < 0 || value > 3000000) return 'Valor de hodômetro inválido.';
    return odometerConflict(value, _date, _others);
  }

  String? _validatePercent(String? text) {
    final value = parseDecimal(text ?? '');
    if (value == null || value < 0 || value > 100) return 'Informe um % entre 0 e 100.';
    return null;
  }

  String? _validateEnd(String? text) {
    final error = _validatePercent(text);
    if (error != null) return error;
    final start = parseDecimal(_start.text);
    if (start != null && parseDecimal(text!)! <= start) return 'Precisa ser maior que o % inicial.';
    return null;
  }

  String? _validateKwh(String? text) {
    if ((text ?? '').trim().isEmpty) return null;
    final value = parseDecimal(text!);
    if (value == null || value <= 0 || value > 300) return 'kWh inválido.';
    return null;
  }

  String? _validatePrice(String? text) {
    final value = parseDecimal(text ?? '');
    if (value == null || value < 0) return 'Informe o preço do kWh (0 se foi gratuita).';
    if (value > 20) return 'Preço do kWh inválido.';
    return null;
  }

  String? _validateRange(String? text) {
    final value = parseDecimal(text ?? '', dotGroupsThousands: true);
    if (value == null) return 'Informe a autonomia a combustão que o painel mostra agora.';
    if (value < 0 || value > 3000) return 'Autonomia inválida.';
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final energy = _wallEnergy;
    if (energy == null) return;
    setState(() => _saving = true);
    final kwhText = _kwh.text.trim();
    await ChargeRepository.save(ChargeRecord(
      id: widget.editing?.id ?? ChargeRepository.newId(),
      date: _date,
      odometerKm: parseDecimal(_odometer.text, dotGroupsThousands: true)!,
      startPercent: parseDecimal(_start.text)!,
      endPercent: parseDecimal(_end.text)!,
      chargerKwh: kwhText.isEmpty ? null : parseDecimal(kwhText),
      pricePerKwh: parseDecimal(_price.text)!,
      wallKwh: energy.kwh,
      usedFuelSinceLast: _usedFuel,
      panelFuelRangeKm: _usedFuel ? parseDecimal(_range.text, dotGroupsThousands: true) : null,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.editing == null ? 'Recarga registrada.' : 'Recarga atualizada.')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final profile = VehicleRepository.profile;
    final title = widget.editing == null ? 'Registrar recarga' : 'Editar recarga';
    if (profile == null || !profile.isPlugIn) {
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
                    'Recargas são para híbridos plug-in. Em Meu veículo, escolha "Plug-in" e informe a bateria.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VehicleProfileScreen()));
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.directions_car_outlined),
                    label: const Text('Meu veículo'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    const numberKeyboard = TextInputType.numberWithOptions(decimal: true);
    final energy = _wallEnergy;
    final price = parseDecimal(_price.text);
    final total = energy == null || price == null ? null : energy.kwh * price;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.editing == null) ...[
                const EnergyKindToggle(charging: true),
                const SizedBox(height: 12),
              ],
              ListTile(
                key: const ValueKey('charge_date'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(formatDate(_date)),
                subtitle: const Text('Data da recarga'),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _pickDate,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('charge_odometer'),
                controller: _odometer,
                decoration: InputDecoration(
                  labelText: 'Hodômetro',
                  suffixText: 'km',
                  border: const OutlineInputBorder(),
                  helperMaxLines: 3,
                  helperText: _suggestion == null
                      ? 'Digite o valor que aparece no painel do carro.'
                      : 'Sugestão: último registro + ${formatKm(_appKmSinceLast)} registrados pelo app. '
                          'Confira no painel do carro.',
                ),
                keyboardType: TextInputType.number,
                validator: _validateOdometer,
              ),
              const SizedBox(height: 16),
              Text('Bateria no painel', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('charge_start'),
                      controller: _start,
                      decoration: const InputDecoration(labelText: 'Ao começar', suffixText: '%', border: OutlineInputBorder()),
                      keyboardType: numberKeyboard,
                      validator: _validatePercent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('charge_end'),
                      controller: _end,
                      decoration: const InputDecoration(labelText: 'Ao terminar', suffixText: '%', border: OutlineInputBorder()),
                      keyboardType: numberKeyboard,
                      validator: _validateEnd,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('charge_kwh'),
                      controller: _kwh,
                      decoration: const InputDecoration(
                        labelText: 'kWh do carregador',
                        helperText: 'Opcional',
                        suffixText: 'kWh',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: numberKeyboard,
                      validator: _validateKwh,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('charge_price'),
                      controller: _price,
                      decoration: const InputDecoration(labelText: 'Preço do kWh', prefixText: 'R\$ ', border: OutlineInputBorder()),
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
                  subtitle: Text(
                    energy == null
                        ? 'Calculado com a energia e o preço do kWh'
                        : energy.measured
                            ? '${formatKwh(energy.kwh)} do carregador'
                            : '${formatKwh(energy.kwh)} estimados pelo %, com 10% de perdas da recarga',
                    key: const ValueKey('charge_energy'),
                  ),
                  trailing: Text(
                    total == null ? '—' : formatMoney(total),
                    key: const ValueKey('charge_total'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const ValueKey('charge_usedFuel'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Usou combustível desde o último registro?'),
                subtitle: const Text('Se a bateria acabou no caminho ou o motor ligou para recarregá-la.'),
                value: _usedFuel,
                onChanged: (v) => setState(() => _usedFuel = v),
              ),
              if (_usedFuel)
                TextFormField(
                  key: const ValueKey('charge_range'),
                  controller: _range,
                  decoration: const InputDecoration(
                    labelText: 'Autonomia a combustão no painel agora',
                    helperText: 'Leia com o carro parado em local plano.',
                    suffixText: 'km',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  validator: _validateRange,
                ),
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('charge_save'),
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
