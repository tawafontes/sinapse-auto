import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../models/dashcam_clip_record.dart';
import '../../services/dashcam_gallery_exporter.dart';
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

/// Where a deletion removes videos from (owner decision, 2026-11-14: deleting
/// a video asks whether its gallery copy goes too).
enum _DeleteScope { appOnly, appAndGallery }

/// "Gravações" — a shortcut to every dashcam clip, without going through
/// Histórico → session → "Vídeo" (the last of eight tabs). Tapping a clip
/// opens the same [DashcamPlaybackScreen] that tab opens. Reached from
/// Settings and from the dashcam's own fullscreen view.
///
/// Several videos, or all of them, can be deleted at once (owner decision,
/// 2026-11-14): a long press (or "Selecionar") starts a selection; "Excluir
/// todos" is in the menu. Every deletion asks whether the gallery copies go
/// too.
class DashcamRecordingsScreen extends StatefulWidget {
  const DashcamRecordingsScreen({super.key, this.galleryExporter = const MethodChannelDashcamGalleryExporter()});

  /// Removes the gallery copies when the user asks for it.
  final DashcamGalleryExporter galleryExporter;

  @override
  State<DashcamRecordingsScreen> createState() => _DashcamRecordingsScreenState();
}

class _DashcamRecordingsScreenState extends State<DashcamRecordingsScreen> {
  late List<DashcamRecordingEntry> _entries = loadDashcamRecordings();

  /// The selected clips, by file path; `null` when not selecting.
  Set<String>? _selected;
  bool _deleting = false;

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _formatDay(DateTime dt) => '${_two(dt.day)}/${_two(dt.month)}/${dt.year}';

  static String _formatTime(DateTime dt) => '${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}';

  static String _formatDuration(int seconds) => '${_two(seconds ~/ 60)}:${_two(seconds % 60)}';

  static String _formatSize(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  void _startSelection([DashcamRecordingEntry? first]) => setState(() => _selected = {if (first != null) first.clip.filePath});

  void _endSelection() => setState(() => _selected = null);

  void _toggle(DashcamRecordingEntry entry) {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      if (!selected.remove(entry.clip.filePath)) selected.add(entry.clip.filePath);
    });
  }

  void _selectAll() => setState(() => _selected = {for (final e in _entries) e.clip.filePath});

  Future<_DeleteScope?> _askScope(List<DashcamRecordingEntry> entries) {
    final one = entries.length == 1;
    final protectedCount = entries.where((e) => e.clip.isProtected).length;
    final String what;
    if (one) {
      final local = entries.single.clip.recordedAt.toLocal();
      what = 'O vídeo de ${_formatDay(local)} às ${_formatTime(local)} será apagado do app'
          '${protectedCount > 0 ? ', mesmo estando protegido' : ''}.';
    } else {
      what = 'Os ${entries.length} vídeos serão apagados do app'
          '${protectedCount > 0 ? ', inclusive $protectedCount protegido${protectedCount > 1 ? 's' : ''}' : ''}.';
    }
    final gallery = widget.galleryExporter.isSupported;
    return showDialog<_DeleteScope>(
      context: context,
      builder: (dialogContext) {
        final danger = FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error);
        return AlertDialog(
          title: Text(one ? 'Excluir este vídeo?' : 'Excluir ${entries.length} vídeos?'),
          content: Text(gallery ? '$what\n\nApagar também ${one ? 'a cópia' : 'as cópias'} na galeria do celular?' : what),
          actions: [
            TextButton(key: const ValueKey('recordingsDelete_cancel'), onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancelar')),
            if (gallery)
              OutlinedButton(
                key: const ValueKey('recordingsDelete_appOnly'),
                onPressed: () => Navigator.of(dialogContext).pop(_DeleteScope.appOnly),
                child: const Text('Só do app'),
              ),
            FilledButton(
              key: const ValueKey('recordingsDelete_confirm'),
              style: danger,
              onPressed: () => Navigator.of(dialogContext).pop(gallery ? _DeleteScope.appAndGallery : _DeleteScope.appOnly),
              child: Text(gallery ? 'Do app e da galeria' : 'Excluir'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _delete(List<DashcamRecordingEntry> entries) async {
    if (entries.isEmpty || _deleting) return;
    final scope = await _askScope(entries);
    if (scope == null || !mounted) return;
    setState(() => _deleting = true);
    var deleted = 0;
    var active = 0;
    var failed = 0;
    var indexLagging = 0;
    final galleryNames = <String>[];
    for (final entry in entries) {
      try {
        final outcome = await deleteDashcamClipByUser(sessionId: entry.sessionId, filePath: entry.clip.filePath);
        switch (outcome) {
          case DashcamClipDeletionOutcome.deleted || DashcamClipDeletionOutcome.notIndexed:
            deleted++;
            galleryNames.add(dashcamGalleryDisplayName(entry.clip.recordedAt));
          case DashcamClipDeletionOutcome.entryFailed:
            deleted++;
            indexLagging++;
            galleryNames.add(dashcamGalleryDisplayName(entry.clip.recordedAt));
          case DashcamClipDeletionOutcome.fileFailed:
            failed++;
        }
      } on DashcamClipDeletionRejected {
        active++;
      }
    }
    GalleryDeletion? gallery;
    String? galleryError;
    if (scope == _DeleteScope.appAndGallery && galleryNames.isNotEmpty) {
      try {
        gallery = await widget.galleryExporter.deleteVideos(galleryNames);
      } on Object catch (e) {
        galleryError = '$e';
      }
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selected = null;
      _entries = loadDashcamRecordings();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_summary(
        total: entries.length,
        deleted: deleted,
        active: active,
        failed: failed,
        indexLagging: indexLagging,
        gallery: gallery,
        galleryError: galleryError,
      )),
    ));
  }

  static String _summary({
    required int total,
    required int deleted,
    required int active,
    required int failed,
    required int indexLagging,
    GalleryDeletion? gallery,
    String? galleryError,
  }) {
    final parts = <String>[
      if (total == 1 && deleted == 1) 'Vídeo excluído.' else if (deleted > 0) '$deleted vídeo${deleted > 1 ? 's' : ''} excluído${deleted > 1 ? 's' : ''}.',
      if (active > 0)
        total == 1
            ? 'Este vídeo é de uma sessão em andamento. Finalize a sessão antes de excluí-lo.'
            : '$active de uma sessão em andamento ficaram (finalize a sessão antes).',
      if (failed > 0) total == 1 ? 'Não foi possível apagar o arquivo do vídeo. Tente novamente.' : '$failed não puderam ser apagados; tente novamente.',
      if (indexLagging > 0) 'A lista termina de se atualizar na próxima abertura do app.',
      if (gallery != null && gallery.deleted > 0) 'Galeria: ${gallery.deleted} cópia${gallery.deleted > 1 ? 's' : ''} apagada${gallery.deleted > 1 ? 's' : ''}.',
      if (gallery != null && gallery.denied > 0) 'Galeria: ${gallery.denied} não autorizada${gallery.denied > 1 ? 's' : ''}.',
      if (gallery != null && gallery.deleted == 0 && gallery.denied == 0) 'Nenhuma cópia na galeria.',
      if (galleryError != null) 'Não foi possível apagar da galeria.',
    ];
    return parts.join(' ');
  }

  Future<void> _open(DashcamRecordingEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DashcamPlaybackScreen(clip: entry.clip, sessionId: entry.sessionId)),
    );
    // The storage quota may have evicted old clips meanwhile.
    if (mounted) setState(() => _entries = loadDashcamRecordings());
  }

  PreferredSizeWidget _appBar() {
    final selected = _selected;
    if (selected == null) {
      return AppBar(
        title: const Text('Gravações'),
        actions: [
          if (_entries.isNotEmpty) ...[
            IconButton(key: const ValueKey('recordings_select'), icon: const Icon(Icons.checklist), tooltip: 'Selecionar', onPressed: _startSelection),
            PopupMenuButton<String>(
              key: const ValueKey('recordings_menu'),
              onSelected: (value) {
                if (value == 'deleteAll') _delete(_entries);
              },
              itemBuilder: (context) => const [PopupMenuItem(value: 'deleteAll', child: Text('Excluir todos'))],
            ),
          ],
        ],
      );
    }
    final picked = [for (final e in _entries) if (selected.contains(e.clip.filePath)) e];
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Cancelar seleção', onPressed: _endSelection),
      title: Text(picked.isEmpty ? 'Selecione os vídeos' : '${picked.length} selecionado${picked.length > 1 ? 's' : ''}'),
      actions: [
        IconButton(key: const ValueKey('recordings_selectAll'), icon: const Icon(Icons.select_all), tooltip: 'Selecionar todos', onPressed: _selectAll),
        IconButton(
          key: const ValueKey('recordings_deleteSelected'),
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Excluir selecionados',
          onPressed: picked.isEmpty ? null : () => _delete(picked),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final selected = _selected;
    return PopScope(
      // Back ends a selection first, like the system gallery.
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endSelection();
      },
      child: Scaffold(
        appBar: _appBar(),
        body: SafeArea(
          child: Stack(
            children: [
              if (entries.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Nenhuma gravação ainda.\nInicie uma sessão com a Dashcam ativada para gravar.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                )
              else
                ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final local = entry.clip.recordedAt.toLocal();
                    final day = _formatDay(local);
                    final newDay = index == 0 || _formatDay(entries[index - 1].clip.recordedAt.toLocal()) != day;
                    final isSelected = selected?.contains(entry.clip.filePath) ?? false;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (newDay)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                            child: Text(day, style: Theme.of(context).textTheme.titleSmall),
                          ),
                        ListTile(
                          key: ValueKey('recording_${entry.clip.filePath}'),
                          selected: isSelected,
                          leading: selected != null
                              ? Checkbox(value: isSelected, onChanged: (_) => _toggle(entry))
                              : Icon(entry.clip.isProtected ? Icons.shield : Icons.videocam),
                          title: Text(_formatTime(local)),
                          subtitle: Text('${_formatDuration(entry.clip.durationSeconds)} · ${_formatSize(entry.clip.sizeBytes)}'),
                          trailing: selected != null
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Excluir vídeo',
                                  onPressed: () => _delete([entry]),
                                ),
                          onTap: selected != null ? () => _toggle(entry) : () => _open(entry),
                          onLongPress: selected != null ? null : () => _startSelection(entry),
                        ),
                      ],
                    );
                  },
                ),
              if (_deleting) const Positioned.fill(child: ColoredBox(color: Color(0x33000000), child: Center(child: CircularProgressIndicator()))),
            ],
          ),
        ),
      ),
    );
  }
}
