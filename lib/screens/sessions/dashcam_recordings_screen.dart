import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../models/dashcam_clip_record.dart';
import '../../services/dashcam_storage_quota.dart' show DashcamClipDeletionOutcome, DashcamClipDeletionRejected, deleteDashcamClipByUser;
import '../../services/hive_boxes.dart';
import 'dashcam_playback_screen.dart';

/// One indexed clip and the session whose index holds it.
@visibleForTesting
typedef DashcamRecordingEntry = ({String sessionId, DashcamClipRecord clip});

/// Every indexed clip of every session, newest first — read from the clip
/// index (`dashcam_session_videos`: session id → its clips), the same source
/// the session detail's "Vídeo" tab reads one session from. Read-only.
@visibleForTesting
List<DashcamRecordingEntry> loadDashcamRecordings() {
  final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
  final entries = <DashcamRecordingEntry>[
    for (final key in box.keys)
      if (key is String)
        for (final clip in (box.get(key) as List?) ?? const []) (sessionId: key, clip: clip as DashcamClipRecord),
  ];
  entries.sort((a, b) => b.clip.recordedAt.compareTo(a.clip.recordedAt));
  return entries;
}

/// "Gravações" — a shortcut to every dashcam clip, without going through
/// Histórico → session → "Vídeo" (the last of eight tabs). Tapping a clip
/// opens the same [DashcamPlaybackScreen] that tab opens. Reached from
/// Settings and from the dashcam's own fullscreen view.
class DashcamRecordingsScreen extends StatefulWidget {
  const DashcamRecordingsScreen({super.key});

  @override
  State<DashcamRecordingsScreen> createState() => _DashcamRecordingsScreenState();
}

class _DashcamRecordingsScreenState extends State<DashcamRecordingsScreen> {
  late List<DashcamRecordingEntry> _entries = loadDashcamRecordings();

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _formatDay(DateTime dt) => '${_two(dt.day)}/${_two(dt.month)}/${dt.year}';

  static String _formatTime(DateTime dt) => '${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}';

  static String _formatDuration(int seconds) => '${_two(seconds ~/ 60)}:${_two(seconds % 60)}';

  static String _formatSize(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  Future<void> _delete(DashcamRecordingEntry entry) async {
    final local = entry.clip.recordedAt.toLocal();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir este vídeo?'),
        content: Text(
          'O vídeo de ${_formatDay(local)} às ${_formatTime(local)} será apagado do app'
          '${entry.clip.isProtected ? ', mesmo estando protegido' : ''}. '
          'A cópia na galeria do celular, se houver, não é apagada.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    String message;
    try {
      final outcome = await deleteDashcamClipByUser(sessionId: entry.sessionId, filePath: entry.clip.filePath);
      message = switch (outcome) {
        DashcamClipDeletionOutcome.deleted || DashcamClipDeletionOutcome.notIndexed => 'Vídeo excluído.',
        DashcamClipDeletionOutcome.fileFailed => 'Não foi possível apagar o arquivo do vídeo. Tente novamente.',
        DashcamClipDeletionOutcome.entryFailed => 'Vídeo apagado; a lista termina de se atualizar na próxima abertura do app.',
      };
    } on DashcamClipDeletionRejected {
      message = 'Este vídeo é de uma sessão em andamento. Finalize a sessão antes de excluí-lo.';
    }
    if (!mounted) return;
    setState(() => _entries = loadDashcamRecordings());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(DashcamRecordingEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DashcamPlaybackScreen(clip: entry.clip, sessionId: entry.sessionId)),
    );
    // The storage quota may have evicted old clips meanwhile.
    if (mounted) setState(() => _entries = loadDashcamRecordings());
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Gravações')),
      body: SafeArea(
        child: entries.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Nenhuma gravação ainda.\nInicie uma sessão com a Dashcam ativada para gravar.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final local = entry.clip.recordedAt.toLocal();
                  final day = _formatDay(local);
                  final newDay = index == 0 || _formatDay(entries[index - 1].clip.recordedAt.toLocal()) != day;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (newDay)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(day, style: Theme.of(context).textTheme.titleSmall),
                        ),
                      ListTile(
                        leading: Icon(entry.clip.isProtected ? Icons.shield : Icons.videocam),
                        title: Text(_formatTime(local)),
                        subtitle: Text('${_formatDuration(entry.clip.durationSeconds)} · ${_formatSize(entry.clip.sizeBytes)}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Excluir vídeo',
                          onPressed: () => _delete(entry),
                        ),
                        onTap: () => _open(entry),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
