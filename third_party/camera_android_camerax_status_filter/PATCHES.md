# Patches

## 0001-drop-VideoRecordEvent-Status-before-Pigeon.patch

The only production change: `VideoRecordEventListenerImpl.onEvent` returns on
`VideoRecordEvent.Status`, before `runOnMainThread` and before the generated `api.onEvent`, whose
codec is what registers a proxy in the `InstanceManager`.

Nothing else is affected:

- `Start`, `Finalize` (with its error, output and stats, the same object), `Pause` and `Resume`
  take the upstream path.
- This patch touches neither Pigeon's generated files nor the plugin's Dart code.
- Dart never read Status. The two consumers of the stream are the loops in
  `startVideoCapturing` (until `VideoRecordEventStart`) and `stopVideoRecording` (until
  `VideoRecordEventFinalize`); both skip anything else.
- CameraX still produces Status and still delivers it to this listener on the main executor. It
  ends there. Patch 0003 adds to the residual cost one field read per frame, and the duration read
  until the first positive one.

## 0002-status-filter-tests.patch

Tests only: `VideoRecordEventListenerStatusFilterTest.java` (JUnit, including the real generated
api and codec over a mocked `BinaryMessenger`) and `test/status_filter_contract_test.dart` (the
plugin's START/STOP with and without Status events, same expected result in both).

Running them:

```
cd android
JAVA_HOME=<Android Studio jbr> ./gradlew :camera_android_camerax:testDebugUnitTest
```

The Dart tests need the plugin's dev dependencies, which the app does not have. Copy `package/` to
a temporary folder and run `flutter pub get` and `flutter test` there, so no `pubspec.lock` or
`.dart_tool` is created in this tree.
## 0003-recording-evidence-channel.patch

The second authorized production delta. See the README for the channel, the message format and the
identity protocol.

- `pigeons/camerax_library.dart`: `VideoRecordEventListener(int recordingIdentity)` and its static
  `allocateRecordingIdentity()`.
- `lib/src/camerax_library.g.dart`, `android/.../CameraXLibrary.g.kt`: what Pigeon 27.3.2 generates from
  that. Upstream's committed files are the generator's output after its repository's formatters, so:
  - the Dart file is `dart run pigeon` followed by `dart format --page-width 100`. That same command on
    the unchanged definition reproduces upstream's file byte for byte;
  - the Kotlin file is upstream's plus the generator's delta, written in upstream's formatting: ktfmt
    is not a dependency here. `pigeon_repro/reproduce.sh` rebuilds both and compares them byte for byte;
    see "Reproduce the generated files" in the README.
- `VideoRecordEventListenerProxyApi.java`: the static `AtomicLong` behind `allocateRecordingIdentity`, advanced only by
  compare-and-set; `Long.MAX_VALUE` is never issued and, once reached, every allocation fails for good.
  `VideoRecordEventListenerImpl` holds its identity and one
  flag per fact. In the filter's branch, the first `Status` with `getRecordedDurationNanos() > 0` sends
  one `videoProgress`; the first `Finalize` sends one `recordingEnded`, and every `Finalize` goes on
  through the unchanged path. A failure of the channel is logged and cannot reach that path. After the
  plugin detached from its engine (`ignoreCallsToDart`) nothing is sent, as in the generated api.
- `lib/src/android_camera_camerax.dart`: creates one listener per recording, with its identity, in the
  step that starts it; installs the class's one handler at each START, before anything that can produce
  an event (`registerWith` runs before a binding exists); routes a message by its identity to the
  instance holding it; keeps one `RecordingEvidence` slot per instance, which accepts only its own
  identity; clears it at the next START and before the first `await` of dispose, and a START caught by a
  dispose holds no evidence. It adds `RecordingEvidence`,
  `RecordingEvidenceSource` and `currentRecordingEvidenceSource`.

Not touched: the event stream and its two loops, what `Start` and `Finalize` mean to START and STOP,
CameraX and F2.

## 0004-recording-evidence-tests.patch

Tests only: `VideoRecordEventListenerRecordingEvidenceTest.java` (real generated api, constructor and
codec over a mocked `BinaryMessenger`), `test/recording_evidence_contract_test.dart` (the real channel
path into the slot, and the real generated constructor), and the changes the constructor's new
parameter requires in `VideoRecordEventListenerStatusFilterTest.java`, `VideoRecordEventListenerTest.java`,
`test/status_filter_contract_test.dart` and `test/android_camera_camerax_test.dart`. `status()` in the
filter test returns stats, because the filter's branch reads them.
