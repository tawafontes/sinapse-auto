# camera_android_camerax 0.7.4+8 + Status filter

The upstream plugin with one change: it stops forwarding `VideoRecordEvent.Status` from Android to
Dart. Same version, same Dart code, same Pigeon files, same CameraX requirement.

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

Only `VideoRecordEventListenerImpl.onEvent` behaves differently: it returns on
`VideoRecordEvent.Status`. `Start`, `Finalize`, `Pause` and `Resume` follow the upstream path. The
plugin's `lib/`, Pigeon definitions and generated code are identical to upstream. Details:
[PATCHES.md](PATCHES.md).

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
- the two patch hashes;
- `package/` against archive + patches, byte for byte, so any unauthorized change or stray file fails;
- the pin, the override and the `pubspec.lock` entry;
- the presence and position of the filter;
- the CameraX version and the F2 substitution.

It does not resolve dependencies. For that, also run `flutter pub get --enforce-lockfile`.

## Rebuild

`verify.sh` leaves the rebuilt tree in `<work dir>/rebuilt`, which is the source of `package/`. After
a `GUARD OK` the two are identical, so nothing has to be copied. To start from the archive by hand:
extract it, delete `example/`, and apply both patches in order with `patch -p1 --binary`.

## Validate CameraX and F2

The filter depends on neither, but the F2 substitution only matches CameraX `1.6.2`.

```
cd android
./gradlew :app:dependencyInsight --dependency androidx.camera:camera-video --configuration releaseRuntimeClasspath
```

It must show `camera-video:1.6.2 -> …:1.6.2-synapse-f2` with "Selected by rule". See
[the F2 README](../androidx_camera_video_f2/README.md).

## Tests

- JUnit, from `android/`: `JAVA_HOME=<Android Studio jbr> ./gradlew :camera_android_camerax:testDebugUnitTest`.
  This is what detects a regression of the filter.
- Dart: copy `package/` to a temporary folder, then run `flutter pub get` and `flutter test` there,
  so that nothing is created in this tree. Three tests fail, the same three on the unpatched upstream
  archive: two in `test/skills_evals_test.dart` and `Validate Skills` in
  `test/validate_skills_test.dart`. They are not caused by the patch.

The app's `flutter test` uses a fake camera platform and does not exercise this plugin.

## Auditing a future update

The override silently replaces whatever version the pin asks for. If the pin changes, this copy
must be redone against the new version or removed. Do not just edit the constants in `verify.sh`.

1. Check whether upstream stopped forwarding `Status`. If it did, remove this fork.
2. Read the new `CHANGELOG.md`, and check that `Start` and `Finalize` still end the only loops that
   consume the event stream, and that nothing has started to read `Status`.
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
excludes, then run `flutter pub get`.
