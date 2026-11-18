/// What a diagnostic report may send to the car (`docs/obd/diagnostico-e-relatorios-futuro.md`
/// §5.2): an allow-list checked for every command before it goes on the wire.
/// The app reads; the only write is mode 04 (clear the engine's codes), and
/// only through [DiagnosticCommandPolicy.check] with `clearingEngine: true`.
library;

/// A command the policy does not allow. Never caught to carry on: a report
/// that builds one has a bug.
class DiagnosticCommandRefused implements Exception {
  const DiagnosticCommandRefused(this.command, this.reason);

  final String command;
  final String reason;

  @override
  String toString() => 'DiagnosticCommandRefused($command): $reason';
}

class DiagnosticCommandPolicy {
  const DiagnosticCommandPolicy._();

  /// The adapter's own commands a report may use: reading the voltage and the
  /// protocol, and the addressing and formatting settings polling already uses.
  static final _at = [
    RegExp(r'^ATRV$'),
    RegExp(r'^ATDPN?$'),
    RegExp(r'^ATI$'),
    RegExp(r'^ATH[01]$'),
    RegExp(r'^ATS[01]$'),
    RegExp(r'^ATAR$'),
    RegExp(r'^ATSH[0-9A-F]{3}$'),
    RegExp(r'^ATCRA[0-9A-F]{3}$'),
    RegExp(r'^ATST[0-9A-F]{2}$'),
    RegExp(r'^ATAT[0-2]$'),
  ];

  /// OBD-II read modes: 01 current data, 02 freeze frame, 03 stored codes, 06
  /// on-board test results, 07 pending codes, 09 vehicle information, 0A
  /// permanent codes.
  static const _readModes = {0x01, 0x02, 0x03, 0x06, 0x07, 0x09, 0x0A};

  /// UDS services that never change anything, with the forms allowed:
  /// TesterPresent, the default session, reading identification DIDs
  /// (F180–F19E) and reading codes.
  static bool _udsRead(List<int> b) => switch (b) {
        [0x3E, 0x00] => true,
        [0x10, 0x01] => true,
        [0x22, 0xF1, final did] when did >= 0x80 && did <= 0x9E => true,
        [0x19, 0x01 || 0x02, _] => true,
        _ => false,
      };

  /// Refused whatever the form, so nobody "just adds" one: programming and
  /// extended sessions, reset, UDS code clearing, security access,
  /// communication control, writing, routines, downloads and DTC settings.
  static const forbiddenServices = {0x11, 0x14, 0x27, 0x28, 0x2E, 0x2F, 0x31, 0x34, 0x35, 0x36, 0x37, 0x3D, 0x85};

  /// Throws [DiagnosticCommandRefused] unless [command] is allowed. Mode 04
  /// passes only with [clearingEngine] (the guarded "Apagar códigos do motor"
  /// path, which also checks the engine is addressed alone).
  static void check(String command, {bool clearingEngine = false}) {
    final c = command.toUpperCase().replaceAll(' ', '');
    if (c.startsWith('AT')) {
      if (_at.any((r) => r.hasMatch(c))) return;
      throw DiagnosticCommandRefused(command, 'comando do adaptador fora da lista');
    }
    if (c.isEmpty || !RegExp(r'^([0-9A-F]{2})+$').hasMatch(c)) {
      throw DiagnosticCommandRefused(command, 'não é um pedido em hexadecimal');
    }
    final bytes = [for (var i = 0; i < c.length; i += 2) int.parse(c.substring(i, i + 2), radix: 16)];
    final service = bytes.first;
    if (forbiddenServices.contains(service)) throw DiagnosticCommandRefused(command, 'serviço proibido');
    if (service == 0x10 && bytes.length > 1 && bytes[1] != 0x01) {
      throw DiagnosticCommandRefused(command, 'só a sessão padrão é permitida');
    }
    if (service == 0x04) {
      if (clearingEngine && bytes.length == 1) return;
      throw DiagnosticCommandRefused(command, 'apagar códigos só pelo fluxo protegido do motor');
    }
    if (_readModes.contains(service)) return;
    if (_udsRead(bytes)) return;
    throw DiagnosticCommandRefused(command, 'serviço fora da lista de leitura');
  }
}
