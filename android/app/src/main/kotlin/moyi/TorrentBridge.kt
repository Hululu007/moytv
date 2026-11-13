package moyi

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.github.catvod.spider.Init
import com.xunlei.downloadlib.XLTaskHelper
import com.xunlei.downloadlib.parameter.GetTaskId
import com.xunlei.downloadlib.parameter.TorrentFileInfo
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 种子原生桥：TorrServer 子进程管理 + 迅雷 SDK 调用。
 *
 * TorrServer：64M Go 二进制以 8 个分片随包下发（assets/torrserver_chunks/），
 * 首次启动时拼回、验大小与 SHA-256、加可执行权限后子进程启动。
 * 迅雷：走 thunder-release.aar 的 XLTaskHelper（渔老 webhtv 的 Thunder.java
 * 同款接法），magnet/thunder/ed2k 与 .torrent 地址都能解析。
 *
 * XLTaskHelper 的方法都是 synchronized 阻塞调用，一律走后台线程，绝不上主线程。
 * release() 是全局的：只在没有任何任务时才不调——这里按任务删除，
 * 从不调 release()，避免杀掉其它正在播的任务。
 */
object TorrentBridge {

    private const val CHANNEL = "moyi/torrent"
    private const val TORRSERVER_SIZE = 64493320L
    private const val TORRSERVER_SHA256 =
        "760f18c6837c7fc1c440726a14e7534e3baca914b780fbc3ec28a38b6158aaf0"
    private const val CHUNK_COUNT = 8

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var process: Process? = null
    private var serverPort: Int = 0

    private class ThunderTask(
        val taskId: GetTaskId,
        val folder: File,
        val singleFile: Boolean,
        val medias: List<TorrentFileInfo> = emptyList(),
    ) {
        var btTaskId: GetTaskId? = null
        var btIndex: Int = -1
    }

    private val thunderTasks = ConcurrentHashMap<String, ThunderTask>()

    fun register(messenger: BinaryMessenger, context: Context) {
        // 迅雷 aar 构造 XLDownloadManager 时就要 Init.context()，通道接通前先保证
        // 兼容层已初始化；JarBridge 也调过，init 是幂等赋值，重复调无害。
        Init.init(context)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "torrserverStatus" -> runAsync(result) { torrserverStatus(context) }
                "torrserverStart" -> {
                    val port = call.argument<Int>("port") ?: 8090
                    runAsync(result) { startServer(context, port) }
                }
                "torrserverStop" -> runAsync(result) {
                    stopServer()
                    emptyMap<String, Any?>()
                }
                "thunderStatus" -> runAsync(result) { thunderStatus() }
                "thunderResolve" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val key = call.argument<String>("key").orEmpty()
                    if (url.isEmpty() || key.isEmpty()) {
                        result.error("torrent_invalid", "缺少种子链接或任务键", null)
                    } else {
                        runAsync(result) { thunderResolve(context, url, key) }
                    }
                }
                "thunderStreamUrl" -> {
                    val taskKey = call.argument<String>("taskKey").orEmpty()
                    val index = call.argument<Int>("index") ?: 0
                    if (taskKey.isEmpty()) {
                        result.error("torrent_invalid", "缺少任务键", null)
                    } else {
                        runAsync(result) { thunderStreamUrl(taskKey, index) }
                    }
                }
                "thunderStats" -> {
                    val taskKey = call.argument<String>("taskKey").orEmpty()
                    if (taskKey.isEmpty()) {
                        result.error("torrent_invalid", "缺少任务键", null)
                    } else {
                        runAsync(result) { thunderStats(taskKey) }
                    }
                }
                "thunderStop" -> {
                    val taskKey = call.argument<String>("taskKey").orEmpty()
                    runAsync(result) {
                        if (taskKey.isNotEmpty()) thunderStop(taskKey)
                        emptyMap<String, Any?>()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Map<String, Any?>) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                val message = error.message ?: error.javaClass.simpleName
                mainHandler.post { result.error("torrent_error", message, null) }
            }
        }
    }

    // ---- TorrServer ----

    private fun torrserverDir(context: Context): File =
        File(context.filesDir, "torrserver").apply { mkdirs() }

    private fun binaryFile(context: Context): File =
        File(torrserverDir(context), "torrserver")

    private fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1024 * 1024)
            var read: Int
            while (input.read(buffer).also { read = it } > 0) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun binaryShaOk(context: Context): Boolean {
        val target = binaryFile(context)
        if (!target.isFile || target.length() != TORRSERVER_SIZE) return false
        return runCatching { sha256Hex(target) == TORRSERVER_SHA256 }.getOrDefault(false)
    }

    private fun torrserverStatus(context: Context): Map<String, Any?> {
        val alive = process?.isAlive == true
        val target = binaryFile(context)
        return mapOf(
            "running" to alive,
            "port" to if (alive) serverPort else 0,
            "binaryPresent" to target.isFile,
            "binaryShaOk" to binaryShaOk(context),
        )
    }

    private fun ensureBinary(context: Context): File {
        val target = binaryFile(context)
        if (target.isFile && target.length() == TORRSERVER_SIZE && binaryShaOk(context)) {
            target.setExecutable(true, false)
            return target
        }
        val tmp = File(torrserverDir(context), "torrserver.tmp")
        tmp.outputStream().use { output ->
            for (i in 0 until CHUNK_COUNT) {
                val assetPath =
                    "flutter_assets/assets/torrserver_chunks/torrserver.part-%02d".format(i)
                context.assets.open(assetPath).use { input -> input.copyTo(output) }
            }
        }
        if (tmp.length() != TORRSERVER_SIZE || sha256Hex(tmp) != TORRSERVER_SHA256) {
            tmp.delete()
            throw IllegalStateException("TorrServer 文件拼回校验失败（大小或哈希不对）")
        }
        if (target.exists()) target.delete()
        if (!tmp.renameTo(target)) {
            tmp.copyTo(target, overwrite = true)
            tmp.delete()
        }
        target.setReadable(true, false)
        target.setExecutable(true, false)
        target.setWritable(false, false)
        return target
    }

    private fun freePort(candidate: Int): Int {
        val wanted = candidate.coerceIn(1, 65535)
        runCatching {
            ServerSocket(wanted).close()
            return wanted
        }
        return ServerSocket(0).use { it.localPort }
    }

    private fun canConnect(port: Int): Boolean {
        return runCatching {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 500)
            }
            true
        }.getOrDefault(false)
    }

    private fun startServer(context: Context, requestedPort: Int): Map<String, Any?> {
        if (process?.isAlive == true) {
            return mapOf("running" to true, "port" to serverPort)
        }
        val binary = try {
            ensureBinary(context)
        } catch (error: Throwable) {
            return mapOf(
                "running" to false,
                "port" to 0,
                "error" to "TorrServer 文件准备失败：${error.message}",
            )
        }
        val dir = torrserverDir(context)
        val port = freePort(requestedPort)
        val proc = ProcessBuilder(
            binary.absolutePath,
            "--port", port.toString(),
            "--path", dir.absolutePath,
            "--logpath", File(dir, "torrserver.log").absolutePath,
        )
            .directory(dir)
            .redirectOutput(ProcessBuilder.Redirect.appendTo(File(dir, "torrserver-stdout.log")))
            .redirectErrorStream(true)
            .start()
        process = proc
        serverPort = port
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            if (!proc.isAlive) {
                process = null
                serverPort = 0
                return mapOf(
                    "running" to false,
                    "port" to 0,
                    "error" to "TorrServer 进程启动后立即退出（退出码 ${proc.exitValue()}），详见 torrserver.log",
                )
            }
            if (canConnect(port)) {
                return mapOf("running" to true, "port" to port)
            }
            Thread.sleep(200)
        }
        return mapOf(
            "running" to false,
            "port" to 0,
            "error" to "TorrServer 10 秒内没有开始监听端口 $port",
        )
    }

    private fun stopServer() {
        val proc = process
        process = null
        serverPort = 0
        if (proc == null) return
        proc.destroy()
        if (!proc.waitFor(5, TimeUnit.SECONDS)) {
            proc.destroyForcibly()
        }
    }

    // ---- Thunder / XLTaskHelper ----

    private fun thunderStatus(): Map<String, Any?> {
        return try {
            XLTaskHelper.get()
            mapOf("available" to true)
        } catch (error: Throwable) {
            mapOf(
                "available" to false,
                "reason" to "迅雷引擎加载失败：${error.message ?: error.javaClass.simpleName}",
            )
        }
    }

    private fun md5(text: String): String {
        val digest = MessageDigest.getInstance("MD5")
        return digest.digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun isTorrentUrl(url: String): Boolean {
        return !url.startsWith("magnet") &&
            url.split(";")[0].lowercase().endsWith(".torrent")
    }

    private fun isVideoName(name: String?): Boolean {
        if (name.isNullOrEmpty()) return false
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in setOf(
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
            "ts", "m2ts", "rmvb", "3gp", "mpg", "mpeg", "vob", "asf",
        )
    }

    private fun waitThunderDone(helper: XLTaskHelper, taskId: GetTaskId) {
        for (i in 0 until 100) {
            if (helper.getTaskInfo(taskId).taskStatus == 2) return
            Thread.sleep(100)
        }
    }

    private fun downloadTo(urlText: String, target: File?) {
        val file = target ?: throw IllegalStateException("迅雷没有给出种子保存位置")
        val connection = URL(urlText).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 30_000
        connection.readTimeout = 30_000
        connection.connect()
        if (connection.responseCode !in 200..299) {
            throw IllegalStateException("下载 .torrent 文件失败：HTTP ${connection.responseCode}")
        }
        connection.inputStream.use { input ->
            file.outputStream().use { output -> input.copyTo(output) }
        }
    }

    private fun thunderResolve(
        context: Context,
        url: String,
        key: String,
    ): Map<String, Any?> {
        val folder = File(File(context.filesDir, "thunder"), md5(url)).apply { mkdirs() }
        val helper = XLTaskHelper.get()
        val taskId = helper.parse(url, folder)
        val torrent = isTorrentUrl(url)
        val realUrl = taskId.realUrl.orEmpty()
        if (!torrent && !realUrl.startsWith("magnet")) {
            val saveFile = taskId.saveFile
            val name = taskId.fileName ?: saveFile?.name ?: url
            val size = saveFile?.takeIf { it.isFile }?.length() ?: 0L
            thunderTasks[key] = ThunderTask(taskId, folder, singleFile = true)
            return mapOf(
                "infoHash" to key,
                "name" to name,
                "size" to size,
                "files" to listOf(
                    mapOf(
                        "index" to 0,
                        "name" to name,
                        "size" to size,
                        "isVideo" to isVideoName(name),
                    ),
                ),
                "taskKey" to key,
                "singleFile" to true,
            )
        }
        if (torrent && url.startsWith("http")) {
            downloadTo(url, taskId.saveFile)
        }
        if (!torrent) waitThunderDone(helper, taskId)
        val saveFile = taskId.saveFile
            ?: throw IllegalStateException("迅雷没有给出种子文件位置")
        val medias = helper.getTorrentInfo(saveFile).medias ?: emptyList()
        if (medias.isEmpty()) {
            throw IllegalStateException("迅雷没有取到种子文件列表（可能元数据还没下到）")
        }
        val files = medias.map { media ->
            mapOf(
                "index" to media.fileIndex,
                "name" to (media.fileName ?: ""),
                "size" to media.fileSize,
                "isVideo" to isVideoName(media.fileName),
            )
        }
        val total = medias.sumOf { it.fileSize }
        thunderTasks[key] = ThunderTask(taskId, folder, singleFile = false, medias = medias)
        return mapOf(
            "infoHash" to key,
            "name" to (taskId.fileName ?: medias.firstOrNull()?.fileName ?: url),
            "size" to total,
            "files" to files,
            "taskKey" to key,
            "singleFile" to false,
        )
    }

    private fun thunderStreamUrl(taskKey: String, index: Int): Map<String, Any?> {
        val task = thunderTasks[taskKey]
            ?: throw IllegalStateException("迅雷任务不存在或已停止，请重新解析")
        val helper = XLTaskHelper.get()
        if (task.singleFile) {
            val saveFile = task.taskId.saveFile
                ?: throw IllegalStateException("迅雷任务没有保存文件")
            return mapOf("url" to helper.getLocalUrl(saveFile))
        }
        val torrentFile = task.taskId.saveFile
            ?: throw IllegalStateException("种子文件不存在")
        val parent = torrentFile.parentFile ?: task.folder
        val media = task.medias.firstOrNull { it.fileIndex == index }
            ?: task.medias.getOrNull(index)
            ?: throw IllegalStateException("文件序号 $index 不存在")
        val btTaskId = helper.addTorrentTask(torrentFile, parent, media.fileIndex)
        task.btTaskId = btTaskId
        task.btIndex = media.fileIndex
        for (i in 0 until 100) {
            val info = helper.getBtSubTaskInfo(btTaskId, media.fileIndex).mTaskInfo
            if (info.mTaskStatus == 3) {
                throw IllegalStateException(info.errorMsg ?: "迅雷任务出错")
            }
            if (info.mTaskStatus != 0) {
                val target = runCatching { media.file }.getOrNull()
                    ?: File(parent, media.fileName ?: "")
                return mapOf("url" to helper.getLocalUrl(target))
            }
            Thread.sleep(100)
        }
        throw IllegalStateException("迅雷取流超时（10 秒没有开始传输）")
    }

    private fun thunderStats(taskKey: String): Map<String, Any?> {
        val task = thunderTasks[taskKey]
            ?: return mapOf(
                "status" to -1,
                "downloadSpeed" to 0,
                "downloaded" to 0,
                "total" to 0,
                "error" to "任务不存在",
            )
        val helper = XLTaskHelper.get()
        val info = if (task.btTaskId != null && task.btIndex >= 0) {
            helper.getBtSubTaskInfo(task.btTaskId, task.btIndex).mTaskInfo
        } else {
            helper.getTaskInfo(task.taskId)
        }
        return mapOf(
            "status" to info.mTaskStatus,
            "downloadSpeed" to info.mDownloadSpeed,
            "downloaded" to info.mDownloadSize,
            "total" to info.mFileSize,
            "error" to (info.errorMsg ?: ""),
        )
    }

    private fun thunderStop(taskKey: String) {
        val task = thunderTasks.remove(taskKey) ?: return
        runCatching { XLTaskHelper.get().deleteTask(task.taskId) }
        task.btTaskId?.let { bt -> runCatching { XLTaskHelper.get().deleteTask(bt) } }
    }
}
