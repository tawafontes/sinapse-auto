import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../models/diagnostic_report.dart';
import '../../hive_boxes.dart';

/// The history of diagnostic reports (§8 of the design): newest first, at most
/// [limit] — the oldest go first, the starred ones never.
class DiagnosticReportRepository {
  DiagnosticReportRepository._();

  static const limit = 200;

  static Box get _box => Hive.box(HiveBoxNames.obdDiagnosticReports);

  static ValueListenable<Box> listenable() => _box.listenable();

  static String newId() => 'diag_${DateTime.now().microsecondsSinceEpoch}';

  static List<DiagnosticReport> get newestFirst {
    final reports = <DiagnosticReport>[];
    for (final value in _box.values) {
      if (value is! String) continue;
      try {
        reports.add(DiagnosticReport.decode(value));
      } on FormatException {
        // A damaged entry: skipped, never fatal to the list.
      } on TypeError {
        // Same.
      }
    }
    reports.sort((a, b) => b.at.compareTo(a.at));
    return reports;
  }

  static DiagnosticReport? byId(String id) {
    final value = _box.get(id);
    return value is String ? DiagnosticReport.decode(value) : null;
  }

  /// The most recent report of [type].
  static DiagnosticReport? latest(DiagnosticReportType type) => newestFirst.where((r) => r.type == type).firstOrNull;

  /// The report of the same type made before [report] on the same car (same
  /// VIN, when both know it) — what "Comparar com o anterior" shows.
  static DiagnosticReport? previous(DiagnosticReport report) => newestFirst
      .where((r) =>
          r.id != report.id &&
          r.type == report.type &&
          r.at.isBefore(report.at) &&
          r.status != DiagnosticReportStatus.cancelled &&
          (r.vin == null || report.vin == null || r.vin == report.vin))
      .firstOrNull;

  /// The last VIN any report read: the battery report, made with the car off,
  /// files itself under it.
  static String? get lastVin => newestFirst.map((r) => r.vin).nonNulls.firstOrNull;

  static Future<void> save(DiagnosticReport report) async {
    await _box.put(report.id, report.encode());
    await _trim();
  }

  static Future<void> setStarred(DiagnosticReport report, bool starred) => _box.put(report.id, report.copyWith(starred: starred).encode());

  static Future<void> delete(Iterable<String> ids) => _box.deleteAll(ids);

  static Future<void> _trim() async {
    final all = newestFirst;
    if (all.length <= limit) return;
    final removable = all.where((r) => !r.starred).toList().reversed; // oldest first
    final excess = all.length - limit;
    await _box.deleteAll(removable.take(excess).map((r) => r.id));
  }
}
