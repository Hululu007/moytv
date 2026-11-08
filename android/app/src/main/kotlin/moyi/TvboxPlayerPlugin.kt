package moyi

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

const val TVBOX_PLAYER_VIEW_TYPE = "moyi/tvboxplayer"

@OptIn(UnstableApi::class)
internal class SoftwarePreferredCodecSelector : MediaCodecSelector {
    override fun getDecoderInfos(
        mimeType: String,
        requiresSecureDecoder: Boolean,
        requiresTunnelingDecoder: Boolean
    ) = MediaCodecSelector.DEFAULT
        .getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
        .sortedByDescending { info ->
            info.name.startsWith("OMX.google.") || info.name.startsWith("c2.google.")
        }
}

@OptIn(UnstableApi::class)
internal class TvboxPlayerView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int
) : PlatformView {
    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, "$TVBOX_PLAYER_VIEW_TYPE/$viewId")
    private val playerView = PlayerView(context).apply { useController = false }
    private val positionHandler = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private var released = false
    private var lastDuration = 0L
    private var lastUrl = ""
    private var lastHeaders: Map<String, String> = emptyMap()
    private var lastDecoderMode = "optimized"
    private var wasPlaying = false

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_READY) {
                sendDuration()
                channel.invokeMethod("onPlaying", player?.isPlaying ?: false)
            }
            if (state == Player.STATE_ENDED) {
                channel.invokeMethod("onCompleted", null)
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            channel.invokeMethod("onPlaying", isPlaying)
        }

        override fun onIsLoadingChanged(isLoading: Boolean) {
            channel.invokeMethod("onBuffering", isLoading)
        }

        override fun onPlayerError(error: PlaybackException) {
            channel.invokeMethod("onError", error.message ?: "播放失败")
        }
    }

    private val positionRunnable = object : Runnable {
        override fun run() {
            if (released) return
            val current = player
            if (current != null) {
                channel.invokeMethod("onPosition", current.currentPosition)
                sendDuration()
            }
            positionHandler.postDelayed(this, 500)
        }
    }

    init {
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
                            val mode = call.argument<String>("decoderMode") ?: "optimized"
                            open(url, headers, position, mode, true)
                            result.success(null)
                        }
                    }
                    "play" -> {
                        player?.play()
                        result.success(null)
                    }
                    "pause" -> {
                        player?.pause()
                        result.success(null)
                    }
                    "seekTo" -> {
                        val position = call.argument<Number>("positionMs")?.toLong()
                        if (position == null) {
                            result.error("invalid_argument", "缺少进度", null)
                        } else {
                            player?.seekTo(position)
                            result.success(null)
                        }
                    }
                    "setSpeed" -> {
                        val speed = call.argument<Double>("speed")
                        if (speed == null) {
                            result.error("invalid_argument", "缺少倍速", null)
                        } else {
                            player?.setPlaybackSpeed(speed.toFloat())
                            result.success(null)
                        }
                    }
                    "setDecoderMode" -> {
                        val mode = call.argument<String>("decoderMode")
                        if (mode == null) {
                            result.error("invalid_argument", "缺少解码模式", null)
                        } else if (mode != lastDecoderMode && lastUrl.isNotEmpty()) {
                            val position = player?.currentPosition ?: 0L
                            wasPlaying = player?.isPlaying ?: false
                            open(lastUrl, lastHeaders, position, mode, wasPlaying)
                            result.success(null)
                        } else {
                            lastDecoderMode = mode
                            result.success(null)
                        }
                    }
                    "stop" -> {
                        player?.stop()
                        result.success(null)
                    }
                    "release" -> {
                        release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                result.error("tvbox_player_error", error.message ?: error.toString(), null)
            }
        }
        positionHandler.postDelayed(positionRunnable, 500)
    }

    override fun getView(): View = playerView

    override fun dispose() {
        release()
    }

    private fun release() {
        if (released) return
        released = true
        positionHandler.removeCallbacks(positionRunnable)
        channel.setMethodCallHandler(null)
        player?.removeListener(listener)
        player?.release()
        player = null
        playerView.player = null
    }

    private fun readHeaders(raw: Map<*, *>?): Map<String, String> {
        if (raw == null) return emptyMap()
        val headers = LinkedHashMap<String, String>()
        for ((key, value) in raw) {
            if (key != null && value != null) headers[key.toString()] = value.toString()
        }
        return headers
    }

    private fun renderersFactory(decoderMode: String): DefaultRenderersFactory {
        val factory = DefaultRenderersFactory(appContext)
        if (decoderMode == "software") {
            factory.setMediaCodecSelector(SoftwarePreferredCodecSelector())
        }
        return factory
    }

    private fun open(
        url: String,
        headers: Map<String, String>,
        positionMs: Long,
        decoderMode: String,
        play: Boolean
    ) {
        val normalized = when {
            url.startsWith("http://") || url.startsWith("https://") ||
                url.startsWith("file://") || url.startsWith("content://") -> url
            else -> "file://$url"
        }
        lastUrl = normalized
        lastHeaders = headers
        lastDecoderMode = decoderMode
        lastDuration = 0L
        player?.removeListener(listener)
        player?.release()
        val httpFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(30000)
            .setReadTimeoutMs(30000)
        if (headers.isNotEmpty()) httpFactory.setDefaultRequestProperties(headers)
        val current = ExoPlayer.Builder(appContext)
            .setRenderersFactory(renderersFactory(decoderMode))
            .setMediaSourceFactory(DefaultMediaSourceFactory(httpFactory))
            .build()
        player = current
        current.addListener(listener)
        playerView.player = current
        current.setMediaItem(MediaItem.Builder().setUri(normalized).build())
        current.playWhenReady = play
        if (positionMs > 0) current.seekTo(positionMs)
        current.prepare()
    }

    private fun sendDuration() {
        val duration = player?.duration ?: 0L
        if (duration > 0 && duration != lastDuration) {
            lastDuration = duration
            channel.invokeMethod("onDuration", duration)
        }
    }
}

internal class TvboxPlayerFactory(
    private val messenger: BinaryMessenger
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        TvboxPlayerView(context, messenger, viewId)
}

class TvboxPlayerPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(
            TVBOX_PLAYER_VIEW_TYPE,
            TvboxPlayerFactory(binding.binaryMessenger)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
}
