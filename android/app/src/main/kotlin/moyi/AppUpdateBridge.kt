package moyi

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

object AppUpdateBridge {
    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, "moyi/appupdate").setMethodCallHandler { call, result ->
            when (call.method) {
                "appInfo" -> {
                    val info = context.packageManager.getPackageInfo(context.packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        info.longVersionCode
                    } else {
                        @Suppress("DEPRECATION")
                        info.versionCode.toLong()
                    }
                    result.success(
                        mapOf(
                            "versionName" to (info.versionName ?: ""),
                            "versionCode" to code
                        )
                    )
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("path")
                    val file = apkPath?.let { File(it) }
                    if (file == null || !file.isFile) {
                        result.error("missing_apk", "安装包不存在", null)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !context.packageManager.canRequestPackageInstalls()
                    ) {
                        val settingsIntent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:" + context.packageName)
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(settingsIntent)
                        result.error(
                            "install_permission",
                            "请先允许本应用安装未知应用，然后回来重新点安装",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(
                        context,
                        context.packageName + ".fileprovider",
                        file
                    )
                    val intent = Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                    context.startActivity(intent)
                    result.success(null)
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    val opened = runCatching {
                        context.startActivity(intent)
                        true
                    }.getOrDefault(false)
                    result.success(opened)
                }
                else -> result.notImplemented()
            }
        }
    }
}
