import 'dart:convert';

import 'dashcam_config.dart';

/// Fase 16.2-R4.4-R1 — the durable identity of one dashcam clip, carried by the
/// clip's own file NAME in `dashcam_clips/` (design closure
/// `scratchpad/fase16_2_r4_4_r1_d1_design_closure/FECHAMENTO_DESIGN_R4_4_R1.md`,
/// FILENAME):
///
/// ```text
/// clip_v1_<sid>_<rec>_<ns>-<rid>_<dur>_<p>_<res>_<a>.mp4
/// ```
///
/// | field | content | grammar |
/// |---|---|---|
/// | `sid` | the producing session's id, UTF-8, lowercase hex | `[0-9a-f]{2,128}`, even length |
/// | `rec` | [recordedAt] in MILLISECONDS since the epoch | `0` or `[1-9][0-9]{0,15}` |
/// | `ns` | the producing `DashcamService` instance's namespace | `[0-9a-f]{32}` |
/// | `rid` | that instance's Recording id | `[1-9][0-9]{0,9}` |
/// | `dur` | [durationSeconds] | `0` or `[1-9][0-9]{0,6}` |
/// | `p` | protection when the clip was published | `0` or `1` |
/// | `res` | [resolution], by its frozen `@HiveField` index | `[0-3]` |
/// | `a` | audio REQUESTED for the Recording | `0` or `1` |
///
/// The name is the whole durable record of the clip: everything a
/// `DashcamClipRecord` holds that cannot be derived is here, and the rest (the
/// path, the size, the order) comes from the directory and a `stat` — so the
/// record a normal STOP writes and the one a startup recovery rebuilds after a
/// process death are the same function of the same name. There is no sidecar
/// (rejected by the design: a second file per clip with its own atomicity).
///
/// Milliseconds, not microseconds: Hive stores a `DateTime` in ms
/// (`DateTimeWithTimezoneAdapter`), so a µs name would rebuild a record that
/// differs from the one read back from disk after a restart.
///
/// This file is pure — no I/O, no Hive — and is the ONE parser: the promotion,
/// the clip index, the startup reconciliation and the session deletion all use
/// [parse]. A name that does not match exactly is not a clip of this version:
/// it is never indexed and never deleted on the strength of its name.
class DashcamClipDescriptor {
  const DashcamClipDescriptor._({
    required this.sessionId,
    required this.recordedAt,
    required this.namespace,
    required this.recordingId,
    required this.durationSeconds,
    required this.isProtected,
    required this.resolution,
    required this.audioEnabled,
  });

  /// The descriptor of a clip about to be published, or `null` when one of the
  /// values cannot be written under the v1 grammar — the clip then has no
  /// canonical name (unknown provenance) and is never indexed.
  ///
  /// [recordedAt] is reduced to whole milliseconds here, and kept as a LOCAL
  /// `DateTime` — exactly what Hive hands back for it after a restart.
  static DashcamClipDescriptor? tryCreate({
    required String sessionId,
    required DateTime recordedAt,
    required String namespace,
    required int recordingId,
    required int durationSeconds,
    required bool isProtected,
    required VideoResolution resolution,
    required bool audioEnabled,
  }) {
    final sidBytes = utf8.encode(sessionId);
    if (sidBytes.isEmpty || sidBytes.length > maxSessionIdBytes) return null;
    // A string with an unpaired surrogate encodes as U+FFFD: it would not come
    // back as the same id.
    if (utf8.decode(sidBytes) != sessionId) return null;
    final ms = recordedAt.millisecondsSinceEpoch;
    if (ms < 0 || ms > maxRecordedAtMs) return null;
    if (!_namespacePattern.hasMatch(namespace)) return null;
    if (recordingId < 1 || recordingId > maxRecordingId) return null;
    if (durationSeconds < 0 || durationSeconds > maxDurationSeconds) return null;
    return DashcamClipDescriptor._(
      sessionId: sessionId,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      namespace: namespace,
      recordingId: recordingId,
      durationSeconds: durationSeconds,
      isProtected: isProtected,
      resolution: resolution,
      audioEnabled: audioEnabled,
    );
  }

  /// [name] as a canonical v1 clip name, or `null`. Only a BASENAME is
  /// accepted — the directory is always the one the app resolved, never
  /// anything a field suggests — and only one that matches the grammar exactly
  /// and comes back byte for byte when encoded again (one name per clip).
  static DashcamClipDescriptor? parse(String name) {
    if (name.length > maxBasenameLength) return null;
    final match = _canonicalPattern.firstMatch(name);
    if (match == null) return null;
    final sidHex = match.group(1)!;
    if (sidHex.length.isOdd || sidHex.length > maxSessionIdBytes * 2) return null;
    final sidBytes = <int>[for (var i = 0; i < sidHex.length; i += 2) int.parse(sidHex.substring(i, i + 2), radix: 16)];
    final String sessionId;
    try {
      sessionId = const Utf8Decoder().convert(sidBytes);
    } on FormatException {
      return null;
    }
    final ms = int.parse(match.group(2)!);
    if (ms > maxRecordedAtMs) return null;
    final descriptor = tryCreate(
      sessionId: sessionId,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      namespace: match.group(3)!,
      recordingId: int.parse(match.group(4)!),
      durationSeconds: int.parse(match.group(5)!),
      isProtected: match.group(6) == '1',
      resolution: _resolutionByCode[int.parse(match.group(7)!)],
      audioEnabled: match.group(8) == '1',
    );
    if (descriptor == null || descriptor.basename != name) return null;
    return descriptor;
  }

  /// [name] as the in-progress copy of a canonical clip (`<canonical>.partial`,
  /// written only by the cross-filesystem fallback of the promotion), or `null`.
  /// A partial is never a clip: nothing indexes it, the startup leaves it alone,
  /// and only the deletion of the session it names removes it.
  static DashcamClipDescriptor? parsePartial(String name) {
    if (!name.endsWith(partialSuffix)) return null;
    return parse(name.substring(0, name.length - partialSuffix.length));
  }

  static const version = 'v1';
  static const partialSuffix = '.partial';

  /// `NAME_MAX` — the longest v1 name is 215 bytes, 223 with [partialSuffix].
  static const maxBasenameLength = 255;
  static const maxSessionIdBytes = 64;

  /// The largest instant a `DateTime` represents.
  static const maxRecordedAtMs = 8640000000000000;
  static const maxRecordingId = 9999999999;
  static const maxDurationSeconds = 9999999;

  /// The producing session — the key the clip is indexed under, and the only
  /// one: nothing indexes a clip under a session its name does not carry.
  final String sessionId;

  /// When the segment's `startVideoRecording()` was requested, in whole ms.
  final DateTime recordedAt;

  /// 128 random bits of the `DashcamService` instance that produced the clip,
  /// lowercase hex — keeps two instances (two processes, or two services in one
  /// test) from ever naming two clips alike although their [recordingId]s
  /// restart from 1.
  final String namespace;

  /// The Recording id of that instance (its existing counter, not a new one).
  final int recordingId;

  final int durationSeconds;

  /// The protection the clip had when it was published. A later protection is
  /// recorded only in the index, and only ever upwards (see
  /// `ensureClipIndexed`).
  final bool isProtected;

  /// The resolution the camera controller of the Recording was built with.
  final VideoResolution resolution;

  /// Whether audio was REQUESTED for the Recording (the plugin drops it,
  /// silently, without permission).
  final bool audioEnabled;

  /// The clip's identity: unique per segment by construction, the same in every
  /// retry, on every restart and in every path the clip is seen at.
  String get clipId => '$namespace-$recordingId';

  /// The canonical file name — the inverse of [parse].
  String get basename {
    final sid = [for (final byte in utf8.encode(sessionId)) byte.toRadixString(16).padLeft(2, '0')].join();
    return 'clip_${version}_${sid}_${recordedAt.millisecondsSinceEpoch}_$namespace-${recordingId}_${durationSeconds}_'
        '${isProtected ? 1 : 0}_${_resolutionByCode.indexOf(resolution)}_${audioEnabled ? 1 : 0}.mp4';
  }

  String get partialBasename => '$basename$partialSuffix';

  /// The order of clips in a session's index: by [recordedAt], then by
  /// [clipId]'s parts — a function of the clips alone, never of which pass
  /// happened to index them first.
  static int compareOrder(DashcamClipDescriptor a, DashcamClipDescriptor b) {
    final byTime = a.recordedAt.millisecondsSinceEpoch.compareTo(b.recordedAt.millisecondsSinceEpoch);
    if (byTime != 0) return byTime;
    final byNamespace = a.namespace.compareTo(b.namespace);
    if (byNamespace != 0) return byNamespace;
    return a.recordingId.compareTo(b.recordingId);
  }

  /// The `@HiveField` indices of [VideoResolution], frozen in its adapter —
  /// listed explicitly rather than read from `VideoResolution.index`, so a
  /// reordering of the enum cannot change what a stored name means.
  static const _resolutionByCode = [VideoResolution.sd480, VideoResolution.hd720, VideoResolution.fhd1080, VideoResolution.uhd4k];

  static final _namespacePattern = RegExp(r'^[0-9a-f]{32}$');

  static final _canonicalPattern = RegExp(
    r'^clip_v1_([0-9a-f]{2,128})_(0|[1-9][0-9]{0,15})_([0-9a-f]{32})-([1-9][0-9]{0,9})_(0|[1-9][0-9]{0,6})_([01])_([0-3])_([01])\.mp4$',
  );
}
