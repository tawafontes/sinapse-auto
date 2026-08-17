import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/driving_session.dart';
import '../../models/unit_system.dart';
import '../../services/driving_session_recorder.dart' show deleteDrivingSession;
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
/// any individual session has accumulated. Uses a [ValueListenableBuilder]
/// over the box itself so a session started/finished elsewhere in the app
/// (or finalized from this same session) updates the list live, with no
/// manual refresh needed.
class SessionHistoryScreen extends StatelessWidget {
  const SessionHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
    return Scaffold(
      appBar: AppBar(title: const Text('Histórico')),
      body: SafeArea(
        child: ValueListenableBuilder<Box<DrivingSession>>(
          valueListenable: box.listenable(),
          builder: (context, box, _) {
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

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferencesScope.of(context);
    final maxSpeed = session.maxSpeedKmh;
    // Cheap — dashcamSessionVideos is a plain (eager, non-lazy) Box, so this
    // is a hashmap lookup already resident in memory, never a disk read
    // (Fase 15 §6: "não carregar o vídeo inteiro em memória").
    final hasVideo = Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(session.id);
    final colorScheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => deleteDrivingSession(session.id),
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
        subtitle: Text(
          '${_formatDuration(session.duration)} · ${(session.distanceMeters / 1000).toStringAsFixed(1)} km'
          '${maxSpeed == null ? '' : ' · máx ${convertSpeedFromKmh(maxSpeed, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}'}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SessionDetailScreen(session: session)),
        ),
      ),
    );
  }
}
