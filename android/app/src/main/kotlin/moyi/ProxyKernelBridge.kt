package moyi

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

object ProxyKernelBridge {
    private const val PREFS = "moyi_proxy_kernel"
    private var process: Process? = null
    private var controllerPort: Int = 0
    private var controllerSecret: String = ""
    private var selectedNode: String = ""
    private var activeBinary: String = ""

    private fun kernelDir(context: Context): File =
        File(context.filesDir, "proxy_kernel").apply { mkdirs() }

    private fun binaryFile(context: Context): File =
        File(kernelDir(context), "mihomo")

    private fun builtinFile(context: Context): File =
        File(kernelDir(context), "mihomo-builtin")

    private fun logFile(context: Context): File =
        File(kernelDir(context), "mihomo.log")

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun builtinAvailable(context: Context): Boolean {
        return runCatching {
            context.assets.open("flutter_assets/assets/proxy_kernel/mihomo").close()
            true
        }.getOrDefault(false)
    }

    private fun isElf(file: File): Boolean {
        if (!file.isFile) return false
        return runCatching {
            val header = ByteArray(4)
            file.inputStream().use { stream ->
                if (stream.read(header) != 4) return@runCatching false
            }
            header[0] == 0x7F.toByte() &&
                header[1] == 'E'.code.toByte() &&
                header[2] == 'L'.code.toByte() &&
                header[3] == 'F'.code.toByte()
        }.getOrDefault(false)
    }

    private fun ensureBuiltin(context: Context): File? {
        val target = builtinFile(context)
        if (target.isFile && target.canExecute() && isElf(target)) return target
        return runCatching {
            if (target.exists()) target.setWritable(true, false)
            context.assets.open("flutter_assets/assets/proxy_kernel/mihomo").use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            target.setReadable(true, false)
            target.setExecutable(true, false)
            target.setWritable(false, false)
            if (!target.canExecute() || !isElf(target)) return@runCatching null
            readVersion(target)?.let { version ->
                prefs(context).edit().putString("builtinVersion", version).apply()
            }
            target
        }.getOrNull()
    }

    private fun freePort(candidate: Int): Int {
        var port = candidate.coerceIn(1, 65535)
        while (port <= 65535) {
            try {
                ServerSocket(port).close()
                return port
            } catch (_: Exception) {
                port++
            }
        }
        return candidate
    }

    private fun readVersion(binary: File): String? {
        return runCatching {
            val proc = ProcessBuilder(binary.absolutePath, "-v")
                .redirectErrorStream(true)
                .start()
            val finished = proc.waitFor(10, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                return@runCatching null
            }
            val output = proc.inputStream.bufferedReader().readText()
            Regex("""v?\d+\.\d+\.\d+""").find(output)?.value
        }.getOrNull()
    }

    private fun running(): Boolean {
        val proc = process
        return proc != null && proc.isAlive
    }

    private fun stopLocked() {
        val proc = process
        process = null
        controllerPort = 0
        controllerSecret = ""
        activeBinary = ""
        if (proc == null) return
        runCatching {
            proc.destroy()
            if (!proc.waitFor(3, TimeUnit.SECONDS)) proc.destroyForcibly()
        }
    }

    private fun statusMap(context: Context): Map<String, Any?> {
        val external = binaryFile(context)
        val hasExternal = external.isFile
        val builtin = builtinAvailable(context)
        val installed = builtin || hasExternal
        val preferences = prefs(context)
        val externalVersion = preferences.getString("externalVersion", null)
            ?: preferences.getString("version", "") ?: ""
        val builtinVersion = preferences.getString("builtinVersion", "") ?: ""
        return mapOf(
            "supported" to true,
            "installed" to installed,
            "builtinAvailable" to builtin,
            "hasExternal" to hasExternal,
            "version" to if (hasExternal) externalVersion else builtinVersion,
            "builtinVersion" to builtinVersion,
            "externalVersion" to if (hasExternal) externalVersion else "",
            "activeBinary" to if (running()) activeBinary else "",
            "running" to running(),
            "mixedPort" to 0,
            "controllerPort" to if (running()) controllerPort else 0,
            "selectedNode" to selectedNode,
            "logTail" to ""
        )
    }

    private fun controllerGet(path: String): String {
        if (!running() || controllerPort <= 0) {
            throw IllegalStateException("代理内核未运行")
        }
        val url = URL("http://127.0.0.1:$controllerPort$path")
        val connection = url.openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        if (controllerSecret.isNotEmpty()) {
            connection.setRequestProperty("Authorization", "Bearer $controllerSecret")
        }
        try {
            val code = connection.responseCode
            val stream = if (code in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            val body = stream?.bufferedReader()?.readText() ?: ""
            if (code !in 200..299) {
                throw IllegalStateException("控制接口返回 HTTP $code：$body")
            }
            return body
        } finally {
            connection.disconnect()
        }
    }

    private fun controllerPut(path: String, body: String) {
        if (!running() || controllerPort <= 0) {
            throw IllegalStateException("代理内核未运行")
        }
        val url = URL("http://127.0.0.1:$controllerPort$path")
        val connection = url.openConnection() as HttpURLConnection
        connection.requestMethod = "PUT"
        connection.doOutput = true
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        connection.setRequestProperty("Content-Type", "application/json")
        if (controllerSecret.isNotEmpty()) {
            connection.setRequestProperty("Authorization", "Bearer $controllerSecret")
        }
        try {
            connection.outputStream.bufferedWriter().use { it.write(body) }
            val code = connection.responseCode
            if (code !in 200..299) {
                val error = connection.errorStream?.bufferedReader()?.readText() ?: ""
                throw IllegalStateException("控制接口返回 HTTP $code：$error")
            }
        } finally {
            connection.disconnect()
        }
    }

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, "moyi/proxykernel").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(statusMap(context))
                    "pickPorts" -> {
                        val mixed = call.argument<Int>("mixedPort") ?: 7890
                        val controller = call.argument<Int>("controllerPort") ?: 9090
                        val pickedMixed = freePort(mixed)
                        var pickedController = freePort(controller)
                        if (pickedController == pickedMixed) {
                            pickedController = freePort(pickedMixed + 1)
                        }
                        result.success(
                            mapOf(
                                "mixedPort" to pickedMixed,
                                "controllerPort" to pickedController
                            )
                        )
                    }
                    "installBinary" -> {
                        val path = call.argument<String>("path")
                        val staged = path?.let { File(it) }
                        if (staged == null || !staged.isFile) {
                            result.error("missing_binary", "待安装的内核文件不存在", null)
                            return@setMethodCallHandler
                        }
                        val header = ByteArray(4)
                        staged.inputStream().use { stream ->
                            if (stream.read(header) != 4) {
                                result.error("bad_binary", "内核文件过小，无法校验", null)
                                return@setMethodCallHandler
                            }
                        }
                        if (!(header[0] == 0x7F.toByte() &&
                                header[1] == 'E'.code.toByte() &&
                                header[2] == 'L'.code.toByte() &&
                                header[3] == 'F'.code.toByte())) {
                            result.error("bad_binary", "内核文件不是 ELF 可执行文件", null)
                            return@setMethodCallHandler
                        }
                        val target = binaryFile(context)
                        staged.copyTo(target, overwrite = true)
                        target.setExecutable(true, false)
                        val version = readVersion(target)
                        if (version == null) {
                            target.delete()
                            prefs(context).edit()
                                .remove("version")
                                .remove("externalVersion")
                                .apply()
                            result.error("bad_binary", "内核无法运行（-v 未返回版本），已删除", null)
                            return@setMethodCallHandler
                        }
                        prefs(context).edit()
                            .putString("version", version)
                            .putString("externalVersion", version)
                            .remove("externalBad")
                            .apply()
                        result.success(statusMap(context))
                    }
                    "start" -> {
                        val configPath = call.argument<String>("configPath")
                        val workDir = call.argument<String>("workDir")
                        val port = call.argument<Int>("controllerPort") ?: 0
                        val secret = call.argument<String>("secret") ?: ""
                        if (configPath.isNullOrBlank() || workDir.isNullOrBlank()) {
                            result.error("missing_config", "缺少内核配置文件", null)
                            return@setMethodCallHandler
                        }
                        stopLocked()
                        val preferences = prefs(context)
                        val externalBad =
                            preferences.getBoolean("externalBad", false)
                        val candidates = mutableListOf<Pair<File, String>>()
                        val external = binaryFile(context)
                        if (external.isFile && !externalBad) {
                            if (isElf(external)) {
                                candidates.add(external to "external")
                            } else {
                                preferences.edit().putBoolean("externalBad", true).apply()
                            }
                        }
                        val builtin = ensureBuiltin(context)
                        if (builtin != null) {
                            candidates.add(builtin to "builtin")
                        }
                        if (candidates.isEmpty()) {
                            result.error(
                                "not_installed",
                                "内核不可用：内置核缺失且无可用外置核，请重装完整安装包",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        val log = logFile(context)
                        var started: Process? = null
                        var startedKind = ""
                        var externalStartFailed = false
                        for ((candidate, kind) in candidates) {
                            val builder = ProcessBuilder(candidate.absolutePath, "-d", workDir)
                                .directory(File(workDir))
                                .redirectOutput(ProcessBuilder.Redirect.appendTo(log))
                                .redirectErrorStream(true)
                            val proc = builder.start()
                            Thread.sleep(800)
                            if (proc.isAlive) {
                                started = proc
                                startedKind = kind
                                break
                            }
                            if (kind == "external") externalStartFailed = true
                        }
                        if (started == null) {
                            result.error(
                                "start_failed",
                                "内核启动后立即退出（内置与外置均失败），请查看运行日志",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        if (externalStartFailed && startedKind == "builtin") {
                            preferences.edit().putBoolean("externalBad", true).apply()
                        }
                        process = started
                        activeBinary = startedKind
                        controllerPort = port
                        controllerSecret = secret
                        val status = statusMap(context).toMutableMap()
                        val configText = runCatching {
                            File(configPath).readText()
                        }.getOrDefault("")
                        val mixed = Regex("""mixed-port:\s*(\d+)""")
                            .find(configText)?.groupValues?.getOrNull(1)?.toIntOrNull()
                            ?: 0
                        status["mixedPort"] = mixed
                        result.success(status)
                    }
                    "stop" -> {
                        stopLocked()
                        result.success(statusMap(context))
                    }
                    "deleteBinary" -> {
                        stopLocked()
                        binaryFile(context).delete()
                        prefs(context).edit()
                            .remove("version")
                            .remove("externalVersion")
                            .remove("externalBad")
                            .apply()
                        selectedNode = ""
                        result.success(statusMap(context))
                    }
                    "proxies" -> {
                        result.success(mapOf("body" to controllerGet("/proxies")))
                    }
                    "selectProxy" -> {
                        val group = call.argument<String>("group") ?: "PROXY"
                        val name = call.argument<String>("name")
                        if (name.isNullOrBlank()) {
                            result.error("missing_node", "缺少节点名", null)
                            return@setMethodCallHandler
                        }
                        val encodedGroup = URLEncoder.encode(group, "UTF-8")
                        val escaped = name
                            .replace("\\", "\\\\")
                            .replace("\"", "\\\"")
                        controllerPut("/proxies/$encodedGroup", "{\"name\":\"$escaped\"}")
                        selectedNode = name
                        result.success(mapOf("selected" to name))
                    }
                    "delay" -> {
                        val name = call.argument<String>("name")
                        val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
                        if (name.isNullOrBlank()) {
                            result.error("missing_node", "缺少节点名", null)
                            return@setMethodCallHandler
                        }
                        val encoded = URLEncoder.encode(name, "UTF-8")
                        val testUrl = URLEncoder.encode(
                            "http://www.gstatic.com/generate_204",
                            "UTF-8"
                        )
                        val body = controllerGet(
                            "/proxies/$encoded/delay?url=$testUrl&timeout=$timeoutMs"
                        )
                        result.success(mapOf("body" to body))
                    }
                    "logs" -> {
                        val log = logFile(context)
                        val lines = if (log.isFile) {
                            log.readLines()
                        } else {
                            emptyList()
                        }
                        result.success(
                            mapOf("log" to lines.takeLast(200).joinToString("\n"))
                        )
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("proxy_kernel_error", error.message ?: "代理内核操作失败", null)
            }
        }
    }
}
