// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.util.Log;
import androidx.annotation.NonNull;
import androidx.camera.video.VideoRecordEvent;
import io.flutter.plugin.common.BasicMessageChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import java.util.Arrays;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicLong;

/**
 * ProxyApi implementation for {@link VideoRecordEventListener}. This class may handle instantiating
 * native object instances that are attached to a Dart instance or handle method calls on the
 * associated native class or an instance of that class.
 */
class VideoRecordEventListenerProxyApi extends PigeonApiVideoRecordEventListener {
  // Keep the name in sync with android_camera_camerax.dart.
  private static final String RECORDING_EVIDENCE_CHANNEL =
      "synapse_auto.camera_android_camerax/recording_evidence";

  // Synapse Auto (R4.4-HW-MIG-5-SIG-2.3): the one source of recording identities. Static, so it outlives
  // a Dart hot restart and a new engine, and only the death of the process, which also ends every
  // listener and pending message, starts it over. Never a value a recording of this process had.
  private static final AtomicLong LAST_RECORDING_IDENTITY = new AtomicLong();

  VideoRecordEventListenerProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  /**
   * Implementation of {@link VideoRecordEventListener} that passes arguments of callback methods to
   * Dart.
   */
  static class VideoRecordEventListenerImpl implements VideoRecordEventListener {
    final VideoRecordEventListenerProxyApi api;

    // Synapse Auto (R4.4-HW-MIG-5-SIG-2.1): Dart creates one listener per physical recording, with
    // this identity, before PendingRecording.start. So it is fixed before CameraX can call back, and
    // every message below says which recording it is about, wherever it is by the time it arrives.
    // The path cannot say that: a later recording may get the same path.
    private final long recordingIdentity;

    // One recording, so one fact each: at most one videoProgress and one recordingEnded. Touched only
    // on the main executor PendingRecordingProxyApi.start gives CameraX, so without a lock.
    private boolean progressReported;
    private boolean endReported;

    VideoRecordEventListenerImpl(
        @NonNull VideoRecordEventListenerProxyApi api, long recordingIdentity) {
      this.api = api;
      this.recordingIdentity = recordingIdentity;
    }

    @Override
    public void onEvent(@NonNull VideoRecordEvent event) {
      // Synapse Auto (R4.4-HW-MIG-4): CameraX emits one Status per encoded frame and nothing in
      // Dart reads it. Forwarding it creates one Pigeon proxy per frame (~5,400 in a 3-minute
      // segment); releasing them in one Dart GC floods the main thread for seconds, and on the
      // SM-A125M that delayed the next recording by 7-20 s.
      if (event instanceof VideoRecordEvent.Status) {
        reportVideoProgressOnce((VideoRecordEvent.Status) event);
        return;
      }
      if (event instanceof VideoRecordEvent.Finalize) {
        reportRecordingEndedOnce((VideoRecordEvent.Finalize) event);
      }
      api.getPigeonRegistrar()
          .runOnMainThread(
              new ProxyApiRegistrar.FlutterMethodRunnable() {
                @Override
                public void run() {
                  api.onEvent(
                      VideoRecordEventListenerImpl.this,
                      event,
                      ResultCompat.asCompatCallback(
                          result -> {
                            if (result.isFailure()) {
                              onFailure(
                                  "VideoRecordEventListener.onEvent",
                                  Objects.requireNonNull(result.exceptionOrNull()));
                            }
                            return null;
                          }));
                }
              });
    }

    // In CameraX 1.6.2 only Recorder.writeVideoData writes this duration, after writeSampleData
    // returned, and it is 0 for the first sample. Audio never writes it, unlike
    // getNumBytesRecorded(), so a Status caused by audio cannot pass this.
    private void reportVideoProgressOnce(@NonNull VideoRecordEvent.Status event) {
      if (progressReported
          || endReported
          || event.getRecordingStats().getRecordedDurationNanos() <= 0) {
        return;
      }
      // Before sending: a channel that throws must not be tried again at every frame.
      progressReported = true;
      sendRecordingEvidence("videoProgress", null);
    }

    private void reportRecordingEndedOnce(@NonNull VideoRecordEvent.Finalize event) {
      if (endReported) {
        return;
      }
      endReported = true;
      sendRecordingEvidence("recordingEnded", event.getError());
    }

    // Never lets a failure reach onEvent: the Finalize that STOP waits for goes out right after it.
    private void sendRecordingEvidence(String kind, Integer error) {
      // The engine went away and CameraX may still call back: the same rule as the generated api.
      if (api.getPigeonRegistrar().getIgnoreCallsToDart()) {
        return;
      }
      try {
        new BasicMessageChannel<>(
                api.getPigeonRegistrar().getBinaryMessenger(),
                RECORDING_EVIDENCE_CHANNEL,
                StandardMessageCodec.INSTANCE)
            .send(Arrays.asList(kind, recordingIdentity, error));
      } catch (RuntimeException exception) {
        Log.w("VideoRecordEventListener", "Could not send recording evidence", exception);
      }
    }
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @NonNull
  @Override
  public VideoRecordEventListener pigeon_defaultConstructor(long recordingIdentity) {
    return new VideoRecordEventListenerImpl(this, recordingIdentity);
  }

  @Override
  public long allocateRecordingIdentity() {
    // Synapse Auto (R4.4-HW-MIG-5-SIG-2.4): 2^63 STARTs do not happen; if they did, every START of this
    // process fails rather than reuses a number. Long.MAX_VALUE is never issued: it means exhausted, and
    // nothing moves the counter from there. A failure leaves it where it is, unlike incrementAndGet,
    // which kept counting after refusing and came back to 1 after going through the negatives.
    // Below zero is not reachable from here; it is refused so that no such state can ever issue a number.
    while (true) {
      final long last = LAST_RECORDING_IDENTITY.get();
      if (last < 0 || last == Long.MAX_VALUE) {
        throw new IllegalStateException("Recording identities exhausted");
      }
      final long identity = last + 1;
      if (LAST_RECORDING_IDENTITY.compareAndSet(last, identity)) {
        if (identity == Long.MAX_VALUE) {
          throw new IllegalStateException("Recording identities exhausted");
        }
        return identity;
      }
    }
  }
}
