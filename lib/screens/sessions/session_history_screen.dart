import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/driving_session.dart';
import '../../models/unit_system.dart';
import '../../services/driving_session_recorder.dart'
    show DrivingSessionRecorder, DrivingSessionRecorderState, SessionDeletionRejected, deleteDrivingSession;
import '../../services/hive_boxes.dart';
import '../../services/unit_preferences.dart';
import 'session_detail_screen.dart';

/// Completed sessions only (an in-progress one has nothing final to show
/// yet — it's already visible live on [SessionRecordingScreen]), most
/// recent first. Pulled out as a pure function — independently
/// unit-testable against plain in-memory [DrivingSession] instances,
/// without needing a Hive box or a widget tree at all.
@visibleForTesting
List<DrivingSession> visibleSessionsSortedByRecency(Iterable<DrivingSession> sessions) {
  return sessions.where((s) => !s.isActive).toList()..sort((a, b) => b.startTime.compareTo(a.startTime));
}

/// Lists every stored [DrivingSession] (most recent first) — reads only the
/// lightweight summary box (`driving_sessions`), never the samples box, so
/// this list stays fast regardless of how much trajectory/telemetry data
/// any individual session has accumulated. Listens to the box itself so a
/// session started/finished elsewhere in the app (or finalized from this same
/// session) updates the list live, with no manual refresh needed.
///
/// Fase 16.2-R4.3-R2.6.6 (D1): a session whose finalization is still pending is
/// listed (the box caches the recorder's own instance, whose endTime is set as
/// soon as it stops) but cannot be deleted until its recorder releases it — see
/// [_SessionListTile]. The list therefore also listens to
/// [DrivingSessionRecorder.sessionControlChanges]: some of those transitions
/// write nothing to this box.
///
/// Fase 16.2-R4.3-R2.6.7: a session whose deletion did not finish (its record
/// still carries the deletion marker) stays listed as pending; swiping it
/// deletes it again. The next app start finishes it anyway.
///
/// Fase 16.2-R4.3-R2.6.11: a session whose dashcam telemetry FAILED says so on
/// its tile, from its own stored outcome (see [_SessionListTile]) — whatever
/// the dashcam is doing now. A complete one adds nothing here (its detail
/// screen shows it), and one with no recorded outcome — every session stored
/// before R2.6.11 — is listed exactly as before.
class SessionHistoryScreen extends StatelessWidget {
  const SessionHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
    return Scaffold(
      appBar: AppBar(title: const Text('Histórico')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([box.listenable(), DrivingSessionRecorder.sessionControlChanges]),
          builder: (context, _) {
            final sessions = visibleSessionsSortedByRecency(box.values);
            if (sessions.isEmpty) {
              return const Center(child: Text('Nenhuma sessão registrada ainda.'));
            }
            return ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, index) => _SessionListTile(session: sessions[index]),
            );
          },
        ),
      ),
    );
  }
}

class _SessionListTile extends StatelessWidget {
  const _SessionListTile({required this.session});

  final DrivingSession session;

  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _formatDuration(Duration? d) {
    if (d == null) return '—';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}min' : '${m}min';
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir esta sessão?'),
        content: Text('A sessão de ${_formatDate(session.startTime)} e sua trajetória serão apagadas permanentemente.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Fase 16.2-R4.3-R2.6.6 (D1): the deletion runs here — after the user
  /// confirmed, before the tile is dismissed — instead of in `onDismissed`.
  /// [deleteDrivingSession] is the authority and may refuse (a recorder still
  /// controls the session); a refusal must put the tile back, and a Dismissible
  /// that was dismissed has to leave the tree. Only that expected refusal is
  /// handled; any other error propagates, as before.
  Future<bool> _confirmAndDelete(BuildContext context) async {
    if (!await _confirmDelete(context)) return false;
    try {
      await deleteDrivingSession(session.id);
      return true;
    } on SessionDeletionRejected {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Esta sessão ainda está sendo finalizada e não pode ser excluída agora.')),
        );
      }
      return false;
    }
  }

  static String _pendingLabel(DrivingSessionRecorderState state) {
    switch (state) {
      case DrivingSessionRecorderState.finalizationFailed:
        return 'Finalização pendente — exclusão indisponível';
      case DrivingSessionRecorderState.finalizing:
        return 'Finalizando — exclusão indisponível';
      case DrivingSessionRecorderState.recording:
        return 'Em gravação — exclusão indisponível';
      case DrivingSessionRecorderState.idle:
        return 'Exclusão indisponível';
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferencesScope.of(context);
    final maxSpeed = session.maxSpeedKmh;
    // Cheap — dashcamSessionVideos is a plain (eager, non-lazy) Box, so this
    // is a hashmap lookup already resident in memory, never a disk read
    // (Fase 15 §6: "não carregar o vídeo inteiro em memória").
    final hasVideo = Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(session.id);
    final colorScheme = Theme.of(context).colorScheme;
    // Fase 16.2-R4.3-R2.6.6: what this tile SHOWS; the deletion itself is
    // checked again by deleteDrivingSession when it runs.
    final controlled = DrivingSessionRecorder.controllingState(session.id);
    // Fase 16.2-R4.3-R2.6.7: a deletion that did not finish keeps the record,
    // marked; swiping it runs the (idempotent) deletion again.
    final note = controlled != null
        ? _pendingLabel(controlled)
        : session.deletionPending
            ? 'Exclusão pendente — deslize para concluir'
            : null;
    // Fase 16.2-R4.3-R2.6.11: what was lost, as recorded on this session. Text
    // only: nothing here can bring a telemetry file back, so there is no
    // action to offer.
    final telemetryNote = session.dashcamTelemetryOutcome == DashcamTelemetryOutcome.failed
        ? 'Telemetria da dashcam ${dashcamTelemetryOutcomeSummary(session)}'
        : null;
    final notes = [?note, ?telemetryNote];
    return Dismissible(
      key: ValueKey(session.id),
      direction: controlled == null ? DismissDirection.endToStart : DismissDirection.none,
      confirmDismiss: (_) => _confirmAndDelete(context),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Theme.of(context).colorScheme.error,
        child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onError),
      ),
      child: ListTile(
        leading: hasVideo
            ? Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.route),
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Icon(Icons.videocam, size: 14, color: colorScheme.primary),
                  ),
                ],
              )
            : const Icon(Icons.route),
        title: Text(_formatDate(session.startTime)),
        isThreeLine: notes.isNotEmpty,
        subtitle: Text(
          '${_formatDuration(session.duration)} · ${(session.distanceMeters / 1000).toStringAsFixed(1)} km'
          '${maxSpeed == null ? '' : ' · máx ${convertSpeedFromKmh(maxSpeed, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}'}'
          '${[for (final n in notes) '\n$n'].join()}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SessionDetailScreen(session: session)),
        ),
      ),
    );
  }
}
