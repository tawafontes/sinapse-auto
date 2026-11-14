package com.synapseauto.synapse_auto

import android.Manifest
import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Fase 16.2-R4.4-R2 — the dashcam storage bridge (`dashcam_storage_probe.dart`).
 * It answers facts Dart cannot read (free space of the volume) and performs the
 * one operation the clip accounting needs (the cache-group repair of P3-HW-1).
 * It decides nothing: which files, what counts, what is evicted and whether a
 * recording may start are all decided in Dart.
 *
 * Public APIs only, all available at minSdk 24: StatFs (API 18) and
 * android.system.Os stat/lstat/chown/getgid (API 21). No reflection, no shell,
 * no hidden API, no new dependency.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        obdBridge = ObdBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        dualCameraRecorder = DualCameraRecorder(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "volumeStats" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "volumeStats: no path", null)
                    } else {
                        try {
                            val stats = StatFs(path)
                            // availableBytes excludes the blocks reserved for root: what this
                            // app can still write, the figure Android's storage monitor and
                            // CameraX's own floor read.
                            result.success(mapOf("availableBytes" to stats.availableBytes, "totalBytes" to stats.totalBytes))
                        } catch (error: IllegalArgumentException) {
                            result.error("statfs_failed", error.message, null)
                        }
                    }
                }
                "normalizeClipGroups" -> {
                    val paths = call.argument<List<String>>("paths")
                    if (paths == null) result.error("bad_args", "normalizeClipGroups: no paths", null) else result.success(normalizeClipGroups(paths))
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GALLERY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveVideo" -> {
                    val path = call.argument<String>("path")
                    val displayName = call.argument<String>("displayName")
                    val recordedAtMs = call.argument<Number>("recordedAtMs")?.toLong()
                    if (path == null || displayName == null || recordedAtMs == null) {
                        result.error("bad_args", "saveVideo: missing arguments", null)
                    } else {
                        saveVideoInBackground(path, displayName, recordedAtMs, result)
                    }
                }
                "deleteVideos" -> {
                    val names = call.argument<List<String>>("displayNames")
                    if (names == null) result.error("bad_args", "deleteVideos: no displayNames", null) else deleteVideosInBackground(names, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Copies a finished dashcam clip into the gallery (`Movies/Synapse Auto`). The
     * clip itself stays in the app's private dashcam_clips/ — Dart's index, quota
     * and playback own it. The copy runs on [galleryExecutor] (one thread, one copy
     * at a time), never on the main thread: that thread also runs the Dart UI
     * isolate and the camera callbacks, and a ~60–100 MB copy there would stall
     * both (see the R4.4-HW-MIG main-thread findings). The reply is posted back to
     * the main thread, where MethodChannel.Result must be answered.
     */
    private fun saveVideoInBackground(path: String, displayName: String, recordedAtMs: Long, result: MethodChannel.Result) {
        try {
            galleryExecutor.execute {
                try {
                    val saved = saveVideoToGallery(path, displayName, recordedAtMs)
                    mainHandler.post { result.success(saved) }
                } catch (error: GalleryPermissionMissing) {
                    mainHandler.post { result.error("storage_permission", "WRITE_EXTERNAL_STORAGE not granted", null) }
                } catch (error: Exception) {
                    mainHandler.post { result.error("save_failed", "${error.javaClass.simpleName}: ${error.message}", null) }
                }
            }
        } catch (error: RejectedExecutionException) {
            result.error("save_failed", "activity is being destroyed", null)
        }
    }

    private class GalleryPermissionMissing : Exception()

    /** Returns the gallery entry's URI (Android 10+) or file path (before 10). */
    private fun saveVideoToGallery(path: String, displayName: String, recordedAtMs: Long): String {
        val source = File(path)
        // Only this app's own files: the channel must not become a way to copy any
        // readable file into shared storage.
        val dataDir = File(applicationInfo.dataDir).canonicalPath + File.separator
        if (!source.canonicalPath.startsWith(dataDir)) throw IOException("not an app file")
        if (!source.isFile) throw IOException("clip not found")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+: MediaStore needs no permission to add the app's own media.
            // IS_PENDING hides the entry from the gallery until the copy is complete;
            // a failed copy deletes it, so no truncated video is ever left behind.
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/$GALLERY_ALBUM")
                put(MediaStore.MediaColumns.DATE_TAKEN, recordedAtMs)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values) ?: throw IOException("MediaStore insert returned null")
            try {
                val output = resolver.openOutputStream(uri) ?: throw IOException("MediaStore output stream unavailable")
                output.use { out -> FileInputStream(source).use { input -> input.copyTo(out, COPY_BUFFER_BYTES) } }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            return uri.toString()
        }

        // Android 7–9: a plain file in the public Movies folder, then a media scan so
        // the gallery lists it. Needs WRITE_EXTERNAL_STORAGE (declared up to API 28).
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            throw GalleryPermissionMissing()
        }
        @Suppress("DEPRECATION")
        val album = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), GALLERY_ALBUM)
        if (!album.isDirectory && !album.mkdirs()) throw IOException("cannot create ${album.path}")
        val base = displayName.removeSuffix(".mp4")
        var target = File(album, displayName)
        var n = 1
        while (target.exists()) target = File(album, "$base ($n).mp4").also { n++ }
        val partial = File(album, ".${target.name}.partial")
        try {
            FileInputStream(source).use { input -> partial.outputStream().use { out -> input.copyTo(out, COPY_BUFFER_BYTES) } }
            if (!partial.renameTo(target)) throw IOException("cannot rename into ${target.path}")
        } catch (error: Exception) {
            partial.delete()
            throw error
        }
        target.setLastModified(recordedAtMs)
        MediaScannerConnection.scanFile(applicationContext, arrayOf(target.path), arrayOf("video/mp4"), null)
        return target.path
    }

    /**
     * Deletes the gallery copies of clips the user deleted in the app (owner
     * decision, 2026-11-14: deleting a video asks whether to remove the gallery
     * copy too). Only entries of this app's album (`Movies/Synapse Auto`) with
     * exactly the given display names are touched. Answers
     * `{deleted, notFound, denied}`.
     *
     * Android 10+: the app may delete the MediaStore entries it inserted; one it
     * no longer owns (inserted before a reinstall) needs the user's consent —
     * on Android 11+ one system dialog for all of them
     * ([MediaStore.createDeleteRequest]); on 10, the consent of the first one.
     * Before 10: plain files in the public Movies folder.
     */
    private fun deleteVideosInBackground(names: List<String>, result: MethodChannel.Result) {
        try {
            galleryExecutor.execute {
                try {
                    val (counts, needConsent) = deleteVideosFromGallery(names)
                    mainHandler.post {
                        if (needConsent.isEmpty()) result.success(counts) else askDeleteConsent(needConsent, counts, result)
                    }
                } catch (error: Exception) {
                    mainHandler.post { result.error("delete_failed", "${error.javaClass.simpleName}: ${error.message}", null) }
                }
            }
        } catch (error: RejectedExecutionException) {
            result.error("delete_failed", "activity is being destroyed", null)
        }
    }

    /** The counts so far and the entries that still need the user's consent. */
    private fun deleteVideosFromGallery(names: List<String>): Pair<Map<String, Int>, List<Uri>> {
        var deleted = 0
        var notFound = 0
        val needConsent = mutableListOf<Uri>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val album = "${Environment.DIRECTORY_MOVIES}/$GALLERY_ALBUM/"
            for (name in names) {
                val uris = mutableListOf<Uri>()
                resolver.query(
                    collection,
                    arrayOf(MediaStore.MediaColumns._ID),
                    "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                    arrayOf(album, name),
                    null,
                )?.use { cursor ->
                    while (cursor.moveToNext()) uris += ContentUris.withAppendedId(collection, cursor.getLong(0))
                }
                if (uris.isEmpty()) {
                    notFound++
                    continue
                }
                for (uri in uris) {
                    try {
                        if (resolver.delete(uri, null, null) > 0) deleted++ else notFound++
                    } catch (error: SecurityException) {
                        needConsent += uri
                    }
                }
            }
        } else {
            @Suppress("DEPRECATION")
            val album = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), GALLERY_ALBUM)
            for (name in names) {
                val file = File(album, name)
                if (file.isFile && file.delete()) {
                    deleted++
                    MediaScannerConnection.scanFile(applicationContext, arrayOf(file.path), null, null)
                } else {
                    notFound++
                }
            }
        }
        return Pair(mapOf("deleted" to deleted, "notFound" to notFound, "denied" to 0), needConsent)
    }

    private var pendingDelete: Triple<List<Uri>, Map<String, Int>, MethodChannel.Result>? = null

    private fun askDeleteConsent(uris: List<Uri>, counts: Map<String, Int>, result: MethodChannel.Result) {
        if (pendingDelete != null) {
            result.success(counts + ("denied" to uris.size))
            return
        }
        try {
            val sender = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                    MediaStore.createDeleteRequest(applicationContext.contentResolver, uris).intentSender
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> try {
                    // Android 10 grants one entry per consent: ask for the first.
                    applicationContext.contentResolver.delete(uris.first(), null, null)
                    null
                } catch (error: RecoverableSecurityException) {
                    error.userAction.actionIntent.intentSender
                }
                else -> null
            }
            if (sender == null) {
                result.success(counts + ("denied" to uris.size))
                return
            }
            pendingDelete = Triple(uris, counts, result)
            startIntentSenderForResult(sender, DELETE_CONSENT_REQUEST, null, 0, 0, 0)
        } catch (error: Exception) {
            pendingDelete = null
            result.success(counts + ("denied" to uris.size))
        }
    }

    @Deprecated("FlutterActivity still routes results here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != DELETE_CONSENT_REQUEST) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val pending = pendingDelete ?: return
        pendingDelete = null
        val (uris, counts, result) = pending
        val granted = resultCode == Activity.RESULT_OK
        if (granted && Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            // The consent of Android 10 covers only that entry: delete it now.
            try {
                applicationContext.contentResolver.delete(uris.first(), null, null)
            } catch (error: SecurityException) {
            }
        }
        val byConsent = if (!granted) 0 else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) uris.size else 1
        result.success(
            mapOf(
                "deleted" to (counts["deleted"] ?: 0) + byConsent,
                "notFound" to (counts["notFound"] ?: 0),
                "denied" to uris.size - byConsent,
            ),
        )
    }

    /**
     * P3-HW-1 (R4.4-R1-HW, D0 §2/§4): the plugin records into the setgid cache/
     * directory, so the recording's inode has the app's CACHE group, and the
     * rename that publishes it as a canonical clip keeps the inode — Android then
     * counts the clip as "Cache" (installd sums the cache GID's quota) and ranks
     * the app first for cache trimming. Cache cleanup deletes by PATH (cache/,
     * code_cache/), never by group, so the clip itself was never at risk; this
     * fixes the accounting only.
     *
     * Each path: only a regular file (lstat — a link is never followed) inside
     * this app's own data directory, and only when its group is the cache group,
     * gets the app's group: chown(path, -1, getgid()). The owner may give a file
     * its own primary group (POSIX). No rename, no copy, nothing else changes.
     * Idempotent; a failure is counted, never thrown.
     */
    private fun normalizeClipGroups(paths: List<String>): Map<String, Int> {
        var normalized = 0
        var alreadyAppGroup = 0
        var otherGroup = 0
        var skipped = 0
        var failed = 0
        val appGid = Os.getgid()
        // The cache directory is created with the cache group and the setgid bit
        // (ContextImpl.ensurePrivateCacheDirExists): its group IS the cache group.
        val cacheGid = try {
            Os.stat(cacheDir.path).st_gid
        } catch (error: ErrnoException) {
            null
        }
        val dataDir = File(applicationInfo.dataDir).canonicalPath + File.separator
        for (path in paths) {
            try {
                if (!File(path).canonicalPath.startsWith(dataDir)) {
                    skipped++
                    continue
                }
                val before = Os.lstat(path)
                if (!OsConstants.S_ISREG(before.st_mode)) {
                    skipped++
                    continue
                }
                when {
                    before.st_gid == appGid -> alreadyAppGroup++
                    cacheGid == null || before.st_gid != cacheGid || cacheGid == appGid -> otherGroup++
                    else -> {
                        Os.chown(path, -1, appGid)
                        if (Os.lstat(path).st_gid == appGid) normalized++ else failed++
                    }
                }
            } catch (error: ErrnoException) {
                if (error.errno == OsConstants.ENOENT) skipped++ else failed++
            } catch (error: java.io.IOException) {
                failed++
            } catch (error: SecurityException) {
                failed++
            }
        }
        return mapOf(
            "normalized" to normalized,
            "alreadyAppGroup" to alreadyAppGroup,
            "otherGroup" to otherGroup,
            "skipped" to skipped,
            "failed" to failed,
        )
    }

    override fun onDestroy() {
        // Pending copies are dropped with the activity; their clips stay in the
        // private folder (only the gallery copy of those segments is missed).
        galleryExecutor.shutdown()
        obdBridge?.dispose()
        obdBridge = null
        dualCameraRecorder?.close()
        dualCameraRecorder = null
        super.onDestroy()
    }

    /** OBD-II phase 0 link (see [ObdBridge]). */
    private var obdBridge: ObdBridge? = null

    /** The dashcam's "Ambas" mode (see [DualCameraRecorder]). */
    private var dualCameraRecorder: DualCameraRecorder? = null

    private val galleryExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private companion object {
        const val STORAGE_CHANNEL = "com.synapseauto.synapse_auto/dashcam_storage"
        const val GALLERY_CHANNEL = "com.synapseauto.synapse_auto/dashcam_gallery"
        const val GALLERY_ALBUM = "Synapse Auto"
        const val DELETE_CONSENT_REQUEST = 0x5A1
        const val COPY_BUFFER_BYTES = 1 shl 20
    }
}
