# androidx.camera:camera-video 1.6.2 + F2

The app records video through `camera_android_camerax` 0.7.4+8, which depends on CameraX 1.6.2.
This folder replaces **one** of those modules, `androidx.camera:camera-video:1.6.2`, with the same
release plus one patch (F2) in `EncoderImpl`. The plugin and every other CameraX module are the
upstream artifacts.

Status: experimental integration for the SM-A326B (Android 13), round R4.3-R2.6.22-INT. Not
validated on other devices or Android versions (see "Known limits").

## Why

On Android 13 (Codec2), `MediaCodec.setInputSurface()` connects a `C2OMXNode` whose thread polls
every 20 ms. `CCodec` only disconnects it when the codec is stopped, or released while
STARTING/RUNNING/STOPPING. CameraX 1.6.2 releases video codecs that are only configured — after
every STOP (the `reset()` that prepares the next recording), when a `VideoCapture` is bound and
unbound without recording, on an aborted START, on HOME/return — so each of those events left one
node thread alive for the rest of the process (~50 wakeups/s each; 48 of them after 45 segment
rotations and 3 session stops on the SM-A326B).

F2: `EncoderImpl.SurfaceInput` parks its persistent input surface after `MediaCodec.release()`
instead of releasing it, and the next video encoder takes a parked surface before creating one.
Associating the same persistent surface with the next codec replaces the `GraphicBufferSource`
component that kept the old node alive, so the node is destroyed. The number of nodes is then
bounded by the peak number of video encoders alive at the same time instead of growing with every
event. Details and evidence: [PATCHES.md](PATCHES.md).

## How the app consumes it

`android/app/build.gradle.kts`, one block at the end of the file:

- an `exclusiveContent` Maven repository pointing at `maven/` here, serving only
  `com.synapseauto.thirdparty.androidx.camera:camera-video`;
- a dependency substitution of exactly `androidx.camera:camera-video:1.6.2` by
  `com.synapseauto.thirdparty.androidx.camera:camera-video:1.6.2-synapse-f2`.

The patched module keeps the upstream dependencies and the CameraX atomic-group constraints, so
Gradle resolves the same graph with only that module swapped. Nothing is patched in the Pub cache
or in `~/.gradle`.

Check the resolution:

```
cd android
./gradlew :app:dependencyInsight --dependency androidx.camera:camera-video --configuration releaseRuntimeClasspath
```

It must show `androidx.camera:camera-video:1.6.2 -> com.synapseauto.thirdparty.androidx.camera:camera-video:1.6.2-synapse-f2`
with "Selected by rule".

## Files

| path | what |
|---|---|
| `maven/com/synapseauto/thirdparty/androidx/camera/camera-video/1.6.2-synapse-f2/` | the artifact the build consumes: AAR, POM, Gradle module metadata |
| `patches/0001-EncoderImpl-reuse-persistent-input-surface-F2.patch` | the only source change, against the official 1.6.2 `EncoderImpl.java` |
| `build.sh` | rebuilds `maven/` from the official release + patch and verifies every step |
| `gen_metadata.pl` | writes the POM/.module from the upstream ones (coordinates and file hashes only) |
| `SHA256SUMS` | written by `build.sh`: inputs, sources, patched classes, outputs |
| `UPSTREAM.md` | exact upstream release, commit, URLs and hashes |
| `PATCHES.md` | what the patch does, how it was validated, equivalence evidence |
| `LICENSE.txt` | Apache License 2.0 (AOSP `platform/frameworks/support` `LICENSE.txt`) |
| `.gitattributes` | keeps LF line endings, so the files stay byte-identical to `SHA256SUMS` |

## Rebuild / verify

```
bash third_party/androidx_camera_video_f2/build.sh <work dir outside the repository>
```

The script downloads the pinned inputs from Google Maven / Maven Central (SHA-256 checked),
applies the patch, checks that the patched source and the ten `EncoderImpl*.class` files are the
validated ones, checks that the AAR differs from upstream only in those class entries, writes
the POM/.module, and compares the result with `maven/` and `SHA256SUMS`. Every line must say
`IDENTICAL`. `--install` writes the result into this folder instead.

Toolchain used: Android Studio JBR 21.0.10 (`javac -source 8 -target 8 -g`), Android SDK
platform 36 and build-tools 36.0.0, Git Bash on Windows.

## Upgrading CameraX or the camera plugin

The substitution matches **only** `androidx.camera:camera-video:1.6.2`. If the plugin moves to
another CameraX version, Gradle silently stops substituting, the app gets upstream
`camera-video` without F2, and the node leak comes back. Before such an upgrade:

1. Check whether the new `EncoderImpl` / the target devices' `CCodec` still leave the node behind.
2. If F2 is still needed, re-derive the patch against the new official sources, rebuild,
   re-verify, and re-validate on a device (thread counts over rotations, sessions, HOME/return,
   aborted START).
3. Re-check the safety invariant below in the new sources.

**Safety invariant (RF2-4).** A parked surface is handed to another codec, so the previous
encoder's codec must be released, and the camera must have finished producing into the surface,
before the surface is associated with the next encoder. In 1.6.2 this holds because:

- `SurfaceInput.getSurface()` is the only place that creates the persistent surface;
- `SurfaceInput.releaseSurface()` runs only from `releaseInternal()`, after `MediaCodec.release()`;
- `Encoder.release()` is only called once the frame producer is finished with the surface
  (`VideoEncoderSession` ReadyToRelease, `Recorder.tryReleaseVideoEncoder()`, camera-pipe
  `CameraSurfaceManager` use count reaching zero before `onSurfaceInactive`);
- the `Recorder` resets the stream id to ANY before releasing an encoder
  (`isStreamIdChanged` / `setLatestSurface`), so reusing the same `Surface` object does not look
  like the same stream.

## Known limits

- RF2-1: the residual is one node per surface in the pool, i.e. the peak number of video
  encoders alive at once (1 in the harness; may be 2 in the product when a new controller is
  created before the old encoder is released). Constant, not cumulative.
- RF2-3: a parked surface that is unusable but still `isValid()` would make one encoder setup
  fail (bind retries once a second; a reset failure puts the `Recorder` in error); the bad
  surface then leaves the pool. Not observed; no extra fallback was added.
- RF2-5: measured only on SM-A326B, Android 13, `c2.mtk.avc.encoder`. Android 15+ (`C2NodeImpl`),
  other OEMs and Codec2 `InputSurface` configurations are not validated.
- RF2-6: the pool never shrinks; a parked surface keeps an idle BufferQueue (and at most one
  node) for the life of the process.
- The javadoc of `Encoder.release()` says it releases the surface; with F2 the video encoder
  parks it instead. Left as is: the integrated patch is exactly the validated one.

## Removal

Delete the `R4.3-R2.6.22-INT` block at the end of `android/app/build.gradle.kts` and this folder,
then rebuild. The graph returns to upstream `androidx.camera:camera-video:1.6.2`.

## License

CameraX is Apache License 2.0 (`LICENSE.txt`, from AOSP `platform/frameworks/support`). The
modified file is `androidx/camera/video/internal/encoder/EncoderImpl.java`; the patch header and
the `R2.6.22-F2` comments in it mark the change.
