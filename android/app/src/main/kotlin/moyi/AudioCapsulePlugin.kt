package moyi

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object AudioCapsulePlugin {

    private const val CHANNEL = "moyi/audio_capsule"

    fun register(messenger: BinaryMessenger, activity: Activity) {
        val context: Context = activity.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPermissionGranted" -> {
                    result.success(Settings.canDrawOverlays(context))
                }
                "ensureService" -> {
                    if (!Settings.canDrawOverlays(context)) {
                        result.success(false)
                    } else {
                        val intent = Intent(context, AudioCapsuleService::class.java)
                        context.startService(intent)
                        result.success(true)
                    }
                }
                "show" -> {
                    if (!Settings.canDrawOverlays(context)) {
                        result.success(false)
                    } else {
                        val args = call.arguments as? Map<*, *>
                        val title = args?.get("title") as? String ?: ""
                        val chapter = args?.get("chapter") as? String ?: ""
                        val playing = args?.get("playing") as? Boolean ?: false
                        AudioCapsuleService.pendingTitle = title
                        AudioCapsuleService.pendingChapter = chapter
                        AudioCapsuleService.pendingPlaying = playing
                        AudioCapsuleService.pendingShow = true
                        val service = AudioCapsuleService.instance
                        if (service == null) {
                            val intent =
                                Intent(context, AudioCapsuleService::class.java)
                            context.startService(intent)
                        } else {
                            AudioCapsuleService.pendingShow = false
                            service.showCapsule(title, chapter, playing)
                        }
                        result.success(true)
                    }
                }
                "hide" -> {
                    AudioCapsuleService.pendingShow = false
                    AudioCapsuleService.instance?.hideCapsule()
                    result.success(true)
                }
                "stop" -> {
                    AudioCapsuleService.pendingShow = false
                    val intent = Intent(context, AudioCapsuleService::class.java)
                    context.stopService(intent)
                    result.success(true)
                }
                "isShowing" -> {
                    result.success(
                        AudioCapsuleService.instance?.isCapsuleShowing() ?: false,
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}
