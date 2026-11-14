import 'dart:async';

import 'elm327_decode.dart';
import 'obd_bridge.dart';

/// What phase 0 learned, for the summary on screen (the transcript has it all).
class Phase0Report {
  String? adapterVersion;
  String? batteryVoltage;
  String? protocol;
  String? searchResult;
  final Set<int> supported = {};
  String? vin;
  String? mil;
  final Map<String, List<String>> troubleCodes = {};
  ({int min, int avg, int max, int count})? singlePidLatency;
  final Map<String, String> multiPid = {};
  String? connectMethod;
}

/// OBD-II phase 0 (decided 2026-11-11): runs, on the real car, the sequence the
/// proposal describes and writes every exchange to the transcript —
/// timestamped, raw, with the latency — which later becomes the fake car of the
/// automated tests and decides phase 1 (protocol, PID map, VIN, speed,
/// multi-PID, behaviour with the ignition off and on).
///
/// Read-only on the car: AT commands, mode 01 (current data), 03/07/0A (trouble
/// codes) and 09 (VIN). It never sends mode 04 (clear codes) or anything else
/// that changes the car.
class ObdPhase0Runner {
  ObdPhase0Runner(this.bridge, {required this.write});

  final ObdBridge bridge;

  /// Receives every transcript line (the screen shows them and appends them to
  /// the file).
  final void Function(String line) write;

  final report = Phase0Report();
  final _clock = Stopwatch()..start();

  /// The bridge codes that mean the link itself is gone, not just one bad
  /// answer. Once one arrives the runner stops sending until [connect] works
  /// again: otherwise each send fails instantly and the 5-minute live loop
  /// fills the transcript with thousands of identical error lines — exactly
  /// in the "link dropped mid-trip" case phase 0 wants to record cleanly.
  static const _linkLostCodes = {'not_connected', 'closed', 'io', 'disabled'};

  /// True after a link-lost error, until the next successful [connect].
  bool linkLost = false;

  /// Logs a bridge error; returns whether it means the link is gone.
  bool _bridgeError(ObdBridgeException e) {
    write('${_stamp()} ! erro ${e.code}: ${e.message}');
    if (!linkLost && _linkLostCodes.contains(e.code)) {
      linkLost = true;
      note('conexão perdida: nada mais é enviado até conectar de novo');
    }
    return linkLost;
  }

  String _stamp() => '[${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(3).padLeft(8)}]';

  void note(String text) => write('${_stamp()} # $text');

  /// Sends [command] and logs it; returns the raw answer ('' on a bridge
  /// error, which is logged too).
  Future<String> _send(String command, {Duration timeout = const Duration(seconds: 2), String Function(String raw)? decode}) async {
    if (linkLost) return '';
    write('${_stamp()} > $command');
    try {
      final reply = await bridge.send(command, timeout: timeout);
      final shown = responseLines(reply.response, command: command).join(' | ');
      final decoded = decode?.call(reply.response);
      write('${_stamp()} < ${shown.isEmpty ? '(vazio)' : shown} (${reply.millis} ms${reply.timedOut ? ', SEM PROMPT' : ''})'
          '${decoded == null || decoded.isEmpty ? '' : '  => $decoded'}');
      return reply.response;
    } on ObdBridgeException catch (e) {
      _bridgeError(e);
      return '';
    }
  }

  Future<ObdConnection?> connect(PairedDevice device) async {
    note('conectando a ${device.name} (${device.address})');
    try {
      final c = await bridge.connect(device.address);
      linkLost = false;
      report.connectMethod = c.method;
      note('conectado pelo método ${c.method} em ${c.millis} ms');
      return c;
    } on ObdBridgeException catch (e) {
      note('falha ao conectar: ${e.code}: ${e.message}');
      return null;
    }
  }

  Future<void> disconnect() async {
    try {
      await bridge.disconnect();
    } on ObdBridgeException catch (_) {}
    note('desconectado');
  }

  /// The full phase 0 sequence: adapter set-up, protocol search, the PID map,
  /// VIN, trouble codes, then single- and multi-PID timing.
  Future<Phase0Report> runSequence() async {
    note('--- sequência da fase 0 ---');
    report.adapterVersion = responseLines(await _send('ATZ', timeout: const Duration(seconds: 5))).lastOrNull;
    for (final c in ['ATE0', 'ATL0', 'ATS0', 'ATH0']) {
      await _send(c);
    }
    report.adapterVersion = responseLines(await _send('ATI')).lastOrNull ?? report.adapterVersion;
    await _send('AT@1');
    report.batteryVoltage = responseLines(await _send('ATRV')).lastOrNull;
    await _send('ATSP0');
    final search = await _send('0100', timeout: const Duration(seconds: 15), decode: _describeBitmap(0x00));
    report.searchResult = elmError(search) ?? 'ok';
    report.protocol = responseLines(await _send('ATDP')).lastOrNull;
    await _send('ATDPN');

    // The rest of the PID map: each bitmap says whether the next one exists.
    var bitmap = supportedPids(search, 0x00);
    report.supported.addAll(bitmap ?? const []);
    for (var base = 0x20; base <= 0xC0 && bitmap != null && bitmap.contains(base); base += 0x20) {
      final raw = await _send('01${_hex(base)}', decode: _describeBitmap(base));
      bitmap = supportedPids(raw, base);
      report.supported.addAll(bitmap ?? const []);
    }
    note('PIDs do modo 01 suportados: ${report.supported.map(_hex).join(' ')}');

    report.mil = describeMode01(await _send('0101', decode: (r) => describeMode01(r, 0x01) ?? ''), 0x01);
    for (final pid in [0x51, 0x5B, 0x2F, 0x42, 0x05, 0x0C, 0x0D, 0x04, 0x10, 0x0B]) {
      if (report.supported.contains(pid)) {
        await _send('01${_hex(pid)}', decode: (r) => describeMode01(r, pid) ?? '');
      }
    }
    await _send('0900', timeout: const Duration(seconds: 5));
    report.vin = vinFrom(await _send('0902', timeout: const Duration(seconds: 5), decode: (r) => vinFrom(r) ?? ''));
    for (final (mode, byte, label) in [('03', 0x43, 'armazenados'), ('07', 0x47, 'pendentes'), ('0A', 0x4A, 'permanentes')]) {
      final raw = await _send(mode, timeout: const Duration(seconds: 5), decode: (r) => troubleCodes(r, byte).join(' '));
      report.troubleCodes[label] = troubleCodes(raw, byte);
    }

    await _timing();
    await _headers();
    note('--- fim da sequência ---');
    return report;
  }

  Future<void> _timing() async {
    final probe = report.supported.contains(0x0C) ? '010C' : '0100';
    note('tempo de resposta: 20 x $probe');
    final times = <int>[];
    for (var i = 0; i < 20 && !linkLost; i++) {
      write('${_stamp()} > $probe');
      try {
        final r = await bridge.send(probe);
        times.add(r.millis);
        write('${_stamp()} < ${responseLines(r.response).join(' | ')} (${r.millis} ms${r.timedOut ? ', SEM PROMPT' : ''})');
      } on ObdBridgeException catch (e) {
        _bridgeError(e);
      }
    }
    if (times.isNotEmpty) {
      times.sort();
      final avg = times.reduce((a, b) => a + b) ~/ times.length;
      report.singlePidLatency = (min: times.first, avg: avg, max: times.last, count: times.length);
      note('latência $probe: mín ${times.first} ms, média $avg ms, máx ${times.last} ms');
    }
    // Several PIDs in one request (CAN cars accept up to six).
    final fast = [0x0C, 0x0D, 0x05, 0x04, 0x11, 0x10].where(report.supported.contains).toList();
    for (final count in [2, fast.length]) {
      if (fast.length < 2 || count < 2) continue;
      final command = '01${fast.take(count).map(_hex).join()}';
      final raw = await _send(command, timeout: const Duration(seconds: 3));
      report.multiPid[command] = elmError(raw) ?? '${responseBytes(raw).length} bytes';
    }
  }

  /// Which ECUs answer, by CAN id. On the Nivus every mode 01 request got two
  /// answers that ATH0 cannot tell apart (engine + probably the gearbox), so
  /// phase 1 needs to know which one is the engine (usually 7E8) and whether
  /// addressing it alone (ATSH7E0, physical) works — that would also halve the
  /// traffic. Read only; ends back on headers off and the default functional
  /// address (7DF), so the live run that may follow sees what it always did.
  Future<void> _headers() async {
    note('cabeçalhos: quais ECUs respondem');
    await _send('ATH1');
    await _send('0100', timeout: const Duration(seconds: 3));
    final probe = report.supported.contains(0x0C) ? '010C' : '0100';
    await _send(probe, timeout: const Duration(seconds: 3));
    await _send('ATSH7E0');
    await _send(probe, timeout: const Duration(seconds: 3));
    await _send('ATSH7DF');
    await _send('ATH0');
  }

  /// One quick look at the car: is the ECU answering, and the battery voltage.
  /// For the ignition off/on checks.
  Future<void> probeCar() async {
    note('--- verificação do carro ---');
    await _send('ATRV');
    await _send('0100', timeout: const Duration(seconds: 10), decode: _describeBitmap(0x00));
  }

  /// Reads the fast PIDs every cycle and the slow ones now and then, for
  /// [duration] or until [cancelled] — the "car moving" session. Reports each
  /// decoded value through [onValue] and the answers per second at the end.
  Future<void> runLive({
    required Duration duration,
    required bool Function() cancelled,
    void Function(String key, String value)? onValue,
  }) async {
    final fast = [0x0C, 0x0D, 0x04, 0x11].where(report.supported.contains).toList();
    final slow = [0x05, 0x2F, 0x5B, 0x10].where(report.supported.contains).toList();
    if (fast.isEmpty && slow.isEmpty) fast.addAll([0x0C, 0x0D, 0x05]);
    note('--- leitura contínua (${duration.inMinutes} min): rápidos ${fast.map(_hex).join(' ')}, lentos ${slow.map(_hex).join(' ')} ---');
    final started = DateTime.now();
    var answers = 0;
    var cycle = 0;
    while (!cancelled() && !linkLost && DateTime.now().difference(started) < duration) {
      final pids = [...fast, if (cycle % 10 == 0) ...slow];
      for (final pid in pids) {
        if (cancelled() || linkLost) break;
        final raw = await _send('01${_hex(pid)}', decode: (r) => describeMode01(r, pid) ?? '');
        final value = describeMode01(raw, pid);
        if (value != null) {
          answers++;
          onValue?.call(_hex(pid), value);
        }
      }
      if (cycle % 20 == 0) {
        final v = responseLines(await _send('ATRV')).lastOrNull;
        if (v != null) onValue?.call('ATRV', 'bateria $v');
      }
      cycle++;
    }
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    note('leitura contínua encerrada: $answers respostas em ${seconds.toStringAsFixed(1)} s '
        '(${seconds > 0 ? (answers / seconds).toStringAsFixed(1) : '0'} por segundo)');
  }

  static String _hex(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

  static String Function(String) _describeBitmap(int base) => (raw) {
        final pids = supportedPids(raw, base);
        return pids == null ? '' : 'suporta ${pids.map(_hex).join(' ')}';
      };
}
