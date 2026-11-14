package moyi

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * 选集卡真帧提取桥：用系统 MediaMetadataRetriever 在后台线程取一帧，
 * 不建播放器、不占界面。地址直接用播放链解析出的 plan.url（含 Go
 * 本地中继解密后的 127.0.0.1 地址，解密已由中继做完，取帧侧只读
 * 明文流）；直链则把 plan.headers 一并带上（防盗链 Referer/UA）。
 *
 * 全黑帧直接判失败返回 null，调用方回落海报，不把黑图存进缓存。
 * 并发池固定 2 路，与 Dart 侧服务上限一致。
 */
object FrameExtractorBridge {

    private const val CHANNEL = "moyi/frame_extractor"

    private val executor = Executors.newFixedThreadPool(2)
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "extractFrame") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val url = call.argument<String>("url").orEmpty()
            if (url.isEmpty()) {
                result.error("frame_invalid", "缺少播放地址", null)
                return@setMethodCallHandler
            }
            val rawHeaders = call.argument<Map<*, *>>("headers")
            val headers = mutableMapOf<String, String>()
            rawHeaders?.forEach { (key, value) ->
                if (key != null && value != null) {
                    headers[key.toString()] = value.toString()
                }
            }
            val positionUs = call.argument<Number>("positionUs")?.toLong() ?: 5_000_000L
            executor.execute {
                try {
                    val bytes = extractFrame(url, headers, positionUs)
                    mainHandler.post { result.success(bytes) }
                } catch (error: Throwable) {
                    val message = error.message ?: error.javaClass.simpleName
                    mainHandler.post { result.error("frame_error", message, null) }
                }
            }
        }
    }

    private fun extractFrame(
        url: String,
        headers: Map<String, String>,
        positionUs: Long,
    ): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            if (headers.isEmpty()) {
                retriever.setDataSource(url)
            } else {
                retriever.setDataSource(url, headers)
            }
            val bitmap = retriever.getFrameAtTime(
                positionUs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return null
            try {
                if (bitmap.width <= 0 || bitmap.height <= 0) return null
                if (isNearBlack(bitmap)) return null
                val out = ByteArrayOutputStream()
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)) {
                    return null
                }
                val bytes = out.toByteArray()
                return bytes.ifEmpty { null }
            } finally {
                if (!bitmap.isRecycled) bitmap.recycle()
            }
        } finally {
            runCatching { retriever.release() }
        }
    }

    /**
     * 只拦“全采样点都近黑”的真黑帧：夜戏/暗场只要有一处亮点就放行。
     * 像素读不到（非常规位图配置）时不拦，宁可放行一张真帧。
     */
    private fun isNearBlack(bitmap: Bitmap): Boolean {
        try {
            val width = bitmap.width
            val height = bitmap.height
            val cols = 16
            val rows = 16
            for (row in 0 until rows) {
                for (col in 0 until cols) {
                    val x = ((col + 0.5) * width / cols).toInt().coerceIn(0, width - 1)
                    val y = ((row + 0.5) * height / rows).toInt().coerceIn(0, height - 1)
                    val pixel = bitmap.getPixel(x, y)
                    val lum = 0.299 * Color.red(pixel) +
                        0.587 * Color.green(pixel) +
                        0.114 * Color.blue(pixel)
                    if (lum >= 12) return false
                }
            }
            return true
        } catch (_: Exception) {
            return false
        }
    }
}
