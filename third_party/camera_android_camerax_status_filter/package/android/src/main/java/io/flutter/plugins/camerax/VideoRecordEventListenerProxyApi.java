// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import androidx.annotation.NonNull;
import androidx.camera.video.VideoRecordEvent;
import java.util.Objects;

/**
 * ProxyApi implementation for {@link VideoRecordEventListener}. This class may handle instantiating
 * native object instances that are attached to a Dart instance or handle method calls on the
 * associated native class or an instance of that class.
 */
class VideoRecordEventListenerProxyApi extends PigeonApiVideoRecordEventListener {
  VideoRecordEventListenerProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  /**
   * Implementation of {@link VideoRecordEventListener} that passes arguments of callback methods to
   * Dart.
   */
  static class VideoRecordEventListenerImpl implements VideoRecordEventListener {
    final VideoRecordEventListenerProxyApi api;

    VideoRecordEventListenerImpl(@NonNull VideoRecordEventListenerProxyApi api) {
      this.api = api;
    }

    @Override
    public void onEvent(@NonNull VideoRecordEvent event) {
      // Synapse Auto (R4.4-HW-MIG-4): CameraX emits one Status per encoded frame and nothing in
      // Dart reads it. Forwarding it creates one Pigeon proxy per frame (~5,400 in a 3-minute
      // segment); releasing them in one Dart GC floods the main thread for seconds, and on the
      // SM-A125M that delayed the next recording by 7-20 s.
      if (event instanceof VideoRecordEvent.Status) {
        return;
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
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @NonNull
  @Override
  public VideoRecordEventListener pigeon_defaultConstructor() {
    return new VideoRecordEventListenerImpl(this);
  }
}
