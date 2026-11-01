import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_clip_descriptor.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/services/dashcam_clip_files.dart';

// Fase 16.2-R4.4-R1 — the promotion of a finished recording to its canonical
// name (design closure, PROMOTION PROTOCOL / COLLISIONS / PARTIAL FILE), on a
// real temporary filesystem: `rename(2)` first; the copy into an exclusive
// `.partial` only for a cross-device rename; never an overwrite; the final
// name only ever appears complete. Faults are injected at single operations
// through [DashcamClipFileOps].
void main() {
  late Directory root;
  late Directory cache;
  late Directory clips;
  late String name;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dashcam_clip_promotion_test');
    cache = Directory('${root.path}/cache')..createSync();
    clips = Directory('${root.path}/dashcam_clips')..createSync();
    name = DashcamClipDescriptor.tryCreate(
      sessionId: 'S-${DateTime.now().microsecondsSinceEpoch}',
      recordedAt: DateTime.now(),
      namespace: 'fedcba9876543210fedcba9876543210',
      recordingId: 1,
      durationSeconds: 3,
      isProtected: false,
      resolution: VideoResolution.hd720,
      audioEnabled: false,
    )!.basename;
    DashcamClipStorageCounters.resetForTest();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A finished recording in the "cache", like the plugin's `REC*.mp4`.
  File recording({int size = 300 * 1024}) => File('${cache.path}/REC${DateTime.now().microsecondsSinceEpoch}.mp4')
    ..writeAsBytesSync([for (var i = 0; i < size; i++) i % 251]);

  String finalPath() => '${clips.path}/$name';
  String partialPath() => '${finalPath()}${DashcamClipDescriptor.partialSuffix}';
  List<String> clipNames() => (clips.listSync().map((e) => dashcamClipBasename(e.path)).toList())..sort();

  FileSystemException crossDevice(String from) => FileSystemException('Cannot rename file', from, OSError('Invalid cross-device link', Platform.isWindows ? 17 : 18));

  group('Fase 16.2-R4.4-R1 — promotion: rename', () {
    test('X422 — the recording is RENAMED to its canonical name: same bytes, one file, the source gone (no twin left in the cache), nothing else in the directory', () async {
      final source = recording();
      final bytes = source.readAsBytesSync();
      final promotion = await promoteDashcamClip(sourcePath: source.path, directory: clips, name: name);
      expect(promotion, isNotNull);
      expect(promotion!.placement, DashcamClipPlacement.renamed);
      expect(promotion.file.path, finalPath());
      expect(promotion.sizeBytes, bytes.length);
      expect(promotion.sourceResidue, isFalse);
      expect(File(finalPath()).readAsBytesSync(), bytes);
      expect(source.existsSync(), isFalse, reason: 'moved, not copied');
      expect(clipNames(), [name], reason: 'the canonical name and nothing else — no partial');
      expect(DashcamClipDescriptor.parse(dashcamClipBasename(promotion.file.path)), isNotNull, reason: 'what was published is canonical');
      expect(DashcamClipStorageCounters.snapshot(), containsPair('promotionsRenamed', 1));
    });

    test('X423 — destination collision: a file, or a directory, already under the canonical name is never overwritten — nothing published, the source where it was, the occupant untouched', () async {
      final source = recording();
      File(finalPath()).writeAsBytesSync([42, 42]);
      await expectLater(promoteDashcamClip(sourcePath: source.path, directory: clips, name: name), throwsA(isA<DashcamClipCollision>()));
      expect(File(finalPath()).readAsBytesSync(), [42, 42]);
      expect(source.existsSync(), isTrue);
      expect(clipNames(), [name]);

      File(finalPath()).deleteSync();
      Directory(finalPath()).createSync();
      await expectLater(promoteDashcamClip(sourcePath: source.path, directory: clips, name: name), throwsA(isA<DashcamClipCollision>()));
      expect(Directory(finalPath()).existsSync(), isTrue);
      expect(source.existsSync(), isTrue);
      expect(DashcamClipStorageCounters.collisions, 2);
    });

    test('X424 — retry: after a rename that failed the source is intact and a new attempt publishes it; after a SUCCESSFUL promotion a second attempt finds no source and fails without touching the canonical file (there is no promotion retry in R1 — the index converges instead)', () async {
      final source = recording();
      final bytes = source.readAsBytesSync();
      final failing = _Ops(onRename: (from, to) async => throw FileSystemException('Cannot rename file', from, const OSError('Permission denied', 13)));
      await expectLater(promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: failing), throwsA(isA<FileSystemException>()));
      expect(source.existsSync(), isTrue);
      expect(clipNames(), isEmpty);

      final promotion = await promoteDashcamClip(sourcePath: source.path, directory: clips, name: name);
      expect(promotion!.placement, DashcamClipPlacement.renamed);
      await expectLater(promoteDashcamClip(sourcePath: source.path, directory: clips, name: name), throwsA(isA<FileSystemException>()));
      expect(File(finalPath()).readAsBytesSync(), bytes, reason: 'the published clip is untouched by the failed retry');
      expect(clipNames(), [name]);
    });

    test('X425 — a rename failure that is NOT a filesystem boundary (EACCES, ENOENT, ENOSPC, EIO) is the promotion\'s failure: rethrown as is, the source intact, no copy attempted, no partial, nothing published', () async {
      for (final errno in [13, 2, 28, 5]) {
        final source = recording(size: 4096);
        final ops = _Ops(onRename: (from, to) async => throw FileSystemException('Cannot rename file', from, OSError('injected', errno)));
        Object? error;
        try {
          await promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: ops);
        } catch (e) {
          error = e;
        }
        expect(error, isA<FileSystemException>().having((e) => e.osError?.errorCode, 'errno', errno));
        expect(source.existsSync(), isTrue, reason: 'errno $errno');
        expect(ops.log, isNot(contains('createExclusive')), reason: 'errno $errno: no fallback copy');
        expect(clipNames(), isEmpty, reason: 'errno $errno');
      }
      expect(isCrossDeviceRenameFailure(crossDevice('x')), isTrue);
      expect(isCrossDeviceRenameFailure(const FileSystemException('x', 'x', OSError('x', 13))), isFalse);
      expect(isCrossDeviceRenameFailure(const FileSystemException('x')), isFalse);
    });

    test('X426 — an EMPTY recording (0 bytes) is not published, not indexed and not deleted: null, the file stays where it was; a missing source fails', () async {
      final empty = File('${cache.path}/REC_empty.mp4')..writeAsBytesSync(const []);
      expect(await promoteDashcamClip(sourcePath: empty.path, directory: clips, name: name), isNull);
      expect(empty.existsSync(), isTrue);
      expect(clipNames(), isEmpty);
      expect(DashcamClipStorageCounters.emptySources, 1);
      await expectLater(promoteDashcamClip(sourcePath: '${cache.path}/REC_missing.mp4', directory: clips, name: name), throwsA(isA<FileSystemException>()));
      expect(clipNames(), isEmpty);
    });
  });

  group('Fase 16.2-R4.4-R1 — promotion: cross-filesystem fallback', () {
    test('X427 — a cross-device rename falls back to copy → <canonical>.partial (created exclusively) → flush → close → rename to the final name → delete the source; the final name never exists before its content is complete', () async {
      final source = recording(size: 300 * 1024 + 17);
      final bytes = source.readAsBytesSync();
      final finalSeenDuringCopy = <bool>[];
      late _Ops ops;
      ops = _Ops(
        onRename: (from, to) async {
          if (from == source.path) throw crossDevice(from);
          await File(from).rename(to);
        },
        onWrite: (_) => finalSeenDuringCopy.add(File(finalPath()).existsSync()),
      );
      final promotion = await promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: ops);
      expect(promotion!.placement, DashcamClipPlacement.copied);
      expect(promotion.sourceResidue, isFalse);
      expect(File(finalPath()).readAsBytesSync(), bytes);
      expect(source.existsSync(), isFalse, reason: 'deleted once the final file was in place');
      expect(clipNames(), [name], reason: 'no partial left');
      expect(finalSeenDuringCopy, isNotEmpty);
      expect(finalSeenDuringCopy, everyElement(isFalse), reason: 'the final name did not exist while its content was being copied');
      final order = ops.log.where((op) => op != 'write').toList();
      expect(order, [
        'stat',
        'isOccupied:final',
        'rename:source',
        'createExclusive',
        'openForAppend',
        'flush',
        'close',
        'isOccupied:final',
        'rename:partial',
        'delete:source',
      ]);
      expect(DashcamClipStorageCounters.promotionsCopied, 1);
    });

    test('X428 — the copy fails half way, the flush fails, the close fails, the final rename fails: nothing published, the partial THIS promotion created is removed, the source is intact', () async {
      for (final failAt in ['write', 'flush', 'close', 'renamePartial']) {
        final source = recording(size: 200 * 1024);
        var writes = 0;
        final ops = _Ops(
          onRename: (from, to) async {
            if (from == source.path) throw crossDevice(from);
            if (failAt == 'renamePartial') throw FileSystemException('injected final rename failure', from, const OSError('injected', 5));
            await File(from).rename(to);
          },
          onWrite: (_) {
            if (failAt == 'write' && ++writes == 2) throw FileSystemException('injected write failure', partialPath(), const OSError('No space left on device', 28));
          },
          onFlush: () {
            if (failAt == 'flush') throw FileSystemException('injected flush failure', partialPath(), const OSError('I/O error', 5));
          },
          onClose: () {
            if (failAt == 'close') throw FileSystemException('injected close failure', partialPath(), const OSError('I/O error', 5));
          },
        );
        await expectLater(promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: ops), throwsA(isA<FileSystemException>()), reason: failAt);
        expect(File(finalPath()).existsSync(), isFalse, reason: '$failAt: nothing published');
        expect(File(partialPath()).existsSync(), isFalse, reason: '$failAt: its own partial removed');
        expect(source.existsSync(), isTrue, reason: '$failAt: the source intact');
        expect(source.lengthSync(), 200 * 1024, reason: failAt);
      }
    });

    test('X429 — a residual partial (someone else\'s, or a killed promotion\'s) is never truncated nor reused: the fallback stops with a collision, the partial keeps its bytes, the source is intact', () async {
      final source = recording();
      File(partialPath()).writeAsBytesSync([7, 7, 7]);
      final ops = _Ops(onRename: (from, to) async => throw crossDevice(from));
      await expectLater(promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: ops), throwsA(isA<DashcamClipCollision>()));
      expect(File(partialPath()).readAsBytesSync(), [7, 7, 7]);
      expect(File(finalPath()).existsSync(), isFalse);
      expect(source.existsSync(), isTrue);
    });

    test('X430 — the final name gets occupied while the copy runs: the partial is not renamed over it (collision), the occupant is untouched, the partial removed, the source intact', () async {
      final source = recording();
      final ops = _Ops(
        onRename: (from, to) async => from == source.path ? throw crossDevice(from) : await File(from).rename(to),
        onFlush: () => File(finalPath()).writeAsBytesSync([9]),
      );
      await expectLater(promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: ops), throwsA(isA<DashcamClipCollision>()));
      expect(File(finalPath()).readAsBytesSync(), [9]);
      expect(File(partialPath()).existsSync(), isFalse);
      expect(source.existsSync(), isTrue);
    });

    test('X431 — the source cannot be deleted after the final file is in place: the promotion stands (a reported twin — sourceResidue), the final file is complete, no second identity', () async {
      final source = recording();
      final bytes = source.readAsBytesSync();
      final ops = _Ops(
        onRename: (from, to) async => from == source.path ? throw crossDevice(from) : await File(from).rename(to),
        onDelete: (path) async {
          if (path == source.path) throw FileSystemException('injected delete failure', path, const OSError('Permission denied', 13));
          await File(path).delete();
        },
      );
      final promotion = await promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: ops);
      expect(promotion!.placement, DashcamClipPlacement.copied);
      expect(promotion.sourceResidue, isTrue);
      expect(File(finalPath()).readAsBytesSync(), bytes);
      expect(source.existsSync(), isTrue, reason: 'the twin is left, and reported');
      expect(clipNames(), [name]);
      expect(DashcamClipStorageCounters.sourceResidues, 1);
    });

    test('X432 — a failed fallback whose partial cannot be removed PRESERVES it and says so; nothing is published and the source is intact', () async {
      final source = recording();
      final ops = _Ops(
        onRename: (from, to) async => throw crossDevice(from),
        onFlush: () => throw FileSystemException('injected flush failure', partialPath(), const OSError('I/O error', 5)),
        onDelete: (path) async => throw FileSystemException('injected delete failure', path, const OSError('Permission denied', 13)),
      );
      Object? error;
      try {
        await promoteDashcamClip(sourcePath: source.path, directory: clips, name: name, ops: ops);
      } catch (e) {
        error = e;
      }
      expect(error, isA<FileSystemException>().having((e) => e.message, 'message', contains('preserved')));
      expect(File(partialPath()).existsSync(), isTrue);
      expect(File(finalPath()).existsSync(), isFalse);
      expect(source.existsSync(), isTrue);
      expect(DashcamClipStorageCounters.partialsPreserved, 1);
    });
  });
}

/// The real operations, with single ones replaced or observed; [log] records
/// the order.
class _Ops extends DashcamClipFileOps {
  _Ops({this.onRename, this.onDelete, this.onWrite, this.onFlush, this.onClose});

  final Future<void> Function(String from, String to)? onRename;
  final Future<void> Function(String path)? onDelete;
  final void Function(List<int> bytes)? onWrite;
  final void Function()? onFlush;
  final void Function()? onClose;
  final List<String> log = [];

  String _role(String path) => path.endsWith(DashcamClipDescriptor.partialSuffix)
      ? 'partial'
      : path.contains('dashcam_clips')
      ? 'final'
      : 'source';

  @override
  Future<FileStat> stat(String path) {
    log.add('stat');
    return super.stat(path);
  }

  @override
  Future<bool> isOccupied(String path) {
    log.add('isOccupied:${_role(path)}');
    return super.isOccupied(path);
  }

  @override
  Future<void> rename(String from, String to) {
    log.add('rename:${_role(from)}');
    final hook = onRename;
    return hook != null ? hook(from, to) : super.rename(from, to);
  }

  @override
  Future<void> createExclusive(String path) {
    log.add('createExclusive');
    return super.createExclusive(path);
  }

  @override
  Future<DashcamClipPartialSink> openForAppend(String path) async {
    log.add('openForAppend');
    return _ObservedSink(await super.openForAppend(path), this);
  }

  @override
  Future<void> delete(String path) {
    log.add('delete:${_role(path)}');
    final hook = onDelete;
    return hook != null ? hook(path) : super.delete(path);
  }
}

class _ObservedSink implements DashcamClipPartialSink {
  _ObservedSink(this._inner, this._ops);

  final DashcamClipPartialSink _inner;
  final _Ops _ops;

  @override
  Future<void> write(List<int> bytes) async {
    _ops.log.add('write');
    _ops.onWrite?.call(bytes);
    await _inner.write(bytes);
  }

  @override
  Future<void> flush() async {
    _ops.log.add('flush');
    _ops.onFlush?.call();
    await _inner.flush();
  }

  @override
  Future<void> close() async {
    _ops.log.add('close');
    // The real handle is closed first: a failure REPORTED by close, not a
    // handle left open (on Windows that would also keep the partial from
    // being deleted — a different case, X432).
    await _inner.close();
    _ops.onClose?.call();
  }
}
