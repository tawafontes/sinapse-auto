import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../models/dashcam_clip_descriptor.dart';

/// Fase 16.2-R4.4-R1 — the clip files on disk: where they live, how one is
/// published there ([promoteDashcamClip]) and how the directory is read back
/// ([listDashcamClipsDirectory]). No Hive and no session logic: the clip index
/// (`dashcam_clip_index.dart`), the session deletion
/// (`driving_session_recorder.dart`) and `DashcamService` all build on it, in
/// one direction.

const dashcamClipsDirectoryName = 'dashcam_clips';

/// `<documents>/dashcam_clips` — resolved, not created. `DashcamService`
/// resolves (and creates) it once per instance; the index and the deletion
/// resolve it when they need it.
Future<Directory> dashcamClipsDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory('${documents.path}/$dashcamClipsDirectoryName');
}

/// Whether anything at all — file, directory, or a link, even a dangling one —
/// is under [path]; i.e. `lstat(path)` succeeds.
///
/// Not `FileSystemEntity.type(path, followLinks: false)`: inside any
/// `IOOverrides` zone that does not override `fseGetType` it answers
/// `notFound` for an existing file (the SDK's default override hands the
/// native call a UTF-8 path without its terminating NUL; reproduced in this
/// round, `scratchpad/fase16_2_r4_4_r1_implementation/01_dev/probes/
/// fse_type_probe_test.dart`). No such zone exists in the app, but tests run
/// the whole app inside one, and a collision check that silently answered
/// "free" there would test nothing. `FileStat.stat` and `Link.exists` go
/// through the entity's own NUL-terminated path.
Future<bool> dashcamClipPathOccupied(String path) async =>
    (await FileStat.stat(path)).type != FileSystemEntityType.notFound || await Link(path).exists();

/// Whether [path] is a regular file — not a directory and not a link (to a
/// file or not) — and its size; `null` otherwise. See [dashcamClipPathOccupied]
/// for why not `FileSystemEntity.type`.
Future<int?> dashcamClipRegularFileSize(String path) async {
  final stat = await FileStat.stat(path);
  if (stat.type != FileSystemEntityType.file || await Link(path).exists()) return null;
  return stat.size;
}

/// The last path segment. On Android/Linux only `/` separates — a `\` is an
/// ordinary character of a name there, and splitting on it would let
/// `x\clip_v1_….mp4` pass for a canonical name.
String dashcamClipBasename(String path) {
  var cut = path.lastIndexOf('/');
  if (Platform.isWindows) {
    final backslash = path.lastIndexOf(r'\');
    if (backslash > cut) cut = backslash;
  }
  return path.substring(cut + 1);
}

/// How a promoted clip reached its canonical name.
enum DashcamClipPlacement {
  /// `rename(2)` of the recording's own file — atomic, no copy, no twin left.
  renamed,

  /// The cross-filesystem fallback: copied into `<canonical>.partial`, flushed,
  /// closed, and only then renamed to the canonical name.
  copied,
}

/// A clip published under its canonical name: from the instant this exists, a
/// process death no longer loses the clip — the next start indexes it.
class DashcamClipPromotion {
  const DashcamClipPromotion({required this.file, required this.sizeBytes, required this.placement, this.sourceResidue = false});

  final File file;
  final int sizeBytes;
  final DashcamClipPlacement placement;

  /// [DashcamClipPlacement.copied] only: the source could not be deleted after
  /// the canonical file was in place — a twin left in the cache (reported; the
  /// promotion stands, and no second identity is ever made for it).
  final bool sourceResidue;
}

/// The canonical name (or the fallback's `.partial`) is already taken. Nothing
/// was overwritten and nothing was published; the source is where it was.
class DashcamClipCollision implements Exception {
  const DashcamClipCollision(this.name);

  final String name;

  @override
  String toString() => 'DashcamClipCollision: "$name" already exists in $dashcamClipsDirectoryName — nothing was overwritten, the recording stays where it was';
}

/// The filesystem operations of a promotion — the real `dart:io` calls. A test
/// replaces single ones to fail exactly there (a cross-device rename, a copy, a
/// flush, a close, the final rename, the source's deletion).
class DashcamClipFileOps {
  const DashcamClipFileOps();

  /// Follows links: the source is the plugin's file.
  Future<FileStat> stat(String path) => FileStat.stat(path);

  /// Whether ANYTHING is under [path] — file, directory, or a link, dangling or
  /// not: a name taken like any other.
  Future<bool> isOccupied(String path) => dashcamClipPathOccupied(path);

  Future<void> rename(String from, String to) => File(from).rename(to);

  /// Fails when [path] exists — nothing preexisting is ever truncated.
  Future<void> createExclusive(String path) => File(path).create(exclusive: true);

  Stream<List<int>> read(String path) => File(path).openRead();

  /// Appends to [path] (just created empty by [createExclusive]).
  Future<DashcamClipPartialSink> openForAppend(String path) async => _RandomAccessFileSink(await File(path).open(mode: FileMode.writeOnlyAppend));

  Future<void> delete(String path) => File(path).delete();
}

/// What the copy of the fallback writes to.
abstract interface class DashcamClipPartialSink {
  Future<void> write(List<int> bytes);

  /// [RandomAccessFile.flush]: down to the device (fsync), unlike
  /// `IOSink.flush`.
  Future<void> flush();

  Future<void> close();
}

class _RandomAccessFileSink implements DashcamClipPartialSink {
  _RandomAccessFileSink(this._file);

  final RandomAccessFile _file;

  @override
  Future<void> write(List<int> bytes) => _file.writeFrom(bytes);

  @override
  Future<void> flush() => _file.flush();

  @override
  Future<void> close() => _file.close();
}

/// The `errno` of a rename that crossed a filesystem boundary: `EXDEV` (18) on
/// Linux/Android/Darwin — also raised between directories of one filesystem
/// whose fscrypt policies differ — and `ERROR_NOT_SAME_DEVICE` (17) on Windows.
/// The fallback copy runs for this and for nothing else: any other failure
/// (ENOENT, EACCES, ENOSPC, EIO…) leaves the source where it was and is the
/// promotion's failure.
bool isCrossDeviceRenameFailure(FileSystemException error) => error.osError?.errorCode == (Platform.isWindows ? 17 : 18);

/// Process-wide counters of clip storage events — the minimal observability of
/// R4.4-R1 (no paths, no ids, nothing per frame). Read with [snapshot].
class DashcamClipStorageCounters {
  DashcamClipStorageCounters._();

  static int promotionsStarted = 0;
  static int promotionsRenamed = 0;
  static int promotionsCopied = 0;
  static int promotionsFailed = 0;
  static int collisions = 0;
  static int emptySources = 0;
  static int sourceResidues = 0;
  static int partialsPreserved = 0;

  /// Fase 16.2-R4.4-R2: how this process's most recent successful promotion
  /// reached its canonical name (`null` before the first). The free-space
  /// guard reserves one more segment while it is
  /// [DashcamClipPlacement.copied]: the cross-filesystem fallback needs the
  /// whole segment twice while it copies (R4.4-R2-D0 §10, term `C`).
  static DashcamClipPlacement? lastPlacement;

  static Map<String, int> snapshot() => {
    'promotionsStarted': promotionsStarted,
    'promotionsRenamed': promotionsRenamed,
    'promotionsCopied': promotionsCopied,
    'promotionsFailed': promotionsFailed,
    'collisions': collisions,
    'emptySources': emptySources,
    'sourceResidues': sourceResidues,
    'partialsPreserved': partialsPreserved,
  };

  @visibleForTesting
  static void resetForTest() {
    promotionsStarted = promotionsRenamed = promotionsCopied = promotionsFailed = 0;
    collisions = emptySources = sourceResidues = partialsPreserved = 0;
    lastPlacement = null;
  }
}

/// Fase 16.2-R4.4-R1 — publishes the finished recording at [sourcePath] as
/// [directory]/[name] (design closure, PROMOTION PROTOCOL). [name] is the
/// clip's canonical v1 name, or a legacy `clip_<ms>.mp4` for a clip of unknown
/// provenance (never indexed). Returns `null` for an EMPTY source — a 0-byte
/// recording is not published, not indexed and not deleted: it stays where it
/// is. Throws for every other failure, with the source where it was; nothing is
/// ever overwritten.
///
/// The RECOVERY FRONTIER is the `rename(2)` that makes [name] appear: before it
/// returns the clip is still the plugin's anonymous temporary file, which no
/// later process can attribute to anyone (D2 — out of R1's reach); after it, a
/// process death leaves a file whose name says whose it is, and the next start
/// indexes it. The syscall is atomic: one name or the other exists, never both,
/// never neither.
///
/// 1. the source is `stat`ed (missing → failure; 0 bytes → `null`);
/// 2. an existing entry under [name] — file, link or directory — is a
///    [DashcamClipCollision]: `File.rename` would replace it;
/// 3. `rename(source, final)`;
/// 4. only when that rename fails with [isCrossDeviceRenameFailure]: copy into
///    `final.partial` (created exclusively — an existing one is a collision,
///    never truncated), check the byte count, flush, close, check [name] is
///    still free and rename the partial to it; then delete the source (a
///    failure there leaves a reported twin, [DashcamClipPromotion
///    .sourceResidue]). A failure before the final rename removes the partial
///    THIS call created (preserved and reported if that fails too); the source
///    is intact.
///
/// The final name appears only once the content meant for it is complete, in
/// both paths: there is no direct copy to the final name.
///
/// No hashing and no comparison of contents: there is one publisher of names
/// in the directory (the camera FIFO of the `DashcamService` that produced the
/// clip — the startup reconciliation and the deletion never create names) and
/// no promotion is ever retried.
Future<DashcamClipPromotion?> promoteDashcamClip({
  required String sourcePath,
  required Directory directory,
  required String name,
  DashcamClipFileOps ops = const DashcamClipFileOps(),
}) async {
  DashcamClipStorageCounters.promotionsStarted++;
  try {
    final promotion = await _promote(sourcePath, directory, name, ops);
    if (promotion != null) {
      DashcamClipStorageCounters.lastPlacement = promotion.placement;
      if (promotion.placement == DashcamClipPlacement.renamed) {
        DashcamClipStorageCounters.promotionsRenamed++;
      } else {
        DashcamClipStorageCounters.promotionsCopied++;
      }
      if (promotion.sourceResidue) DashcamClipStorageCounters.sourceResidues++;
    }
    return promotion;
  } catch (error) {
    DashcamClipStorageCounters.promotionsFailed++;
    if (error is DashcamClipCollision) DashcamClipStorageCounters.collisions++;
    rethrow;
  }
}

Future<DashcamClipPromotion?> _promote(String sourcePath, Directory directory, String name, DashcamClipFileOps ops) async {
  final source = await ops.stat(sourcePath);
  if (source.type == FileSystemEntityType.notFound) {
    throw FileSystemException('The finished recording is not there', sourcePath);
  }
  if (source.size == 0) {
    DashcamClipStorageCounters.emptySources++;
    return null;
  }
  final finalPath = '${directory.path}/$name';
  if (await ops.isOccupied(finalPath)) throw DashcamClipCollision(name);
  try {
    await ops.rename(sourcePath, finalPath);
    return DashcamClipPromotion(file: File(finalPath), sizeBytes: source.size, placement: DashcamClipPlacement.renamed);
  } on FileSystemException catch (error) {
    if (!isCrossDeviceRenameFailure(error)) rethrow;
  }
  return _promoteByCopy(sourcePath, source.size, finalPath, name, ops);
}

Future<DashcamClipPromotion> _promoteByCopy(String sourcePath, int size, String finalPath, String name, DashcamClipFileOps ops) async {
  final partialPath = '$finalPath${DashcamClipDescriptor.partialSuffix}';
  try {
    await ops.createExclusive(partialPath);
  } on FileSystemException {
    // Someone else's partial (or anything under that name): never truncated.
    if (await ops.isOccupied(partialPath)) {
      throw DashcamClipCollision('$name${DashcamClipDescriptor.partialSuffix}');
    }
    rethrow;
  }
  try {
    final sink = await ops.openForAppend(partialPath);
    try {
      var copied = 0;
      await for (final chunk in ops.read(sourcePath)) {
        await sink.write(chunk);
        copied += chunk.length;
      }
      if (copied != size) throw FileSystemException('Copied $copied of $size bytes of the finished recording', sourcePath);
      await sink.flush();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {
        // The copy's own failure is the one reported.
      }
      rethrow;
    }
    await sink.close();
    if (await ops.isOccupied(finalPath)) throw DashcamClipCollision(name);
    await ops.rename(partialPath, finalPath);
  } catch (error, stackTrace) {
    // This call created the partial and nothing else can have used it.
    try {
      await ops.delete(partialPath);
    } catch (_) {
      DashcamClipStorageCounters.partialsPreserved++;
      Error.throwWithStackTrace(
        FileSystemException('The fallback copy failed ($error) and its partial file could not be removed — it is preserved', partialPath),
        stackTrace,
      );
    }
    rethrow;
  }
  var residue = false;
  try {
    await ops.delete(sourcePath);
  } catch (_) {
    residue = true;
  }
  return DashcamClipPromotion(file: File(finalPath), sizeBytes: size, placement: DashcamClipPlacement.copied, sourceResidue: residue);
}

/// What one entry of `dashcam_clips/` is, by its name alone.
enum DashcamClipEntryKind {
  /// A canonical v1 clip — a durable obligation to index it.
  canonical,

  /// `<canonical>.partial` — an unpublished copy of the fallback, complete or
  /// not (nothing can tell): never indexed, never promoted, never deleted
  /// except with the session it names.
  partial,

  /// Anything else: a legacy `clip_<ms>.mp4`, another version, a malformed
  /// name, a link, a directory. Never indexed, never deleted by R1.
  invalid,
}

class DashcamClipDirectoryEntry {
  const DashcamClipDirectoryEntry({required this.path, required this.name, required this.kind, this.descriptor});

  final String path;
  final String name;
  final DashcamClipEntryKind kind;

  /// Set for [DashcamClipEntryKind.canonical] and [DashcamClipEntryKind.partial].
  final DashcamClipDescriptor? descriptor;
}

/// The entries of [directory] — not recursive, links not followed, classified
/// by [DashcamClipDescriptor.parse] alone (no `stat`). A directory that does
/// not exist has none; one that exists and cannot be listed throws.
///
/// Each entry's [DashcamClipDirectoryEntry.path] is built as
/// `'${directory.path}/<name>'` — exactly how `DashcamService` builds the path
/// it publishes and indexes — not the lister's own (`\`-joined on Windows): a
/// path is compared as a string with indexed paths (the R2.6.6 rule that a file
/// another session's index names is never deleted), so the same file must
/// always be spelled the same way.
Future<List<DashcamClipDirectoryEntry>> listDashcamClipsDirectory(Directory directory) async {
  if (!await directory.exists()) return const [];
  final entries = <DashcamClipDirectoryEntry>[];
  await for (final entity in directory.list(followLinks: false)) {
    final name = dashcamClipBasename(entity.path);
    final path = '${directory.path}/$name';
    if (entity is! File) {
      entries.add(DashcamClipDirectoryEntry(path: path, name: name, kind: DashcamClipEntryKind.invalid));
      continue;
    }
    final canonical = DashcamClipDescriptor.parse(name);
    if (canonical != null) {
      entries.add(DashcamClipDirectoryEntry(path: path, name: name, kind: DashcamClipEntryKind.canonical, descriptor: canonical));
      continue;
    }
    final partial = DashcamClipDescriptor.parsePartial(name);
    entries.add(
      partial != null
          ? DashcamClipDirectoryEntry(path: path, name: name, kind: DashcamClipEntryKind.partial, descriptor: partial)
          : DashcamClipDirectoryEntry(path: path, name: name, kind: DashcamClipEntryKind.invalid),
    );
  }
  return entries;
}

/// The canonical clips and partials in [directory] whose name says they are
/// session [sessionId]'s — exactly that session, by the decoded id, never by
/// substring, glob, time or anything else. What the session's deletion removes
/// besides its indexed paths.
Future<List<String>> canonicalClipArtifactsIn(Directory directory, String sessionId) async => [
  for (final entry in await listDashcamClipsDirectory(directory))
    if (entry.kind != DashcamClipEntryKind.invalid && entry.descriptor!.sessionId == sessionId) entry.path,
];
