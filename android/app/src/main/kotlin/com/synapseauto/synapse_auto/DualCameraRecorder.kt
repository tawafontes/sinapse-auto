package com.synapseauto.synapse_auto

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.camera.core.AspectRatio
import androidx.camera.core.CameraSelector
import androidx.camera.core.CompositionSettings
import androidx.camera.core.ConcurrentCamera.SingleCameraConfig
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * The dashcam's "Ambas" mode (dual camera, phase 2, 2026-11-14): the back and
 * front cameras bound together through CameraX's concurrent camera, composed
 * into ONE Preview and ONE VideoCapture — one encoder, one file, one audio
 * track — with the secondary camera as a picture-in-picture a third of the
 * size in the lower right corner (owner decisions; measured by the phase 0
 * probe on the SM-S918B — `docs/dashcam/dual_camera_handoff.md`).
 *
 * Driven from Dart by `DashcamCameraPlatform`, which presents it to the
 * dashcam as one more camera, so `DashcamService` records with it exactly as
 * with the camera plugin. It reports the same facts the plugin's fork does
 * for each recording, identified by the token Dart gave at START: video
 * progress (`recordedDurationNanos > 0`) and the Finalize with its error.
 *
 * What the probe established and this relies on:
 *  * the composed frame's orientation is fixed when the cameras are bound, so
 *    [open] binds at the current display rotation and [start] rebinds first
 *    when the display turned since (Dart closes the running segment on a turn
 *    — owner decision: follow the turn, accepting ~1 s without video);
 *  * in concurrent mode CameraX refuses to unbind single use cases: only
 *    `unbindAll()`;
 *  * CameraX is a process-wide singleton shared with the camera plugin: this
 *    and the plugin are never bound at once (Dart opens one or the other);
 *  * the PiP camera is the second of the list given to `bindToLifecycle`;
 *    offsets are normalized device coordinates where y negative is down.
 *
 * Every call arrives and answers on the main thread, where CameraX binding
 * and MethodChannel.Result both belong.
 */
class DualCameraRecorder(
    private val activity: FlutterActivity,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainExecutor = ContextCompat.getMainExecutor(activity)

    private var provider: ProcessCameraProvider? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var preview: Preview? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var recordingToken: Long? = null
    private var primaryFront = false
    private var boundRotation: Int? = null
    private var previewWidth = 0
    private var previewHeight = 0

    /**
     * The display's rotation, reported to Dart while the cameras are open.
     * Found on the S23 (2026-11-14): the app learns the device orientation from
     * the camera plugin, which only watches it once IT has opened a camera — in
     * "Ambas" the plugin opens none, so the dashcam stayed in portrait after a
     * turn. This is that source for the composite.
     */
    private val displayManager = activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private var reportedRotation: Int? = null
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) = reportRotation()
    }
    private var watchingDisplay = false

    private fun reportRotation() {
        val rotation = displayRotation()
        if (rotation == reportedRotation) return
        reportedRotation = rotation
        emit("displayRotation", mapOf("degrees" to rotation * 90))
    }

    private fun watchDisplay() {
        if (watchingDisplay) return
        watchingDisplay = true
        reportedRotation = null
        displayManager.registerDisplayListener(displayListener, Handler(Looper.getMainLooper()))
        reportRotation()
    }

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isSupported" -> withProvider(result) { result.success(isSupported(it)) }
                    "open" -> withProvider(result) {
                        primaryFront = call.argument<String>("primary") == "front"
                        val opened = bind(it)
                        watchDisplay()
                        result.success(opened)
                    }
                    "rebind" -> {
                        val provider = provider ?: throw DualError("not_open", "open the cameras first")
                        if (recording != null) throw DualError("busy", "recording")
                        result.success(bind(provider))
                    }
                    "start" -> {
                        val path = call.argument<String>("path") ?: throw DualError("bad_args", "start: no path")
                        val token = (call.argument<Number>("token") ?: throw DualError("bad_args", "start: no token")).toLong()
                        result.success(start(path, token, call.argument<Boolean>("audio") ?: false))
                    }
                    "stop" -> {
                        recording?.stop()
                        result.success(null)
                    }
                    "close" -> {
                        close()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: DualError) {
                result.error(error.code, error.message, null)
            } catch (error: Exception) {
                result.error("failed", "${error.javaClass.simpleName}: ${error.message}", null)
            }
        }
    }

    private class DualError(val code: String, message: String) : Exception(message)

    private fun withProvider(result: MethodChannel.Result, block: (ProcessCameraProvider) -> Unit) {
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            try {
                block(future.get().also { provider = it })
            } catch (error: DualError) {
                result.error(error.code, error.message, null)
            } catch (error: Exception) {
                result.error("failed", "${error.javaClass.simpleName}: ${error.message}", null)
            }
        }, mainExecutor)
    }

    private fun backAndFront(provider: ProcessCameraProvider) = provider.availableConcurrentCameraInfos.firstOrNull { infos ->
        infos.any { it.lensFacing == CameraSelector.LENS_FACING_BACK } &&
            infos.any { it.lensFacing == CameraSelector.LENS_FACING_FRONT }
    }

    private fun isSupported(provider: ProcessCameraProvider): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            activity.packageManager.hasSystemFeature("android.hardware.camera.concurrent") &&
            backAndFront(provider) != null

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) activity.display?.rotation else activity.windowManager.defaultDisplay.rotation)
            ?: Surface.ROTATION_0

    private fun composition(pip: Boolean): CompositionSettings {
        if (!pip) return CompositionSettings.DEFAULT
        // A third of the size, 5 % from the lower right corner (y negative is down).
        val inset = 1f - 1f / 3f - 0.05f
        return CompositionSettings.Builder()
            .setAlpha(1f)
            .setOffset(inset, -inset)
            .setScale(1f / 3f, 1f / 3f)
            .build()
    }

    /** (Re)binds both cameras at the current display rotation. */
    private fun bind(provider: ProcessCameraProvider): Map<String, Any?> {
        unbind()
        val combo = backAndFront(provider) ?: throw DualError("unsupported", "no concurrent back + front combination")
        val back = combo.first { it.lensFacing == CameraSelector.LENS_FACING_BACK }
        val front = combo.first { it.lensFacing == CameraSelector.LENS_FACING_FRONT }
        val rotation = displayRotation()

        val producer = producer ?: textures.createSurfaceProducer().also { this.producer = it }
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() = emit("surfaceAvailable", emptyMap())
            override fun onSurfaceCleanup() = emit("surfaceCleanup", emptyMap())
        })
        // 16:9 like the video: left to itself the composed preview came out 3:4
        // against a 16:9 video (phase 0) — another framing than the file's.
        val preview = Preview.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY).build(),
            )
            .setTargetRotation(rotation)
            .build()
            .also { this.preview = it }
        preview.setSurfaceProvider(mainExecutor) { request ->
            val size = request.resolution
            previewWidth = size.width
            previewHeight = size.height
            producer.setSize(size.width, size.height)
            request.setTransformationInfoListener(mainExecutor) { info ->
                emit("transform", mapOf("rotationDegrees" to info.rotationDegrees))
            }
            request.provideSurface(producer.surface, mainExecutor) { }
        }
        // Reduced resolution in "Ambas" is accepted (owner decision): HD.
        val recorder = Recorder.Builder()
            .setAspectRatio(AspectRatio.RATIO_16_9)
            .setQualitySelector(QualitySelector.from(Quality.HD, FallbackStrategy.lowerQualityOrHigherThan(Quality.HD)))
            .build()
        val videoCapture = VideoCapture.Builder(recorder).setTargetRotation(rotation).build().also { this.videoCapture = it }
        val group = UseCaseGroup.Builder().addUseCase(preview).addUseCase(videoCapture).build()

        val backConfig = SingleCameraConfig(back.cameraSelector, group, composition(pip = primaryFront), activity)
        val frontConfig = SingleCameraConfig(front.cameraSelector, group, composition(pip = !primaryFront), activity)
        // The first config is the primary, drawn first; the PiP goes second, over it.
        provider.bindToLifecycle(if (primaryFront) listOf(frontConfig, backConfig) else listOf(backConfig, frontConfig))
        boundRotation = rotation

        val video = videoCapture.resolutionInfo?.resolution
        val shown = preview.resolutionInfo?.resolution
        return mapOf(
            "textureId" to producer.id(),
            "handlesCropAndRotation" to producer.handlesCropAndRotation(),
            // Reported landscape, like the camera plugin's previewSize.
            "previewWidth" to maxOf(shown?.width ?: 1280, shown?.height ?: 720),
            "previewHeight" to minOf(shown?.width ?: 1280, shown?.height ?: 720),
            "previewRotation" to preview.resolutionInfo?.rotationDegrees,
            "video" to video?.let { "${it.width}x${it.height}" },
            "displayRotation" to rotation * 90,
        )
    }

    @SuppressLint("MissingPermission")
    private fun start(path: String, token: Long, audio: Boolean): Map<String, Any?> {
        val provider = provider ?: throw DualError("not_open", "open the cameras first")
        if (recording != null) throw DualError("busy", "already recording")
        // The composed frame keeps the orientation of the bind: a segment after a
        // turn starts on a rebind at the new rotation.
        var rebound = false
        if (boundRotation != displayRotation()) {
            bind(provider)
            rebound = true
        }
        val videoCapture = videoCapture ?: throw DualError("not_open", "open the cameras first")
        val file = File(path)
        file.parentFile?.mkdirs()
        var pending = videoCapture.output.prepareRecording(activity, FileOutputOptions.Builder(file).build())
        val micGranted = ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (audio && micGranted) pending = pending.withAudioEnabled()
        var progressSeen = false
        recordingToken = token
        recording = pending.start(mainExecutor) { event ->
            when (event) {
                is VideoRecordEvent.Start -> emit("recordStart", mapOf("token" to token))
                is VideoRecordEvent.Status -> if (!progressSeen && event.recordingStats.recordedDurationNanos > 0) {
                    progressSeen = true
                    emit("progress", mapOf("token" to token))
                }
                is VideoRecordEvent.Finalize -> {
                    if (recordingToken == token) {
                        recording = null
                        recordingToken = null
                    }
                    emit(
                        "finalize",
                        mapOf(
                            "token" to token,
                            "path" to path,
                            "error" to event.error,
                            "cause" to event.cause?.toString(),
                            "durationMs" to event.recordingStats.recordedDurationNanos / 1_000_000,
                            "bytes" to event.recordingStats.numBytesRecorded,
                        ),
                    )
                }
            }
        }
        return mapOf("rebound" to rebound, "audio" to (audio && micGranted))
    }

    private fun emit(kind: String, data: Map<String, Any?>) {
        channel.invokeMethod("event", data + ("kind" to kind))
    }

    private fun unbind() {
        val provider = provider
        if (provider != null && (preview != null || videoCapture != null)) provider.unbindAll()
        preview = null
        videoCapture = null
        boundRotation = null
    }

    /** Stops a recording, leaves concurrent mode and releases the texture. */
    fun close() {
        if (watchingDisplay) {
            displayManager.unregisterDisplayListener(displayListener)
            watchingDisplay = false
        }
        recording?.stop()
        recording = null
        recordingToken = null
        unbind()
        producer?.release()
        producer = null
    }

    private companion object {
        const val CHANNEL = "com.synapseauto.synapse_auto/dual_camera"
    }
}
