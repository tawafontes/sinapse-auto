// Synapse Auto (R4.4-HW-MIG-4): VideoRecordEvent.Status must not cross Pigeon; every other event
// must cross exactly once, in the order CameraX delivered it, as the same object.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import androidx.camera.video.RecordingStats;
import androidx.camera.video.VideoRecordEvent;
import io.flutter.plugin.common.BinaryMessenger;
import java.util.ArrayList;
import java.util.List;
import org.junit.Test;

public class VideoRecordEventListenerStatusFilterTest {
  private static final String ON_EVENT =
      "dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.onEvent";
  private static final int FRAMES_IN_A_SEGMENT = 5400;

  /** Listener over a mocked api that records what would be sent to Dart. */
  private static class Fixture {
    final VideoRecordEventListenerProxyApi api = mock(VideoRecordEventListenerProxyApi.class);
    final List<VideoRecordEvent> sent = new ArrayList<>();
    final VideoRecordEventListenerProxyApi.VideoRecordEventListenerImpl listener;

    Fixture() {
      when(api.getPigeonRegistrar()).thenReturn(new TestProxyApiRegistrar());
      doAnswer(
              invocation -> {
                sent.add(invocation.getArgument(1));
                return null;
              })
          .when(api)
          .onEvent(any(), any(), any());
      listener = new VideoRecordEventListenerProxyApi.VideoRecordEventListenerImpl(api, 1L);
    }
  }

  private static VideoRecordEvent.Status status() {
    final VideoRecordEvent.Status event = mock(VideoRecordEvent.Status.class);
    final RecordingStats stats = mock(RecordingStats.class);
    when(event.getRecordingStats()).thenReturn(stats);
    return event;
  }

  private static VideoRecordEvent.Start start() {
    return mock(VideoRecordEvent.Start.class);
  }

  private static VideoRecordEvent.Finalize finalizeEvent() {
    return mock(VideoRecordEvent.Finalize.class);
  }

  @Test
  public void status_stopsBeforeAnyPigeonWork() {
    final Fixture f = new Fixture();

    f.listener.onEvent(status());

    verify(f.api, never()).onEvent(any(), any(), any());
    // Not even scheduled on the main thread: the filter runs before runOnMainThread.
    verify(f.api, never()).getPigeonRegistrar();
  }

  @Test
  public void start_crossesOnceAsTheSameObject() {
    final Fixture f = new Fixture();
    final VideoRecordEvent.Start event = start();

    f.listener.onEvent(event);

    assertEquals(1, f.sent.size());
    assertSame(event, f.sent.get(0));
  }

  @Test
  public void finalizeWithError_crossesOnceWithItsErrorOutputAndStatsIntact() {
    final Fixture f = new Fixture();
    final VideoRecordEvent.Finalize event = finalizeEvent();
    when(event.getError()).thenReturn(VideoRecordEvent.Finalize.ERROR_ENCODING_FAILED);
    when(event.hasError()).thenReturn(true);

    f.listener.onEvent(event);

    assertEquals(1, f.sent.size());
    final VideoRecordEvent.Finalize received = (VideoRecordEvent.Finalize) f.sent.get(0);
    assertSame(event, received);
    assertTrue(received.hasError());
    assertEquals(VideoRecordEvent.Finalize.ERROR_ENCODING_FAILED, received.getError());
  }

  @Test
  public void pauseAndResume_areNotFiltered() {
    final Fixture f = new Fixture();
    final VideoRecordEvent.Pause pause = mock(VideoRecordEvent.Pause.class);
    final VideoRecordEvent.Resume resume = mock(VideoRecordEvent.Resume.class);

    f.listener.onEvent(pause);
    f.listener.onEvent(resume);

    assertEquals(List.of(pause, resume), f.sent);
  }

  @Test
  public void multipleRecordings_onlyStartAndFinalizeOfEachCross() {
    final Fixture f = new Fixture();
    final List<VideoRecordEvent> expected = new ArrayList<>();

    for (int recording = 0; recording < 3; recording++) {
      final VideoRecordEvent.Start s = start();
      final VideoRecordEvent.Finalize e = finalizeEvent();
      expected.add(s);
      expected.add(e);
      f.listener.onEvent(s);
      for (int frame = 0; frame < FRAMES_IN_A_SEGMENT; frame++) {
        f.listener.onEvent(status());
      }
      f.listener.onEvent(e);
    }

    assertEquals(expected, f.sent);
  }

  @Test
  public void abortedStart_finalizeWithoutStartStillCrosses() {
    final Fixture f = new Fixture();
    final VideoRecordEvent.Finalize aborted = finalizeEvent();
    when(aborted.getError()).thenReturn(VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE);

    f.listener.onEvent(aborted);

    assertEquals(List.of(aborted), f.sent);
  }

  @Test
  public void outOfOrderEvents_keepTheirOrderAndStatusAroundThemIsDropped() {
    final Fixture f = new Fixture();
    final VideoRecordEvent.Finalize stale = finalizeEvent();
    final VideoRecordEvent.Start s = start();
    final VideoRecordEvent.Finalize e = finalizeEvent();

    f.listener.onEvent(status());
    f.listener.onEvent(stale);
    f.listener.onEvent(status());
    f.listener.onEvent(s);
    f.listener.onEvent(e);
    f.listener.onEvent(status());

    assertEquals(List.of(stale, s, e), f.sent);
  }

  /** The real generated api and codec: what reaches the BinaryMessenger and InstanceManager. */
  @Test
  public void realPigeonPath_statusCreatesNoMessageAndNoProxy() {
    final TestProxyApiRegistrar registrar = new TestProxyApiRegistrar();
    final BinaryMessenger messenger = registrar.getBinaryMessenger();
    final VideoRecordEventListener listener =
        registrar.getPigeonApiVideoRecordEventListener().pigeon_defaultConstructor(1L);
    registrar.getInstanceManager().addDartCreatedInstance(listener, 1L);
    final List<VideoRecordEvent.Status> frames = new ArrayList<>();

    for (int frame = 0; frame < FRAMES_IN_A_SEGMENT; frame++) {
      final VideoRecordEvent.Status event = status();
      frames.add(event);
      listener.onEvent(event);
    }

    verify(messenger, never()).send(any(), any(), any());
    for (VideoRecordEvent.Status event : frames) {
      assertFalse(registrar.getInstanceManager().containsInstance(event));
    }
  }

  @Test
  public void realPigeonPath_startAndFinalizeEachSendOneOnEventAndRegisterOneProxy() {
    final TestProxyApiRegistrar registrar = new TestProxyApiRegistrar();
    final BinaryMessenger messenger = registrar.getBinaryMessenger();
    final VideoRecordEventListener listener =
        registrar.getPigeonApiVideoRecordEventListener().pigeon_defaultConstructor(1L);
    registrar.getInstanceManager().addDartCreatedInstance(listener, 1L);
    final VideoRecordEvent.Start s = start();
    final VideoRecordEvent.Finalize e = finalizeEvent();

    listener.onEvent(s);
    verify(messenger, times(1)).send(eq(ON_EVENT), any(), any());
    assertTrue(registrar.getInstanceManager().containsInstance(s));

    listener.onEvent(status());
    verify(messenger, times(1)).send(eq(ON_EVENT), any(), any());

    listener.onEvent(e);
    verify(messenger, times(2)).send(eq(ON_EVENT), any(), any());
    assertTrue(registrar.getInstanceManager().containsInstance(e));
  }
}
