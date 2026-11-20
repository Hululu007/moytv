package moyi

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * 区插件 APK 探测桥：查已装的区插件 APK，把其 assets 内容拷到壳内暂存目录，
 * 交给 Dart 侧注册表走同一条校验与提升路导入；并提供跳系统卸载页。
 *
 * 探测只认带 `moyi.zone.plugin` meta-data 的包（见区插件 APK 模板的
 * AndroidManifest）。包可见性：Android 11+ 只返回“可见”的包，壳的
 * AndroidManifest 里 `<queries>` 已逐个声明五个官方区插件包名，第一方
 * 包不依赖 QUERY_ALL_PACKAGES 也能被看见；第三方包名能否被看见取决于
 * 平台的包可见性规则，看不见就是探测不到，如实返回空，不谎报。
 *
 * 资产拷贝在后台线程跑（小程序包近 60MB，不能占主线程），结果经主线程
 * Handler 回给 Flutter（与 JarBridge 同款模式）。暂存目录每次探测先清
 * 后拷，旧版内容不会残留进新导入。
 */
object ZonePluginProbeBridge {

    private const val CHANNEL = "moyi/zone_plugin_probe"
    private const val META_KEY = "moyi.zone.plugin"
    private const val MANIFEST_ASSET = "moyi-zone.json"
    private const val STAGING_DIR = "zone_plugin_apk_staging"

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> {
                    executor.execute {
                        try {
                            val found = probeInstalled(appContext)
                            mainHandler.post { result.success(found) }
                        } catch (error: Exception) {
                            mainHandler.post {
                                result.error(
                                    "probe_failed",
                                    "探测区插件 APK 失败：${error.message}",
                                    null,
                                )
                            }
                        }
                    }
                }
                "uninstallApk" -> {
                    val pkg = call.argument<String>("pkg").orEmpty()
                    if (pkg.isEmpty()) {
                        result.error("invalid_pkg", "缺少要卸载的包名", null)
                    } else {
                        val intent = Intent(
                            Intent.ACTION_DELETE,
                            Uri.parse("package:$pkg"),
                        ).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        appContext.startActivity(intent)
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun probeInstalled(context: Context): List<Map<String, String>> {
        val pm = context.packageManager
        val apps: List<ApplicationInfo> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getInstalledApplications(
                    PackageManager.ApplicationInfoFlags.of(
                        PackageManager.GET_META_DATA.toLong(),
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                pm.getInstalledApplications(PackageManager.GET_META_DATA)
            }
        val found = mutableListOf<Map<String, String>>()
        for (app in apps) {
            val marker = app.metaData?.getString(META_KEY)
            if (marker.isNullOrEmpty()) continue
            val staging = File(
                File(context.filesDir, STAGING_DIR),
                app.packageName,
            )
            try {
                val assets = pm.getResourcesForApplication(app).assets
                val manifestJson = readAssetText(assets, MANIFEST_ASSET)
                    ?: continue
                if (staging.exists()) staging.deleteRecursively()
                staging.mkdirs()
                copyAssets(assets, "", staging)
                found.add(
                    mapOf(
                        "pkg" to app.packageName,
                        "manifestJson" to manifestJson,
                        "contentDirPath" to staging.absolutePath,
                    ),
                )
            } catch (_: Exception) {
                // 单个包读失败跳过，不影响其他包；暂存半成品清掉，
                // 不让残缺内容进导入。
                if (staging.exists()) staging.deleteRecursively()
                continue
            }
        }
        return found
    }

    private fun readAssetText(assets: AssetManager, path: String): String? {
        return try {
            assets.open(path).use { input ->
                input.readBytes().toString(Charsets.UTF_8)
            }
        } catch (_: IOException) {
            null
        }
    }

    private fun copyAssets(assets: AssetManager, dir: String, outDir: File) {
        val entries = assets.list(dir) ?: return
        for (entry in entries) {
            val path = if (dir.isEmpty()) entry else "$dir/$entry"
            val children = assets.list(path)
            if (children != null && children.isNotEmpty()) {
                val sub = File(outDir, entry)
                sub.mkdirs()
                copyAssets(assets, path, sub)
            } else {
                try {
                    assets.open(path).use { input ->
                        FileOutputStream(File(outDir, entry)).use { output ->
                            input.copyTo(output)
                        }
                    }
                } catch (_: IOException) {
                    // 空目录会被当成文件走到这里，打开失败即跳过；
                    // 空目录对区内容没有意义，不必建。
                }
            }
        }
    }
}
