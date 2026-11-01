// Fake of the FILE-SYSTEM edge under one Hive box.
//
// A box opened inside [HiveBoxIoGate.open] has its `<name>.hive` file handed to
// hive through IOOverrides (dart:io's own seam — nothing of hive's internals is
// touched), so the handle hive appends its frames with is a [_GatedWriteHandle].
// Each writeFrom() of that handle is ONE WRITE of the box: hive 2.2.3
// serializes the frames of a put/delete first and hands the bytes over in a
// single call, one write at a time per box. So when a write reaches the gate
// its frame HAS ALREADY BEEN SERIALIZED — the adapter read the object — and the
// gate can
//  * HOLD it before any byte reaches the file (a slow or busy disk): every
//    write requested meanwhile waits behind it in hive's own queue, requested
//    and not yet serialized;
//  * FAIL it before it takes effect (a write error).
// A released write goes to the real file with real asynchronous I/O, as do
// reads, flushes, compactions and everything about any other path — so under
// FakeAsync (testWidgets) these belong inside `tester.runAsync`.
//
// The wrapped File is the one hive keeps for the box, so the gate stays in
// place when hive reopens the file after a compaction.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class HiveBoxIoGate {
  HiveBoxIoGate(this.boxName);

  /// The box whose `<boxName>.hive` file is gated.
  final String boxName;

  /// While true, each write waits — serialized, not written — until
  /// [releaseNext]/[releaseAll].
  bool hold = false;

  Object? _failNext;
  final List<Completer<void>> _held = [];
  final List<Completer<void>> _heldWaiters = [];

  /// Writes that reached the gate (their frames are serialized).
  int writes = 0;

  /// Writes whose bytes reached the real file.
  int landed = 0;

  /// Writes failed by [failNext].
  int failures = 0;

  /// Whether a write is waiting at the gate right now.
  bool get isHolding => _held.isNotEmpty;

  /// Runs [openBox] — which must open the box — with the box's file gated.
  Future<T> open<T>(Future<T> Function() openBox) => IOOverrides.runWithIOOverrides(openBox, _GateOverrides(this));

  /// The next write that reaches the gate fails with [error], before any byte
  /// is written.
  void failNext(Object error) => _failNext = error;

  /// Completes once a write is waiting at the gate.
  Future<void> untilHolding() {
    if (_held.isNotEmpty) return Future.value();
    final waiter = Completer<void>();
    _heldWaiters.add(waiter);
    return waiter.future;
  }

  /// Lets the waiting write through; with [hold] still set, the next one waits.
  void releaseNext() {
    if (_held.isEmpty) return;
    _held.removeAt(0).complete();
  }

  /// Stops holding and lets the waiting write through.
  void releaseAll() {
    hold = false;
    final held = List.of(_held);
    _held.clear();
    for (final c in held) {
      c.complete();
    }
  }

  bool _matches(String path) => path.replaceAll('\\', '/').endsWith('/$boxName.hive');
}

final class _GateOverrides extends IOOverrides {
  _GateOverrides(this.gate);

  final HiveBoxIoGate gate;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return gate._matches(path) ? _GatedBoxFile(real, gate) : real;
  }
}

class _GatedBoxFile implements File {
  _GatedBoxFile(this._real, this._gate);

  final File _real;
  final HiveBoxIoGate _gate;

  @override
  String get path => _real.path;

  @override
  Uri get uri => _real.uri;

  @override
  File get absolute => _real.absolute;

  @override
  Directory get parent => _real.parent;

  @override
  Future<bool> exists() => _real.exists();

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await _real.create(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => _real.delete(recursive: recursive);

  @override
  void deleteSync({bool recursive = false}) => _real.deleteSync(recursive: recursive);

  @override
  Future<File> rename(String newPath) => _real.rename(newPath);

  @override
  Future<int> length() => _real.length();

  @override
  int lengthSync() => _real.lengthSync();

  @override
  Future<Uint8List> readAsBytes() => _real.readAsBytes();

  @override
  Uint8List readAsBytesSync() => _real.readAsBytesSync();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final handle = await _real.open(mode: mode);
    // hive reads through other handles; this is the one it appends with.
    return mode == FileMode.writeOnlyAppend ? _GatedWriteHandle(handle, _gate) : handle;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('_GatedBoxFile.${invocation.memberName}');
}

class _GatedWriteHandle implements RandomAccessFile {
  _GatedWriteHandle(this._real, this._gate);

  final RandomAccessFile _real;
  final HiveBoxIoGate _gate;

  @override
  String get path => _real.path;

  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async {
    _gate.writes++;
    if (_gate.hold) {
      final release = Completer<void>();
      _gate._held.add(release);
      final waiters = List.of(_gate._heldWaiters);
      _gate._heldWaiters.clear();
      for (final waiter in waiters) {
        waiter.complete();
      }
      await release.future;
    }
    final fail = _gate._failNext;
    if (fail != null) {
      _gate._failNext = null;
      _gate.failures++;
      throw fail;
    }
    await _real.writeFrom(buffer, start, end);
    _gate.landed++;
    return this;
  }

  @override
  Future<int> length() => _real.length();

  @override
  Future<int> position() => _real.position();

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _real.setPosition(position);
    return this;
  }

  @override
  Future<RandomAccessFile> truncate(int length) async {
    await _real.truncate(length);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _real.flush();
    return this;
  }

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('_GatedWriteHandle.${invocation.memberName}');
}
