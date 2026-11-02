// Applies the fork's one Pigeon change to a Kotlin file, in one of two layouts, and refuses anything
// else. No dependencies, so it runs before and without `pub get`.
//
//   dart normalize_kotlin.dart raw       <in> <out>   generator layout: baseline output -> fork output
//   dart normalize_kotlin.dart formatted <in> <out>   upstream layout: upstream's file -> fork's file
//
// Upstream's CameraXLibrary.g.kt is the generator's output after ktfmt, which is not a dependency
// here. reproduce.sh proves the two columns below describe the same change: `raw` must turn the
// baseline generator output into exactly the fork's generator output, and each `formatted` text must
// equal its `raw` text once whitespace is removed, which this program checks on every run.
//
// A change to the Pigeon definition makes `raw` stop matching, on purpose: edit [_hunks] in the same
// review, or adopt the canonical output (see README.md).
import 'dart:convert';
import 'dart:io';

class _Hunk {
  const _Hunk(this.name, this.rawOld, this.rawNew, this.formattedOld, this.formattedNew);
  final String name;
  final String rawOld;
  final String rawNew;
  final String formattedOld;
  final String formattedNew;
}

const String _channel =
    '"dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.pigeon_defaultConstructor"';

const List<_Hunk> _hunks = <_Hunk>[
  _Hunk(
    'class comment',
    _commentOld,
    _commentNew,
    _commentOld,
    _commentNew,
  ),
  _Hunk(
    'abstract constructor',
    '  abstract fun pigeon_defaultConstructor(): VideoRecordEventListener\n',
    _abstractNew,
    '  abstract fun pigeon_defaultConstructor(): VideoRecordEventListener\n',
    _abstractNew,
  ),
  // From the channel name: the same statements exist for every other no-argument constructor. Through the
  // end of that `run`, because the allocator's handler is generated right after it.
  _Hunk(
    'constructor message handler',
    _channel +
        r''', codec)
        if (api != null) {
          channel.setMessageHandler { message, reply ->
            val args = message as List<Any?>
            val pigeon_identifierArg = args[0] as Long
            val wrapped: List<Any?> = try {
              api.pigeonRegistrar.instanceManager.addDartCreatedInstance(api.pigeon_defaultConstructor(), pigeon_identifierArg)
              listOf(null)
            } catch (exception: Throwable) {
              CameraXLibraryPigeonUtils.wrapError(exception)
            }
            reply.reply(wrapped)
          }
        } else {
          channel.setMessageHandler(null)
        }
      }
''',
    _channel +
        r''', codec)
        if (api != null) {
          channel.setMessageHandler { message, reply ->
            val args = message as List<Any?>
            val pigeon_identifierArg = args[0] as Long
            val recordingIdentityArg = args[1] as Long
            val wrapped: List<Any?> = try {
              api.pigeonRegistrar.instanceManager.addDartCreatedInstance(api.pigeon_defaultConstructor(recordingIdentityArg), pigeon_identifierArg)
              listOf(null)
            } catch (exception: Throwable) {
              CameraXLibraryPigeonUtils.wrapError(exception)
            }
            reply.reply(wrapped)
          }
        } else {
          channel.setMessageHandler(null)
        }
      }
      run {
        val channel = BasicMessageChannel<Any?>(binaryMessenger, "dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.allocateRecordingIdentity", codec)
        if (api != null) {
          channel.setMessageHandler { _, reply ->
            val wrapped: List<Any?> = try {
              listOf(api.allocateRecordingIdentity())
            } catch (exception: Throwable) {
              CameraXLibraryPigeonUtils.wrapError(exception)
            }
            reply.reply(wrapped)
          }
        } else {
          channel.setMessageHandler(null)
        }
      }
''',
    _channel +
        r''',
                codec)
        if (api != null) {
          channel.setMessageHandler { message, reply ->
            val args = message as List<Any?>
            val pigeon_identifierArg = args[0] as Long
            val wrapped: List<Any?> =
                try {
                  api.pigeonRegistrar.instanceManager.addDartCreatedInstance(
                      api.pigeon_defaultConstructor(), pigeon_identifierArg)
                  listOf(null)
                } catch (exception: Throwable) {
                  CameraXLibraryPigeonUtils.wrapError(exception)
                }
            reply.reply(wrapped)
          }
        } else {
          channel.setMessageHandler(null)
        }
      }
''',
    _channel +
        r''',
                codec)
        if (api != null) {
          channel.setMessageHandler { message, reply ->
            val args = message as List<Any?>
            val pigeon_identifierArg = args[0] as Long
            val recordingIdentityArg = args[1] as Long
            val wrapped: List<Any?> =
                try {
                  api.pigeonRegistrar.instanceManager.addDartCreatedInstance(
                      api.pigeon_defaultConstructor(recordingIdentityArg), pigeon_identifierArg)
                  listOf(null)
                } catch (exception: Throwable) {
                  CameraXLibraryPigeonUtils.wrapError(exception)
                }
            reply.reply(wrapped)
          }
        } else {
          channel.setMessageHandler(null)
        }
      }
      run {
        val channel =
            BasicMessageChannel<Any?>(
                binaryMessenger,
                "dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.allocateRecordingIdentity",
                codec)
        if (api != null) {
          channel.setMessageHandler { _, reply ->
            val wrapped: List<Any?> =
                try {
                  listOf(api.allocateRecordingIdentity())
                } catch (exception: Throwable) {
                  CameraXLibraryPigeonUtils.wrapError(exception)
                }
            reply.reply(wrapped)
          }
        } else {
          channel.setMessageHandler(null)
        }
      }
''',
  ),
];

const String _abstractNew = '''
  abstract fun pigeon_defaultConstructor(recordingIdentity: Long): VideoRecordEventListener

  /**
   * Synapse Auto (R4.4-HW-MIG-5-SIG-2.3): a value no other recording of this process had or will
   * have, from a counter that outlives a Dart isolate.
   */
  abstract fun allocateRecordingIdentity(): Long
''';

const String _commentOld = '/** Listens for `VideoRecordEvent`s from a `PendingRecording`. */\n';
const String _commentNew = '''
/**
 * Listens for `VideoRecordEvent`s from a `PendingRecording`.
 *
 * Synapse Auto (R4.4-HW-MIG-5-SIG-2.1): one per physical recording. Its identity reaches
 * native with this object, before `PendingRecording.start`, and every evidence message of
 * the recording carries it back.
 */
''';

Never _refuse(String reason) {
  stderr.writeln('normalize_kotlin: $reason');
  exit(1);
}

int _count(String text, String pattern) {
  var count = 0;
  for (var at = text.indexOf(pattern); at >= 0; at = text.indexOf(pattern, at + 1)) {
    count++;
  }
  return count;
}

String _withoutWhitespace(String text) => text.replaceAll(RegExp(r'\s'), '');

void main(List<String> args) {
  if (args.length != 3 || (args[0] != 'raw' && args[0] != 'formatted')) {
    _refuse('usage: normalize_kotlin.dart raw|formatted <in> <out>');
  }
  final raw = args[0] == 'raw';

  for (final hunk in _hunks) {
    if (_withoutWhitespace(hunk.rawOld) != _withoutWhitespace(hunk.formattedOld) ||
        _withoutWhitespace(hunk.rawNew) != _withoutWhitespace(hunk.formattedNew)) {
      _refuse('"${hunk.name}": the two layouts are not the same tokens');
    }
  }

  var text = utf8.decode(File(args[1]).readAsBytesSync());
  if (text.contains('\r')) _refuse('${args[1]} is not LF');

  for (final hunk in _hunks) {
    final from = raw ? hunk.rawOld : hunk.formattedOld;
    final to = raw ? hunk.rawNew : hunk.formattedNew;
    if (_count(text, from) != 1) {
      _refuse('"${hunk.name}": expected exactly one match, found ${_count(text, from)}');
    }
    if (_count(text, to) != 0) _refuse('"${hunk.name}": its result is already there');
    text = text.replaceFirst(from, to);
    if (_count(text, from) != 0 || _count(text, to) != 1) _refuse('"${hunk.name}": wrong result');
  }

  File(args[2]).writeAsBytesSync(utf8.encode(text));
}
