import 'package:synapse_auto/services/obd/obd_bridge.dart';

/// Where the ignition is, as the real car showed it in phase 0 (Nivus, rodada 2).
enum FakeIgnition { off, on, running }

/// One ECU on the car's CAN bus: its response id, the PIDs it declares and the
/// values it answers with.
class FakeEcu {
  FakeEcu({required this.responseId, required this.bitmaps});

  final int responseId;

  /// The "supported PIDs" bitmaps it answers `0100`, `0120`, … with.
  final Map<int, List<int>> bitmaps;

  /// The physical request id the ELM sends to for this ECU alone (7E8 → 7E0).
  int get requestId => responseId - 8;

  bool supports(int pid) {
    if (pid == 0x00) return true;
    final base = (pid - 1) ~/ 0x20 * 0x20;
    final bitmap = bitmaps[base];
    if (bitmap == null) return false;
    final bit = pid - base - 1;
    return bitmap[bit ~/ 8] & (0x80 >> (bit % 8)) != 0;
  }

  List<int>? bitmap(int base) => bitmaps[base];
}

/// A scripted Vgate iCar Pro (ELM327 v2.3) plugged into a VW Nivus 2021, built
/// from the real phase 0 transcripts (`docs/obd/fase-0-resultados-nivus.md`):
///
/// * two ECUs answer a functional (7DF) request — the engine at 7E8 with 39
///   PIDs and a second ECU at 7E9 with 12 — in an order that alternates, as
///   the real car's did, so code that trusts the first answer gets caught;
/// * physical addressing (ATSH7E0) reaches the engine alone;
/// * the adapter wakes with ELM defaults — echo and spaces on, headers off —
///   and goes back to them on ATZ and whenever it loses power;
/// * multi-PID answers longer than one CAN frame come as ISO-TP numbered lines
///   (headers off) or `10`/`21` frames (headers on), padded like the real ones;
/// * with the ignition off every mode 01 request is `NO DATA`, while the
///   adapter keeps answering AT commands and the link stays up (> 4 min on the
///   Nivus);
/// * an adapter pulled from the OBD socket stops answering — requests time out
///   with no prompt — and only the fourth send fails with a broken pipe, as on
///   the Nivus; it cannot be connected to again until plugged back.
///
/// Timing: every answer takes [latency] (the Nivus' median was ~66 ms), a
/// timed-out request takes its whole timeout. Under `testWidgets` both run on
/// the fake clock, so a test drives minutes of driving with `tester.pump`.
class FakeObdCar implements ObdBridge {
  FakeObdCar({this.latency = const Duration(milliseconds: 60)});

  final Duration latency;

  final engine = FakeEcu(responseId: 0x7E8, bitmaps: {
    0x00: [0xBE, 0x3E, 0xB8, 0x13],
    0x20: [0xA0, 0x07, 0xA0, 0x11],
    0x40: [0xFE, 0xD0, 0xC0, 0x00],
  });
  final gearbox = FakeEcu(responseId: 0x7E9, bitmaps: {
    0x00: [0x98, 0x18, 0x80, 0x01],
    0x20: [0x00, 0x00, 0x00, 0x01],
    0x40: [0xE0, 0x80, 0x00, 0x00],
  });

  List<FakeEcu> get ecus => [engine, gearbox];

  /// Every command sent, in order — for tests asserting what went on the wire.
  final sent = <String>[];

  var ignition = FakeIgnition.running;
  double rpm = 982;
  double speedKmh = 0;
  double loadPercent = 17;
  double throttlePercent = 16;
  double coolantC = 81;
  double fuelPercent = 50;

  /// When false, a multi-PID request gets only its first PID answered (some
  /// cars do this), so the service has to fall back to one PID per request.
  bool acceptsMultiPid = true;

  bool _connected = false;
  bool _plugged = true;
  int _sendsSinceUnplug = 0;
  int _connects = 0;

  bool _echo = true;
  bool _spaces = true;
  bool _headers = false;
  int _header = 0x7DF;
  int _functionalAnswers = 0;

  int get connects => _connects;
  bool get connected => _connected;

  /// Pulls the adapter from the OBD socket.
  void unplug() {
    _plugged = false;
    _sendsSinceUnplug = 0;
  }

  /// Plugs it back: it powers up with ELM defaults (it lost them with power).
  void plugIn() {
    _plugged = true;
    _resetElm();
  }

  void _resetElm() {
    _echo = true;
    _spaces = true;
    _headers = false;
    _header = 0x7DF;
  }

  double get batteryVolts => switch (ignition) {
        FakeIgnition.off => 11.8,
        FakeIgnition.on => 11.6,
        FakeIgnition.running => 13.3,
      };

  @override
  Future<List<PairedDevice>> pairedDevices() async => [
        (name: 'Fone', address: '00:11:22:33:44:55'),
        (name: 'V-LINK', address: '10:21:3E:4C:3A:AF'),
      ];

  @override
  Future<ObdConnection> connect(String address) async {
    _connects++;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!_plugged) {
      throw const ObdBridgeException('connect_failed', 'secure: IOException: read failed, socket might closed or timeout');
    }
    _connected = true;
    return (method: 'secure', millis: 450);
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<ObdReply> send(String command, {Duration timeout = const Duration(seconds: 2)}) async {
    sent.add(command);
    if (!_connected) throw const ObdBridgeException('not_connected', 'not connected');
    if (!_plugged) {
      _sendsSinceUnplug++;
      if (_sendsSinceUnplug > 3) {
        _connected = false;
        throw const ObdBridgeException('closed', 'link lost: IOException: Broken pipe');
      }
      await Future<void>.delayed(timeout);
      return (response: '', millis: timeout.inMilliseconds, timedOut: true);
    }
    await Future<void>.delayed(latency);
    final body = _answer(command.toUpperCase().replaceAll(' ', ''));
    final echoed = _echo ? '$command\r$body' : body;
    return (response: '$echoed\r\r', millis: latency.inMilliseconds, timedOut: false);
  }

  String _answer(String c) {
    if (c.startsWith('AT')) return _at(c.substring(2));
    if (RegExp(r'^01([0-9A-F]{2})+$').hasMatch(c)) return _mode01(c);
    return 'NO DATA';
  }

  String _at(String c) {
    switch (c) {
      case 'Z':
        _resetElm();
        return '\rELM327 v2.3';
      case 'I':
        return 'ELM327 v2.3';
      case '@1':
        return 'OBDII to RS232 Interpreter';
      case 'RV':
        return '${batteryVolts.toStringAsFixed(1)}V';
      case 'DP':
        return 'AUTO, ISO 15765-4 (CAN 11/500)';
      case 'DPN':
        return 'A6';
      case 'E0' || 'E1':
        _echo = c == 'E1';
        return 'OK';
      case 'S0' || 'S1':
        _spaces = c == 'S1';
        return 'OK';
      case 'H0' || 'H1':
        _headers = c == 'H1';
        return 'OK';
      case 'L0' || 'L1' || 'SP0':
        return 'OK';
    }
    final sh = RegExp(r'^SH([0-9A-F]{3})$').firstMatch(c);
    if (sh != null) {
      _header = int.parse(sh.group(1)!, radix: 16);
      return 'OK';
    }
    return '?';
  }

  String _mode01(String c) {
    if (ignition == FakeIgnition.off) return 'NO DATA';
    final pids = [for (var i = 2; i < c.length; i += 2) int.parse(c.substring(i, i + 2), radix: 16)];
    var targets = switch (_header) {
      0x7DF => ecus,
      _ => ecus.where((e) => e.requestId == _header).toList(),
    };
    if (_header == 0x7DF && (_functionalAnswers++).isOdd) targets = targets.reversed.toList();
    final answers = <String>[];
    for (final ecu in targets) {
      final asked = acceptsMultiPid ? pids : pids.take(1).toList();
      final data = <int>[0x41];
      for (final pid in asked) {
        if (!ecu.supports(pid)) continue;
        final value = _value(ecu, pid);
        if (value == null) continue;
        data
          ..add(pid)
          ..addAll(value);
      }
      if (data.length > 1) answers.add(_frames(ecu.responseId, data));
    }
    return answers.isEmpty ? 'NO DATA' : answers.join('\r');
  }

  List<int>? _value(FakeEcu ecu, int pid) {
    if (pid % 0x20 == 0) return ecu.bitmap(pid);
    final running = ignition == FakeIgnition.running;
    int pct(double v) => (v * 255 / 100).round().clamp(0, 255);
    return switch (pid) {
      0x0C => () {
          final raw = ((running ? rpm : 0) * 4).round();
          return [raw >> 8, raw & 0xFF];
        }(),
      0x04 => [pct(running ? loadPercent : 0)],
      0x11 => [pct(throttlePercent)],
      0x0D => [speedKmh.round().clamp(0, 255)],
      0x05 => [(coolantC + 40).round().clamp(0, 255)],
      0x2F => [pct(fuelPercent)],
      0x42 => () {
          final mv = (batteryVolts * 1000 + 360).round();
          return [mv >> 8, mv & 0xFF];
        }(),
      0x01 => [0x00, 0x07, 0xE1, 0x00],
      _ => null,
    };
  }

  String _hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();

  String _bytes(Iterable<int> bytes) => bytes.map(_hex).join(_spaces ? ' ' : '');

  String _frames(int id, List<int> payload) {
    final idHex = id.toRadixString(16).toUpperCase();
    if (payload.length <= 7) {
      return _headers ? '$idHex${_bytes([payload.length, ...payload])}' : _bytes(payload);
    }
    // ISO-TP: a first frame with 6 data bytes, then consecutive frames of 7,
    // the last padded — 0xAA headers off and 0x55 headers on, like the Nivus.
    final lines = <String>[];
    final first = payload.sublist(0, 6);
    final rest = payload.sublist(6);
    if (_headers) {
      lines.add('$idHex${_bytes([0x10, payload.length, ...first])}');
    } else {
      lines
        ..add(payload.length.toRadixString(16).padLeft(3, '0').toUpperCase())
        ..add('0:${_bytes(first)}');
    }
    var seq = 1;
    for (var i = 0; i < rest.length; i += 7) {
      final chunk = rest.sublist(i, i + 7 > rest.length ? rest.length : i + 7);
      final padded = [...chunk, for (var p = chunk.length; p < 7; p++) _headers ? 0x55 : 0xAA];
      lines.add(_headers ? '$idHex${_bytes([0x20 | (seq & 0x0F), ...padded])}' : '${seq & 0x0F}:${_bytes(padded)}');
      seq++;
    }
    return lines.join('\r');
  }
}
