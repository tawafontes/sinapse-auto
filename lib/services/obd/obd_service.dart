import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'diagnostic/diagnostic_policy.dart';
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
enum ObdSignal {
  rpm,
  engineLoad,
  speed,
  throttle,
  coolant,
  moduleVoltage,
  fuelLevel,
  adapterVoltage,

  // 2026-11-14 (owner request): the tank's ethanol share, the temperatures
  // around the engine, the accelerator pedal, and what the instant consumption
  // is estimated from (manifold pressure, or the MAF on a car that has one).
  ethanol,
  intakeTemp,
  ambientTemp,
  catalystTemp,
  manifoldPressure,
  pedal,
  maf,

  /// 2026-11-15: the car's own odometer (km), on cars that report it (the
  /// Haval H6 PHEV does, the Nivus does not) — fills the refuel and recharge
  /// forms.
  odometer,

  /// 2026-11-15, from the Haval H6 PHEV: the barometric pressure (turbo boost
  /// = manifold - barometric), and from the hybrid ECU (7EB on the Haval)
  /// the high-voltage battery's charge (PID 5B) and its voltage and current
  /// (PID 9A).
  baro,
  hybridBattery,
  hvVoltage,
  hvCurrent,
}

/// The mode 01 PID behind each [ObdSignal] (`adapterVoltage` is `ATRV`).
const Map<ObdSignal, int> obdSignalPids = {
  ObdSignal.rpm: 0x0C,
  ObdSignal.engineLoad: 0x04,
  ObdSignal.speed: 0x0D,
  ObdSignal.throttle: 0x11,
  ObdSignal.coolant: 0x05,
  ObdSignal.moduleVoltage: 0x42,
  ObdSignal.fuelLevel: 0x2F,
  ObdSignal.ethanol: 0x52,
  ObdSignal.intakeTemp: 0x0F,
  ObdSignal.ambientTemp: 0x46,
  ObdSignal.catalystTemp: 0x3C,
  ObdSignal.manifoldPressure: 0x0B,
  ObdSignal.pedal: 0x49,
  ObdSignal.odometer: 0xA6,
  ObdSignal.baro: 0x33,
  ObdSignal.hybridBattery: 0x5B,
  ObdSignal.hvVoltage: 0x9A,
  ObdSignal.hvCurrent: 0x9A,
  ObdSignal.maf: 0x10,
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
/// One drive split by what moved the car: the engine off (electric, on a
/// hybrid) or on.
@immutable
class ObdDriveTrip {
  const ObdDriveTrip({this.electricKm = 0, this.engineKm = 0, this.electricTime = Duration.zero, this.engineTime = Duration.zero});

  final double electricKm;
  final double engineKm;
  final Duration electricTime;
  final Duration engineTime;

  double get totalKm => electricKm + engineKm;

  /// The electric share of the distance, 0-1; `null` before any.
  double? get electricShare => totalKm < 0.01 ? null : electricKm / totalKm;

  ObdDriveTrip copyWith({double? electricKm, double? engineKm, Duration? electricTime, Duration? engineTime}) => ObdDriveTrip(
        electricKm: electricKm ?? this.electricKm,
        engineKm: engineKm ?? this.engineKm,
        electricTime: electricTime ?? this.electricTime,
        engineTime: engineTime ?? this.engineTime,
      );
}

@immutable
class ObdLinkInfo {
  const ObdLinkInfo({
    this.connectMethod,
    this.connectMillis,
    this.elmVersion,
    this.protocol,
    this.engineEcu,
    this.engineByFilter = false,
    this.hybridEcu,
    this.hybridPids,
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

  /// How the engine is reached: `false`, addressed alone (ATSH7E0, the
  /// Nivus); `true`, functional requests (7DF) with the adapter keeping only
  /// the engine's answers (ATCRA7E8) — the Haval H6 PHEV refuses a physical
  /// mode 01 request (`7F 01 11`, 2026-11-15) but answers a functional one.
  final bool engineByFilter;

  /// A second ECU with the hybrid system's PIDs (the high-voltage battery,
  /// the pedal) - 7EB on the Haval H6 PHEV - read through the adapter's
  /// filter once a second; `null` on a car without one (the Nivus).
  final int? hybridEcu;

  /// The mode 01 PIDs [hybridEcu] declares.
  final Set<int>? hybridPids;

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
    bool? engineByFilter,
    int? hybridEcu,
    Set<int>? hybridPids,
    bool clearHybridEcu = false,
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
        engineByFilter: clearEngineEcu ? false : (engineByFilter ?? this.engineByFilter),
        hybridEcu: clearHybridEcu ? null : (hybridEcu ?? this.hybridEcu),
        hybridPids: clearHybridEcu ? null : (hybridPids ?? this.hybridPids),
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

/// A diagnostic report cannot start: the link is not where it needs to be
/// ([reason], in Portuguese, for the "Executar" button).
class DiagnosticUnavailable implements Exception {
  const DiagnosticUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'DiagnosticUnavailable: $reason';
}

/// The link dropped (or was closed) while a diagnostic report ran: the report
/// keeps what it read and ends incomplete.
class DiagnosticLinkLost implements Exception {
  const DiagnosticLinkLost(this.reason);
  final String reason;

  @override
  String toString() => 'DiagnosticLinkLost: $reason';
}

/// One command a report sent and what came back (`null`: no answer in time).
typedef DiagnosticExchange = ({String command, String? response});

/// What a diagnostic report gets while it runs: the link, for a moment its
/// own (polling waits). Every command goes through [DiagnosticCommandPolicy]
/// first, and is kept in [exchanges] — the raw answers a saved report stores.
class DiagnosticLink {
  DiagnosticLink._(this._service, this._generation);

  final ObdService _service;
  final int _generation;
  bool _clearing = false;

  final List<DiagnosticExchange> exchanges = [];

  ObdLinkInfo get info => _service.info;
  ObdLinkState get state => _service.state;

  /// The service's clock (the fake one, in tests).
  DateTime now() => _service._now();

  Future<String?> send(String command, {Duration timeout = const Duration(seconds: 2)}) async {
    DiagnosticCommandPolicy.check(command, clearingEngine: _clearing);
    final response = await _service._send(command, _generation, timeout: timeout);
    exchanges.add((command: command, response: response));
    return response;
  }

  /// Mode 04 to the engine alone (its physical address, headers on), the only
  /// write the app makes; the caller has checked the car is stopped with the
  /// engine off. `null`: no engine found, nothing sent.
  Future<String?> clearEngineCodes() async {
    final engine = info.engineEcu;
    if (engine == null) return null;
    await send('ATAR');
    await send('ATH1');
    await send('ATSH${(engine - 8).toRadixString(16).toUpperCase()}');
    _clearing = true;
    try {
      return await send('04', timeout: const Duration(seconds: 5));
    } finally {
      _clearing = false;
    }
  }
}

class _DiagnosticJob {
  _DiagnosticJob(this.run, this.fail);

  final Future<void> Function(int generation) run;
  final void Function(String reason) fail;
}

/// The single owner of the OBD-II link (phase 1). Lives in the
/// `DrivingSessionHost`; nothing else talks to the [ObdBridge]. Its readings reach the
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
/// * Polling (owner decision): rpm and load (plus speed, throttle, pedal and
///   the manifold pressure — or the MAF — when the car has them) twice a
///   second in one multi-PID request, at most six PIDs, the ELM's limit on
///   CAN; coolant, module voltage, fuel level and the intake, ambient and
///   catalyst temperatures every 5 s; the adapter's voltage every 10 s; the
///   ethanol share every 30 s.
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
  static const verySlowPeriod = Duration(seconds: 30);
  static const waitingPeriod = Duration(seconds: 3);
  static const requestTimeout = Duration(milliseconds: 500);

  /// A data request with the engine reached through the adapter's filter
  /// ([ObdLinkInfo.engineByFilter]): every ECU answers a functional request,
  /// and on the Haval H6 PHEV the engine's answer drifted past 500 ms
  /// (317, 388, 475 ms, then three misses: a false "link lost", 2026-11-15).
  static const filteredRequestTimeout = Duration(milliseconds: 1500);

  Duration get _dataTimeout => _info.engineByFilter ? filteredRequestTimeout : requestTimeout;

  /// With the car off the Nivus' adapter took up to ~500 ms to answer ATRV.
  static const slowCommandTimeout = Duration(milliseconds: 1500);

  /// The first `0100` after ATSP0 searches the protocols.
  static const searchTimeout = Duration(seconds: 10);
  static const failuresBeforeLost = 3;
  static const noDataBeforeCarOff = 2;

  /// How old a value may be and still count as live: twice its polling period
  /// plus slack.
  static Duration maxAge(ObdSignal signal) => switch (signal) {
        ObdSignal.rpm ||
        ObdSignal.engineLoad ||
        ObdSignal.speed ||
        ObdSignal.throttle ||
        ObdSignal.pedal ||
        ObdSignal.manifoldPressure ||
        ObdSignal.maf =>
          const Duration(seconds: 3),
        ObdSignal.coolant ||
        ObdSignal.moduleVoltage ||
        ObdSignal.fuelLevel ||
        ObdSignal.intakeTemp ||
        ObdSignal.ambientTemp ||
        ObdSignal.catalystTemp =>
          const Duration(seconds: 15),
        ObdSignal.adapterVoltage => const Duration(seconds: 30),
        ObdSignal.ethanol || ObdSignal.odometer => const Duration(seconds: 90),
        ObdSignal.baro => const Duration(seconds: 90),
        ObdSignal.hybridBattery || ObdSignal.hvVoltage || ObdSignal.hvCurrent => const Duration(seconds: 4),
      };

  /// The fast group: what the dashboard moves with, and what the instant
  /// consumption needs — the MAF when the car has one, else the manifold
  /// pressure (speed-density). Six at most.
  static const _fastSignals = [ObdSignal.rpm, ObdSignal.engineLoad, ObdSignal.speed, ObdSignal.throttle, ObdSignal.pedal];
  static const _slowSignals = [
    ObdSignal.coolant,
    ObdSignal.moduleVoltage,
    ObdSignal.fuelLevel,
    ObdSignal.intakeTemp,
    ObdSignal.ambientTemp,
    ObdSignal.catalystTemp,
  ];
  static const _verySlowSignals = [ObdSignal.ethanol, ObdSignal.odometer, ObdSignal.baro];

  /// Read from the hybrid ECU once a second: the pedal (when the engine does
  /// not report it), the battery's charge, its voltage and current.
  static const _hybridSignals = [ObdSignal.pedal, ObdSignal.hybridBattery, ObdSignal.hvVoltage];
  static const hybridPeriod = Duration(seconds: 1);

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
    // A diagnostic report holds the link: polling waits on purpose, and the
    // widgets keep their last value without the red border.
    return linkOk && (_diagnosing || _now().difference(sample.at) <= maxAge(signal));
  }

  /// Whether a diagnostic report holds the link right now.
  bool get diagnosing => _diagnosing;
  bool _diagnosing = false;
  _DiagnosticJob? _job;

  /// Why a diagnostic report cannot run now, or `null` when it can.
  /// [needsCar]: the car must answer (most reports); without it, the adapter
  /// answering is enough (the battery's rest and cranking steps).
  String? diagnosticUnavailableReason({bool needsCar = true}) {
    if (_job != null || _diagnosing) return 'Outro diagnóstico em andamento';
    return switch (_state) {
      ObdLinkState.noAdapter => 'Escolha o adaptador em Veículo → Adaptador OBD-II',
      ObdLinkState.off => 'Conecte o adaptador',
      ObdLinkState.connecting || ObdLinkState.reconnecting => 'Aguarde a conexão com o adaptador',
      ObdLinkState.waitingForCar => needsCar ? 'Ligue a ignição' : null,
      ObdLinkState.receiving => null,
    };
  }

  /// Runs [body] with the link to itself: polling pauses at its next turn,
  /// [body] talks through a [DiagnosticLink], then the addressing polling
  /// needs is restored (always, unless the link dropped) and polling goes on.
  /// Fails with [DiagnosticUnavailable] when it cannot start, and with
  /// [DiagnosticLinkLost] when the link drops meanwhile.
  Future<T> runDiagnostic<T>(Future<T> Function(DiagnosticLink link) body, {bool needsCar = true}) {
    final reason = _disposed ? 'Serviço encerrado' : diagnosticUnavailableReason(needsCar: needsCar);
    if (reason != null) return Future.error(DiagnosticUnavailable(reason));
    final completer = Completer<T>();
    _job = _DiagnosticJob((generation) async {
      final link = DiagnosticLink._(this, generation);
      var lost = false;
      _diagnosing = true;
      notifyListeners();
      try {
        final result = await body(link);
        completer.complete(result);
      } on _LinkLost catch (e) {
        lost = true;
        completer.completeError(DiagnosticLinkLost(e.reason));
        rethrow;
      } on _Cancelled {
        lost = true;
        completer.completeError(const DiagnosticLinkLost('Conexão encerrada'));
        rethrow;
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _diagnosing = false;
        if (!_disposed) notifyListeners();
        if (!lost) await _restoreAddressing(generation);
      }
    }, (reason) {
      if (!completer.isCompleted) completer.completeError(DiagnosticLinkLost(reason));
    });
    _wake();
    return completer.future;
  }

  void _failJob(String reason) {
    final job = _job;
    _job = null;
    job?.fail(reason);
  }

  /// Runs the queued diagnostic, if any: `true` when one ran.
  Future<bool> _serveDiagnostic(int generation) async {
    final job = _job;
    if (job == null) return false;
    _job = null;
    await job.run(generation);
    return true;
  }

  /// Back to what polling expects after a report changed the addressing:
  /// headers off, every ECU heard, then the engine reached as [_findEngine]
  /// chose.
  Future<void> _restoreAddressing(int generation) async {
    String id(int v) => v.toRadixString(16).toUpperCase();
    await _send('ATAR', generation, timeout: slowCommandTimeout);
    await _send('ATH0', generation, timeout: slowCommandTimeout);
    final engine = _info.engineEcu;
    if (engine == null) {
      await _send('ATSH7DF', generation, timeout: slowCommandTimeout);
    } else if (_info.engineByFilter) {
      await _send('ATSH7DF', generation, timeout: slowCommandTimeout);
      await _send('ATCRA${id(engine)}', generation, timeout: slowCommandTimeout);
    } else {
      await _send('ATSH${id(engine - 8)}', generation, timeout: slowCommandTimeout);
    }
  }

  /// Cuts a wait short (a diagnostic was queued).
  void _wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final completer = _sleepCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Whether the car reports [signal]: `null` until its PID map is known.
  bool? supports(ObdSignal signal) {
    if (signal == ObdSignal.adapterVoltage) return true;
    final pids = _info.supportedPids;
    if (pids == null) return null;
    final pid = obdSignalPids[signal];
    return pids.contains(pid) || (_info.hybridPids?.contains(pid) ?? false);
  }

  /// The drive so far - distance and time with the engine off (electric) and
  /// on - since the car last started answering. Meaningful on a hybrid.
  ObdDriveTrip get trip => _trip;
  ObdDriveTrip _trip = const ObdDriveTrip();
  DateTime? _lastMotion;

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

  /// The app went to the background with no session recording: let the
  /// adapter go. [resume] picks it up again.
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
    _failJob('Conexão encerrada');
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
        _failJob(lost.reason);
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
      if (!await _findEngine(generation)) {
        // Only small ECUs answer: the car is off and some module is still
        // awake (the Haval's battery and charger, for minutes after it is
        // switched off). Waiting, until the engine answers too.
        _setState(ObdLinkState.waitingForCar, detail: 'Motor não responde (carro desligado)');
        await _serveDiagnostic(generation);
        await _sleep(waitingPeriod, generation);
        continue;
      }
      await _readSupportedPids(generation);
      _reconnectAttempt = 0;
      // A new drive when the car comes back after being off (not after a
      // dropped link, which is the same drive).
      if (_state == ObdLinkState.waitingForCar || _state == ObdLinkState.connecting) _trip = const ObdDriveTrip();
      _lastMotion = null;
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
      _log('$command !! ${e.code}');
      _check(generation);
      if (e.code == 'closed' || e.code == 'not_connected' || e.code == 'io') {
        throw _LinkLost('Conexão perdida');
      }
      rethrow;
    }
    if (reply.timedOut) {
      _log('$command -- sem resposta (${reply.millis} ms)');
    } else {
      final oneLine = reply.response.split(RegExp('[\r\n]+')).where((l) => l.trim().isNotEmpty).join(' | ');
      _log('$command => $oneLine (${reply.millis} ms)');
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
      await _serveDiagnostic(generation);
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
  /// The fewest mode 01 PIDs an engine ECU declares: the Nivus' engine declares 39, the Haval's 40; the ECUs that
  /// stay awake on a switched-off Haval (battery, charger) 9, the Nivus'
  /// gearbox 10. Fewer: the car is off and a module is still awake.
  static const engineMinPids = 15;

  /// Finds the engine among the ECUs that answer and how to reach it alone;
  /// `false` when the ECUs that answer are all too small to be an engine.
  Future<bool> _findEngine(int generation) async {
    // Every ECU must be heard: a filter left from before the car went quiet
    // (ATCRA7E8 on the Haval) would hide all but the engine.
    await _send('ATAR', generation, timeout: slowCommandTimeout);
    await _send('ATSH7DF', generation, timeout: slowCommandTimeout);
    await _send('ATH1', generation, timeout: slowCommandTimeout);
    final raw = await _send('0100', generation, timeout: slowCommandTimeout);
    // Every ECU's whole map (headers on): which one is the hybrid system.
    final maps = <int, Set<int>>{};
    void addMaps(String? answer, int base) {
      if (answer == null) return;
      canSingleFrames(answer).forEach((id, data) {
        if (data.length < 6 || data[0] != 0x41 || data[1] != base) return;
        final set = maps.putIfAbsent(id, () => <int>{});
        for (var i = 0; i < 32; i++) {
          if (data[2 + i ~/ 8] & (0x80 >> (i % 8)) != 0) set.add(base + i + 1);
        }
      });
    }

    addMaps(raw, 0x00);
    for (var base = 0x20; base <= 0xE0; base += 0x20) {
      if (!maps.values.any((m) => m.contains(base))) break;
      addMaps(await _send('01${_hex(base)}', generation, timeout: slowCommandTimeout), base);
    }
    await _send('ATH0', generation, timeout: slowCommandTimeout);
    final engine = raw == null ? null : engineEcuFrom(raw);
    _info = _info.copyWith(clearHybridEcu: true);
    const hybridPids = {0x5B, 0x9A};
    final hybrid = maps.entries.where((e) => e.key != engine && e.value.any(hybridPids.contains)).firstOrNull;
    if (hybrid != null) _info = _info.copyWith(hybridEcu: hybrid.key, hybridPids: hybrid.value);
    if (engine == null) {
      // Not 11-bit CAN, or one ECU only: functional requests are fine.
      _info = _info.copyWith(clearEngineEcu: true);
      return true;
    }
    if ((maps[engine]?.length ?? 0) < engineMinPids) return false;
    bool ok(String? answer) => answer != null && answer.toUpperCase().contains('OK');
    final id = engine.toRadixString(16).toUpperCase();
    final request = (engine - 8).toRadixString(16).toUpperCase();
    // Addressed alone first (the Nivus), then checked: some cars refuse a
    // physical mode 01 request — the Haval H6 PHEV answers `7F 01 11`.
    if (ok(await _send('ATSH$request', generation, timeout: slowCommandTimeout)) && await _carAnswers(generation)) {
      _info = _info.copyWith(engineEcu: engine, engineByFilter: false);
      return true;
    }
    // Functional requests, the adapter keeping only the engine's answers.
    await _send('ATSH7DF', generation, timeout: slowCommandTimeout);
    if (ok(await _send('ATCRA$id', generation, timeout: slowCommandTimeout)) && await _carAnswers(generation)) {
      _info = _info.copyWith(engineEcu: engine, engineByFilter: true);
      return true;
    }
    // No filter either: plain functional requests, as with one ECU.
    await _send('ATAR', generation, timeout: slowCommandTimeout);
    _info = _info.copyWith(clearEngineEcu: true);
    return true;
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
    final airflow = supported.contains(obdSignalPids[ObdSignal.maf]) ? ObdSignal.maf : ObdSignal.manifoldPressure;
    final fast = available([..._fastSignals, airflow]);
    final slow = available(_slowSignals);
    final verySlow = available(_verySlowSignals);
    final hybridEcu = _info.hybridEcu;
    final hybridPids = _info.hybridPids ?? const <int>{};
    final hybrid = hybridEcu == null
        ? const <ObdSignal>[]
        : [
            for (final s in _hybridSignals)
              if (hybridPids.contains(obdSignalPids[s]) && !(s == ObdSignal.pedal && supported.contains(obdSignalPids[s]))) s,
          ];
    var sinceHybrid = hybridPeriod;
    var sinceSlow = slowPeriod; // read the slow groups right away
    var sinceVerySlow = verySlowPeriod;
    var sinceVoltage = Duration.zero;
    var noData = 0;
    while (true) {
      if (await _serveDiagnostic(generation)) continue;
      final started = _now();
      final answered = await _read(fast, generation);
      if (answered == false) {
        if (++noData >= noDataBeforeCarOff) return;
      } else if (answered == true) {
        noData = 0;
      }
      if (hybrid.isNotEmpty && sinceHybrid >= hybridPeriod) {
        sinceHybrid = Duration.zero;
        await _readHybrid(hybridEcu!, hybrid, generation);
      }
      if (sinceSlow >= slowPeriod) {
        sinceSlow = Duration.zero;
        await _read(slow, generation);
      }
      if (sinceVerySlow >= verySlowPeriod) {
        sinceVerySlow = Duration.zero;
        await _read(verySlow, generation);
      }
      if (sinceVoltage >= voltagePeriod) {
        sinceVoltage = Duration.zero;
        await _readAdapterVoltage(generation);
      }
      final elapsed = _now().difference(started);
      await _sleep(fastPeriod - elapsed, generation);
      final tick = elapsed > fastPeriod ? elapsed : fastPeriod;
      sinceSlow += tick;
      sinceHybrid += tick;
      sinceVerySlow += tick;
      sinceVoltage += tick;
    }
  }

  /// Reads [signals] in one multi-PID request (or one by one, for a car that
  /// answers only the first PID). `true`: the car answered; `false`: it said
  /// `NO DATA` (ignition off); `null`: nothing to read, or no answer in time.
  Future<bool?> _read(List<ObdSignal> signals, int generation) async {
    if (signals.isEmpty) return null;
    final pids = {for (final s in signals) obdSignalPids[s]!}.toList();
    if (_info.multiPid || pids.length == 1) {
      final command = '01${pids.map(_hex).join()}';
      final raw = await _send(command, generation, timeout: _dataTimeout);
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
      final raw = await _send(command, generation, timeout: _dataTimeout);
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

  /// Reads [signals] from the hybrid ECU: the adapter's filter moves to it
  /// for one request (functional, 7DF) and back to the engine.
  Future<void> _readHybrid(int ecu, List<ObdSignal> signals, int generation) async {
    String id(int v) => v.toRadixString(16).toUpperCase();
    final engine = _info.engineEcu;
    if (!_info.engineByFilter) await _send('ATSH7DF', generation, timeout: slowCommandTimeout);
    await _send('ATCRA${id(ecu)}', generation, timeout: slowCommandTimeout);
    try {
      await _read(signals, generation);
    } finally {
      if (_info.engineByFilter && engine != null) {
        await _send('ATCRA${id(engine)}', generation, timeout: slowCommandTimeout);
      } else {
        await _send('ATAR', generation, timeout: slowCommandTimeout);
        if (engine != null) await _send('ATSH${id(engine - 8)}', generation, timeout: slowCommandTimeout);
      }
    }
  }

  void _recordPids(Map<int, List<int>> values) {
    final update = <ObdSignal, double>{};
    for (final entry in obdSignalPids.entries) {
      final data = values[entry.value];
      if (data == null || entry.value == 0x9A) continue;
      final value = mode01Physical(entry.value, data);
      if (value != null) update[entry.key] = value;
    }
    final hvData = values[0x9A];
    final hv = hvData == null ? null : hybridSystemData(hvData);
    if (hv != null) {
      update[ObdSignal.hvVoltage] = hv.volts;
      update[ObdSignal.hvCurrent] = hv.amps;
    }
    _record(update);
    final speed = update[ObdSignal.speed];
    if (speed != null) _countTrip(speed, update[ObdSignal.rpm]);
  }

  /// Adds the time since the last fast reading to the electric or the engine
  /// share of [trip] (a gap of more than 3 s is not counted).
  void _countTrip(double speedKmh, double? rpm) {
    final now = _now();
    final last = _lastMotion;
    _lastMotion = now;
    if (last == null) return;
    final dt = now.difference(last);
    if (dt > const Duration(seconds: 3) || speedKmh < 1) return;
    final km = speedKmh * dt.inMilliseconds / 3.6e6;
    final engineOn = (rpm ?? 0) > 0;
    _trip = engineOn
        ? _trip.copyWith(engineKm: _trip.engineKm + km, engineTime: _trip.engineTime + dt)
        : _trip.copyWith(electricKm: _trip.electricKm + km, electricTime: _trip.electricTime + dt);
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

  /// Debug builds only: every command and answer, and every state change, to
  /// logcat with the `OBD` prefix — to follow a run on a new car live over
  /// USB (`adb logcat -s flutter`). Release builds log nothing.
  static void _log(String line) {
    if (kDebugMode) debugPrintSynchronously('OBD $line');
  }

  void _setState(ObdLinkState state, {String? detail}) {
    if (_state == state && _detail == detail) return;
    _log('estado: ${state.name}${detail == null ? '' : ' ($detail)'}');
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
