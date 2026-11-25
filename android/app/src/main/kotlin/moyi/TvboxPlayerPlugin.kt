package moyi

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.DefaultDrmSessionManagerProvider
import androidx.media3.exoplayer.drm.DrmSessionManager
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.LocalMediaDrmCallback
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
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
    private val playerView = PlayerView(context).apply {
        useController = false
        // 字幕改由 Dart 层叠放渲染（同组多 cue 不重叠），原生
        // SubtitleView 隐藏，否则同一组 cue 会画两遍。构建时验。
        subtitleView?.visibility = View.GONE
    }
    private val positionHandler = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private var released = false
    private var lastDuration = 0L
    private var lastUrl = ""
    private var lastHeaders: Map<String, String> = emptyMap()
    private var lastDecoderMode = "optimized"
    private var lastDrm: DrmArgs? = null
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

        // 字幕组变化时原样转发给 Dart 层叠放渲染；只实现 CueGroup
        // 这一版 onCues（已废弃的 List<Cue> 版与它同时触发，勿重复实现）。
        // 空组也转发，Dart 侧据此清掉上一组字幕。构建时验。
        override fun onCues(cueGroup: CueGroup) {
            val cueList = ArrayList<Map<String, Any?>>()
            for (cue in cueGroup.cues) {
                val text = cue.text?.toString() ?: ""
                if (text.isEmpty()) continue
                val map = HashMap<String, Any?>()
                map["text"] = text
                if (cue.line != Cue.DIMEN_UNSET) map["line"] = cue.line.toDouble()
                if (cue.position != Cue.DIMEN_UNSET) {
                    map["position"] = cue.position.toDouble()
                }
                cueList.add(map)
            }
            channel.invokeMethod(
                "onCues",
                mapOf(
                    "presentationTimeUs" to cueGroup.presentationTimeUs,
                    "cues" to cueList
                )
            )
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
                            val drm = readDrm(call.argument<Map<*, *>>("drm"))
                            open(url, headers, position, mode, true, drm)
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
                            open(lastUrl, lastHeaders, position, mode, wasPlaying, lastDrm)
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

    // DRM 参数（Dart 侧 PlaybackDrm.toJson 的形状）：type/key/
    // headers/forceKey。key 已在 Dart 侧归一化：服务器型是许可证
    // 地址，ClearKey 本地键是 JWK JSON 字符串（以 { 开头）。
    private data class DrmArgs(
        val type: String,
        val key: String,
        val headers: Map<String, String>,
        val forceKey: Boolean
    )

    private fun readDrm(raw: Map<*, *>?): DrmArgs? {
        if (raw == null) return null
        val type = raw["type"]?.toString()?.trim().orEmpty()
        val key = raw["key"]?.toString()?.trim().orEmpty()
        if (type.isEmpty() || key.isEmpty()) return null
        @Suppress("UNCHECKED_CAST")
        val headers = readHeaders(raw["headers"] as? Map<*, *>)
        return DrmArgs(type, key, headers, raw["forceKey"] == true)
    }

    private fun drmUuid(type: String): java.util.UUID? = when {
        type.contains("widevine", ignoreCase = true) -> C.WIDEVINE_UUID
        type.contains("playready", ignoreCase = true) -> C.PLAYREADY_UUID
        type.contains("clearkey", ignoreCase = true) -> C.CLEARKEY_UUID
        else -> null
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
        play: Boolean,
        drm: DrmArgs? = null
    ) {
        val normalized = when {
            url.startsWith("http://") || url.startsWith("https://") ||
                url.startsWith("file://") || url.startsWith("content://") -> url
            else -> "file://$url"
        }
        lastUrl = normalized
        lastHeaders = headers
        lastDecoderMode = decoderMode
        lastDrm = drm
        lastDuration = 0L
        player?.removeListener(listener)
        player?.release()
        val httpFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(30000)
            .setReadTimeoutMs(30000)
        if (headers.isNotEmpty()) httpFactory.setDefaultRequestProperties(headers)
        // 文本轨默认只选带语言的：MKV 内嵌 ASS 常无语言标记，须显式
        // 允许未定语言轨，否则字幕轨根本不被选中。构建时验。
        val trackSelector = DefaultTrackSelector(appContext).apply {
            parameters = buildUponParameters()
                .setRendererDisabled(C.TRACK_TYPE_TEXT, false)
                .setSelectUndeterminedTextLanguage(true)
                .build()
        }
        // DRM：按 type 选方案 UUID。服务器型（Widevine/PlayReady/
        // ClearKey 许可证端点）走 MediaItem.DrmConfiguration +
        // 默认会话管理（HttpMediaDrmCallback 向许可证地址发请求、
        // 系统 MediaDrm 真正解密）；ClearKey 本地键（JWK JSON）
        // 默认管理走不通，换 LocalMediaDrmCallback 在本地应答
        // 密钥请求。无 drm 或 type 不认时与旧行为完全一致。
        var localClearKeyJwk: ByteArray? = null
        val itemBuilder = MediaItem.Builder().setUri(normalized)
        val drmUuid = drm?.let { drmUuid(it.type) }
        if (drm != null && drmUuid != null) {
            val isLocalClearKey = drmUuid == C.CLEARKEY_UUID &&
                drm.key.trimStart().startsWith("{")
            if (isLocalClearKey) {
                localClearKeyJwk = drm.key.toByteArray(Charsets.UTF_8)
            }
            val configBuilder = MediaItem.DrmConfiguration.Builder(drmUuid)
                .setMultiSession(drmUuid != C.CLEARKEY_UUID)
                .setForceDefaultLicenseUri(drm.forceKey)
            if (!isLocalClearKey) {
                configBuilder.setLicenseUri(drm.key)
                if (drm.headers.isNotEmpty()) {
                    configBuilder.setLicenseRequestHeaders(drm.headers)
                }
            }
            itemBuilder.setDrmConfiguration(configBuilder.build())
        }
        val sourceFactory = DefaultMediaSourceFactory(httpFactory)
        val jwk = localClearKeyJwk
        if (jwk != null) {
            sourceFactory.setDrmSessionManagerProvider(
                object : DrmSessionManagerProvider {
                    override fun get(
                        configuration: MediaItem.DrmConfiguration
                    ): DrmSessionManager {
                        if (configuration.schemeUuid == C.CLEARKEY_UUID) {
                            return DefaultDrmSessionManager.Builder()
                                .setUuidAndExoMediaDrmProvider(
                                    C.CLEARKEY_UUID,
                                    FrameworkMediaDrm.DEFAULT_PROVIDER
                                )
                                .setMultiSession(false)
                                .build(LocalMediaDrmCallback(jwk))
                        }
                        return DefaultDrmSessionManagerProvider().get(configuration)
                    }
                }
            )
        }
        val current = ExoPlayer.Builder(appContext)
            .setTrackSelector(trackSelector)
            .setRenderersFactory(renderersFactory(decoderMode))
            .setMediaSourceFactory(sourceFactory)
            .build()
        player = current
        current.addListener(listener)
        playerView.player = current
        playerView.subtitleView?.visibility = View.GONE
        current.setMediaItem(itemBuilder.build())
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
