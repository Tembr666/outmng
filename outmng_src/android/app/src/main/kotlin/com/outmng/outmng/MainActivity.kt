package com.outmng.outmng

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "com.outmng/downloads"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestLegacyStorageAccess()
    }

    /**
     * Android 9 и ниже: чтобы принять файл сразу в общую папку «Загрузки»,
     * нужно разрешение на запись. На Android 10+ оно не требуется.
     */
    private fun requestLegacyStorageAccess() {
        if (Build.VERSION.SDK_INT > Build.VERSION_CODES.P) return
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            LEGACY_STORAGE_REQUEST
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDownloadsPath" -> result.success(publicDownloadsDir().absolutePath)
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name")
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        if (path.isNullOrBlank() || name.isNullOrBlank()) {
                            result.error("bad_args", "path and name are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(saveToDownloads(File(path), name, mime))
                        } catch (error: Exception) {
                            result.error("save_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun publicDownloadsDir(): File =
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)

    private fun saveToDownloads(source: File, displayName: String, mime: String): String? {
        if (!source.exists()) return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveViaMediaStore(source, displayName, mime)
        } else {
            saveLegacy(source, displayName)
        }
    }

    /** Android 10+: общая папка Download без каких-либо разрешений. */
    private fun saveViaMediaStore(source: File, displayName: String, mime: String): String? {
        val resolver = contentResolver
        val uniqueName = uniqueDisplayName(displayName)
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, uniqueName)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = resolver.insert(collection, values) ?: return null
        try {
            val output = resolver.openOutputStream(uri)
                ?: run {
                    resolver.delete(uri, null, null)
                    return null
                }
            output.use { out ->
                FileInputStream(source).use { input ->
                    input.copyTo(out, DEFAULT_BUFFER_SIZE)
                }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Download/$uniqueName"
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    /** Android 9 и ниже: прямая запись в Download (нужно разрешение). */
    private fun saveLegacy(source: File, displayName: String): String? {
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val directory = publicDownloadsDir()
        if (!directory.exists() && !directory.mkdirs()) return null
        val target = uniqueLegacyFile(directory, displayName)
        source.copyTo(target, overwrite = false)
        return "Download/${target.name}"
    }

    private fun uniqueLegacyFile(directory: File, displayName: String): File {
        var candidate = File(directory, displayName)
        if (!candidate.exists()) return candidate
        val dot = displayName.lastIndexOf('.')
        val base = if (dot > 0) displayName.substring(0, dot) else displayName
        val extension = if (dot > 0) displayName.substring(dot) else ""
        var index = 1
        while (candidate.exists() && index < 1000) {
            candidate = File(directory, "$base ($index)$extension")
            index++
        }
        return candidate
    }

    private fun uniqueDisplayName(displayName: String): String {
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        val dot = displayName.lastIndexOf('.')
        val base = if (dot > 0) displayName.substring(0, dot) else displayName
        val extension = if (dot > 0) displayName.substring(dot) else ""
        var candidate = displayName
        var index = 1
        while (index < 1000) {
            var exists = false
            contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                arrayOf(candidate),
                null
            )?.use { cursor ->
                exists = cursor.count > 0
            }
            if (!exists) return candidate
            candidate = "$base ($index)$extension"
            index++
        }
        return "$base-${System.currentTimeMillis()}$extension"
    }

    private companion object {
        const val LEGACY_STORAGE_REQUEST = 1001
    }
}
