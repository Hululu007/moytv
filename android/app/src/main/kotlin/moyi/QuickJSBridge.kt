package moyi

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request

class QuickJSBridge {
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        init {
            System.loadLibrary("moyi_quickjs")
        }

        private val httpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(15, TimeUnit.SECONDS)
                .build()
        }

        @JvmStatic
        fun fetch(url: String): String? {
            return try {
                val request = Request.Builder().url(url)
                    .header("User-Agent", "Mozilla/5.0")
                    .build()
                httpClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) null else response.body?.string()
                }
            } catch (error: Throwable) {
                null
            }
        }
    }

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger): MethodChannel {
        val channel = MethodChannel(messenger, "moyi/quickjs")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "eval" -> {
                    val script = call.argument<String>("script")
                    if (script == null) {
                        result.error("invalid_argument", "缺少 JS 脚本", null)
                    } else {
                        val timeout = call.argument<Int>("timeoutMs") ?: 10000
                        executor.execute {
                            try {
                                val value = nativeEval(script, timeout)
                                mainHandler.post { result.success(value) }
                            } catch (error: Throwable) {
                                val message = error.message ?: error.toString()
                                mainHandler.post { result.error("quickjs_error", message, null) }
                            }
                        }
                    }
                }
                "status" -> result.success("{\"available\":true,\"engine\":\"QuickJS 2024-01-13\"}")
                else -> result.notImplemented()
            }
        }
        return channel
    }

    fun shutdown() {
        executor.shutdownNow()
    }

    private external fun nativeEval(script: String, timeoutMs: Int): String
}
