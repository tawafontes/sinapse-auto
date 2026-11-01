# Upstream

## Release

| item | value |
|---|---|
| module | `androidx.camera:camera-video` |
| version | `1.6.2` (released 2026-08-26; same version as every other CameraX module the app resolves) |
| requested by | `camera_android_camerax` 0.7.4+8 (`cameraxVersion = "1.6.2"` in its `android/build.gradle.kts`) |
| repository | Google Maven, `https://dl.google.com/android/maven2/androidx/camera/camera-video/1.6.2/` |
| source repository | AOSP `platform/frameworks/support` (POM `scm`), branch `androidx-camera-release` |
| source commit | `9046f07948c1e7a89aaec581463730f4d666611b` — end of the official "Version 1.6.2 contains these commits" range (`987b9ac8585b31424a397206c492196dd163997b..9046f07948c1e7a89aaec581463730f4d666611b`, developer.android.com/jetpack/androidx/releases/camera#1.6.2) |
| build | Gradle module metadata `createdBy`: Gradle 9.4.0-rc-1, buildId `16115938` (the POM records no commit) |
| license | Apache License 2.0 (POM `licenses`; `LICENSE.txt` here is `platform/frameworks/support/LICENSE.txt`, sha256 `809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0`) |

The patched file, `camera/camera-video/src/main/java/androidx/camera/video/internal/encoder/EncoderImpl.java`,
is byte-identical in three places (sha256 `fc9054b2cf4282bc9ab538d0a82c566d9103dec69bff153ad249ea5d57f755c7`):
the `camera-video-1.6.2-sources.jar` published with the binary, commit `9046f079…`, and the start of
the 1.6.2 range (`987b9ac8…`, i.e. 1.6.2 did not touch it). Recompiling it with the toolchain below
gives classes whose `javap -c -p` output is identical to the published AAR's (`build.sh` checks
this on every run).

## Upstream files (sha256)

| file | sha256 |
|---|---|
| `camera-video-1.6.2.aar` | `dee568da7d1ce009506a538b2916cce6f23473a835b0aeb4e8193483ff1174d0` |
| `camera-video-1.6.2-sources.jar` | `dc8f8ac4f891fdaa76087ab43ce79b9a8386f507c5cf351d7189eabde1074a66` |
| `camera-video-1.6.2.pom` | `9b237fa922df0019ff3e5dba4043dca082836b7b93b9ed045061f706da831c8d` |
| `camera-video-1.6.2.module` | `cf1e3fb9362af9c020f1126f8c56e7578f73a96b6f670136cc756a907182733c` |

The AAR is the same file Gradle had resolved for the app before this integration
(`~/.gradle/caches/modules-2/files-2.1/androidx.camera/camera-video/1.6.2/24c939e4…/`).

## Compile classpath of `EncoderImpl.java` (only used to compile; not shipped)

The same versions the validated F2 harness build used; all from Google Maven / Maven Central:

| file | sha256 |
|---|---|
| `camera-core-1.6.2.aar` (`classes.jar`) | `ebd66f090414f4c12f23a55b5023aeee1b096da8a06c02a0b6fb3520c4ddadf6` |
| `androidx.core:core:1.3.2` AAR | `94de196cd67950cff6ef3e1ac59015f8eaaf61840bdc238f2cf54ddef8dd0be9` |
| `annotation-jvm-1.8.1.jar` | `9aab326d9492800991854360ac248f493ce7f7c3183519309b78ace9e240f6f6` |
| `concurrent-futures-1.1.0.jar` | `0ce067c514a0d1049d1bebdf709e344ed3266fe9744275682937cdcb13334e9e` |
| `core-common-2.2.0.jar` | `65308a06b1c00ee186cb9e19321383f043b993813f1522c47f4a3e3303bdba41` |
| `guava-33.3.1-android.jar` | `2c3e41d1b380f2044d257947a3aa82dabf3ae4b978622745254aa18b6cf89ab0` |
| `jspecify-1.0.0.jar` | `1fad6e6be7557781e4d33729d49ae1cdc8fdda6fe477bb0cc68ce351eafdfbab` |

## Toolchain

| item | value |
|---|---|
| JDK | Android Studio JBR, `javac 21.0.10`, flags `-source 8 -target 8 -g -proc:none -encoding UTF-8` (class major version 52, like the upstream classes) |
| boot classpath | Android SDK `platforms/android-36/android.jar` (rev 2, sha256 `d9eb9da824d9e247a352f570f01e1169e725b2954bca9e283a71786c59b59f9a`) + `build-tools/36.0.0/core-lambda-stubs.jar` (sha256 `2feb8df434cae3218ed9ffe9bae01ddec101d1dc5e12824c4209f61e283e0d3d`) |
| packaging | `jar --update --date=…` (fixed dates of the upstream archives) on copies of the upstream `classes.jar` and AAR |

## Output coordinates

`com.synapseauto.thirdparty.androidx.camera:camera-video:1.6.2-synapse-f2` — a project-owned group,
so the dependency report shows the replacement explicitly instead of passing it off as
`androidx.camera`.
