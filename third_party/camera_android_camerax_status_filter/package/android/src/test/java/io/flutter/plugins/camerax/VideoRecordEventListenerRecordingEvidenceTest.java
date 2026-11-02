// Synapse Auto (R4.4-HW-MIG-5-SIG-2.1): each listener is one physical recording. Every message it
// sends carries the identity Dart gave it through the real generated constructor, at most one
// videoProgress and one recordingEnded cross the private channel, Status still never reaches Pigeon,
// and a failure of the channel cannot touch the Finalize that STOP waits for.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import androidx.camera.video.RecordingStats;
import androidx.camera.video.VideoRecordEvent;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.StandardMessageCodec;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.Test;
import org.mockito.ArgumentCaptor;

public class VideoRecordEventListenerRecordingEvidenceTest {
  private static final String CHANNEL = "synapse_auto.camera_android_camerax/recording_evidence";
  private static final String ON_EVENT =
      "dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.onEvent";
  private static final String CONSTRUCTOR =
      "dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.pigeon_defaultConstructor";
  private static final String ALLOCATOR =
      "dev.flutter.pigeon.camera_android_camerax.VideoRecordEventListener.allocateRecordingIdentity";
  private static final int FRAMES_IN_A_SEGMENT = 5400;

  private static final long IDENTITY_A = 0x0123456789ABL;
  private static final long IDENTITY_B = IDENTITY_A + 1;

  // The same bytes are fed to the real Dart handler by recording_evidence_contract_test.dart, and
  // verify.sh fails if the two files stop agreeing.
  private static final String GOLDEN_PROGRESS =
      "0c03070d766964656f50726f677265737304ab8967452301000000";
  private static final String GOLDEN_ENDED =
      "0c03070e7265636f7264696e67456e64656404ab896745230100000303000000";

  private final TestProxyApiRegistrar registrar = new TestProxyApiRegistrar();
  private final BinaryMessenger messenger = registrar.getBinaryMessenger();
  private final VideoRecordEventListener listener = newListener(IDENTITY_A, 1L);

  private VideoRecordEventListener newListener(long identity, long instanceId) {
    final VideoRecordEventListener created =
        registrar.getPigeonApiVideoRecordEventListener().pigeon_defaultConstructor(identity);
    registrar.getInstanceManager().addDartCreatedInstance(created, instanceId);
    return created;
  }

  private static VideoRecordEvent.Status status(long durationNanos, long bytes) {
    final VideoRecordEvent.Status event = mock(VideoRecordEvent.Status.class);
    final RecordingStats stats = mock(RecordingStats.class);
    when(stats.getRecordedDurationNanos()).thenReturn(durationNanos);
    when(stats.getNumBytesRecorded()).thenReturn(bytes);
    when(event.getRecordingStats()).thenReturn(stats);
    return event;
  }

  private static VideoRecordEvent.Finalize finalizeEvent(int error) {
    final VideoRecordEvent.Finalize event = mock(VideoRecordEvent.Finalize.class);
    when(event.getError()).thenReturn(error);
    return event;
  }

  private List<ByteBuffer> sentBuffers() {
    final ArgumentCaptor<ByteBuffer> captor = ArgumentCaptor.forClass(ByteBuffer.class);
    verify(messenger, org.mockito.Mockito.atLeast(0)).send(eq(CHANNEL), captor.capture(), any());
    return captor.getAllValues();
  }

  /** The messages that crossed the private channel, decoded, in order. */
  private List<Object> evidence() {
    final List<Object> messages = new ArrayList<>();
    for (ByteBuffer buffer : sentBuffers()) {
      buffer.position(0);
      messages.add(StandardMessageCodec.INSTANCE.decodeMessage(buffer));
    }
    return messages;
  }

  private static String hex(ByteBuffer buffer) {
    buffer.position(0);
    final StringBuilder out = new StringBuilder();
    while (buffer.hasRemaining()) {
      out.append(String.format("%02x", buffer.get()));
    }
    return out.toString();
  }

  private static List<Object> progress(long identity) {
    return Arrays.asList("videoProgress", identity, null);
  }

  private static List<Object> ended(long identity, int error) {
    return Arrays.asList("recordingEnded", identity, error);
  }

  @Test
  public void wireFormat_isTheOneTheDartHandlerIsTestedWith() {
    listener.onEvent(status(1, 1));
    listener.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE));

    final List<ByteBuffer> sent = sentBuffers();
    assertEquals(3, VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE);
    assertEquals(GOLDEN_PROGRESS, hex(sent.get(0)));
    assertEquals(GOLDEN_ENDED, hex(sent.get(1)));
  }

  @Test
  public void generatedConstructor_bindsTheIdentityBeforeAnyCallback() {
    PigeonApiVideoRecordEventListener.Companion.setUpMessageHandlers(
        messenger, registrar.getPigeonApiVideoRecordEventListener());
    final ArgumentCaptor<BinaryMessenger.BinaryMessageHandler> handler =
        ArgumentCaptor.forClass(BinaryMessenger.BinaryMessageHandler.class);
    verify(messenger).setMessageHandler(eq(CONSTRUCTOR), handler.capture());
    final ByteBuffer message =
        registrar.getCodec().encodeMessage(Arrays.asList(7L, IDENTITY_B));
    message.position(0);

    handler.getValue().onMessage(message, mock(BinaryMessenger.BinaryReply.class));

    final VideoRecordEventListener bound = registrar.getInstanceManager().getInstance(7L);
    assertNotNull(bound);
    bound.onEvent(status(1, 1));
    assertEquals(List.of(progress(IDENTITY_B)), evidence());
  }

  @Test
  public void zeroDuration_sendsNothing_evenWithBytes() {
    // The first video sample has duration 0; a Status caused by audio has bytes and duration 0.
    listener.onEvent(status(0, 4096));

    assertEquals(List.of(), evidence());
  }

  @Test
  public void firstPositiveDuration_sendsOneMessage_andLaterStatusNone() {
    listener.onEvent(status(0, 100));
    listener.onEvent(status(33_000_000L, 200));
    for (int frame = 0; frame < FRAMES_IN_A_SEGMENT; frame++) {
      listener.onEvent(status(66_000_000L + frame, 300));
    }

    assertEquals(List.of(progress(IDENTITY_A)), evidence());
  }

  @Test
  public void statusFlood_neverReachesPigeonNorRegistersAProxy() {
    final List<VideoRecordEvent.Status> frames = new ArrayList<>();

    for (int frame = 1; frame <= FRAMES_IN_A_SEGMENT; frame++) {
      final VideoRecordEvent.Status event = status(frame, frame);
      frames.add(event);
      listener.onEvent(event);
    }

    verify(messenger, never()).send(eq(ON_EVENT), any(), any());
    for (VideoRecordEvent.Status event : frames) {
      assertFalse(registrar.getInstanceManager().containsInstance(event));
    }
  }

  @Test
  public void twoRecordings_withTheSamePath_sendPayloadsThatTellThemApart() {
    // Nothing about the file reaches the wire: this is why a reused path cannot confuse them.
    final VideoRecordEventListener second = newListener(IDENTITY_B, 2L);

    listener.onEvent(status(1, 1));
    second.onEvent(status(1, 1));
    listener.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE));
    second.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE));

    assertEquals(
        List.of(
            progress(IDENTITY_A),
            progress(IDENTITY_B),
            ended(IDENTITY_A, VideoRecordEvent.Finalize.ERROR_NONE),
            ended(IDENTITY_B, VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE)),
        evidence());
  }

  @Test
  public void twoLiveRecordingsInterleaved_doNotBecomeOneMessagePerFrame() {
    final VideoRecordEventListener second = newListener(IDENTITY_B, 2L);

    for (int frame = 1; frame <= 100; frame++) {
      listener.onEvent(status(frame, frame));
      second.onEvent(status(frame, frame));
    }

    assertEquals(List.of(progress(IDENTITY_A), progress(IDENTITY_B)), evidence());
  }

  @Test
  public void finalizeWithoutProgress_sendsOnlyTheTerminal() {
    listener.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NO_VALID_DATA));

    assertEquals(List.of(ended(IDENTITY_A, VideoRecordEvent.Finalize.ERROR_NO_VALID_DATA)), evidence());
  }

  @Test
  public void finalizeWithError_sendsTheError_andStillCrossesPigeonOnce() {
    final VideoRecordEvent.Finalize event =
        finalizeEvent(VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE);

    listener.onEvent(event);

    assertEquals(
        List.of(ended(IDENTITY_A, VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE)),
        evidence());
    verify(messenger, times(1)).send(eq(ON_EVENT), any(), any());
    assertTrue(registrar.getInstanceManager().containsInstance(event));
  }

  @Test
  public void afterTheTerminal_noProgressAndNoSecondTerminal_butPigeonSeesEveryFinalize() {
    listener.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE));
    listener.onEvent(status(1, 1));
    listener.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE));

    assertEquals(List.of(ended(IDENTITY_A, VideoRecordEvent.Finalize.ERROR_NONE)), evidence());
    verify(messenger, times(2)).send(eq(ON_EVENT), any(), any());
  }

  @Test
  public void channelFailure_isNotRetriedByLaterFrames_andFinalizeStillCrossesPigeon() {
    doThrow(new IllegalStateException("detached")).when(messenger).send(eq(CHANNEL), any(), any());

    for (int frame = 1; frame <= FRAMES_IN_A_SEGMENT; frame++) {
      listener.onEvent(status(frame, frame));
    }
    listener.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE));

    assertEquals("one progress attempt and one terminal attempt", 2, sentBuffers().size());
    verify(messenger, times(1)).send(eq(ON_EVENT), any(), any());
  }

  @Test
  public void afterTheEngineDetached_nothingIsSent_likeTheGeneratedApi() {
    registrar.setIgnoreCallsToDart(true);

    listener.onEvent(status(1, 1));
    listener.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE));

    assertEquals(List.of(), evidence());
    verify(messenger, never()).send(eq(ON_EVENT), any(), any());
  }

  // Synapse Auto (R4.4-HW-MIG-5-SIG-2.3): what the JVM can show about the allocator. Two registrars stand
  // for two engines of one process; no real engine or hot restart runs here.
  @Test
  public void allocator_neverRepeatsAcrossApisAndRegistrars() {
    final VideoRecordEventListenerProxyApi first =
        new VideoRecordEventListenerProxyApi(registrar);
    final VideoRecordEventListenerProxyApi second =
        new VideoRecordEventListenerProxyApi(new TestProxyApiRegistrar());

    final long a = first.allocateRecordingIdentity();
    final long b = second.allocateRecordingIdentity();
    final long c = first.allocateRecordingIdentity();

    assertTrue("positive", a > 0);
    assertTrue("a new api continues the same counter", b > a);
    assertTrue("and the first one sees that", c > b);
  }

  // Synapse Auto (R4.4-HW-MIG-5-SIG-2.4): the limit, on the real method and the real static field, of a
  // private copy of the plugin's classes: a second loader gives that field its own value, so the counter
  // the rest of this process shares is never set, and production needs no seam for it. 2^63 increments
  // are not run: the copy's counter is placed near the limit.
  private static final class PluginClassesCopy extends ClassLoader {
    PluginClassesCopy() {
      super(VideoRecordEventListenerRecordingEvidenceTest.class.getClassLoader());
    }

    @Override
    protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
      if (!name.startsWith("io.flutter.plugins.camerax.")) {
        return super.loadClass(name, resolve);
      }
      synchronized (this) {
        final Class<?> loaded = findLoadedClass(name);
        if (loaded != null) {
          return loaded;
        }
        try (InputStream in = getParent().getResourceAsStream(name.replace('.', '/') + ".class")) {
          if (in == null) {
            throw new ClassNotFoundException(name);
          }
          final byte[] bytes = in.readAllBytes();
          return defineClass(name, bytes, 0, bytes.length);
        } catch (IOException e) {
          throw new ClassNotFoundException(name, e);
        }
      }
    }
  }

  private static final class CopyOfAllocator {
    final ClassLoader loader = new PluginClassesCopy();
    final AtomicLong counter;
    final Object api;
    final Method allocate;

    CopyOfAllocator(long last) throws Exception {
      final Class<?> apiClass =
          loader.loadClass("io.flutter.plugins.camerax.VideoRecordEventListenerProxyApi");
      assertNotSame(
          "must not be the class the other tests share",
          VideoRecordEventListenerProxyApi.class,
          apiClass);
      final Field field = apiClass.getDeclaredField("LAST_RECORDING_IDENTITY");
      field.setAccessible(true);
      counter = (AtomicLong) field.get(null);
      counter.set(last);
      final Object copyRegistrar =
          loader
              .loadClass("io.flutter.plugins.camerax.TestProxyApiRegistrar")
              .getDeclaredConstructor()
              .newInstance();
      final Constructor<?> constructor = apiClass.getDeclaredConstructors()[0];
      constructor.setAccessible(true);
      api = constructor.newInstance(copyRegistrar);
      allocate = apiClass.getDeclaredMethod("allocateRecordingIdentity");
      allocate.setAccessible(true);
    }

    long next() throws Exception {
      try {
        return (Long) allocate.invoke(api);
      } catch (InvocationTargetException e) {
        throw (Exception) e.getCause();
      }
    }

    void assertRefused() {
      final IllegalStateException refused = assertThrows(IllegalStateException.class, this::next);
      assertEquals("Recording identities exhausted", refused.getMessage());
    }

    /** The handler Pigeon generates for this copy, on a messenger of the test. */
    BinaryMessenger.BinaryMessageHandler generatedHandler(BinaryMessenger on) throws Exception {
      final Class<?> pigeon =
          loader.loadClass("io.flutter.plugins.camerax.PigeonApiVideoRecordEventListener");
      final Object companion = pigeon.getField("Companion").get(null);
      final Method setUp =
          companion
              .getClass()
              .getDeclaredMethod("setUpMessageHandlers", BinaryMessenger.class, pigeon);
      setUp.setAccessible(true);
      setUp.invoke(companion, on, api);
      final ArgumentCaptor<BinaryMessenger.BinaryMessageHandler> handler =
          ArgumentCaptor.forClass(BinaryMessenger.BinaryMessageHandler.class);
      verify(on).setMessageHandler(eq(ALLOCATOR), handler.capture());
      return handler.getValue();
    }
  }

  private static List<?> replyOf(BinaryMessenger.BinaryMessageHandler handler) {
    final BinaryMessenger.BinaryReply reply = mock(BinaryMessenger.BinaryReply.class);
    handler.onMessage(null, reply);
    final ArgumentCaptor<ByteBuffer> replied = ArgumentCaptor.forClass(ByteBuffer.class);
    verify(reply).reply(replied.capture());
    replied.getValue().position(0);
    return (List<?>) StandardMessageCodec.INSTANCE.decodeMessage(replied.getValue());
  }

  @Test
  public void allocatorT1_fromAFreshCounter_countsOneByOneFromOne() throws Exception {
    final CopyOfAllocator allocator = new CopyOfAllocator(0);
    for (long expected = 1; expected <= 1000; expected++) {
      assertEquals(expected, allocator.next());
    }
    assertEquals(1000, allocator.counter.get());
  }

  @Test
  public void allocatorT2_threadsAtTheLimit_shareExactlyTheNumbersLeft() throws Exception {
    final int left = 1000;
    final int threads = 8;
    final int attemptsEach = 500;
    final CopyOfAllocator allocator = new CopyOfAllocator(Long.MAX_VALUE - 1 - left);
    final List<Long> issued = Collections.synchronizedList(new ArrayList<>());
    final AtomicLong refused = new AtomicLong();
    final List<Throwable> unexpected = Collections.synchronizedList(new ArrayList<>());
    final CountDownLatch go = new CountDownLatch(1);
    final CountDownLatch done = new CountDownLatch(threads);
    for (int t = 0; t < threads; t++) {
      new Thread(
              () -> {
                try {
                  go.await();
                  for (int i = 0; i < attemptsEach; i++) {
                    try {
                      issued.add(allocator.next());
                    } catch (IllegalStateException e) {
                      refused.incrementAndGet();
                    }
                  }
                } catch (Exception e) {
                  unexpected.add(e);
                } finally {
                  done.countDown();
                }
              })
          .start();
    }
    go.countDown();
    done.await();

    assertEquals(List.of(), unexpected);
    assertEquals("each number once, none lost", left, issued.size());
    assertEquals(left, new HashSet<>(issued).size());
    assertEquals(Long.MAX_VALUE - left, (long) Collections.min(issued));
    assertEquals(Long.MAX_VALUE - 1, (long) Collections.max(issued));
    assertEquals(threads * attemptsEach - left, refused.get());
    assertEquals(Long.MAX_VALUE, allocator.counter.get());
  }

  @Test
  public void allocatorT3_issuesTheLastValuesInOrder_endingAtMaxMinusOne() throws Exception {
    final CopyOfAllocator allocator = new CopyOfAllocator(Long.MAX_VALUE - 3);
    assertEquals(Long.MAX_VALUE - 2, allocator.next());
    assertEquals(Long.MAX_VALUE - 1, allocator.next());
    assertEquals("not exhausted yet", Long.MAX_VALUE - 1, allocator.counter.get());
    allocator.assertRefused();
  }

  @Test
  public void allocatorT4_reachingTheSentinel_failsAndIsTheTerminalState() throws Exception {
    final CopyOfAllocator allocator = new CopyOfAllocator(Long.MAX_VALUE - 1);
    allocator.assertRefused();
    assertEquals(Long.MAX_VALUE, allocator.counter.get());
  }

  @Test
  public void allocatorT5_everyLaterCallFails_withTheStateUnmoved() throws Exception {
    final CopyOfAllocator allocator = new CopyOfAllocator(Long.MAX_VALUE - 1);
    allocator.assertRefused();
    for (int i = 0; i < 10000; i++) {
      allocator.assertRefused();
      assertEquals("refusing moves nothing", Long.MAX_VALUE, allocator.counter.get());
    }
  }

  @Test
  public void allocatorT6_exhaustedGeneratedReply_isAnErrorWithNoIdentityInIt() throws Exception {
    final CopyOfAllocator allocator = new CopyOfAllocator(Long.MAX_VALUE);
    final BinaryMessenger.BinaryMessageHandler handler =
        allocator.generatedHandler(mock(BinaryMessenger.class));

    for (int i = 0; i < 3; i++) {
      final List<?> reply = replyOf(handler);
      assertEquals("Pigeon's error: code, message, details", 3, reply.size());
      assertEquals("IllegalStateException", reply.get(0));
      assertEquals("java.lang.IllegalStateException: Recording identities exhausted", reply.get(1));
    }
    assertEquals(Long.MAX_VALUE, allocator.counter.get());
  }

  @Test
  public void allocatorT7_aCounterOutOfRange_issuesNothing() throws Exception {
    for (long invalid : new long[] {Long.MIN_VALUE, Long.MIN_VALUE + 1, -2, -1}) {
      final CopyOfAllocator allocator = new CopyOfAllocator(invalid);
      allocator.assertRefused();
      assertEquals("and stays out of the way back to 1", invalid, allocator.counter.get());
    }
    assertEquals("zero is the start, never an identity", 1, new CopyOfAllocator(0).next());
  }

  @Test
  public void allocatorT8_theLastIdentity_crossesLongAndIsTheOneTheListenerSends() throws Exception {
    final CopyOfAllocator allocator = new CopyOfAllocator(Long.MAX_VALUE - 2);
    final List<?> reply = replyOf(allocator.generatedHandler(mock(BinaryMessenger.class)));
    assertEquals(1, reply.size());
    final long identity = ((Number) reply.get(0)).longValue();
    assertEquals(Long.MAX_VALUE - 1, identity);

    newListener(identity, 2L).onEvent(status(1, 1));

    assertEquals(List.of(progress(Long.MAX_VALUE - 1)), evidence());
  }

  @Test
  public void allocatorCopy_leavesTheCounterTheOtherTestsShareAlone() throws Exception {
    final VideoRecordEventListenerProxyApi shared = new VideoRecordEventListenerProxyApi(registrar);
    final long before = shared.allocateRecordingIdentity();
    new CopyOfAllocator(Long.MAX_VALUE).assertRefused();
    assertTrue(shared.allocateRecordingIdentity() > before);
  }

  @Test
  public void allocator_isSafeUnderConcurrency() throws InterruptedException {
    final VideoRecordEventListenerProxyApi api = new VideoRecordEventListenerProxyApi(registrar);
    final Set<Long> seen = ConcurrentHashMap.newKeySet();
    final int threads = 8;
    final int each = 2000;
    final CountDownLatch go = new CountDownLatch(1);
    final CountDownLatch done = new CountDownLatch(threads);
    for (int t = 0; t < threads; t++) {
      new Thread(
              () -> {
                try {
                  go.await();
                  for (int i = 0; i < each; i++) {
                    seen.add(api.allocateRecordingIdentity());
                  }
                } catch (InterruptedException e) {
                  Thread.currentThread().interrupt();
                } finally {
                  done.countDown();
                }
              })
          .start();
    }
    go.countDown();
    done.await();
    assertEquals(threads * each, seen.size());
  }

  @Test
  public void generatedAllocator_repliesWithTheValue_andTheListenerCarriesIt() {
    PigeonApiVideoRecordEventListener.Companion.setUpMessageHandlers(
        messenger, registrar.getPigeonApiVideoRecordEventListener());
    final ArgumentCaptor<BinaryMessenger.BinaryMessageHandler> handler =
        ArgumentCaptor.forClass(BinaryMessenger.BinaryMessageHandler.class);
    verify(messenger).setMessageHandler(eq(ALLOCATOR), handler.capture());
    final BinaryMessenger.BinaryReply reply = mock(BinaryMessenger.BinaryReply.class);

    handler.getValue().onMessage(null, reply);

    final ArgumentCaptor<ByteBuffer> replied = ArgumentCaptor.forClass(ByteBuffer.class);
    verify(reply).reply(replied.capture());
    replied.getValue().position(0);
    final long identity =
        (Long) ((List<?>) registrar.getCodec().decodeMessage(replied.getValue())).get(0);
    assertTrue(identity > 0);

    newListener(identity, 2L).onEvent(status(1, 1));
    assertEquals(List.of(progress(identity)), evidence());
  }

  @Test
  public void oldEngineDetached_itsListenerIsSilent_andTheNewEnginesIdentityDiffers() {
    final long old = registrar.getPigeonApiVideoRecordEventListener().allocateRecordingIdentity();
    final VideoRecordEventListener survivor = newListener(old, 2L);
    registrar.setIgnoreCallsToDart(true);

    final TestProxyApiRegistrar next = new TestProxyApiRegistrar();
    final long current = next.getPigeonApiVideoRecordEventListener().allocateRecordingIdentity();
    assertTrue(current > old);
    survivor.onEvent(status(1, 1));
    survivor.onEvent(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE));

    assertEquals("the detached registrar reactivates for nobody", List.of(), evidence());
    verify(next.getBinaryMessenger(), never()).send(eq(CHANNEL), any(), any());
  }

  @Test
  public void startCrossesPigeonOnly() {
    final VideoRecordEvent.Start event = mock(VideoRecordEvent.Start.class);

    listener.onEvent(event);

    assertEquals(List.of(), evidence());
    verify(messenger, times(1)).send(eq(ON_EVENT), any(), any());
  }
}
