import 'dart:convert';

/// Which diagnostic report (`docs/obd/diagnostico-e-relatorios-futuro.md` §7).
enum DiagnosticReportType { health, battery, emissions }

const Map<DiagnosticReportType, String> diagnosticReportTypeLabels = {
  DiagnosticReportType.health: 'Saúde do veículo',
  DiagnosticReportType.battery: 'Bateria, partida e carga',
  DiagnosticReportType.emissions: 'Emissões e prontidão',
};

/// How a report ended: all read, the link dropped midway, or the user
/// cancelled — what was read is kept either way.
enum DiagnosticReportStatus { complete, incomplete, cancelled }

const Map<DiagnosticReportStatus, String> diagnosticReportStatusLabels = {
  DiagnosticReportStatus.complete: 'Completo',
  DiagnosticReportStatus.incomplete: 'Incompleto',
  DiagnosticReportStatus.cancelled: 'Cancelado',
};

/// The traffic light a report (and each of its parts) shows.
enum ReportLevel { ok, attention, problem, unknown }

ReportLevel worstLevel(Iterable<ReportLevel> levels) {
  var worst = ReportLevel.unknown;
  for (final level in levels) {
    if (level == ReportLevel.problem) return level;
    if (level == ReportLevel.attention) worst = level;
    if (level == ReportLevel.ok && worst == ReportLevel.unknown) worst = level;
  }
  return worst;
}

/// One saved diagnostic report: when and on which car, how it ended, every
/// command with its raw answer (so a better decoding or code table can read an
/// old report again) and the interpreted [result], whose shape depends on
/// [type]. Stored as JSON in its own Hive box (`DiagnosticReportRepository`).
/// The VIN is kept whole on the phone and masked on screen.
class DiagnosticReport {
  DiagnosticReport({
    required this.id,
    required this.type,
    required this.at,
    required this.status,
    required this.level,
    required this.summary,
    required this.result,
    this.statusDetail,
    this.vin,
    this.odometerKm,
    this.raw = const [],
    this.starred = false,
    this.beforeId,
    this.afterId,
  });

  final String id;
  final DiagnosticReportType type;
  final DateTime at;
  final DiagnosticReportStatus status;
  final String? statusDetail;
  final ReportLevel level;

  /// One line for the lists ("2 códigos · luz de injeção acesa").
  final String summary;
  final String? vin;
  final double? odometerKm;
  final List<({String command, String? response})> raw;
  final Map<String, Object?> result;

  /// Kept when the history is trimmed.
  final bool starred;

  /// "Antes e depois" of clearing the codes: this report was made right after
  /// clearing ([beforeId] the one made before), or before ([afterId]).
  final String? beforeId;
  final String? afterId;

  DiagnosticReport copyWith({bool? starred, String? afterId}) => DiagnosticReport(
        id: id,
        type: type,
        at: at,
        status: status,
        statusDetail: statusDetail,
        level: level,
        summary: summary,
        result: result,
        vin: vin,
        odometerKm: odometerKm,
        raw: raw,
        starred: starred ?? this.starred,
        beforeId: beforeId,
        afterId: afterId ?? this.afterId,
      );

  Map<String, Object?> toJson() => {
        'v': 1,
        'id': id,
        'type': type.name,
        'at': at.toIso8601String(),
        'status': status.name,
        'statusDetail': statusDetail,
        'level': level.name,
        'summary': summary,
        'vin': vin,
        'odometerKm': odometerKm,
        'raw': [
          for (final e in raw) {'c': e.command, 'r': e.response},
        ],
        'result': result,
        'starred': starred,
        'beforeId': beforeId,
        'afterId': afterId,
      };

  factory DiagnosticReport.fromJson(Map<String, Object?> j) => DiagnosticReport(
        id: j['id'] as String,
        type: DiagnosticReportType.values.byName(j['type'] as String),
        at: DateTime.parse(j['at'] as String),
        status: DiagnosticReportStatus.values.byName(j['status'] as String),
        statusDetail: j['statusDetail'] as String?,
        level: ReportLevel.values.byName(j['level'] as String),
        summary: j['summary'] as String? ?? '',
        vin: j['vin'] as String?,
        odometerKm: (j['odometerKm'] as num?)?.toDouble(),
        raw: [
          for (final e in (j['raw'] as List? ?? const []).cast<Map>()) (command: e['c'] as String, response: e['r'] as String?),
        ],
        result: (j['result'] as Map? ?? const {}).cast<String, Object?>(),
        starred: j['starred'] as bool? ?? false,
        beforeId: j['beforeId'] as String?,
        afterId: j['afterId'] as String?,
      );

  String encode() => jsonEncode(toJson());

  static DiagnosticReport decode(String text) => DiagnosticReport.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
}
