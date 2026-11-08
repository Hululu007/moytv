package moyi

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object FloatingWindowPlugin {

    private const val CHANNEL = "moyi/floating_window"

    fun register(messenger: BinaryMessenger, activity: Activity) {
        val context: Context = activity.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPermissionGranted" -> {
                    result.success(Settings.canDrawOverlays(context))
                }
                "requestPermission" -> {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + context.packageName),
                    )
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(null)
                }
                "show" -> {
                    if (!Settings.canDrawOverlays(context)) {
                        result.error(
                            "floating_denied",
                            "未授予悬浮窗权限",
                            null,
                        )
                    } else {
                        val intent = Intent(context, FloatingBallService::class.java)
                        context.startService(intent)
                        result.success(null)
                    }
                }
                "hide" -> {
                    val intent = Intent(context, FloatingBallService::class.java)
                    context.stopService(intent)
                    result.success(null)
                }
                "isShowing" -> {
                    result.success(FloatingBallService.isRunning)
                }
                else -> result.notImplemented()
            }
        }
    }
}
