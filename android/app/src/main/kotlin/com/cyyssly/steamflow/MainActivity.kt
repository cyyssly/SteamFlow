package com.cyyssly.steamflow

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.content.ContentUris
import android.database.Cursor
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.Locale
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.cyyssly.steamflow/media_store"

    /// 缩略图最长边（与 Dart 侧 video_thumbnail_win.dart 的 _maxSize 保持一致）
    private val THUMBNAIL_MAX_SIZE = 512

    private var pendingResult: MethodChannel.Result? = null
    private var pendingTrashResult: MethodChannel.Result? = null

    // SAF 目录选择（移动/复制目标）相关
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getVideoAlbums" -> handleGetVideoAlbums(result)
                "requestStoragePermission" -> handleRequestPermission(result)
                "getFolderVideos" -> {
                    val folderPath = call.argument<String>("folderPath") ?: ""
                    handleGetFolderVideos(folderPath, result)
                }
                "getVideoThumbnail" -> {
                    val path = call.argument<String>("path") ?: ""
                    handleGetVideoThumbnail(path, result)
                }
                "deleteToTrash" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    handleDeleteToTrash(paths, result)
                }
                "pickDestinationDir" -> pickDestinationDir(result)
                "copyFiles" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    val destinationUri = call.argument<String>("destinationUri") ?: ""
                    result.success(copyFilesToDestination(paths, destinationUri))
                }
                "moveFiles" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    val destinationUri = call.argument<String>("destinationUri") ?: ""
                    result.success(moveFilesToDestination(paths, destinationUri))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100) {
            // Android 14+ 用户可能只选择“部分视频”，此时只有
            // READ_MEDIA_VISUAL_USER_SELECTED 被授予。
            // 这种情况仍允许继续使用，但要记录日志，
            // 因为后续查询结果会是不完整的（相册数量/缩略图会时多时少）。
            val granted = grantResults.isNotEmpty() &&
                grantResults.any { it == PackageManager.PERMISSION_GRANTED }
            if (granted && !hasFullStoragePermission()) {
                android.util.Log.w(
                    "SteamFlow",
                    "requestStoragePermission: 仅获取到部分视频访问权限，结果可能不完整"
                )
            }
            pendingResult?.success(granted)
            pendingResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            200 -> {
                // 回收站授权结果
                val success = resultCode == Activity.RESULT_OK
                pendingTrashResult?.success(success)
                pendingTrashResult = null
            }
            300 -> {
                // SAF 目录选择结果
                val pickResult = pendingPickResult
                pendingPickResult = null
                if (resultCode == Activity.RESULT_OK && data != null) {
                    val treeUri = data.data
                    if (treeUri != null) {
                        // 持久化 uri 权限，以便后续读写该目录
                        runCatching {
                            contentResolver.takePersistableUriPermission(
                                treeUri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                            )
                        }
                        pickResult?.success(treeUri.toString())
                        return
                    }
                }
                pickResult?.success(null)
            }
        }
    }

    /// 把视频移入系统回收站（Android 11+ 使用 MediaStore.createTrashRequest）
    private fun handleDeleteToTrash(paths: List<String>, result: MethodChannel.Result) {
        if (paths.isEmpty()) {
            result.success(true)
            return
        }

        // Android 11+ (API 30+) 使用系统回收站
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val uris = queryUrisByPaths(paths)
                if (uris.isEmpty()) {
                    // 查询不到 URI（可能不在 MediaStore 中），回退到直接删除文件
                    deleteFilesDirectly(paths)
                    result.success(true)
                    return
                }
                // 创建回收站请求，需要用户授权（弹出系统对话框）
                val pendingIntent = MediaStore.createTrashRequest(
                    contentResolver,
                    uris,
                    true
                )
                pendingTrashResult = result
                startIntentSenderForResult(
                    pendingIntent.intentSender,
                    200,
                    null,
                    0,
                    0,
                    0
                )
            } catch (e: Exception) {
                android.util.Log.e("SteamFlow", "deleteToTrash failed: ${e.message}", e)
                // 失败时回退到直接删除
                deleteFilesDirectly(paths)
                result.success(true)
            }
        } else {
            // Android 10 及以下：直接删除文件
            deleteFilesDirectly(paths)
            result.success(true)
        }
    }

    /// 通过路径查询 MediaStore 中的视频 URI
    private fun queryUrisByPaths(paths: List<String>): List<Uri> {
        val uris = mutableListOf<Uri>()
        val contentResolver: ContentResolver = contentResolver
        val projection = arrayOf(MediaStore.Video.Media._ID)

        for (path in paths) {
            val selection = "${MediaStore.Video.Media.DATA} = ?"
            val selectionArgs = arrayOf(path)
            val cursor = contentResolver.query(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                null
            )
            cursor?.use {
                if (it.moveToFirst()) {
                    val id = it.getLong(it.getColumnIndexOrThrow(MediaStore.Video.Media._ID))
                    uris.add(
                        ContentUris.withAppendedId(
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                            id
                        )
                    )
                }
            }
        }
        return uris
    }

    /// 直接删除文件（Android 10 及以下，或 MediaStore 查询失败时回退）
    private fun deleteFilesDirectly(paths: List<String>) {
        for (path in paths) {
            try {
                val file = File(path)
                if (file.exists()) {
                    file.delete()
                }
            } catch (e: Exception) {
                android.util.Log.e("SteamFlow", "delete file failed: $path: ${e.message}")
            }
        }
    }

    /// 弹出系统目录选择器（SAF），返回可写目录的 content:// tree uri
    private fun pickDestinationDir(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("BUSY", "正在选择目录", null)
            return
        }
        pendingPickResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
            }
            startActivityForResult(intent, 300)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("PICK_FAILED", "无法打开目录选择器: ${e.message}", null)
        }
    }

    /// 把文件复制到 SAF tree 目录中
    /// @return true 表示全部复制成功（或路径为空）
    private fun copyFilesToDestination(paths: List<String>, destTreeUriString: String): Boolean {
        if (paths.isEmpty()) return true
        try {
            val treeUri = Uri.parse(destTreeUriString)
            val resolver: ContentResolver = contentResolver

            // 目标目录的 document id
            val treeDocId = android.provider.DocumentsContract.getTreeDocumentId(treeUri)

            var allOk = true
            for (path in paths) {
                try {
                    val fileName = path.substringAfterLast('/')
                    val destDirUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        treeDocId
                    )

                    // 创建新文档（视频类型）
                    val newDocUri = resolver.insert(
                        destDirUri,
                        ContentValues().apply {
                            put(
                                android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                                fileName
                            )
                            put(
                                android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
                                getMimeType(fileName)
                            )
                        }
                    )

                    if (newDocUri == null) {
                        android.util.Log.e("SteamFlow", "create doc failed for: $fileName")
                        allOk = false
                        continue
                    }

                    // 从源读取并写入目标文档
                    val inputStream = openInputStreamFor(path, resolver)
                    if (inputStream == null) {
                        allOk = false
                        continue
                    }
                    inputStream.use { ins ->
                        resolver.openOutputStream(newDocUri)?.use { outs ->
                            ins.copyTo(outs)
                        } ?: run {
                            android.util.Log.e("SteamFlow", "open output failed for: $fileName")
                            allOk = false
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("SteamFlow", "copy file failed: $path: ${e.message}")
                    allOk = false
                }
            }
            return allOk
        } catch (e: Exception) {
            android.util.Log.e("SteamFlow", "copyFilesToDestination failed: ${e.message}", e)
            return false
        }
    }

    /// 把文件移动到 SAF tree 目录中（复制成功后再删除源文件）
    private fun moveFilesToDestination(paths: List<String>, destTreeUriString: String): Boolean {
        if (paths.isEmpty()) return true
        val copied = copyFilesToDestination(paths, destTreeUriString)
        if (copied) {
            deleteFilesDirectly(paths)
        }
        return copied
    }

    /// 打开源文件的输入流：MediaStore 项用 content uri，普通路径用 File
    private fun openInputStreamFor(path: String, resolver: ContentResolver): java.io.InputStream? {
        return try {
            if (path.startsWith("content://")) {
                resolver.openInputStream(Uri.parse(path))
            } else {
                val file = File(path)
                if (file.exists()) java.io.FileInputStream(file) else null
            }
        } catch (e: Exception) {
            android.util.Log.e("SteamFlow", "open input stream failed: $path: ${e.message}")
            null
        }
    }

    /// 根据文件扩展名返回 MIME 类型
    private fun getMimeType(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return when (ext) {
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            else -> "video/*"
        }
    }

    private fun handleGetVideoAlbums(result: MethodChannel.Result) {
        if (!hasStoragePermission()) {
            android.util.Log.e("SteamFlow", "getVideoAlbums: permission denied")
            result.error("PERMISSION_DENIED", "没有读取视频的权限", null)
            return
        }
        if (hasPartialStoragePermission()) {
            // 部分权限下查询结果只是用户勾选的子集，记录日志便于区分原因
            android.util.Log.w(
                "SteamFlow",
                "getVideoAlbums: 仅有部分视频访问权限，结果可能不完整"
            )
        }
        try {
            val albums = queryVideoAlbums()
            android.util.Log.d("SteamFlow", "getVideoAlbums: returning ${albums.size} albums")
            for (album in albums) {
                android.util.Log.d("SteamFlow", "  album: ${album["name"]} path=${album["path"]} count=${album["videoCount"]}")
            }
            result.success(albums)
        } catch (e: Exception) {
            android.util.Log.e("SteamFlow", "getVideoAlbums: query failed: ${e.message}", e)
            result.error("QUERY_FAILED", "查询相册失败: ${e.message}", null)
        }
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        if (hasFullStoragePermission()) {
            result.success(true)
            return
        }
        pendingResult = result
        // Android 14+ 同时请求 READ_MEDIA_VIDEO 和 READ_MEDIA_VISUAL_USER_SELECTED
        val permissions = getRequiredPermissions()
        ActivityCompat.requestPermissions(this, permissions, 100)
    }

    /// 取视频首帧缩略图（等比缩放到最长边不超过 [THUMBNAIL_MAX_SIZE]，
    /// 不裁剪、不留黑边，因此返回的宽高比就是视频本身的宽高比）。
    ///
    /// MediaMetadataRetriever 的解码是同步阻塞的，必须放到后台线程，
    /// 否则会卡住平台主线程，进而卡住整个 Flutter UI。
    private fun handleGetVideoThumbnail(path: String, result: MethodChannel.Result) {
        if (path.isBlank()) {
            result.success(null)
            return
        }
        Thread {
            val payload = try {
                generateVideoThumbnail(path)
            } catch (e: Exception) {
                android.util.Log.e("SteamFlow", "getVideoThumbnail failed: $path: ${e.message}", e)
                null
            }
            // MethodChannel.Result 必须在平台主线程上回调
            runOnUiThread { result.success(payload) }
        }.start()
    }

    /// 解码首帧并编码为 PNG；失败返回 null。
    private fun generateVideoThumbnail(path: String): Map<String, Any?>? {
        val retriever = MediaMetadataRetriever()
        try {
            setDataSourceFor(retriever, path)
            val frame = retriever.getFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: return null

            val (width, height) = scaledThumbnailSize(frame.width, frame.height)
            val scaled = if (width == frame.width && height == frame.height) {
                frame
            } else {
                Bitmap.createScaledBitmap(frame, width, height, true)
            }

            val stream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, stream)
            if (scaled !== frame) scaled.recycle()
            frame.recycle()

            return mapOf(
                "bytes" to stream.toByteArray(),
                "width" to width,
                "height" to height
            )
        } finally {
            runCatching { retriever.release() }
        }
    }

    /// [retriever] 的数据源可能是文件路径，也可能是相册返回的 content:// URI。
    private fun setDataSourceFor(retriever: MediaMetadataRetriever, path: String) {
        if (path.startsWith("content://")) {
            retriever.setDataSource(this, Uri.parse(path))
            return
        }
        try {
            retriever.setDataSource(path)
        } catch (e: Exception) {
            // Android 10+ 上其他应用写入的媒体文件可能无法按路径读取，
            // 回退到用 MediaStore 解析成 content:// URI 再读
            val uri = queryUrisByPaths(listOf(path)).firstOrNull()
            if (uri == null) throw e
            retriever.setDataSource(this, uri)
        }
    }

    /// 等比缩放到最长边不超过 [THUMBNAIL_MAX_SIZE]，保持原始宽高比。
    private fun scaledThumbnailSize(width: Int, height: Int): Pair<Int, Int> {
        val longest = maxOf(width, height)
        if (longest <= THUMBNAIL_MAX_SIZE) return width to height
        val scale = THUMBNAIL_MAX_SIZE.toDouble() / longest
        return maxOf(1, (width * scale).roundToInt()) to
            maxOf(1, (height * scale).roundToInt())
    }

    /// 通过 MediaStore 查询指定文件夹下的所有视频路径
    private fun handleGetFolderVideos(folderPath: String, result: MethodChannel.Result) {
        if (!hasStoragePermission()) {
            result.error("PERMISSION_DENIED", "没有读取视频的权限", null)
            return
        }
        try {
            val videos = queryFolderVideos(folderPath)
            result.success(videos)
        } catch (e: Exception) {
            android.util.Log.e("SteamFlow", "getFolderVideos failed: ${e.message}", e)
            result.error("QUERY_FAILED", "查询文件夹视频失败: ${e.message}", null)
        }
    }

    /// 通过 MediaStore ContentResolver 按文件夹路径查询视频
    ///
    /// 同时把 MediaStore 已索引好的 WIDTH / HEIGHT 一并返回。
    /// 瀑布流需要每个视频的宽高比来决定卡片高度，而视频的尺寸无法
    /// 从文件头解析出来，只能解码一帧；MediaStore 既然已索引好就直接用，
    /// 省掉一次首帧解码（手机上这一步非常慢）。
    private fun queryFolderVideos(folderPath: String): List<Map<String, Any?>> {
        val videos = mutableListOf<Map<String, Any?>>()
        val contentResolver: ContentResolver = contentResolver

        // 把文件夹路径转为 relative_path 格式
        // 输入: /storage/emulated/0/DCIM/Camera
        // 输出: DCIM/Camera/
        val rootDir = Environment.getExternalStorageDirectory().absolutePath
        val relativePath = if (folderPath.startsWith(rootDir)) {
            var rel = folderPath.removePrefix(rootDir).trimStart('/')
            if (rel.isNotEmpty() && !rel.endsWith("/")) rel += "/"
            rel
        } else {
            // 如果路径不在标准 external storage 下，尝试直接用 DATA 列匹配后缀
            null
        }

        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_MODIFIED
        )

        // 查询条件：相对路径匹配，或 DATA 列以文件夹路径开头
        val selection = if (relativePath != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            "${MediaStore.Video.Media.RELATIVE_PATH} = ?"
        } else {
            "${MediaStore.Video.Media.DATA} LIKE ?"
        }
        val selectionArgs = if (relativePath != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            arrayOf(relativePath)
        } else {
            arrayOf("$folderPath/%")
        }

        val collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val cursor = contentResolver.query(
            collection,
            projection,
            selection,
            selectionArgs,
            null
        )

        cursor?.use {
            val idIdx = it.getColumnIndex(MediaStore.Video.Media._ID)
            val dataIdx = it.getColumnIndex(MediaStore.Video.Media.DATA)
            val widthIdx = it.getColumnIndex(MediaStore.Video.Media.WIDTH)
            val heightIdx = it.getColumnIndex(MediaStore.Video.Media.HEIGHT)
            val sizeIdx = it.getColumnIndex(MediaStore.Video.Media.SIZE)
            val dateIdx = it.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED)
            if (idIdx < 0) return@use

            while (it.moveToNext()) {
                var videoPath: String? = null
                if (dataIdx >= 0) {
                    videoPath = it.getString(dataIdx)
                }
                if (videoPath == null || videoPath.isBlank()) continue

                // WIDTH/HEIGHT 可能为 0（MediaStore 尚未扫描到该文件），
                // 此时返回 null，由 Dart 端回退到解码首帧推导宽高比；
                // 同时把真实像素一并返回，供瀑布流卡片显示「分辨率」。
                var aspectRatio: Double? = null
                var width: Int? = null
                var height: Int? = null
                if (widthIdx >= 0 && heightIdx >= 0) {
                    val w = it.getInt(widthIdx)
                    val h = it.getInt(heightIdx)
                    if (w > 0 && h > 0) {
                        aspectRatio = w.toDouble() / h.toDouble()
                        width = w
                        height = h
                    }
                }

                val size = if (sizeIdx >= 0 && !it.isNull(sizeIdx)) it.getLong(sizeIdx) else null
                // DATE_MODIFIED 单位是秒，转成毫秒供 Dart 端直接构造 DateTime
                val dateModified = if (dateIdx >= 0 && !it.isNull(dateIdx)) {
                    it.getLong(dateIdx) * 1000L
                } else {
                    null
                }

                videos.add(
                    mapOf(
                        "name" to videoPath.substringAfterLast('/'),
                        "path" to videoPath,
                        "aspectRatio" to aspectRatio,
                        "width" to width,
                        "height" to height,
                        "size" to size,
                        "dateModified" to dateModified
                    )
                )
            }
        }

        return videos
    }

    /// 是否拥有“完整”的视频读取权限
    private fun hasFullStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            isGranted(Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            isGranted(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    /// 是否只拿到“部分视频”访问权限（Android 14+ 用户选择“仅允许访问部分视频”）
    ///
    /// 这种状态下 MediaStore 只会返回用户勾选过的那部分视频，
    /// 相册数量、视频数量和缩略图都不完整，且会随用户选择而变化。
    private fun hasPartialStoragePermission(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            !isGranted(Manifest.permission.READ_MEDIA_VIDEO) &&
            isGranted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
    }

    /// 是否可以进行 MediaStore 查询（完整权限或部分权限都算）。
    ///
    /// 注意不能简单地用 any 判断后就当成“完整权限”：
    /// 部分权限下结果只是用户勾选的子集，必须显式区分并记录日志，
    /// 否则现象会表现为相册/缩略图时多时少、对不上号。
    private fun hasStoragePermission(): Boolean {
        return hasFullStoragePermission() || hasPartialStoragePermission()
    }

    private fun isGranted(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(this, permission) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun getRequiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+：同时请求完整访问和部分访问权限
            arrayOf(
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    private fun queryVideoAlbums(): List<Map<String, Any>> {
        val albums = mutableListOf<Map<String, Any>>()
        val contentResolver: ContentResolver = contentResolver

        // Android 10+ 使用 RELATIVE_PATH 替代已废弃的 DATA 列
        val projection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            arrayOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.BUCKET_ID,
                MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
                MediaStore.Video.Media.DATA,
                MediaStore.Video.Media.RELATIVE_PATH
            )
        } else {
            arrayOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.BUCKET_ID,
                MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
                MediaStore.Video.Media.DATA
            )
        }

        // 查询所有存储卷，确保不遗漏
        val volumes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 用 Map 按卷名去重，避免 external 和 external_primary 指向同一卷时重复查询
            val volMap = linkedMapOf<String, Uri>()
            // EXTERNAL_CONTENT_URI 默认指向 external_primary
            volMap["external_primary"] = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            // 尝试获取所有卷名并查询每个卷
            try {
                val volNames = MediaStore.getExternalVolumeNames(this)
                for (name in volNames) {
                    if (!volMap.containsKey(name)) {
                        volMap[name] = MediaStore.Video.Media.getContentUri(name)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("SteamFlow", "getExternalVolumeNames failed: ${e.message}")
            }
            android.util.Log.d("SteamFlow", "queryVideoAlbums: querying ${volMap.size} volume(s): ${volMap.keys}")
            volMap.values.toList()
        } else {
            listOf(MediaStore.Video.Media.EXTERNAL_CONTENT_URI)
        }

        for (collection in volumes) {
            android.util.Log.d("SteamFlow", "queryVideoAlbums: querying $collection")
            val cursor = contentResolver.query(
                collection,
                projection,
                null,
                null,
                "${MediaStore.Video.Media.BUCKET_DISPLAY_NAME} ASC"
            )

            cursor?.use {
                val idIdx = it.getColumnIndex(MediaStore.Video.Media._ID)
                val bucketIdIdx = it.getColumnIndex(MediaStore.Video.Media.BUCKET_ID)
                val bucketNameIdx = it.getColumnIndex(MediaStore.Video.Media.BUCKET_DISPLAY_NAME)
                val dataIdx = it.getColumnIndex(MediaStore.Video.Media.DATA)
                val relativePathIdx = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    it.getColumnIndex(MediaStore.Video.Media.RELATIVE_PATH)
                } else {
                    -1
                }

                // 如果连基本列都找不到，直接返回空
                if (bucketIdIdx < 0 || bucketNameIdx < 0) {
                    return@use
                }

                // 必须把当前查询所用的 collection 传下去：缩略图 URI 要用
                // “这条记录所属的卷”来拼，否则外置 SD 卡上的视频 ID 会被拼到
                // 主存储（external_primary）上，解析成完全不相干的另一个视频
                querySingleVolume(it, collection, idIdx, bucketIdIdx, bucketNameIdx, dataIdx, relativePathIdx, albums)
            }
        }

        android.util.Log.d("SteamFlow", "queryVideoAlbums: found ${albums.size} albums total")
        albums.sortByDescending { it["videoCount"] as Int }
        return albums.filter { (it["videoCount"] as Int) > 0 }
    }

    private fun querySingleVolume(
        cursor: android.database.Cursor,
        collection: Uri,
        idIdx: Int,
        bucketIdIdx: Int,
        bucketNameIdx: Int,
        dataIdx: Int,
        relativePathIdx: Int,
        albums: MutableList<Map<String, Any>>
    ) {
        val albumMap = mutableMapOf<String, AlbumData>()
        val rootDir = Environment.getExternalStorageDirectory().absolutePath

        while (cursor.moveToNext()) {
            val bucketName = cursor.getString(bucketNameIdx) ?: "Unknown"

            // 尝试多种方式获取相册路径
            var albumPath: String? = null

            // 1. 优先尝试 RELATIVE_PATH (Android 11+)
            if (relativePathIdx >= 0) {
                val relativePath = cursor.getString(relativePathIdx)
                if (!relativePath.isNullOrBlank()) {
                    val cleanPath = relativePath.trimEnd('/')
                    albumPath = "$rootDir/$cleanPath"
                }
            }

            // 2. 回退到 DATA 列
            if (albumPath == null && dataIdx >= 0) {
                val dataPath = cursor.getString(dataIdx)
                if (!dataPath.isNullOrBlank()) {
                    albumPath = getAlbumDirectoryPath(dataPath)
                }
            }

            // 3. 最后回退：用 bucket name 构造路径
            if (albumPath == null) {
                albumPath = "$rootDir/$bucketName"
            }

            // 按实际目录路径分组（而非 bucket_id），
            // 这样大小写不同的目录（DCIM/Camera vs dcim/Camera）不会合并
            val album = albumMap.getOrPut(albumPath) {
                AlbumData(
                    name = bucketName,
                    representativePath = albumPath,
                    count = 0,
                    firstVideoId = 0
                )
            }
            album.count++

            // 记录该相册第一个视频的 ID（用于取缩略图）
            if (album.firstVideoId == 0L && idIdx >= 0) {
                album.firstVideoId = cursor.getLong(idIdx)
            }
        }

        for ((_, albumData) in albumMap) {
            val thumbnailUri = if (albumData.firstVideoId > 0) {
                // 用实际来源卷拼接 URI，保证缩略图指向同一卷上的那个视频
                ContentUris.withAppendedId(collection, albumData.firstVideoId).toString()
            } else null

            albums.add(
                mapOf(
                    "name" to albumData.name,
                    "path" to albumData.representativePath,
                    "videoCount" to albumData.count,
                    "thumbnailPath" to (thumbnailUri ?: albumData.representativePath)
                )
            )
        }
    }

    private fun getAlbumDirectoryPath(videoPath: String?): String? {
        if (videoPath == null || videoPath.isBlank()) return null
        val lastSlash = videoPath.lastIndexOf('/')
        return if (lastSlash > 0) videoPath.substring(0, lastSlash) else null
    }

    data class AlbumData(
        val name: String,
        val representativePath: String,
        var count: Int,
        var firstVideoId: Long
    )
}