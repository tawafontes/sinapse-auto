import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/driving_session_host.dart';
import '../../services/obd/obd_bridge.dart';
import '../../services/obd/obd_service.dart';

/// The words for each link state, shared by this screen and the top bar icon.
const Map<ObdLinkState, String> obdLinkStateLabels = {
  ObdLinkState.noAdapter: 'Sem adaptador',
  ObdLinkState.off: 'Desconectado',
  ObdLinkState.connecting: 'Conectando…',
  ObdLinkState.waitingForCar: 'Adaptador conectado, aguardando o carro',
  ObdLinkState.receiving: 'Recebendo dados',
  ObdLinkState.reconnecting: 'Reconectando…',
};

/// The color of each link state (owner decision, 2026-11-11): grey off,
/// amber waiting for the car, green receiving, red failing. Connecting blinks
/// (see `ObdStatusIcon`).
Color obdLinkStateColor(ObdLinkState state, ColorScheme scheme) => switch (state) {
      ObdLinkState.noAdapter || ObdLinkState.off || ObdLinkState.connecting => scheme.onSurfaceVariant,
      ObdLinkState.waitingForCar => const Color(0xFFFFA000),
      ObdLinkState.receiving => const Color(0xFF43A047),
      ObdLinkState.reconnecting => scheme.error,
    };

String _protocolName(String? dpn) => switch (dpn?.toUpperCase().replaceFirst('A', '')) {
      null => '—',
      '6' => 'ISO 15765-4 CAN (11 bits, 500 kbps)',
      '7' => 'ISO 15765-4 CAN (29 bits, 500 kbps)',
      '8' => 'ISO 15765-4 CAN (11 bits, 250 kbps)',
      '9' => 'ISO 15765-4 CAN (29 bits, 250 kbps)',
      '3' => 'ISO 9141-2',
      '4' || '5' => 'ISO 14230-4 (KWP2000)',
      '1' || '2' => 'SAE J1850',
      _ => dpn!,
    };

/// Configurações → Veículo → Adaptador OBD-II (phase 1): pick the paired
/// adapter (the Bluetooth permission is asked here, and only here), the two
/// switches, Conectar/Desconectar, and what the link knows about the car.
/// Pairing itself happens in Android's Bluetooth settings: the app only lists
/// already-paired devices, so it needs no scan and no location.
class ObdAdapterScreen extends StatefulWidget {
  const ObdAdapterScreen({super.key});

  @override
  State<ObdAdapterScreen> createState() => _ObdAdapterScreenState();
}

class _ObdAdapterScreenState extends State<ObdAdapterScreen> {
  String? _problem;
  bool _choosing = false;

  ObdService? get _service => DrivingSessionScope.maybeOf(context)?.obd;

  Future<void> _chooseAdapter(ObdService service) async {
    setState(() {
      _choosing = true;
      _problem = null;
    });
    try {
      if (MethodChannelObdBridge.isSupported) {
        final status = await Permission.bluetoothConnect.request();
        if (!status.isGranted) {
          setState(() => _problem = 'Sem a permissão de Bluetooth ("Dispositivos próximos") o app não fala com o adaptador.');
          return;
        }
      }
      final List<PairedDevice> devices;
      try {
        devices = await service.bridge.pairedDevices();
      } on ObdBridgeException catch (e) {
        setState(() => _problem = e.code == 'disabled' ? 'Ligue o Bluetooth do celular.' : 'Bluetooth: ${e.message ?? e.code}');
        return;
      }
      if (!mounted) return;
      if (devices.isEmpty) {
        setState(() => _problem = 'Nenhum aparelho pareado. Pareie o adaptador nas configurações de Bluetooth do Android (PIN 1234 ou 0000).');
        return;
      }
      final likely = RegExp(r'obd|v-?link|vgate|icar|elm', caseSensitive: false);
      final sorted = [...devices.where((d) => likely.hasMatch(d.name)), ...devices.where((d) => !likely.hasMatch(d.name))];
      final picked = await showModalBottomSheet<PairedDevice>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Aparelhos pareados')),
              for (final d in sorted)
                ListTile(
                  key: ValueKey('obdDevice_${d.address}'),
                  leading: Icon(likely.hasMatch(d.name) ? Icons.settings_input_component : Icons.bluetooth),
                  title: Text(d.name.isEmpty ? d.address : d.name),
                  subtitle: Text(d.address),
                  selected: d.address == service.preferences.adapterAddress,
                  onTap: () => Navigator.of(context).pop(d),
                ),
            ],
          ),
        ),
      );
      if (picked == null) return;
      await service.preferences.setAdapter(address: picked.address, name: picked.name);
      service.connect();
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return Scaffold(
      appBar: AppBar(title: const Text('Adaptador OBD-II')),
      body: SafeArea(
        child: service == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('A conexão com o adaptador OBD-II está disponível só no Android.'),
              )
            : ListenableBuilder(
                listenable: Listenable.merge([service, service.preferences]),
                builder: (context, _) => _content(context, service),
              ),
      ),
    );
  }

  Widget _content(BuildContext context, ObdService service) {
    final theme = Theme.of(context);
    final prefs = service.preferences;
    final state = service.state;
    final info = service.info;
    final running = service.isRunning;
    final pids = info.supportedPids?.toList()?..sort();
    String hex(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

    return ListView(
      children: [
        ListTile(
          key: const ValueKey('obdAdapter_state'),
          leading: Icon(Icons.settings_input_component, color: obdLinkStateColor(state, theme.colorScheme)),
          title: Text(obdLinkStateLabels[state]!),
          subtitle: service.detail == null ? null : Text(service.detail!),
          trailing: prefs.hasAdapter
              ? FilledButton.tonal(
                  key: const ValueKey('obdAdapter_connectButton'),
                  onPressed: running ? () => service.disconnect() : service.connect,
                  child: Text(running ? 'Desconectar' : 'Conectar'),
                )
              : null,
        ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_problem!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        const Divider(),
        ListTile(
          key: const ValueKey('obdAdapter_choose'),
          leading: const Icon(Icons.bluetooth),
          title: Text(prefs.hasAdapter ? (prefs.adapterName?.isNotEmpty ?? false ? prefs.adapterName! : prefs.adapterAddress!) : 'Escolher adaptador'),
          subtitle: Text(prefs.hasAdapter ? '${prefs.adapterAddress} · toque para trocar' : 'Pareie antes nas configurações de Bluetooth do Android'),
          trailing: _choosing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.chevron_right),
          onTap: _choosing ? null : () => _chooseAdapter(service),
        ),
        SwitchListTile(
          key: const ValueKey('obdAdapter_autoConnect'),
          secondary: const Icon(Icons.autorenew),
          title: const Text('Conectar automaticamente'),
          subtitle: const Text('Ao abrir o app e ao voltar para ele'),
          value: prefs.autoConnect,
          onChanged: (v) => prefs.setAutoConnect(v),
        ),
        SwitchListTile(
          key: const ValueKey('obdAdapter_autoStart'),
          secondary: const Icon(Icons.play_circle_outline),
          title: const Text('Iniciar sessão quando o carro ligar'),
          subtitle: const Text('Quando o motor girar ou o carro andar, com o app aberto'),
          value: prefs.autoStartSession,
          onChanged: (v) => prefs.setAutoStartSession(v),
        ),
        const Divider(),
        const ListTile(dense: true, title: Text('Diagnóstico')),
        _info('Adaptador', info.elmVersion ?? '—'),
        _info('Conexão', info.connectMethod == null ? '—' : '${info.connectMethod} · ${info.connectMillis} ms'),
        _info('Protocolo', _protocolName(info.protocol)),
        _info(
          'Central do motor',
          info.engineEcu == null ? (pids == null ? '—' : 'endereço padrão (7DF)') : info.engineEcu!.toRadixString(16).toUpperCase(),
        ),
        _info('Leitura em grupo', pids == null ? '—' : (info.multiPid ? 'sim' : 'não (um dado por pedido)')),
        _info('PIDs suportados', pids == null ? 'conecte com o carro ligado' : '${pids.length}: ${pids.map(hex).join(' ')}'),
        const Divider(),
        const ListTile(dense: true, title: Text('Histórico')),
        for (final t in service.history.reversed.take(12))
          ListTile(
            dense: true,
            leading: Icon(Icons.circle, size: 12, color: obdLinkStateColor(t.state, theme.colorScheme)),
            title: Text(obdLinkStateLabels[t.state]!),
            subtitle: t.detail == null ? null : Text(t.detail!),
            trailing: Text(
              '${t.at.hour.toString().padLeft(2, '0')}:${t.at.minute.toString().padLeft(2, '0')}:${t.at.second.toString().padLeft(2, '0')}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _info(String label, String value) => ListTile(
        dense: true,
        title: Text(label),
        subtitle: Text(value, key: ValueKey('obdAdapter_info_$label')),
      );
}
