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

  // The diagnostic reports (2026-11-15): codes, freeze frame, identification.
  List<String> stored = [];
  List<String> pending = [];
  List<String> permanent = [];

  /// The code that froze the frame (mode 02), `null`: no freeze frame.
  String? freezeDtc;
  String? name;
  String? calibrationId;
  List<int>? cvn;

  /// Mode 04 cleared it: its monitors start over.
  bool cleared = false;
}

/// A `P0123`-style code as its two bytes.
List<int> fakeDtcBytes(String code) {
  const letters = 'PCBU';
  final a = (letters.indexOf(code[0]) << 6) | (int.parse(code[1]) << 4) | int.parse(code[2], radix: 16);
  return [a, int.parse(code.substring(3), radix: 16)];
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
  FakeObdCar({this.latency = const Duration(milliseconds: 60)}) {
    _identify();
  }

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

  /// The hybrid system's ECU, on a [haval] car: the high-voltage battery
  /// (5B), its voltage and current (9A) and the pedal (49).
  FakeEcu? hybrid;

  List<FakeEcu> get ecus => [engine, gearbox, ?hybrid];

  /// ECUs that go on answering with the car switched off — the Haval's
  /// battery and charger modules (7EC, 7ED, 7EF), for minutes after it is
  /// switched off, while the engine is silent.
  final offEcus = <FakeEcu>[];

  String vin = '9BWZZZ5Z0MP012345';

  /// The check-engine light (follows the engine's stored codes unless set).
  bool? milOverride;
  bool get mil => milOverride ?? engine.stored.isNotEmpty;

  /// Kilometres since the codes were last cleared (PID 31).
  double kmSinceClear = 4321;

  /// The next ATRV answers, in order (a cranking dip, the DC-DC's jump);
  /// [batteryVolts] once used up.
  final voltageQueue = <double>[];

  /// The Nivus' engine with a code, its freeze frame and its identification.
  void withEngineCodes({List<String> stored = const ['P0301'], List<String> pending = const ['P0171']}) {
    engine
      ..stored = [...stored]
      ..pending = [...pending]
      ..freezeDtc = stored.isEmpty ? null : stored.first;
  }

  /// Every command sent, in order — for tests asserting what went on the wire.
  final sent = <String>[];

  var ignition = FakeIgnition.running;
  double rpm = 982;
  double speedKmh = 0;
  double loadPercent = 17;
  double throttlePercent = 16;
  double coolantC = 81;
  double fuelPercent = 50;
  double ethanolPercent = 27;
  double intakeC = 34;
  double ambientC = 27;
  double catalystC = 512;
  double pedalPercent = 18;
  double odometerKm = 23456.7;
  double baroKpa = 94;
  double hybridChargePercent = 64;
  double hvVolts = 362;

  /// Positive while the battery feeds the car.
  double hvAmps = 24;

  /// The Haval H6 PHEV as seen on 2026-11-15: the engine refuses physical
  /// requests, reports the odometer but not the pedal; a hybrid ECU at 7EB
  /// reports the pedal and the high-voltage battery.
  void haval() {
    refusesPhysicalMode01 = true;
    reportOdometer();
    final m40 = engine.bitmaps[0x40]!;
    engine.bitmaps[0x40] = [m40[0], m40[1] & ~0x80, m40[2], m40[3]]; // no 49
    hybrid = FakeEcu(responseId: 0x7EB, bitmaps: {
      0x00: [0x98, 0x18, 0x80, 0x01],
      0x20: [0x00, 0x00, 0x00, 0x01],
      0x40: [0x44, 0xC0, 0x00, 0x21],
      0x60: [0x00, 0x00, 0x00, 0x01],
      0x80: [0x00, 0x00, 0x00, 0x40],
    });
  }

  /// The Haval H6 PHEV's extra: the odometer (PID A6), which the Nivus lacks.
  void reportOdometer() {
    engine.bitmaps[0x40] = [...engine.bitmaps[0x40]!.take(3), engine.bitmaps[0x40]![3] | 0x01];
    engine.bitmaps[0x60] = [0x00, 0x00, 0x00, 0x01];
    engine.bitmaps[0x80] = [0x00, 0x00, 0x00, 0x01];
    engine.bitmaps[0xA0] = [0x04, 0x00, 0x00, 0x00];
  }

  /// The intake manifold pressure: about atmospheric with the engine stopped,
  /// ~35 kPa idling (vacuum).
  double get manifoldKpa => ignition == FakeIgnition.running ? 35 : 100;

  /// When false, a multi-PID request gets only its first PID answered (some
  /// cars do this), so the service has to fall back to one PID per request.
  bool acceptsMultiPid = true;

  /// The Haval H6 PHEV (2026-11-15): a mode 01 request addressed to the
  /// engine alone (ATSH7E0) gets `7F 01 11` (service not supported); only
  /// functional requests are answered.
  bool refusesPhysicalMode01 = false;

  bool _connected = false;
  bool _plugged = true;
  int _sendsSinceUnplug = 0;
  int _connects = 0;

  bool _echo = true;
  bool _spaces = true;
  bool _headers = false;
  int _header = 0x7DF;
  int? _receiveFilter;
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

  void _identify() {
    engine
      ..name = 'ECM\u0000-EngineControl'
      ..calibrationId = '04C906032BA'
      ..cvn = [0x1A, 0x2B, 0x3C, 0x4D];
    gearbox
      ..name = 'TCM\u0000-TransmissionCtrl'
      ..calibrationId = '0CW300040';
  }

  void _resetElm() {
    _echo = true;
    _spaces = true;
    _headers = false;
    _header = 0x7DF;
    _receiveFilter = null;
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
    if (RegExp(r'^(02|03|04|07|09|0A)([0-9A-F]{2})*$').hasMatch(c)) return _diagnostic(c);
    return 'NO DATA';
  }

  /// Modes 02, 03, 04, 07, 09 and 0A, per ECU.
  String _diagnostic(String c) {
    final pool = ignition == FakeIgnition.off ? offEcus : ecus;
    var targets = _header == 0x7DF ? pool : pool.where((e) => e.requestId == _header).toList();
    final filter = _receiveFilter;
    if (filter != null) targets = targets.where((e) => e.responseId == filter).toList();
    final mode = int.parse(c.substring(0, 2), radix: 16);
    final args = [for (var i = 2; i < c.length; i += 2) int.parse(c.substring(i, i + 2), radix: 16)];
    final answers = <String>[];
    for (final ecu in targets) {
      final payload = _diagnosticPayload(ecu, mode, args);
      if (payload != null) answers.add(_frames(ecu.responseId, payload));
    }
    return answers.isEmpty ? 'NO DATA' : answers.join('\r');
  }

  List<int>? _diagnosticPayload(FakeEcu ecu, int mode, List<int> args) {
    List<int> codes(int sid, List<String> list) => [sid, list.length, for (final code in list) ...fakeDtcBytes(code)];
    List<int> ascii(String text, int length) => [for (var i = 0; i < length; i++) i < text.length ? text.codeUnitAt(i) : 0];
    switch (mode) {
      case 0x03:
        return codes(0x43, ecu.stored);
      case 0x07:
        return codes(0x47, ecu.pending);
      case 0x0A:
        return codes(0x4A, ecu.permanent);
      case 0x04:
        if (ignition == FakeIgnition.running) return [0x7F, 0x04, 0x22];
        ecu
          ..stored = []
          ..pending = []
          ..freezeDtc = null
          ..cleared = true;
        if (ecu == engine) {
          milOverride = null;
          kmSinceClear = 0;
        }
        return [0x44];
      case 0x02:
        if (args.length < 2 || ecu.freezeDtc == null) return null;
        final pid = args[0];
        if (pid == 0x02) return [0x42, 0x02, 0x00, ...fakeDtcBytes(ecu.freezeDtc!)];
        if (pid == 0x00) return [0x42, 0x00, 0x00, 0x1F, 0x3B, 0x80, 0x00];
        final value = _value(ecu, pid);
        return value == null ? null : [0x42, pid, 0x00, ...value];
      case 0x09:
        if (args.isEmpty) return null;
        switch (args[0]) {
          case 0x00:
            return [0x49, 0x00, 0x54, 0x40, 0x00, 0x00];
          case 0x02:
            return ecu == engine ? [0x49, 0x02, 0x01, ...vin.codeUnits] : null;
          case 0x04:
            return ecu.calibrationId == null ? null : [0x49, 0x04, 0x01, ...ascii(ecu.calibrationId!, 16)];
          case 0x06:
            return ecu.cvn == null ? null : [0x49, 0x06, 0x01, ...ecu.cvn!];
          case 0x0A:
            return ecu.name == null ? null : [0x49, 0x0A, 0x01, ...ascii(ecu.name!, 20)];
        }
        return null;
    }
    return null;
  }

  /// PID 01 / 41: the light and the count (A), the continuous monitors, all
  /// complete (B), spark ignition with catalyst, EVAP, O2 sensor and heater
  /// supported (C) and, after a clear, all of them incomplete (D).
  List<int> _monitorBytes(FakeEcu ecu, {required bool thisCycle}) {
    const supported = 0x01 | 0x04 | 0x20 | 0x40;
    final incomplete = ecu.cleared ? supported : (thisCycle ? 0x04 : 0x00);
    final a = thisCycle ? 0x00 : (ecu == engine && mil ? 0x80 : 0x00) | (ecu.stored.length & 0x7F);
    return [a, 0x07, supported, incomplete];
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
        final volts = voltageQueue.isEmpty ? batteryVolts : voltageQueue.removeAt(0);
        return '${volts.toStringAsFixed(1)}V';
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
      case 'L0' || 'L1' || 'SP0' || 'AT0' || 'AT1' || 'AT2':
        return 'OK';
      case 'AR':
        _receiveFilter = null;
        return 'OK';
    }
    final cra = RegExp(r'^CRA([0-9A-F]{3})$').firstMatch(c);
    if (cra != null) {
      _receiveFilter = int.parse(cra.group(1)!, radix: 16);
      return 'OK';
    }
    if (RegExp(r'^ST[0-9A-F]{2}$').hasMatch(c)) return 'OK';
    final sh = RegExp(r'^SH([0-9A-F]{3})$').firstMatch(c);
    if (sh != null) {
      _header = int.parse(sh.group(1)!, radix: 16);
      return 'OK';
    }
    return '?';
  }

  String _mode01(String c) {
    final pool = ignition == FakeIgnition.off ? offEcus : ecus;
    if (pool.isEmpty) return 'NO DATA';
    final pids = [for (var i = 2; i < c.length; i += 2) int.parse(c.substring(i, i + 2), radix: 16)];
    var targets = switch (_header) {
      0x7DF => pool,
      _ => pool.where((e) => e.requestId == _header).toList(),
    };
    if (_header != 0x7DF && refusesPhysicalMode01) return _bytes([0x7F, 0x01, 0x11]);
    if (_header == 0x7DF && (_functionalAnswers++).isOdd) targets = targets.reversed.toList();
    final filter = _receiveFilter;
    if (filter != null) targets = targets.where((e) => e.responseId == filter).toList();
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
      0x52 => [pct(ethanolPercent)],
      0x49 => [pct(pedalPercent)],
      0x0B => [manifoldKpa.round()],
      0x0F => [(intakeC + 40).round()],
      0x46 => [(ambientC + 40).round()],
      0x3C => () {
          final raw = ((catalystC + 40) * 10).round();
          return [raw >> 8, raw & 0xFF];
        }(),
      0x42 => () {
          final mv = (batteryVolts * 1000 + 360).round();
          return [mv >> 8, mv & 0xFF];
        }(),
      0x01 => _monitorBytes(ecu, thisCycle: false),
      0x41 => _monitorBytes(ecu, thisCycle: true),
      0x21 => [0x00, mil ? 0x2A : 0x00],
      0x30 => [ecu.cleared ? 0 : 0x7B],
      0x31 => () {
          final km = kmSinceClear.round();
          return [km >> 8, km & 0xFF];
        }(),
      0x33 => [baroKpa.round()],
      0x5B => [pct(hybridChargePercent)],
      0x9A => () {
          final v = (hvVolts * 64).round();
          final a = (hvAmps * 10).round() & 0xFFFF;
          return [0x00, v >> 8, v & 0xFF, a >> 8, a & 0xFF, 0x00];
        }(),
      0xA6 => () {
          final raw = (odometerKm * 10).round();
          return [raw >> 24 & 0xFF, raw >> 16 & 0xFF, raw >> 8 & 0xFF, raw & 0xFF];
        }(),
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
