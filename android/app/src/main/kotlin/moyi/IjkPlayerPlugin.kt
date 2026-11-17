package moyi

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import tv.danmaku.ijk.media.player.IjkMediaPlayer

const val IJK_PLAYER_VIEW_TYPE = "moyi/ijkplayer"

internal class IjkPlayerView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int
) : PlatformView {
    private val channel = MethodChannel(messenger, "$IJK_PLAYER_VIEW_TYPE/$viewId")
    private val surfaceView = SurfaceView(context)
    private val positionHandler = Handler(Looper.getMainLooper())
    private var player: IjkMediaPlayer? = null
    private var surface: Surface? = null
    private var released = false
    private var lastDuration = 0L
    private var lastUrl = ""
    private var lastHeaders: Map<String, String> = emptyMap()
    private var lastPosition = 0L
    private var librariesLoaded = false

    private val positionRunnable = object : Runnable {
        override fun run() {
            if (released) return
            val current = player
            if (current != null) {
                try {
                    channel.invokeMethod("onPosition", current.currentPosition)
                } catch (_: Exception) {
                }
                sendDuration()
            }
            positionHandler.postDelayed(this, 500)
        }
    }

    private val holderCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            surface = holder.surface
            try {
                player?.setSurface(holder.surface)
            } catch (_: Exception) {
            }
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            surface = holder.surface
            try {
                player?.setSurface(holder.surface)
            } catch (_: Exception) {
            }
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            surface = null
            try {
                player?.setSurface(null)
            } catch (_: Exception) {
            }
        }
    }

    init {
        surfaceView.holder.addCallback(holderCallback)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "open" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("invalid_argument", "缺少播放地址", null)
                        } else {
                            val headers = readHeaders(call.argument<Map<*, *>>("headers"))
                            val position = call.argument<Number>("positionMs")?.toLong() ?: 0L
                            open(url, headers, position)
                            result.success(null)
                        }
                    }
                    "play" -> {
                        try {
                            player?.start()
                            channel.invokeMethod("onPlaying", true)
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    "pause" -> {
                        try {
                            player?.pause()
                            channel.invokeMethod("onPlaying", false)
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    "seekTo" -> {
                        val position = call.argument<Number>("positionMs")?.toLong()
                        if (position == null) {
                            result.error("invalid_argument", "缺少进度", null)
                        } else {
                            try {
                                player?.seekTo(position)
                            } catch (_: Exception) {
                            }
                            result.success(null)
                        }
                    }
                    "setSpeed" -> {
                        val speed = call.argument<Double>("speed")
                        if (speed == null) {
                            result.error("invalid_argument", "缺少倍速", null)
                        } else {
                            try {
                                player?.setSpeed(speed.toFloat())
                            } catch (_: Exception) {
                            }
                            result.success(null)
                        }
                    }
                    "stop" -> {
                        try {
                            player?.stop()
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    "release" -> {
                        release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                result.error("ijk_player_error", error.message ?: error.toString(), null)
            }
        }
        positionHandler.postDelayed(positionRunnable, 500)
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        release()
    }

    private fun release() {
        if (released) return
        released = true
        positionHandler.removeCallbacks(positionRunnable)
        surfaceView.holder.removeCallback(holderCallback)
        channel.setMethodCallHandler(null)
        try {
            player?.release()
        } catch (_: Exception) {
        }
        player = null
    }

    private fun readHeaders(raw: Map<*, *>?): Map<String, String> {
        if (raw == null) return emptyMap()
        val headers = LinkedHashMap<String, String>()
        for ((key, value) in raw) {
            if (key != null && value != null) headers[key.toString()] = value.toString()
        }
        return headers
    }

    private fun open(url: String, headers: Map<String, String>, positionMs: Long) {
        val normalized = when {
            url.startsWith("http://") || url.startsWith("https://") ||
                url.startsWith("file://") || url.startsWith("content://") -> url
            else -> "file://$url"
        }
        lastUrl = normalized
        lastHeaders = headers
        lastPosition = positionMs
        lastDuration = 0L
        try {
            player?.release()
        } catch (_: Exception) {
        }
        player = null
        try {
            if (!librariesLoaded) {
                IjkMediaPlayer.loadLibrariesOnce(null)
                librariesLoaded = true
            }
        } catch (_: Exception) {
        }
        val current = IjkMediaPlayer()
        current.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec", 1L)
        current.setOnPreparedListener { mp ->
            sendDuration()
            channel.invokeMethod("onBuffering", false)
            try {
                if (lastPosition > 0) mp.seekTo(lastPosition)
            } catch (_: Exception) {
            }
            try {
                mp.start()
                channel.invokeMethod("onPlaying", true)
            } catch (_: Exception) {
            }
        }
        current.setOnCompletionListener {
            channel.invokeMethod("onPlaying", false)
            channel.invokeMethod("onCompleted", null)
        }
        current.setOnErrorListener { _, _, _ ->
            channel.invokeMethod("onError", "播放失败")
            true
        }
        try {
            surface?.let { current.setSurface(it) }
        } catch (_: Exception) {
        }
        try {
            current.setDataSource(normalized, headers)
            channel.invokeMethod("onBuffering", true)
            current.prepareAsync()
        } catch (error: Throwable) {
            channel.invokeMethod("onError", error.message ?: "播放失败")
            try {
                current.release()
            } catch (_: Exception) {
            }
            return
        }
        player = current
    }

    private fun sendDuration() {
        val duration = try {
            player?.duration ?: 0L
        } catch (_: Exception) {
            0L
        }
        if (duration > 0 && duration != lastDuration) {
            lastDuration = duration
            channel.invokeMethod("onDuration", duration)
        }
    }
}

internal class IjkPlayerFactory(
    private val messenger: BinaryMessenger
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        IjkPlayerView(context, messenger, viewId)
}

class IjkPlayerPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(
            IJK_PLAYER_VIEW_TYPE,
            IjkPlayerFactory(binding.binaryMessenger)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
}
