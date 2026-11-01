# Patches

## 0001-drop-VideoRecordEvent-Status-before-Pigeon.patch

The only production change: `VideoRecordEventListenerImpl.onEvent` returns on
`VideoRecordEvent.Status`, before `runOnMainThread` and before the generated `api.onEvent`, whose
codec is what registers a proxy in the `InstanceManager`.

Nothing else is affected:

- `Start`, `Finalize` (with its error, output and stats, the same object), `Pause` and `Resume`
  take the upstream path.
- Pigeon's generated files are unchanged, and so is the plugin's Dart code.
- Dart never read Status. The two consumers of the stream are the loops in
  `startVideoCapturing` (until `VideoRecordEventStart`) and `stopVideoRecording` (until
  `VideoRecordEventFinalize`); both skip anything else.
- CameraX still produces Status and still delivers it to this listener on the main executor. It
  ends there, and that residual cost is one `instanceof` per frame.

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
