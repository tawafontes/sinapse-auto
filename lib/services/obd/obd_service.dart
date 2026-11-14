import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'elm327_decode.dart';
import 'obd_bridge.dart';
import 'obd_preferences.dart';

/// Where the OBD-II link is (phase 1 state machine, `docs/obd/fase-1-rascunho.md` §2).
enum ObdLinkState {
  /// No adapter chosen yet.
  noAdapter,

  /// Not connected: automatic connection is off, the user disconnected, or
  /// the app released the adapter (background without a recording session).
  off,

  /// Opening the link and setting the adapter up.
  connecting,

  /// The adapter answers but the car does not (ignition off). The link stays
  /// up — on the Nivus it did for > 4 min — and the car is asked again.
  waitingForCar,

  /// The car answers and is being polled.
  receiving,

  /// The link failed and is being retried after a backoff.
  reconnecting,
}

/// The values the app reads from the car (and the adapter's own voltage).
enum ObdSignal { rpm, engineLoad, speed, throttle, coolant, moduleVoltage, fuelLevel, adapterVoltage }

/// The mode 01 PID behind each [ObdSignal] (`adapterVoltage` is `ATRV`).
const Map<ObdSignal, int> obdSignalPids = {
  ObdSignal.rpm: 0x0C,
  ObdSignal.engineLoad: 0x04,
  ObdSignal.speed: 0x0D,
  ObdSignal.throttle: 0x11,
  ObdSignal.coolant: 0x05,
  ObdSignal.moduleVoltage: 0x42,
  ObdSignal.fuelLevel: 0x2F,
};

/// One value and when it was read.
@immutable
class ObdSample {
  const ObdSample(this.value, this.at);

  final double value;
  final DateTime at;
}

/// The latest value of every signal read so far — kept after the link drops,
/// so a widget can go on showing the last value (with a red border: owner
/// decision, 2026-11-13). Whether a value is still live is [ObdService.isFresh].
@immutable
class ObdReadings {
  const ObdReadings(this.samples);

  static const empty = ObdReadings({});

  final Map<ObdSignal, ObdSample> samples;

  ObdSample? operator [](ObdSignal signal) => samples[signal];
}

/// What the link learned about the adapter and the car.
@immutable
class ObdLinkInfo {
  const ObdLinkInfo({
    this.connectMethod,
    this.connectMillis,
    this.elmVersion,
    this.protocol,
    this.engineEcu,
    this.supportedPids,
    this.multiPid = true,
  });

  /// Which RFCOMM method the native bridge used (`secure` on the Nivus).
  final String? connectMethod;
  final int? connectMillis;
  final String? elmVersion;

  /// `ATDPN` (`A6` = ISO 15765-4 CAN 11/500).
  final String? protocol;

  /// The engine's CAN response id (0x7E8), when found; requests then go to it
  /// alone (ATSH7E0). `null`: requests stay functional (7DF).
  final int? engineEcu;

  /// The mode 01 PIDs the engine declares; `null` until the car first answered.
  final Set<int>? supportedPids;

  /// Whether the car answers several PIDs per request.
  final bool multiPid;

  ObdLinkInfo copyWith({
    String? connectMethod,
    int? connectMillis,
    String? elmVersion,
    String? protocol,
    int? engineEcu,
    bool clearEngineEcu = false,
    Set<int>? supportedPids,
    bool? multiPid,
  }) =>
      ObdLinkInfo(
        connectMethod: connectMethod ?? this.connectMethod,
        connectMillis: connectMillis ?? this.connectMillis,
        elmVersion: elmVersion ?? this.elmVersion,
        protocol: protocol ?? this.protocol,
        engineEcu: clearEngineEcu ? null : (engineEcu ?? this.engineEcu),
        supportedPids: supportedPids ?? this.supportedPids,
        multiPid: multiPid ?? this.multiPid,
      );
}

/// One state change, for the adapter screen's short history.
@immutable
class ObdTransition {
  const ObdTransition(this.at, this.state, this.detail);

  final DateTime at;
  final ObdLinkState state;
  final String? detail;
}

class _LinkLost implements Exception {
  const _LinkLost(this.reason);
  final String reason;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// The single owner of the OBD-II link (phase 1). Lives in the
/// `DrivingSessionHost`; nothing else talks to the [ObdBridge] (the phase 0
/// test screen pauses this service while it runs). Its readings reach the
/// pipeline through `DashboardSensorStreams`, like every other physical source.
///
/// Built on what the Vgate and the Nivus showed in phase 0
/// (`docs/obd/fase-0-resultados-nivus.md`):
///
/// * **Every (re)connection runs the whole set-up** — ATZ, ATE0 ATL0 ATS0 ATH0,
///   ATSP0: an adapter that lost power comes back with echo and spaces on.
/// * **Requests go to the engine alone.** Two ECUs answer a functional request,
///   in an order that changes even within one run, so the engine is found from
///   a headers-on `0100` (most PIDs) and addressed physically (ATSH7E0); its
///   PID map is read only then.
/// * **A drop is noticed by silence, not by the socket:** a pulled adapter
///   left requests unanswered for 6 s before Android reported a broken pipe.
///   Three requests in a row without a prompt (500 ms each) count as lost.
/// * **Ignition off is not a drop:** the adapter goes on answering while the
///   car says `NO DATA`, so the link stays up in [ObdLinkState.waitingForCar].
/// * Polling (owner decision): rpm and load (plus speed and throttle when the
///   car has them) twice a second in one multi-PID request; coolant, module
///   voltage and fuel level every 5 s; the adapter's voltage every 10 s.
class ObdService extends ChangeNotifier {
  ObdService({required this.bridge, required this.preferences, DateTime Function()? now})
      : _now = now ?? DateTime.now,
        _address = preferences.adapterAddress {
    _state = preferences.hasAdapter ? ObdLinkState.off : ObdLinkState.noAdapter;
    preferences.addListener(_onPreferencesChanged);
  }

  final ObdBridge bridge;
  final ObdPreferences preferences;
  final DateTime Function() _now;

  /// Waits between reconnection attempts: 5 s, 15 s, 30 s, then 60 s.
  static const backoff = [Duration(seconds: 5), Duration(seconds: 15), Duration(seconds: 30), Duration(seconds: 60)];
  static const fastPeriod = Duration(milliseconds: 500);
  static const slowPeriod = Duration(seconds: 5);
  static const voltagePeriod = Duration(seconds: 10);
  static const waitingPeriod = Duration(seconds: 3);
  static const requestTimeout = Duration(milliseconds: 500);

  /// With the car off the Nivus' adapter took up to ~500 ms to answer ATRV.
  static const slowCommandTimeout = Duration(milliseconds: 1500);

  /// The first `0100` after ATSP0 searches the protocols.
  static const searchTimeout = Duration(seconds: 10);
  static const failuresBeforeLost = 3;
  static const noDataBeforeCarOff = 2;

  /// How old a value may be and still count as live: twice its polling period
  /// plus slack.
  static Duration maxAge(ObdSignal signal) => switch (signal) {
        ObdSignal.rpm || ObdSignal.engineLoad || ObdSignal.speed || ObdSignal.throttle => const Duration(seconds: 3),
        ObdSignal.coolant || ObdSignal.moduleVoltage || ObdSignal.fuelLevel => const Duration(seconds: 15),
        ObdSignal.adapterVoltage => const Duration(seconds: 30),
      };

  static const _fastSignals = [ObdSignal.rpm, ObdSignal.engineLoad, ObdSignal.speed, ObdSignal.throttle];
  static const _slowSignals = [ObdSignal.coolant, ObdSignal.moduleVoltage, ObdSignal.fuelLevel];

  late ObdLinkState _state;
  String? _detail;
  String? _address;
  ObdLinkInfo _info = const ObdLinkInfo();
  final Map<ObdSignal, ObdSample> _samples = {};
  ObdReadings _readings = ObdReadings.empty;
  final _readingsController = StreamController<ObdReadings>.broadcast();
  final List<ObdTransition> _history = [];
  int _reconnectAttempt = 0;

  int _generation = 0;
  bool _running = false;
  bool _userStopped = false;
  bool _disposed = false;
  int _silentRequests = 0;
  Timer? _sleepTimer;
  Completer<void>? _sleepCompleter;

  ObdLinkState get state => _state;

  /// Why the link is in its state, in Portuguese for the adapter screen
  /// ("sem resposta do adaptador", "carro não responde"…), or `null`.
  String? get detail => _detail;
  ObdLinkInfo get info => _info;
  ObdReadings get readings => _readings;

  /// Every new reading, as the whole [ObdReadings].
  Stream<ObdReadings> get readingsStream => _readingsController.stream;
  List<ObdTransition> get history => List.unmodifiable(_history);

  /// Which attempt the current [ObdLinkState.reconnecting] is (1-based).
  int get reconnectAttempt => _reconnectAttempt;

  /// Whether a link is wanted right now (connecting, connected or retrying).
  bool get isRunning => _running;

  /// Whether [signal]'s last value is still live: read recently enough, while
  /// the car answers (the adapter's voltage also counts while waiting for it).
  bool isFresh(ObdSignal signal) {
    final sample = _samples[signal];
    if (sample == null) return false;
    final linkOk = signal == ObdSignal.adapterVoltage
        ? _state == ObdLinkState.receiving || _state == ObdLinkState.waitingForCar
        : _state == ObdLinkState.receiving;
    return linkOk && _now().difference(sample.at) <= maxAge(signal);
  }

  /// Whether the car reports [signal]: `null` until its PID map is known.
  bool? supports(ObdSignal signal) {
    if (signal == ObdSignal.adapterVoltage) return true;
    final pids = _info.supportedPids;
    if (pids == null) return null;
    return pids.contains(obdSignalPids[signal]);
  }

  /// The app opened or came back to the foreground: connect if the user wants
  /// it automatic and did not disconnect by hand.
  void resume() {
    if (_disposed || _running || _userStopped) return;
    if (preferences.hasAdapter && preferences.autoConnect) _start();
  }

  /// "Conectar": connect now, even with automatic connection off.
  void connect() {
    if (_disposed) return;
    _userStopped = false;
    if (!preferences.hasAdapter) return;
    if (_running) _stop();
    _start();
  }

  /// "Desconectar": drop the link and stay off until [connect] (or the next
  /// app start).
  Future<void> disconnect() async {
    _userStopped = true;
    await _release();
  }

  /// The app went to the background with no session recording, or the phase 0
  /// test screen needs the adapter: let it go. [resume] picks it up again.
  Future<void> pause() => _release();

  Future<void> _release() async {
    if (!_running) return;
    _stop();
    _setState(preferences.hasAdapter ? ObdLinkState.off : ObdLinkState.noAdapter);
    try {
      await bridge.disconnect();
    } on ObdBridgeException {
      // Already gone.
    }
  }

  void _onPreferencesChanged() {
    if (_disposed) return;
    final address = preferences.adapterAddress;
    if (address != _address) {
      _address = address;
      _info = const ObdLinkInfo();
      if (address == null) {
        if (_running) unawaited(_release());
        _setState(ObdLinkState.noAdapter);
      } else if (_running) {
        _stop();
        _start();
      } else {
        _setState(ObdLinkState.off);
      }
    }
  }

  void _start() {
    _running = true;
    _reconnectAttempt = 0;
    final generation = ++_generation;
    unawaited(_run(generation));
  }

  void _stop() {
    _running = false;
    _generation++;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final completer = _sleepCompleter;
    _sleepCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  bool _alive(int generation) => !_disposed && _running && generation == _generation;

  void _check(int generation) {
    if (!_alive(generation)) throw const _Cancelled();
  }

  Future<void> _sleep(Duration duration, int generation) async {
    if (duration <= Duration.zero) return;
    final completer = Completer<void>();
    _sleepCompleter = completer;
    _sleepTimer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    _check(generation);
  }

  Future<void> _run(int generation) async {
    var connectedOnce = false;
    while (_alive(generation)) {
      try {
        await _session(generation, firstAttempt: _reconnectAttempt == 0);
      } on _Cancelled {
        return;
      } on _LinkLost catch (lost) {
        if (!_alive(generation)) return;
        if (_state == ObdLinkState.receiving || _state == ObdLinkState.waitingForCar) connectedOnce = true;
        try {
          await bridge.disconnect();
        } on ObdBridgeException {
          // Already gone.
        }
        if (!_alive(generation)) return;
        _reconnectAttempt = connectedOnce ? 1 : _reconnectAttempt + 1;
        connectedOnce = false;
        _setState(ObdLinkState.reconnecting, detail: lost.reason);
      } on ObdBridgeException catch (e) {
        if (!_alive(generation)) return;
        if (e.code == 'permission' || e.code == 'unavailable') {
          // Nothing a retry fixes: the adapter screen asks for the permission.
          _running = false;
          _setState(ObdLinkState.off, detail: e.code == 'permission' ? 'Permissão de Bluetooth negada' : 'Este aparelho não tem Bluetooth');
          return;
        }
        _reconnectAttempt++;
        _setState(ObdLinkState.reconnecting, detail: _describeBridgeError(e));
      }
      try {
        await _sleep(backoff[math.min(_reconnectAttempt, backoff.length) - 1], generation);
      } on _Cancelled {
        return;
      }
    }
  }

  String _describeBridgeError(ObdBridgeException e) => switch (e.code) {
        'disabled' => 'Bluetooth desligado',
        'connect_failed' => 'Adaptador não encontrado (desligado ou fora de alcance)',
        _ => e.message ?? e.code,
      };

  /// One link, from opening it until it is lost (throws [_LinkLost] or an
  /// [ObdBridgeException]) — or forever, while the car comes and goes.
  Future<void> _session(int generation, {required bool firstAttempt}) async {
    if (firstAttempt) _setState(ObdLinkState.connecting);
    _silentRequests = 0;
    final connection = await bridge.connect(_address!);
    _check(generation);
    _info = _info.copyWith(connectMethod: connection.method, connectMillis: connection.millis);

    await _setUpAdapter(generation);
    while (true) {
      if (!await _carAnswers(generation, searching: true)) {
        _setState(ObdLinkState.waitingForCar, detail: 'Carro desligado ou sem resposta');
        await _waitForCar(generation);
      }
      await _findEngine(generation);
      await _readSupportedPids(generation);
      _reconnectAttempt = 0;
      _setState(ObdLinkState.receiving);
      await _poll(generation);
      // The car went quiet (ignition off): back to waiting, link still up.
    }
  }

  /// Sends [command]; `null` when the adapter did not answer in time. Three
  /// unanswered requests in a row, or a failed socket, lose the link.
  Future<String?> _send(String command, int generation, {Duration timeout = requestTimeout}) async {
    _check(generation);
    final ObdReply reply;
    try {
      reply = await bridge.send(command, timeout: timeout);
    } on ObdBridgeException catch (e) {
      _check(generation);
      if (e.code == 'closed' || e.code == 'not_connected' || e.code == 'io') {
        throw _LinkLost('Conexão perdida');
      }
      rethrow;
    }
    _check(generation);
    if (reply.timedOut) {
      if (++_silentRequests >= failuresBeforeLost) throw const _LinkLost('Sem resposta do adaptador');
      return null;
    }
    _silentRequests = 0;
    return reply.response;
  }

  Future<void> _setUpAdapter(int generation) async {
    final reset = await _send('ATZ', generation, timeout: const Duration(seconds: 3));
    final version = reset == null ? null : responseLines(reset, command: 'ATZ').where((l) => l.toUpperCase().startsWith('ELM')).lastOrNull;
    for (final command in ['ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0']) {
      await _send(command, generation, timeout: slowCommandTimeout);
    }
    _info = _info.copyWith(elmVersion: version, clearEngineEcu: true);
    await _readAdapterVoltage(generation);
  }

  Future<void> _readAdapterVoltage(int generation) async {
    final raw = await _send('ATRV', generation, timeout: slowCommandTimeout);
    final volts = raw == null ? null : adapterVoltage(raw);
    if (volts != null) _record({ObdSignal.adapterVoltage: volts});
  }

  Future<bool> _carAnswers(int generation, {bool searching = false}) async {
    final raw = await _send('0100', generation, timeout: searching ? searchTimeout : slowCommandTimeout);
    return raw != null && supportedPids(raw, 0x00) != null;
  }

  Future<void> _waitForCar(int generation) async {
    var sinceVoltage = Duration.zero;
    while (true) {
      await _sleep(waitingPeriod, generation);
      sinceVoltage += waitingPeriod;
      if (sinceVoltage >= voltagePeriod) {
        sinceVoltage = Duration.zero;
        await _readAdapterVoltage(generation);
      }
      if (await _carAnswers(generation)) return;
    }
  }

  /// Finds the engine among the ECUs that answer and addresses it alone.
  Future<void> _findEngine(int generation) async {
    await _send('ATH1', generation, timeout: slowCommandTimeout);
    final raw = await _send('0100', generation, timeout: slowCommandTimeout);
    await _send('ATH0', generation, timeout: slowCommandTimeout);
    final engine = raw == null ? null : engineEcuFrom(raw);
    if (engine == null) {
      // Not 11-bit CAN, or one ECU only: functional requests are fine.
      _info = _info.copyWith(clearEngineEcu: true);
      return;
    }
    final answer = await _send('ATSH${(engine - 8).toRadixString(16).toUpperCase()}', generation, timeout: slowCommandTimeout);
    _info = answer != null && answer.toUpperCase().contains('OK') ? _info.copyWith(engineEcu: engine) : _info.copyWith(clearEngineEcu: true);
  }

  Future<void> _readSupportedPids(int generation) async {
    final pids = <int>{};
    for (var base = 0x00; base <= 0xE0; base += 0x20) {
      final raw = await _send('01${_hex(base)}', generation, timeout: slowCommandTimeout);
      final declared = raw == null ? null : supportedPids(raw, base);
      if (declared == null) break;
      pids.addAll(declared);
      if (!declared.contains(base + 0x20)) break;
    }
    String? protocol;
    final dpn = await _send('ATDPN', generation, timeout: slowCommandTimeout);
    if (dpn != null) protocol = responseLines(dpn, command: 'ATDPN').lastOrNull;
    _info = _info.copyWith(supportedPids: pids, protocol: protocol, multiPid: true);
    notifyListeners();
  }

  Future<void> _poll(int generation) async {
    final supported = _info.supportedPids ?? const <int>{};
    List<ObdSignal> available(List<ObdSignal> signals) => [
          for (final s in signals)
            if (supported.contains(obdSignalPids[s])) s,
        ];
    final fast = available(_fastSignals);
    final slow = available(_slowSignals);
    var sinceSlow = slowPeriod; // read the slow group right away
    var sinceVoltage = Duration.zero;
    var noData = 0;
    while (true) {
      final started = _now();
      final answered = await _read(fast, generation);
      if (answered == false) {
        if (++noData >= noDataBeforeCarOff) return;
      } else if (answered == true) {
        noData = 0;
      }
      if (sinceSlow >= slowPeriod) {
        sinceSlow = Duration.zero;
        await _read(slow, generation);
      }
      if (sinceVoltage >= voltagePeriod) {
        sinceVoltage = Duration.zero;
        await _readAdapterVoltage(generation);
      }
      final elapsed = _now().difference(started);
      await _sleep(fastPeriod - elapsed, generation);
      final tick = elapsed > fastPeriod ? elapsed : fastPeriod;
      sinceSlow += tick;
      sinceVoltage += tick;
    }
  }

  /// Reads [signals] in one multi-PID request (or one by one, for a car that
  /// answers only the first PID). `true`: the car answered; `false`: it said
  /// `NO DATA` (ignition off); `null`: nothing to read, or no answer in time.
  Future<bool?> _read(List<ObdSignal> signals, int generation) async {
    if (signals.isEmpty) return null;
    final pids = [for (final s in signals) obdSignalPids[s]!];
    if (_info.multiPid || pids.length == 1) {
      final command = '01${pids.map(_hex).join()}';
      final raw = await _send(command, generation);
      if (raw == null) return null;
      if ((elmError(raw) ?? '').toUpperCase().contains('NO DATA')) return false;
      final values = mode01Values(raw, pids, command: command);
      if (values.isEmpty) return null;
      _recordPids(values);
      if (pids.length > 1 && values.length == 1) {
        // Only the first PID came back: this car takes one PID per request.
        _info = _info.copyWith(multiPid: false);
        notifyListeners();
      }
      return true;
    }
    bool? answered;
    for (final pid in pids) {
      final command = '01${_hex(pid)}';
      final raw = await _send(command, generation);
      if (raw == null) continue;
      if ((elmError(raw) ?? '').toUpperCase().contains('NO DATA')) {
        answered ??= false;
        continue;
      }
      final values = mode01Values(raw, [pid], command: command);
      if (values.isNotEmpty) {
        _recordPids(values);
        answered = true;
      }
    }
    return answered;
  }

  void _recordPids(Map<int, List<int>> values) {
    final update = <ObdSignal, double>{};
    for (final entry in obdSignalPids.entries) {
      final data = values[entry.value];
      if (data == null) continue;
      final value = mode01Physical(entry.value, data);
      if (value != null) update[entry.key] = value;
    }
    _record(update);
  }

  void _record(Map<ObdSignal, double> update) {
    if (update.isEmpty) return;
    final at = _now();
    for (final entry in update.entries) {
      _samples[entry.key] = ObdSample(entry.value, at);
    }
    _readings = ObdReadings(Map.unmodifiable(_samples));
    _readingsController.add(_readings);
  }

  void _setState(ObdLinkState state, {String? detail}) {
    if (_state == state && _detail == detail) return;
    _state = state;
    _detail = detail;
    _history.add(ObdTransition(_now(), state, detail));
    if (_history.length > 30) _history.removeAt(0);
    if (!_disposed) {
      notifyListeners();
      // A state change alone changes what is live (see isFresh): consumers of
      // the readings stream re-evaluate on it.
      _readingsController.add(_readings);
    }
  }

  static String _hex(int byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase();

  @override
  void dispose() {
    if (_disposed) return;
    _stop();
    _disposed = true;
    preferences.removeListener(_onPreferencesChanged);
    unawaited(_readingsController.close());
    super.dispose();
  }
}
