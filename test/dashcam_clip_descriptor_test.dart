import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_clip_descriptor.dart';
import 'package:synapse_auto/models/dashcam_config.dart';

// Fase 16.2-R4.4-R1 — the canonical clip name v1 (design closure, FILENAME):
// one strict grammar, one parser, an encoder that is its exact inverse. A name
// that is not canonical is never a clip of this version: these tests pin what
// the parser refuses, because whatever it accepts the startup indexes.
void main() {
  const ns = '0123456789abcdef0123456789abcdef';
  final t0 = DateTime.fromMillisecondsSinceEpoch(1791348535280);

  DashcamClipDescriptor descriptor({
    String sessionId = '1791348535279822-0',
    DateTime? recordedAt,
    String namespace = ns,
    int recordingId = 3,
    int durationSeconds = 179,
    bool isProtected = false,
    VideoResolution resolution = VideoResolution.hd720,
    bool audioEnabled = true,
  }) =>
      DashcamClipDescriptor.tryCreate(
        sessionId: sessionId,
        recordedAt: recordedAt ?? t0,
        namespace: namespace,
        recordingId: recordingId,
        durationSeconds: durationSeconds,
        isProtected: isProtected,
        resolution: resolution,
        audioEnabled: audioEnabled,
      )!;

  /// The valid example of the design closure, field by field, so each test can
  /// break exactly one of them.
  String name({
    String version = 'v1',
    String sid = '313739313334383533353237393832322d30',
    String rec = '1791348535280',
    String namespace = ns,
    String rid = '3',
    String dur = '179',
    String p = '0',
    String res = '1',
    String a = '1',
    String extension = '.mp4',
  }) =>
      'clip_${version}_${sid}_${rec}_$namespace-${rid}_${dur}_${p}_${res}_$a$extension';

  group('Fase 16.2-R4.4-R1 — canonical clip name v1', () {
    test('X414 — a valid name round-trips: encode(parse(n)) == n, every field decoded, recordedAt local and in whole milliseconds', () {
      final valid = name();
      final d = DashcamClipDescriptor.parse(valid);
      expect(d, isNotNull);
      expect(d!.sessionId, '1791348535279822-0');
      expect(d.recordedAt, DateTime.fromMillisecondsSinceEpoch(1791348535280));
      expect(d.recordedAt.isUtc, isFalse, reason: 'what Hive hands back for a DateTime.now() after a restart');
      expect(d.namespace, ns);
      expect(d.recordingId, 3);
      expect(d.clipId, '$ns-3');
      expect(d.durationSeconds, 179);
      expect(d.isProtected, isFalse);
      expect(d.resolution, VideoResolution.hd720);
      expect(d.audioEnabled, isTrue);
      expect(d.basename, valid);
      expect(descriptor().basename, valid, reason: 'the encoder produces exactly the design\'s example');

      // Every resolution code and every flag.
      for (final (code, resolution) in [('0', VideoResolution.sd480), ('1', VideoResolution.hd720), ('2', VideoResolution.fhd1080), ('3', VideoResolution.uhd4k)]) {
        expect(DashcamClipDescriptor.parse(name(res: code))!.resolution, resolution);
        expect(descriptor(resolution: resolution).basename, name(res: code));
      }
      expect(DashcamClipDescriptor.parse(name(p: '1', a: '0'))!.isProtected, isTrue);
      expect(DashcamClipDescriptor.parse(name(p: '1', a: '0'))!.audioEnabled, isFalse);
      expect(DashcamClipDescriptor.parse(name(rec: '0', dur: '0'))!.durationSeconds, 0);
    });

    test('X415 — the encoder keeps only whole milliseconds: two instants inside one ms name the same clip time, and the name survives the restart round-trip', () {
      final withMicros = DateTime.fromMicrosecondsSinceEpoch(1791348535280999);
      final d = descriptor(recordedAt: withMicros);
      expect(d.recordedAt.microsecondsSinceEpoch, 1791348535280000);
      expect(d.basename, name());
      expect(DashcamClipDescriptor.parse(d.basename)!.recordedAt, d.recordedAt);
      final utc = descriptor(recordedAt: DateTime.fromMillisecondsSinceEpoch(1791348535280, isUtc: true));
      expect(utc.recordedAt.isUtc, isFalse, reason: 'normalized to local, like the adapter\'s read-back');
      expect(utc.basename, name());
    });

    test('X416 — session ids round-trip byte for byte whatever they contain (the id is a key, hex-encoded, never a path): Unicode, "_", "/", "\\\\", NUL, "-", ".."; the encoder refuses an empty id, one over 64 UTF-8 bytes and an unpaired surrogate', () {
      for (final id in ['A', 'sessão-ação', '日本語', '😀', 'a_b_c', '../etc/passwd', r'C:\x', 'nul\u0000inside', '--', '..', 'x' * 64, 'é' * 32]) {
        final d = descriptor(sessionId: id);
        expect(d.basename, matches(RegExp(r'^clip_v1_[0-9a-f]+_')), reason: id);
        expect(d.basename.contains('/') || d.basename.contains(r'\'), isFalse, reason: 'no separator can come from the id: $id');
        final back = DashcamClipDescriptor.parse(d.basename);
        expect(back?.sessionId, id, reason: 'round-trip of "$id"');
      }
      DashcamClipDescriptor? create(String id) => DashcamClipDescriptor.tryCreate(
        sessionId: id,
        recordedAt: t0,
        namespace: ns,
        recordingId: 1,
        durationSeconds: 0,
        isProtected: false,
        resolution: VideoResolution.hd720,
        audioEnabled: false,
      );
      expect(create(''), isNull);
      expect(create('x' * 65), isNull);
      expect(create('é' * 33), isNull, reason: '66 bytes');
      expect(create('\uD800'), isNull, reason: 'an unpaired surrogate would come back as U+FFFD');
    });

    test('X417 — the encoder refuses out-of-grammar values (no canonical name, the clip is then of unknown provenance): negative or too large time, recording id 0 or > 10 digits, negative or > 7-digit duration, a malformed namespace', () {
      DashcamClipDescriptor? create({DateTime? recordedAt, String namespace = ns, int recordingId = 1, int durationSeconds = 0}) => DashcamClipDescriptor.tryCreate(
        sessionId: 'S',
        recordedAt: recordedAt ?? t0,
        namespace: namespace,
        recordingId: recordingId,
        durationSeconds: durationSeconds,
        isProtected: false,
        resolution: VideoResolution.hd720,
        audioEnabled: false,
      );
      expect(create(recordedAt: DateTime.fromMillisecondsSinceEpoch(-1)), isNull);
      expect(create(recordedAt: DateTime.fromMillisecondsSinceEpoch(DashcamClipDescriptor.maxRecordedAtMs)), isNotNull);
      expect(create(recordingId: 0), isNull);
      expect(create(recordingId: -5), isNull);
      expect(create(recordingId: DashcamClipDescriptor.maxRecordingId), isNotNull);
      expect(create(recordingId: DashcamClipDescriptor.maxRecordingId + 1), isNull);
      expect(create(durationSeconds: -1), isNull);
      expect(create(durationSeconds: DashcamClipDescriptor.maxDurationSeconds), isNotNull);
      expect(create(durationSeconds: DashcamClipDescriptor.maxDurationSeconds + 1), isNull);
      expect(create(namespace: ns.toUpperCase()), isNull);
      expect(create(namespace: ns.substring(1)), isNull);
      expect(create(namespace: '${ns}0'), isNull);
      expect(create(namespace: ns.replaceFirst('0', 'g')), isNull);
    });

    test('X418 — fails closed on every malformed field: version, session hex, timestamp, recording id, duration, protected, resolution, audio', () {
      final invalid = <String, String>{
        'version v2': name(version: 'v2'),
        'version V1': name(version: 'V1'),
        'version v0': name(version: 'v0'),
        'version v01': name(version: 'v01'),
        'no version': 'clip__${name().substring('clip_v1_'.length)}',
        'empty sid': name(sid: ''),
        'odd-length sid hex': name(sid: '313'),
        'uppercase sid hex': name(sid: '4A'),
        'non-hex sid': name(sid: 'zz'),
        'sid hex with g': name(sid: '6g'),
        'sid not UTF-8 (lone 0xff)': name(sid: 'ff'),
        'sid overlong UTF-8 (c0 af = "/")': name(sid: 'c0af'),
        'sid UTF-8 truncated': name(sid: 'e697'),
        'sid UTF-8 surrogate (ed a0 80)': name(sid: 'eda080'),
        'sid over 64 bytes': name(sid: '61' * 65),
        'timestamp with a leading zero': name(rec: '01791348535280'),
        'timestamp negative': name(rec: '-1'),
        'timestamp with a sign': name(rec: '+1791348535280'),
        'timestamp above DateTime\'s range': name(rec: '8640000000000001'),
        'timestamp of 17 digits': name(rec: '17913485352800000'),
        'timestamp not decimal': name(rec: '1e10'),
        'empty timestamp': name(rec: ''),
        'recording id 0': name(rid: '0'),
        'recording id with a leading zero': name(rid: '03'),
        'recording id of 11 digits': name(rid: '12345678901'),
        'recording id negative': name(rid: '-3'),
        'namespace uppercase': name(namespace: ns.toUpperCase()),
        'namespace of 31': name(namespace: ns.substring(1)),
        'namespace of 33': name(namespace: '${ns}0'),
        'duration with a leading zero': name(dur: '0179'),
        'duration of 8 digits': name(dur: '12345678'),
        'duration negative': name(dur: '-1'),
        'protected 2': name(p: '2'),
        'protected true': name(p: 'true'),
        'protected empty': name(p: ''),
        'resolution 4': name(res: '4'),
        'resolution 01': name(res: '01'),
        'resolution x': name(res: 'x'),
        'audio 2': name(a: '2'),
        'audio empty': name(a: ''),
        'extension .MP4': name(extension: '.MP4'),
        'extension .mov': name(extension: '.mov'),
        'no extension': name(extension: ''),
        'extension .mp4.mp4': name(extension: '.mp4.mp4'),
      };
      invalid.forEach((label, value) {
        expect(DashcamClipDescriptor.parse(value), isNull, reason: label);
      });
    });

    test('X419 — fails closed on structure: extra or missing fields, path components and traversal, unexpected Unicode (look-alike digits, accents, spaces, control characters), legacy and plugin names, partial suffixes, an excessive length', () {
      final valid = name();
      final invalid = <String, String>{
        'an extra field': valid.replaceFirst('.mp4', '_9.mp4'),
        'an extra field in the middle': valid.replaceFirst('_179_', '_179_7_'),
        'a missing field (audio)': valid.replaceFirst('_1.mp4', '.mp4'),
        'a missing field (duration)': valid.replaceFirst('_179_', '_'),
        'a missing separator': valid.replaceFirst('-3_', '3_'),
        'a doubled separator': valid.replaceFirst('_179', '__179'),
        'a relative path': 'dashcam_clips/$valid',
        'a traversal': '../$valid',
        'a Windows traversal': '..\\$valid',
        'an absolute path': '/data/user/0/x/app_flutter/dashcam_clips/$valid',
        'a separator inside': valid.replaceFirst('_179_', '_1/9_'),
        'a backslash inside': valid.replaceFirst('_179_', r'_1\9_'),
        'dot': '.',
        'dot-dot': '..',
        'fullwidth digit': valid.replaceFirst('_179_', '_１79_'),
        'Arabic-Indic digit': valid.replaceFirst('_179_', '_١79_'),
        'accented letter': valid.replaceFirst('clip', 'clíp'),
        'NBSP': valid.replaceFirst('_179_', '_179\u00a0_'),
        'a leading space': ' $valid',
        'a trailing space': '$valid ',
        'a trailing newline': '$valid\n',
        'a NUL inside': valid.replaceFirst('_179_', '_17\u00009_'),
        'zero-width joiner': valid.replaceFirst('clip_', 'clip\u200d_'),
        'legacy clip_<ms>': 'clip_1791348535280.mp4',
        'legacy test name': 'clip_x113_a.mp4',
        'plugin REC file': 'REC1234567890.mp4',
        'partial (the canonical parser)': '$valid.partial',
        'an excessive length': '${name(sid: '61' * 64)}${'x' * 300}',
        'empty': '',
      };
      invalid.forEach((label, value) {
        expect(DashcamClipDescriptor.parse(value), isNull, reason: label);
      });
    });

    test('X420 — a partial is exactly "<canonical>.partial": parsePartial accepts that and nothing else; the worst-case names fit NAME_MAX (215 bytes, 223 with the suffix)', () {
      final d = descriptor();
      expect(DashcamClipDescriptor.parsePartial(d.partialBasename)?.basename, d.basename);
      expect(DashcamClipDescriptor.parsePartial(d.basename), isNull, reason: 'a canonical name is not a partial');
      expect(DashcamClipDescriptor.parsePartial('${d.partialBasename}.partial'), isNull);
      expect(DashcamClipDescriptor.parsePartial('clip_123.mp4.partial'), isNull, reason: 'a legacy partial names no clip');
      expect(DashcamClipDescriptor.parsePartial('.partial'), isNull);
      expect(DashcamClipDescriptor.parsePartial('${name(version: 'v2')}.partial'), isNull);

      final worst = descriptor(
        sessionId: 'x' * 64,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(DashcamClipDescriptor.maxRecordedAtMs),
        recordingId: DashcamClipDescriptor.maxRecordingId,
        durationSeconds: DashcamClipDescriptor.maxDurationSeconds,
        isProtected: true,
        resolution: VideoResolution.uhd4k,
      );
      expect(worst.basename.length, 215);
      expect(worst.partialBasename.length, 223);
      expect(DashcamClipDescriptor.parse(worst.basename)?.basename, worst.basename);
    });

    test('X421 — no collision: distinct descriptors never share a name (any one field differs → another name); one descriptor always yields one name; the order is (recordedAt, namespace, recording id)', () {
      final base = descriptor();
      final variants = [
        descriptor(sessionId: '1791348535279822-1'),
        descriptor(recordedAt: t0.add(const Duration(milliseconds: 1))),
        descriptor(namespace: ns.replaceFirst('0', '1')),
        descriptor(recordingId: 4),
        descriptor(durationSeconds: 180),
        descriptor(isProtected: true),
        descriptor(resolution: VideoResolution.fhd1080),
        descriptor(audioEnabled: false),
      ];
      final names = {base.basename, for (final v in variants) v.basename};
      expect(names, hasLength(variants.length + 1));
      expect(descriptor().basename, base.basename);
      expect(variants.where((v) => v.clipId == base.clipId), hasLength(6), reason: 'the clip id is namespace + recording id only');

      final a = descriptor(recordingId: 2);
      final b = descriptor(recordingId: 10);
      final c = descriptor(recordedAt: t0.subtract(const Duration(milliseconds: 1)), recordingId: 99);
      final sorted = [b, a, base, c]..sort(DashcamClipDescriptor.compareOrder);
      expect(sorted.map((d) => d.recordingId), [99, 2, 3, 10], reason: 'by time, then numerically by recording id — never by the text of the name');
    });
  });
}
