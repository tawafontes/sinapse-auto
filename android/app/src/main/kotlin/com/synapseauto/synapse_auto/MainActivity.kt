package com.synapseauto.synapse_auto

import android.os.StatFs
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

    private companion object {
        const val STORAGE_CHANNEL = "com.synapseauto.synapse_auto/dashcam_storage"
    }
}
