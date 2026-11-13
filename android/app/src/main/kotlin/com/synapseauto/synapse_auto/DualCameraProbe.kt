package com.synapseauto.synapse_auto

import android.os.Build
import androidx.camera.core.AspectRatio
import androidx.camera.core.CameraInfo
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
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * Dashcam dual camera, phase 0 (2026-11-13): a diagnostics-only probe of
 * CameraX's concurrent camera with composition — the back and front cameras
 * bound together, their images composed into ONE Preview and ONE VideoCapture
 * stream (one encoder, one file). It answers on the real device what the
 * dual-camera dashcam depends on: whether the composition binds, at which
 * resolutions, how the composed frame is oriented, and what the recorded file
 * looks like. Nothing here is used by the dashcam itself.
 *
 * CameraX is a process-wide singleton shared with the camera plugin: the probe
 * must only run while the dashcam is not recording (the Dart screen says so),
 * and [release] takes the cameras back out of concurrent mode.
 *
 * Every call arrives and answers on the main thread, where CameraX binding and
 * MethodChannel.Result both belong. Recording events go to Dart as `event`
 * calls on the same channel.
 */
class DualCameraProbe(
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

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "inspect" -> withProvider(result) { result.success(inspect(it)) }
                    "start" -> withProvider(result) { result.success(start(it, call)) }
                    "record" -> {
                        val path = call.argument<String>("path")
                        if (path == null) result.error("bad_args", "record: no path", null) else result.success(record(path))
                    }
                    "stopRecording" -> {
                        recording?.stop()
                        result.success(null)
                    }
                    "release" -> {
                        release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: ProbeError) {
                result.error(error.code, error.message, null)
            } catch (error: Exception) {
                result.error("failed", "${error.javaClass.simpleName}: ${error.message}", null)
            }
        }
    }

    private class ProbeError(val code: String, message: String) : Exception(message)

    private fun withProvider(result: MethodChannel.Result, block: (ProcessCameraProvider) -> Unit) {
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            try {
                block(future.get().also { provider = it })
            } catch (error: ProbeError) {
                result.error(error.code, error.message, null)
            } catch (error: Exception) {
                result.error("failed", "${error.javaClass.simpleName}: ${error.message}", null)
            }
        }, mainExecutor)
    }

    private fun facing(info: CameraInfo): String = when (info.lensFacing) {
        CameraSelector.LENS_FACING_BACK -> "back"
        CameraSelector.LENS_FACING_FRONT -> "front"
        CameraSelector.LENS_FACING_EXTERNAL -> "external"
        else -> "unknown"
    }

    private fun inspect(provider: ProcessCameraProvider): Map<String, Any> = mapOf(
        // The system feature exists from Android 11 (API 30); before it the
        // combinations list is empty anyway.
        "feature" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            activity.packageManager.hasSystemFeature("android.hardware.camera.concurrent")),
        "combos" to provider.availableConcurrentCameraInfos.map { combo ->
            combo.map { info -> mapOf("facing" to facing(info), "sensorRotation" to info.sensorRotationDegrees) }
        },
        "concurrentModeOn" to provider.isConcurrentCameraModeOn,
    )

    private fun composition(spec: Map<String, Double>?): CompositionSettings {
        if (spec == null) return CompositionSettings.DEFAULT
        return CompositionSettings.Builder()
            .setAlpha(1f)
            .setOffset((spec["offsetX"] ?: 0.0).toFloat(), (spec["offsetY"] ?: 0.0).toFloat())
            .setScale((spec["scaleX"] ?: 1.0).toFloat(), (spec["scaleY"] ?: 1.0).toFloat())
            .build()
    }

    /**
     * Binds back (primary) and front (secondary) with one Preview and one
     * VideoCapture shared by both, each camera placed by its composition
     * settings (offset and scale in normalized device coordinates, -1..1).
     */
    private fun start(provider: ProcessCameraProvider, call: MethodCall): Map<String, Any?> {
        release()
        val combo = provider.availableConcurrentCameraInfos.firstOrNull { infos ->
            infos.any { it.lensFacing == CameraSelector.LENS_FACING_BACK } &&
                infos.any { it.lensFacing == CameraSelector.LENS_FACING_FRONT }
        } ?: throw ProbeError("no_combo", "no concurrent back + front combination")
        val back = combo.first { it.lensFacing == CameraSelector.LENS_FACING_BACK }
        val front = combo.first { it.lensFacing == CameraSelector.LENS_FACING_FRONT }

        val producer = textures.createSurfaceProducer().also { this.producer = it }
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceCleanup() = emit("surfaceCleanup", emptyMap())
            override fun onSurfaceAvailable() = emit("surfaceAvailable", emptyMap())
        })
        // 16:9 like the video: left to itself the composed preview came out 3:4
        // (1080x1440) against a 9:16 video (720x1280) — another framing than the file's.
        val preview = Preview.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY).build(),
            )
            .build()
            .also { this.preview = it }
        preview.setSurfaceProvider(mainExecutor) { request ->
            val size = request.resolution
            producer.setSize(size.width, size.height)
            request.setTransformationInfoListener(mainExecutor) { info ->
                emit("transform", mapOf("rotationDegrees" to info.rotationDegrees, "mirroring" to info.isMirroring))
            }
            request.provideSurface(producer.surface, mainExecutor) { }
            emit("previewSurface", mapOf("width" to size.width, "height" to size.height))
        }
        val recorder = Recorder.Builder()
            .setAspectRatio(AspectRatio.RATIO_16_9)
            .setQualitySelector(QualitySelector.from(Quality.HD, FallbackStrategy.lowerQualityOrHigherThan(Quality.HD)))
            .build()
        val videoCapture = VideoCapture.withOutput(recorder).also { this.videoCapture = it }
        val group = UseCaseGroup.Builder().addUseCase(preview).addUseCase(videoCapture).build()

        val layout = call.argument<Map<String, Map<String, Double>>>("layout")
        val backConfig = SingleCameraConfig(back.cameraSelector, group, composition(layout?.get("back")), activity)
        val frontConfig = SingleCameraConfig(front.cameraSelector, group, composition(layout?.get("front")), activity)
        // The first config is the primary camera, drawn first; the second is drawn
        // over it — the picture-in-picture goes second.
        val primaryFront = call.argument<String>("primary") == "front"
        provider.bindToLifecycle(if (primaryFront) listOf(frontConfig, backConfig) else listOf(backConfig, frontConfig))
        return mapOf(
            "textureId" to producer.id(),
            "handlesCropAndRotation" to producer.handlesCropAndRotation(),
            "preview" to preview.resolutionInfo?.resolution?.let { "${it.width}x${it.height}" },
            "previewRotation" to preview.resolutionInfo?.rotationDegrees,
            "video" to videoCapture.resolutionInfo?.resolution?.let { "${it.width}x${it.height}" },
            "videoRotation" to videoCapture.resolutionInfo?.rotationDegrees,
            "concurrentModeOn" to provider.isConcurrentCameraModeOn,
        )
    }

    private fun record(path: String): Any? {
        val videoCapture = videoCapture ?: throw ProbeError("not_started", "start the cameras first")
        if (recording != null) throw ProbeError("busy", "already recording")
        val file = File(path)
        file.parentFile?.mkdirs()
        var progressSeen = false
        recording = videoCapture.output
            .prepareRecording(activity, FileOutputOptions.Builder(file).build())
            .start(mainExecutor) { event ->
                when (event) {
                    is VideoRecordEvent.Start -> emit("recordStart", emptyMap())
                    is VideoRecordEvent.Status -> if (!progressSeen && event.recordingStats.recordedDurationNanos > 0) {
                        progressSeen = true
                        emit("recordProgress", emptyMap())
                    }
                    is VideoRecordEvent.Finalize -> {
                        recording = null
                        emit(
                            "recordFinalize",
                            mapOf(
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
        return null
    }

    private fun emit(kind: String, data: Map<String, Any?>) {
        channel.invokeMethod("event", data + ("kind" to kind))
    }

    /** Stops a recording, unbinds the probe's use cases and leaves concurrent mode. */
    fun release() {
        recording?.stop()
        recording = null
        val provider = provider
        if (provider != null && (preview != null || videoCapture != null)) {
            // Concurrent mode refuses to unbind single use cases ("call unbindAll()
            // first", SM-S918B, 2026-11-13). The dashcam is not recording while the
            // probe runs, so nothing else is bound.
            provider.unbindAll()
        }
        preview = null
        videoCapture = null
        producer?.release()
        producer = null
    }

    private companion object {
        const val CHANNEL = "com.synapseauto.synapse_auto/dual_camera_probe"
    }
}
