import '../../../models/diagnostic_report.dart';
import '../elm327_decode.dart';
import '../obd_service.dart';

/// The user tapped "Cancelar": checked between commands.
class DiagnosticCancelled implements Exception {
  const DiagnosticCancelled();
}

class DiagnosticCancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const DiagnosticCancelled();
  }
}

/// "Lendo códigos da central 7E8…".
typedef DiagnosticProgress = void Function(String step);

/// How one run ended, before it becomes a [DiagnosticReport].
typedef DiagnosticRunEnd = ({DiagnosticReportStatus status, String? detail, List<({String command, String? response})> raw});

/// Runs [body] through [ObdService.runDiagnostic] and says how it ended:
/// complete, incomplete (the link dropped: what was read stays in the
/// builder) or cancelled. [DiagnosticUnavailable] goes through: nothing ran.
Future<DiagnosticRunEnd> runDiagnosticSteps(
  ObdService obd,
  Future<void> Function(DiagnosticLink link) body, {
  bool needsCar = true,
}) async {
  DiagnosticLink? used;
  try {
    await obd.runDiagnostic((link) async {
      used = link;
      await body(link);
    }, needsCar: needsCar);
    return (status: DiagnosticReportStatus.complete, detail: null, raw: _raw(used));
  } on DiagnosticLinkLost catch (e) {
    return (status: DiagnosticReportStatus.incomplete, detail: 'A conexão caiu no meio: ${e.reason}', raw: _raw(used));
  } on DiagnosticCancelled {
    return (status: DiagnosticReportStatus.cancelled, detail: 'Cancelado por você', raw: _raw(used));
  }
}

List<({String command, String? response})> _raw(DiagnosticLink? link) => List.of(link?.exchanges ?? const []);

/// Every ECU heard, functional requests (7DF), headers on: each answer says
/// which ECU sent it.
Future<void> listenToAllEcus(DiagnosticLink link) async {
  await link.send('ATAR');
  await link.send('ATSH7DF');
  await link.send('ATH1');
}

/// [command] to every ECU: each one's messages, by CAN id (empty: nobody, or
/// `NO DATA`).
Future<Map<int, List<List<int>>>> askAllEcus(DiagnosticLink link, String command, {Duration timeout = const Duration(seconds: 2)}) async {
  final raw = await link.send(command, timeout: timeout);
  return raw == null ? const {} : canMessages(raw);
}

/// A number the Brazilian way: `12,6`.
String ptNumber(double value, [int decimals = 1]) => value.toStringAsFixed(decimals).replaceAll('.', ',');
