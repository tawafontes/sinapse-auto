import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/obd/obd_bridge.dart';
import '../../services/obd/obd_phase0_runner.dart';

/// "Teste do adaptador OBD-II" — the phase 0 tool (2026-11-12), reached from
/// Diagnóstico. Not part of the product: it connects to the paired adapter,
/// runs the phase 0 sequence ([ObdPhase0Runner]) and writes the transcript to
/// `obd_phase0/` in the app's documents, to be pulled over USB and analysed.
/// Nothing here touches the dashboard, the telemetry pipeline or Hive.
class ObdPhase0Screen extends StatefulWidget {
  const ObdPhase0Screen({super.key, this.bridge = const MethodChannelObdBridge(), this.directory});

  final ObdBridge bridge;

  /// Where the transcript goes; the app's documents when null (tests pass a
  /// temporary one).
  final Directory? directory;

  @override
  State<ObdPhase0Screen> createState() => _ObdPhase0ScreenState();
}

class _ObdPhase0ScreenState extends State<ObdPhase0Screen> {
  late final ObdPhase0Runner _runner = ObdPhase0Runner(widget.bridge, write: _write);
  final List<String> _lines = [];
  final Map<String, String> _live = {};
  List<PairedDevice> _devices = const [];
  PairedDevice? _selected;
  File? _file;
  String? _problem;
  bool _connected = false;
  bool _busy = false;
  bool _stopLive = false;

  static const _notes = ['ignição desligada', 'ignição ligada (motor desligado)', 'motor ligado, parado', 'carro andando', 'modo EV', 'motor a combustão ligou'];

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _stopLive = true;
    if (_connected) widget.bridge.disconnect().catchError((_) {});
    super.dispose();
  }

  Future<void> _prepare() async {
    if (widget.directory == null) {
      if (!MethodChannelObdBridge.isSupported) {
        setState(() => _problem = 'Disponível só no Android.');
        return;
      }
      final status = await Permission.bluetoothConnect.request();
      if (!status.isGranted) {
        setState(() => _problem = 'Sem a permissão de Bluetooth ("Dispositivos próximos") o app não fala com o adaptador.');
        return;
      }
    }
    final dir = widget.directory ?? Directory('${(await getApplicationDocumentsDirectory()).path}/obd_phase0');
    dir.createSync(recursive: true);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _file = File('${dir.path}/phase0_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}.txt');
    _write('# Synapse Auto — OBD-II fase 0 — ${now.toIso8601String()}');
    await _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await widget.bridge.pairedDevices();
      final likely = RegExp(r'obd|v-?link|vgate|icar|elm', caseSensitive: false);
      setState(() {
        _devices = devices;
        _selected = devices.where((d) => likely.hasMatch(d.name)).firstOrNull ?? devices.firstOrNull;
        _problem = devices.isEmpty ? 'Nenhum aparelho pareado. Pareie o adaptador nas configurações de Bluetooth do Android.' : null;
      });
    } on ObdBridgeException catch (e) {
      setState(() => _problem = e.code == 'disabled' ? 'Ligue o Bluetooth do celular.' : 'Bluetooth: ${e.code} ${e.message ?? ''}');
    }
  }

  void _write(String line) {
    _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > 400) _lines.removeRange(0, _lines.length - 400);
    });
  }

  Future<void> _guard(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _guard(() async {
        final device = _selected;
        if (device == null) return;
        final c = await _runner.connect(device);
        if (mounted) setState(() => _connected = c != null);
      });

  Future<void> _disconnect() => _guard(() async {
        await _runner.disconnect();
        if (mounted) setState(() => _connected = false);
      });

  Future<void> _sequence() => _guard(() async {
        final r = await _runner.runSequence();
        _write('# resumo: versão ${r.adapterVersion}, bateria ${r.batteryVoltage}, protocolo ${r.protocol} (${r.searchResult}), '
            '${r.supported.length} PIDs, VIN ${r.vin ?? '—'}, ${r.mil ?? 'MIL —'}, '
            'latência ${r.singlePidLatency == null ? '—' : '${r.singlePidLatency!.avg} ms'}, multi-PID ${r.multiPid}');
      });

  Future<void> _live5min() => _guard(() async {
        _stopLive = false;
        await _runner.runLive(
          duration: const Duration(minutes: 5),
          cancelled: () => _stopLive,
          onValue: (key, value) {
            if (mounted) setState(() => _live[key] = value);
          },
        );
      });

  Future<void> _probe() => _guard(_runner.probeCar);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11);
    return Scaffold(
      appBar: AppBar(title: const Text('Teste do adaptador OBD-II')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Fase 0: só lê o carro, nunca apaga nada. Com o adaptador na tomada OBD e a ignição ligada, conecte '
                'e rode a sequência; depois a leitura contínua com o carro andando (alguém no passageiro, ou deixe '
                'rodando antes de sair). Use as notas para marcar o que está acontecendo.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_problem!, key: const ValueKey('obd0_problem'), style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (_devices.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: DropdownButton<PairedDevice>(
                  key: const ValueKey('obd0_device'),
                  isExpanded: true,
                  value: _selected,
                  items: [
                    for (final d in _devices) DropdownMenuItem(value: d, child: Text('${d.name.isEmpty ? '(sem nome)' : d.name} · ${d.address}')),
                  ],
                  onChanged: _connected || _busy ? null : (d) => setState(() => _selected = d),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!_connected)
                    FilledButton(key: const ValueKey('obd0_connect'), onPressed: _busy || _selected == null ? null : _connect, child: const Text('Conectar'))
                  else
                    OutlinedButton(key: const ValueKey('obd0_disconnect'), onPressed: _busy ? null : _disconnect, child: const Text('Desconectar')),
                  FilledButton.tonal(key: const ValueKey('obd0_sequence'), onPressed: _connected && !_busy ? _sequence : null, child: const Text('1. Sequência')),
                  FilledButton.tonal(key: const ValueKey('obd0_live'), onPressed: _connected && !_busy ? _live5min : null, child: const Text('2. Contínua 5 min')),
                  if (_busy && !_stopLive)
                    TextButton(key: const ValueKey('obd0_stop'), onPressed: () => setState(() => _stopLive = true), child: const Text('Parar')),
                  OutlinedButton(key: const ValueKey('obd0_probe'), onPressed: _connected && !_busy ? _probe : null, child: const Text('Verificar carro')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 0,
                children: [
                  for (final n in _notes)
                    ActionChip(label: Text(n, style: theme.textTheme.labelSmall), visualDensity: VisualDensity.compact, onPressed: () => _runner.note('nota: $n')),
                ],
              ),
            ),
            if (_live.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(_live.values.join('  ·  '), key: const ValueKey('obd0_live_values'), style: theme.textTheme.titleSmall),
              ),
            if (_file != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    Expanded(child: Text(_file!.path, style: mono, maxLines: 2, overflow: TextOverflow.ellipsis)),
                    IconButton(
                      tooltip: 'Copiar a transcrição',
                      icon: const Icon(Icons.copy),
                      onPressed: () => Clipboard.setData(ClipboardData(text: _file!.readAsStringSync())),
                    ),
                  ],
                ),
              ),
            const Divider(height: 16),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('obd0_transcript'),
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _lines.length,
                itemBuilder: (_, i) => Text(_lines[_lines.length - 1 - i], style: mono),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
