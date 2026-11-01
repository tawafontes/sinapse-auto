# Patches

## 0001 — F2: reuse the persistent input surface across video encoders

File: `patches/0001-EncoderImpl-reuse-persistent-input-surface-F2.patch`, against
`androidx/camera/video/internal/encoder/EncoderImpl.java` of camera-video 1.6.2 (see
[UPSTREAM.md](UPSTREAM.md)). +48 / −1 lines, all in `EncoderImpl`:

| where | change |
|---|---|
| `EncoderImpl` static fields | `sParkedInputSurfacesLock` and `sParkedInputSurfaces` (`ArrayDeque<Surface>`, `@GuardedBy`), with the comment that explains the leak |
| `SurfaceInput.releaseSurface()` | after `mSurface = null` (unchanged): an invalid surface is released as before; a valid one is appended to the pool instead of `surface.release()`; debug log `R2.6.22-F2 parked input surface …, parked=N` |
| `SurfaceInput.getSurface()` | when it has no surface, first takes one from the pool (`takeParkedSurface()`), and only then calls `MediaCodec.createPersistentInputSurface()` |
| new `SurfaceInput.takeParkedSurface()` | `pollFirst()` under the pool lock, releases invalid surfaces it meets, returns the first valid one; debug log `R2.6.22-F2 reusing parked input surface …` |

Nothing else changes: `reset()`, `resetSurface()` (still `setInputSurface(getSurface())` in the
constructor and after every STOP), `start/stop/release/releaseInternal`, the callbacks and the
audio `ByteBufferInput` are the upstream code. The timing of every `setInputSurface` is unchanged.
No reflection, no hidden API, no new timeout.

### Why it frees the orphan node

`GraphicBufferSource::configure()` (AOSP, in the app process on Android 13) replaces its
`mComponent` — the reference that keeps the `C2OMXNode` of a never-started codec alive — and is
run by every `setInputSurface` of that same persistent surface. `release()` of a configured codec
does not disconnect it (`CCodec::initiateRelease` only disconnects in STARTING/RUNNING/STOPPING),
and no public `MediaCodec` call can undo the association without `start()`. Handing the surface
to the next codec is the documented use of a persistent surface ("can be reused by subsequent
MediaCodec … instances, but … by at most one codec … concurrently") and is what `EncoderImpl`
already does between its own resets.

### Validation history

| round | result |
|---|---|
| R2.6.22 diagnosis + review | orphan = `setInputSurface` on a codec released without `start()`; minimum fix boundary is `EncoderImpl` |
| R2.6.22-F1 (harness) | F1 breaks the camera stream (1×1); F1R leaves bind/unbind and HOME/return growing — **neither is in this patch** |
| R2.6.22-F2 (harness, SM-A326B, 2026-10-21) | verdict A: `C2OMXNode` 20→1 (bind/unbind), 20→1 (rotation), 20→1 (sessions), 21→1 (aborted START, codec never started), 41→1 (HOME/resume), 70→1 (all paths mixed); Start/Finalize exactly once in 225/225 recordings, codes equal to CONTROL per recording; 172/172 MP4 clean; latency equal; REV (patch reverted) reproduces the leak |
| independent review (2026-10-21) | verdict A: patch rebuilt from the official sources = harness AAR; ownership single-owner by construction; no use-after-release / harmful double release / two codecs on one surface; findings RF2-1…RF2-6 (README "Known limits") |
| R2.6.22-INT (this integration) | product validation on the SM-A326B — see the round report |

### Equivalence with the validated F2

Checked when this folder was created (2026-10-22) and, for the class files, on every `build.sh` run:

- the patch hunks are identical to the harness diff (`F2_parked_input_surface.diff`) and to the
  review's independent diff;
- applying the patch to the official `EncoderImpl.java` gives sha256 `3f969cef…`, the source
  compiled in the harness (`EncoderImpl_F2.java`);
- the ten `EncoderImpl*.class` files are **byte-identical** to the classes of the harness AAR
  `camera-video-1.6.2-f2.aar` (sha256 `1d98185b…`) that ran on the SM-A326B;
- `javap -c -p` (constant-pool indices removed) differs from upstream only in `EncoderImpl` and
  `EncoderImpl$SurfaceInput`; the other eight inner classes are bytecode-identical (their bytes
  differ only in line-number tables shifted by the inserted lines, and `EncoderImpl$2` also in two
  local-variable names, as in the harness);
- `javap -protected` of `EncoderImpl` and `EncoderImpl$SurfaceInput` is identical to upstream
  (public/protected ABI unchanged). New members: two `private static final` fields, one `private`
  method, two synthetic package accessors (`access$300`, `access$400`);
- the AAR differs from upstream only in `classes.jar`, and `classes.jar` only in those ten
  entries (same entry list and order, same entry dates).

### Not included on purpose

- F1 / F1R (deferred input-surface association): rejected / not needed.
- A fallback for a parked surface that is unusable but `isValid()` (RF2-3): not observed; would be
  a new design decision.
- The `Encoder.release()` javadoc ("releases the surface"): unchanged, to keep the patch identical
  to the validated one.
