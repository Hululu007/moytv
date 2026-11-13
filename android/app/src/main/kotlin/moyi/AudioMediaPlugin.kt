package moyi

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * 听书锁屏媒体会话：只用安卓框架类（MediaSession + 媒体样式通知），不新增依赖。
 *
 * 锁屏界面只含六项：书名、章节、封面、播放/暂停、上一章/下一章、进度。
 * 通知上的按键与耳机媒体键都经 MediaSession 回调 / 广播转发回 Dart 侧处理，
 * 原生侧自己不控制播放器。
 *
 * 注意：前台保活仍走 Dart 侧已有的 PlaybackForeground（flutter_foreground_task），
 * 本通知只负责锁屏/通知栏控制。两者通知并存，属已知形态。
 */
object AudioMediaPlugin {

    private const val CHANNEL = "moyi/audio_media"
    private const val CHANNEL_ID = "moyi_audio_playback"
    private const val NOTIFICATION_ID = 2407
    private const val ACTION_PLAY = "moyi.audio.ACTION_PLAY"
    private const val ACTION_PAUSE = "moyi.audio.ACTION_PAUSE"
    private const val ACTION_PREVIOUS = "moyi.audio.ACTION_PREVIOUS"
    private const val ACTION_NEXT = "moyi.audio.ACTION_NEXT"
    private const val COVER_MAX_PX = 512

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var session: MediaSession? = null
    private var receiver: BroadcastReceiver? = null
    private var published = false
    private var mainHandler: Handler? = null

    private var lastBookTitle = ""
    private var lastChapterTitle = ""
    private var lastCoverUrl = ""
    private var lastCover: Bitmap? = null
    private var lastPlaying = false
    private var lastPositionMs = 0L
    private var lastDurationMs = 0L
    private var lastHasPrevious = false
    private var lastHasNext = false
    private var lastRate = 1.0f

    fun register(messenger: BinaryMessenger, activity: Activity) {
        context = activity.applicationContext
        mainHandler = Handler(Looper.getMainLooper())
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "publish" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.success(false)
                    } else {
                        result.success(publish(args))
                    }
                }
                "updateState" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.success(false)
                    } else {
                        result.success(updateState(args))
                    }
                }
                "release" -> {
                    release()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun forwardAction(action: String) {
        runCatching {
            channel?.invokeMethod("mediaAction", mapOf("action" to action))
        }
    }

    private fun stringArg(args: Map<*, *>, key: String): String {
        return args[key] as? String ?: ""
    }

    private fun longArg(args: Map<*, *>, key: String): Long {
        return when (val value = args[key]) {
            is Number -> value.toLong()
            else -> 0L
        }
    }

    private fun boolArg(args: Map<*, *>, key: String): Boolean {
        return args[key] as? Boolean ?: false
    }

    private fun floatArg(args: Map<*, *>, key: String, fallback: Float): Float {
        val value = (args[key] as? Number)?.toFloat() ?: return fallback
        if (value.isNaN() || value.isInfinite()) return fallback
        return value.coerceIn(0.25f, 4.0f)
    }

    private fun publish(args: Map<*, *>): Boolean {
        val ctx = context ?: return false
        lastBookTitle = stringArg(args, "bookTitle")
        lastChapterTitle = stringArg(args, "chapterTitle")
        val coverUrl = stringArg(args, "coverUrl")
        lastPlaying = boolArg(args, "playing")
        lastPositionMs = longArg(args, "positionMs").coerceAtLeast(0L)
        lastDurationMs = longArg(args, "durationMs").coerceAtLeast(0L)
        if (lastDurationMs > 0L) {
            lastPositionMs = lastPositionMs.coerceAtMost(lastDurationMs)
        }
        lastHasPrevious = boolArg(args, "hasPrevious")
        lastHasNext = boolArg(args, "hasNext")
        lastRate = floatArg(args, "rate", 1.0f)
        ensureSession(ctx)
        ensureReceiver(ctx)
        ensureChannel(ctx)
        if (coverUrl != lastCoverUrl) {
            lastCoverUrl = coverUrl
            lastCover = null
            if (coverUrl.isNotEmpty()) fetchCover(ctx, coverUrl)
        }
        published = true
        applyMetadata()
        applyPlaybackState()
        postNotification(ctx)
        return true
    }

    private fun updateState(args: Map<*, *>): Boolean {
        val ctx = context ?: return false
        if (!published) return false
        lastPlaying = boolArg(args, "playing")
        lastPositionMs = longArg(args, "positionMs").coerceAtLeast(0L)
        lastDurationMs = longArg(args, "durationMs").coerceAtLeast(0L)
        if (lastDurationMs > 0L) {
            lastPositionMs = lastPositionMs.coerceAtMost(lastDurationMs)
        }
        lastRate = floatArg(args, "rate", 1.0f)
        applyPlaybackState()
        postNotification(ctx)
        return true
    }

    private fun release() {
        val ctx = context
        if (ctx != null) {
            runCatching {
                val manager =
                    ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(NOTIFICATION_ID)
            }
            receiver?.let { runCatching { ctx.unregisterReceiver(it) } }
        }
        receiver = null
        runCatching { session?.release() }
        session = null
        published = false
        lastCover = null
        lastCoverUrl = ""
    }

    private fun ensureSession(ctx: Context) {
        if (session != null) return
        val created = MediaSession(ctx, "moyi_audio")
        created.setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
        )
        created.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = forwardAction("play")
            override fun onPause() = forwardAction("pause")
            override fun onSkipToPrevious() = forwardAction("previous")
            override fun onSkipToNext() = forwardAction("next")
        })
        created.isActive = true
        session = created
    }

    private fun ensureReceiver(ctx: Context) {
        if (receiver != null) return
        val created = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    ACTION_PLAY -> forwardAction("play")
                    ACTION_PAUSE -> forwardAction("pause")
                    ACTION_PREVIOUS -> forwardAction("previous")
                    ACTION_NEXT -> forwardAction("next")
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_PLAY)
            addAction(ACTION_PAUSE)
            addAction(ACTION_PREVIOUS)
            addAction(ACTION_NEXT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(created, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            ctx.registerReceiver(created, filter)
        }
        receiver = created
    }

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "听书播放",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "听书锁屏控制"
        channel.setShowBadge(false)
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        manager.createNotificationChannel(channel)
    }

    private fun applyMetadata() {
        val current = session ?: return
        val builder = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, lastChapterTitle)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, lastBookTitle)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, lastBookTitle)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, lastDurationMs)
        lastCover?.let { builder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) }
        current.setMetadata(builder.build())
    }

    private fun applyPlaybackState() {
        val current = session ?: return
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE
        if (lastHasPrevious) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        if (lastHasNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        val state = if (lastPlaying) {
            PlaybackState.STATE_PLAYING
        } else {
            PlaybackState.STATE_PAUSED
        }
        val playbackState = PlaybackState.Builder()
            .setActions(actions)
            .setState(state, lastPositionMs, lastRate, SystemClock.elapsedRealtime())
            .build()
        current.setPlaybackState(playbackState)
    }

    private fun actionIntent(ctx: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(action).setPackage(ctx.packageName)
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        return PendingIntent.getBroadcast(ctx, requestCode, intent, flags)
    }

    private fun postNotification(ctx: Context) {
        val currentSession = session ?: return
        val manager =
            ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                ctx,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val smallIcon = ctx.applicationInfo.icon.takeIf { it != 0 }
            ?: android.R.drawable.ic_media_play
        val playPauseAction = if (lastPlaying) {
            Notification.Action.Builder(
                android.R.drawable.ic_media_pause,
                "暂停",
                actionIntent(ctx, ACTION_PAUSE, 2),
            ).build()
        } else {
            Notification.Action.Builder(
                android.R.drawable.ic_media_play,
                "播放",
                actionIntent(ctx, ACTION_PLAY, 2),
            ).build()
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(ctx)
        }
        builder
            .setSmallIcon(smallIcon)
            .setContentTitle(lastChapterTitle.ifEmpty { lastBookTitle })
            .setContentText(lastBookTitle)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_previous,
                    "上一章",
                    actionIntent(ctx, ACTION_PREVIOUS, 1),
                ).build(),
            )
            .addAction(playPauseAction)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_next,
                    "下一章",
                    actionIntent(ctx, ACTION_NEXT, 3),
                ).build(),
            )
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(currentSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
        lastCover?.let { builder.setLargeIcon(it) }
        manager.notify(NOTIFICATION_ID, builder.build())
    }

    private fun fetchCover(ctx: Context, coverUrl: String) {
        thread(name = "moyi-audio-cover") {
            val bitmap = runCatching {
                val connection = URL(coverUrl).openConnection() as HttpURLConnection
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.instanceFollowRedirects = true
                connection.connect()
                if (connection.responseCode !in 200..299) return@runCatching null
                val decoded = connection.inputStream.use { BitmapFactory.decodeStream(it) }
                    ?: return@runCatching null
                val width = decoded.width
                val height = decoded.height
                if (width <= COVER_MAX_PX && height <= COVER_MAX_PX) {
                    decoded
                } else {
                    val scale = COVER_MAX_PX.toFloat() / maxOf(width, height)
                    val scaled = Bitmap.createScaledBitmap(
                        decoded,
                        (width * scale).toInt().coerceAtLeast(1),
                        (height * scale).toInt().coerceAtLeast(1),
                        true,
                    )
                    if (scaled != decoded) decoded.recycle()
                    scaled
                }
            }.getOrNull() ?: return@thread
            mainHandler?.post {
                if (coverUrl != lastCoverUrl || !published) {
                    bitmap.recycle()
                    return@post
                }
                val oldCover = lastCover
                lastCover = bitmap
                applyMetadata()
                postNotification(ctx)
                oldCover?.recycle()
            }
        }
    }
}
