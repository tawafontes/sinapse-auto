# camera_android_camerax 0.7.4+8 + Status filter + recording evidence

The upstream plugin with exactly two authorized deltas. Same version, same CameraX requirement:

1. **Status filter:** it stops forwarding `VideoRecordEvent.Status` from Android to Dart.
2. **Private video-progress and recording-end evidence channel:** one listener per physical
   recording tells Dart, at most once each, that video progress was seen and that the recording
   ended. Every message carries the identity of that recording.

Delta 2 was implemented in round R4.4-HW-MIG-5-SIG-2 and its identity protocol corrected in SIG-2.1,
after the independent review rejected the path-based one. It has automated tests only: a new
independent review and its physical validation are still open.

Classification: **Correção validada experimentalmente; integração definitiva pendente de auditoria.**
The fix was measured on one device (SM-A125M, Android 12, standing still, round R4.4-HW-MIG-4). The
independent audit of the integration is still open, and real driving has not been tested.

## Why this fork exists

It fixes a P1 defect: after a segment rotation, the next recording could start 7–20 s late.

CameraX emits one `Status` per encoded frame, and the plugin creates one Pigeon proxy per event,
about 5,400 in a 3-minute segment. Dart keeps them until the plugin's `StreamQueue` is read at
STOP. The first Dart old-generation GC after that releases them all at once: about 5,400
`removeStrongReference` messages to Android and as many back. Those messages run on the main
thread, the same thread as the Dart UI isolate and the camera calls, so a START behind them waited
7–20 s on the SM-A125M. Nothing in the plugin or in the app reads `Status`.

The filter has to live in the plugin. A filter in Dart would run after the proxy already exists.

## What changed

`VideoRecordEventListenerImpl.onEvent` still ends every `VideoRecordEvent.Status` before Pigeon.
`Start`, `Finalize`, `Pause` and `Resume` follow the upstream path. `lib/src/android_camera_camerax.dart`
gains the receiving side of delta 2. One Pigeon definition differs from upstream, twice:
`VideoRecordEventListener(int recordingIdentity)`, which gives a native listener a value before
`PendingRecording.start`, and its static `allocateRecordingIdentity()`, the source of that value. The generated files come from Pigeon
27.3.2, the version upstream used; [Reproduce the generated files](#reproduce-the-generated-files) rebuilds
them. Details: [PATCHES.md](PATCHES.md).

The channel is `synapse_auto.camera_android_camerax/recording_evidence`
(`BasicMessageChannel`, `StandardMessageCodec`, Android to Dart, no reply). Each message is
`[kind, identity, error]`:

| kind | sent | error |
|---|---|---|
| `videoProgress` | once per recording, on its first `Status` with `getRecordedDurationNanos() > 0` | `null` |
| `recordingEnded` | on its `Finalize`, before that event goes to Pigeon | `Finalize.getError()` |

**Identity.** `VideoRecordEventListenerProxyApi` hands out one per START from a static `AtomicLong`, starting
at 1, through a Pigeon call that `startVideoCapturing` makes before its other steps. That is one more
round trip per START, among the ones it already makes, and it is what the guarantee costs: a number
chosen in Dart cannot rule out one that a surviving listener of a previous isolate still reports, and
a random one only makes that unlikely.

| Boundary | The counter | Guarantee |
|---|---|---|
| Plugin instances, Dart hot restart, engines of one process | The same static field (one class, one process) | No value repeats |
| Process death | Starts over at 1 | Nothing to confuse: every listener, callback and undelivered message died with the process, and identities are never persisted |

A `long`, 8 bytes in Java's message and Dart's `int` on Android. The last identity issued is
`Long.MAX_VALUE - 1`. The next allocation moves the counter to `Long.MAX_VALUE`, where it stays until the
process dies: that allocation and every later one fail, so that START fails before anything physical
begins, and no number is reused. At one START per second that is 292 billion years away.

Then, in the synchronous step that creates that recording's listener and calls
`PendingRecording.start`, the slot takes the identity and the Pigeon constructor message, then the `start`
message, go on one ordered path from Dart to the platform thread. So the native listener holds it,
immutably, before CameraX can call back. It never derives from a path, a clock, or what is current when
a message arrives.

**Receiving.** Dart keeps one slot, `AndroidCameraCameraX.recordingEvidence`: a `RecordingEvidence`
whose `token` is that identity. A message with any other identity is dropped, whatever its order, and so
is anything after the recording's end. No order between this channel and Pigeon is assumed.

### Channel ownership and lifecycle

**Owner.** One handler per messenger, owned by the class: a static function, installed by every START
before anything that can produce an event. Installing it again replaces it with itself. It routes a
message by the identity it carries to the instance holding that identity, so a second plugin instance
neither replaces nor silences the first. An instance is in that table only while its slot holds the
identity (removed at the next START and at the start of `dispose`), and removes only its own entry, so
the handler retains nothing afterwards. The
handler is never removed: with no handler, the framework's channel buffer keeps the last message for
whoever installs one next.

**Dispose.** The first thing `dispose` does, before its first `await`, is empty the slot and remove the
owner, so a release that hangs or throws leaves nothing registered; its error still reaches the caller,
and the order of the release is upstream's. The plugin object lives on for the next camera, so what ends is
a camera session: a START caught by a dispose (begun before it or during it) holds no evidence, and
only a START begun after the dispose holds any. That physical recording is not cancelled here, as before.

**Not protected.** Other code calling `setMessageHandler` with this private name replaces the owner until
the next START. Nothing in the app does. The result reads as "not confirmed".

**Delivery.** One attempt, no reply, no retransmission, no persistence. A lost `videoProgress` leaves
that recording unconfirmed, and REC neutral, until it ends; the next recording has its own listener and
its own message. A lost `recordingEnded` after progress leaves it confirmed until the next STOP or
rotation, which is a known limit. In the service, a `Finalize` the app did not ask for is reported, not
recovered from; that policy is outside this channel.

| Transition | Handler afterwards | Old identity | REC | Next valid progress | Status |
|---|---|---|---|---|---|
| Widget rebuilt or recreated | Unchanged: the service is app-scoped | Same recording, still valid | Unchanged | Same recording | Supported; tested |
| Service or controller recreated, same plugin | Unchanged | Refused: the new START has a new identity, and the old service withdrew its adoption | Neutral until the new recording proves video | New recording | Supported; X586 |
| New plugin instance, same isolate | Unchanged | Refused: one counter per process | Neutral | New recording | Supported; X575, X585 |
| Dart hot restart (debug builds only) | None until the first START in the new isolate | Refused: the counter continues, so no new recording has that number. A native listener may survive, because CameraX holds it and the generated `clear` does not stop a recording. A message before that START waits in the channel buffer and is routed to nobody | Neutral | New recording | Fails closed, with no recovery of the old recording. Not run on a device |
| Engine destroyed and recreated, same process | New isolate, new messenger | Old listeners use the old messenger, and the plugin's detach sets `ignoreCallsToDart`, so they send nothing | Neutral | New recording | Fails closed. Not run on a device |
| Process death | Everything gone | Nothing survives on either side | Neutral | New recording | Fails closed. Not run on a device here |

**Evidence for this table.** The counter's behaviour across instances and registrars has JUnit tests, and the
refusal has Dart tests in which a previous incarnation is modeled as an identity no Dart object knows.
Neither runs a real hot restart, engine teardown or process death.

Limit: a terminal message that is lost after a progress message leaves the slot confirmed until the
app's next STOP or rotation. Nothing here waits for this channel, on purpose.

The proof that duration means video holds for CameraX 1.6.2 only (`Recorder.writeVideoData` is the
one writer of that field, after `writeSampleData`). Do not use `getNumBytesRecorded()`, which
includes audio.

## Origin

`camera_android_camerax` `0.7.4+8` from pub.dev, archive sha256
`977f54512d338b3b36d7f82929794886766d8f41ae84a48fe103eb0106ecfe25`. URLs and patch hashes:
[UPSTREAM.md](UPSTREAM.md).

## How the app consumes it

`pubspec.yaml`:

```yaml
dependency_overrides:
  camera_android_camerax:
    path: third_party/camera_android_camerax_status_filter/package
```

The override is intentional: it is the only way to replace a published plugin's Android code
without editing the Pub cache or needing a Git remote. `flutter pub get` reports it as an overridden
dependency, and that is expected.

The direct dependency stays pinned at `0.7.4+8` to state the approved base version. The override
wins over any pin without a warning, so `verify.sh` is what catches the two drifting apart.

Root `analysis_options.yaml` excludes only `package/test/**` and `package/pigeons/**`, which need
the plugin's dev dependencies. The fork's `lib/` stays under the app's `flutter analyze`.

## Verify

```
bash third_party/camera_android_camerax_status_filter/verify.sh <work dir outside the repository>
```

Run it in a clean work dir; the last line must be `GUARD OK`, and any `FAIL` line exits 1. It needs
network the first time, and Bash, curl, tar, patch and diff. It checks:

- the version and archive hash, by download;
- the four patch hashes;
- `package/` against archive + patches, byte for byte, so any unauthorized change or stray file fails;
- the pin, the override and the `pubspec.lock` entry;
- the presence and position of the filter, and that the evidence channel has the same name on both
  sides;
- that the identity is bound in the Pigeon definition and in both generated files, that it comes from
  native's static counter and not from a generator in Dart, that the listener sends it and no file path,
  that Dart compares it, that `dispose` withdraws it before its first `await`, and that the wire bytes pinned by the JUnit test and
  by the Dart test are the same;
- that the channel handler is still the class's single static function;
- the hashes of `pigeon_repro/`, without running it (`reproduce.sh` needs Dart);
- the CameraX version and the F2 substitution.

It does not resolve dependencies. For that, also run `flutter pub get --enforce-lockfile`.

## Reproduce the generated files

```
bash third_party/camera_android_camerax_status_filter/pigeon_repro/reproduce.sh <empty work dir outside the repository>
bash third_party/camera_android_camerax_status_filter/pigeon_repro/selftest.sh <another one>
```

`reproduce.sh` needs Dart and, unless `ARCHIVE` and `PUB_CACHE` are set, network. It writes only in the
work dir and repairs nothing; the last line must be `REPRODUCED`. Run `selftest.sh` after changing the
tool: it damages copies of the fork (bytes of each file, another Pigeon version, a changed definition, an
ambiguous context) and expects each exact failure.

- **Generator.** `tool/pubspec.yaml` and `tool/pubspec.lock` pin Pigeon 27.3.2 and its dependencies, by
  content hash. The script refuses another version before running anything, and checks the version in
  the generated header.
- **Command.** In the temporary copy of `tool/`: `dart run pigeon --input <definition> --base_path <empty
  folder holding pigeons/copyright.txt> --package_name camera_android_camerax`. The definition's own
  `@ConfigurePigeon` names the Dart and Kotlin outputs.
- **Dart.** Generator, then `dart format --page-width 100`, with no other step. Compared with the kept file.
  The formatter is the SDK's, so another SDK can legitimately fail this comparison; the run prints the
  version. Reproduced with 3.12.2.
- **Kotlin.** Upstream's file is the generator's output after ktfmt, which is not a dependency here, and
  a raw file would rewrite about 4,800 lines. So the kept file is rebuilt from upstream's, in three steps:
  1. the generator's output for upstream's definition must have a pinned hash;
  2. `normalize_kotlin.dart`'s three recorded hunks, applied to that output, must give exactly the
     generator's output for the fork's definition, which shows they are all the generator changed;
  3. the same hunks in upstream's layout, applied to upstream's file (pinned hash), must give the kept file.

  Each hunk must match exactly once and its two layouts must be the same tokens without whitespace.

**Limit.** The layout of the three hunks is recorded by hand, not computed by ktfmt: it reproduces ktfmt's
line breaks, it does not prove ktfmt would choose them.

**Changing the Pigeon definition.** `reproduce.sh` fails at step 2. Edit the hunks in the same review, or,
if that stops being small, replace the kept file with the raw output, which needs no table, and accept the
reformatting diff.

## Rebuild

`verify.sh` leaves the rebuilt tree in `<work dir>/rebuilt`, which is the source of `package/`. After
a `GUARD OK` the two are identical, so nothing has to be copied. To start from the archive by hand:
extract it, delete `example/`, and apply the four patches in order with `patch -p1 --binary`.

## Validate CameraX and F2

The filter depends on neither, the evidence's meaning depends on CameraX `1.6.2`, and the F2
substitution only matches that version.

```
cd android
./gradlew :app:dependencyInsight --dependency androidx.camera:camera-video --configuration releaseRuntimeClasspath
```

It must show `camera-video:1.6.2 -> …:1.6.2-synapse-f2` with "Selected by rule". See
[the F2 README](../androidx_camera_video_f2/README.md).

## Tests

- JUnit, from `android/`: `JAVA_HOME=<Android Studio jbr> ./gradlew :camera_android_camerax:testDebugUnitTest`.
  This is what detects a regression of the filter or of the once-per-recording evidence.
- Dart: copy `package/` to a temporary folder, then run `flutter pub get` and `flutter test` there,
  so that nothing is created in this tree. Three tests fail, the same three on the unpatched upstream
  archive: two in `test/skills_evals_test.dart` and `Validate Skills` in
  `test/validate_skills_test.dart`. They are not caused by the patch.

The app's `flutter test` mostly uses a fake camera platform. The exception is
`test/dashcam_recording_identity_protocol_test.dart`: the real plugin, service, controller and channel
handler over native objects held by the test.

## Auditing a future update

The override silently replaces whatever version the pin asks for. If the pin changes, this copy
must be redone against the new version or removed. Do not just edit the constants in `verify.sh`.

1. Check whether upstream stopped forwarding `Status`. If it did, remove this fork.
2. Read the new `CHANGELOG.md`, and check that `Start` and `Finalize` still end the only loops that
   consume the event stream, and that nothing has started to read `Status`. Re-derive, in the new
   `Recorder`, that only video writes the recorded duration, and when.
3. Rebuild from the new archive and re-derive the patches. Take the new hash from the pub.dev API.
4. Update the constants in `verify.sh` and `UPSTREAM.md`, the pin and the lockfile, then run
   `verify.sh`.
5. If CameraX moved, deal with F2 first, as its README explains.
6. Run the tests above, remove the filter once to confirm that the JUnit tests fail, and repeat the
   physical measurement: rotation gaps with a forced GC after STOP, and `VideoRecordEvent` counts in
   the Dart heap.

The filter does nothing for a future event type: only `Status` is dropped.

## Remove

Delete the `dependency_overrides` block and this folder, restore the root `analysis_options.yaml`
excludes, then run `flutter pub get`. The app's `DashcamService` imports the evidence API, and REC
depends on it: removing this fork requires another source of that evidence, or a decision on REC.
