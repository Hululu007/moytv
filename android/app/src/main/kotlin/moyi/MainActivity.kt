package moyi

import io.flutter.embedding.android.FlutterActivity
import android.app.UiModeManager
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.os.Build
import android.os.Bundle
import android.os.BatteryManager
import android.os.PowerManager
import android.os.SystemClock
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.net.ConnectivityManager
import android.net.Uri
import android.util.Rational
import android.view.InputDevice
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var headroomReadAt = 0L
    private var thermalHeadroom: Double? = null
    private var deviceChannel: MethodChannel? = null
    private var pyBridge: PyBridge? = null
    private var pyChannel: MethodChannel? = null
    private var quickJSBridge: QuickJSBridge? = null
    private var quickJSChannel: MethodChannel? = null
    private var pyImportChannel: MethodChannel? = null
    private val pendingPyFiles = mutableListOf<Map<String, Any?>>()
    private val pendingJarFiles = mutableListOf<Map<String, Any?>>()
    private var televisionMode = false

    // 播放页左半屏竖向拖动临时调亮度：只改本窗口 screenBrightness（-1f 表示跟随系统），
    // 不动系统全局亮度设置，退出播放 reset 后自动恢复，无需 WRITE_SETTINGS 权限。
    private fun effectiveScreenBrightness(): Double {
        val local = window.attributes.screenBrightness
        if (local >= 0f) return local.toDouble()
        val resolver = contentResolver
        val system = runCatching {
            android.provider.Settings.System.getInt(
                resolver,
                android.provider.Settings.System.SCREEN_BRIGHTNESS
            )
        }.getOrNull()
        if (system == null) return .5
        val auto = runCatching {
            android.provider.Settings.System.getInt(
                resolver,
                android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE
            )
        }.getOrNull() == android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC
        if (auto) {
            val autoValue = runCatching {
                android.provider.Settings.System.getInt(
                    resolver,
                    "screen_auto_brightness_adj"
                )
            }.getOrNull() ?: 128
            return (autoValue.coerceIn(0, 255)) / 255.0
        }
        return system / 255.0
    }

    private fun applyScreenBrightness(value: Float) {
        val attributes = window.attributes
        attributes.screenBrightness = value.coerceIn(0.01f, 1f)
        window.attributes = attributes
    }

    private fun renderingPreferences() =
        getSharedPreferences("moyi_rendering", Context.MODE_PRIVATE)

    private fun compatibleRendering(): Boolean =
        renderingPreferences().getBoolean("compatibleRendering", false)

    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = super.getFlutterShellArgs()
        if (compatibleRendering()) args.add("--enable-impeller=false")
        return args
    }

    private fun restartApplication() {
        startActivity(Intent.makeRestartActivityTask(ComponentName(this, MainActivity::class.java)))
        Runtime.getRuntime().exit(0)
    }

    @Suppress("DEPRECATION")
    private fun isTelevisionDevice(): Boolean {
        val configuration = resources.configuration
        val mode = (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType
            ?: (configuration.uiMode and Configuration.UI_MODE_TYPE_MASK)
        if (mode == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            packageManager.hasSystemFeature("amazon.hardware.fire_tv")) {
            return true
        }
        if (mode == Configuration.UI_MODE_TYPE_CAR ||
            mode == Configuration.UI_MODE_TYPE_WATCH ||
            mode == Configuration.UI_MODE_TYPE_VR_HEADSET ||
            configuration.touchscreen != Configuration.TOUCHSCREEN_NOTOUCH ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_SENSOR_ACCELEROMETER) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_PC)) {
            return false
        }
        val remoteNavigation = configuration.navigation == Configuration.NAVIGATION_DPAD ||
            InputDevice.getDeviceIds().any { id ->
                val device = InputDevice.getDevice(id)
                device != null && !device.isVirtual && device.supportsSource(InputDevice.SOURCE_DPAD)
            }
        return remoteNavigation || packageManager.hasSystemFeature(PackageManager.FEATURE_LIVE_TV)
    }

    override fun setRequestedOrientation(requestedOrientation: Int) {
        super.setRequestedOrientation(
            if (televisionMode) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else requestedOrientation
        )
    }

    private fun playbackPower(): Map<String, Any?> {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val activity = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val now = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            (headroomReadAt == 0L || now - headroomReadAt >= 10000L)) {
            headroomReadAt = now
            thermalHeadroom = runCatching {
                power?.getThermalHeadroom(0)?.toDouble()?.takeIf { it.isFinite() }
            }.getOrNull()
        }
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            power?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
        } else 0
        return mapOf(
            "batterySaver" to (power?.isPowerSaveMode ?: false),
            "onBattery" to ((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1) <= 0),
            "thermalStatus" to thermalStatus,
            "headroom" to thermalHeadroom,
            "lowMemory" to (activity?.isLowRamDevice ?: true),
            "gles" to (activity?.deviceConfigurationInfo?.reqGlEsVersion ?: 0)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        televisionMode = if (savedInstanceState?.containsKey("moyi.televisionMode") == true) {
            savedInstanceState.getBoolean("moyi.televisionMode")
        } else isTelevisionDevice()
        super.onCreate(savedInstanceState)
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
    }

    override fun onResume() {
        super.onResume()
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("moyi.televisionMode", televisionMode)
        super.onSaveInstanceState(outState)
    }

    @Suppress("DEPRECATION")
    private fun displayNameFor(uri: Uri): String? {
        if (uri.scheme != "content") return uri.lastPathSegment?.substringAfterLast('/')
        return runCatching {
            contentResolver.query(
                uri,
                arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
    }

    @Suppress("DEPRECATION")
    private fun stageIncomingIntent(incoming: Intent?) {
        if (incoming == null) return
        val action = incoming.action
        if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return
        val uri: Uri = when (action) {
            Intent.ACTION_VIEW -> incoming.data
            else -> incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: incoming.data
        } ?: return
        val name = displayNameFor(uri) ?: uri.lastPathSegment?.substringAfterLast('/') ?: ""
        val mime = incoming.type ?: runCatching { contentResolver.getType(uri) }.getOrNull()
        val lowerName = name.lowercase()
        val looksPy = lowerName.endsWith(".py") ||
            (!lowerName.endsWith(".jar") &&
                (mime == "text/x-python" || mime == "application/x-python"))
        val looksJar = !looksPy && (lowerName.endsWith(".jar") ||
            mime == "application/java-archive" || mime == "application/x-java-archive")
        if (!looksPy && !looksJar) return
        val staged = runCatching {
            val dir = java.io.File(cacheDir, if (looksJar) "jarimport" else "pyimport").apply { if (!exists()) mkdirs() }
            val suffix = if (looksJar) "jar" else "py"
            val target = java.io.File(dir, "${System.currentTimeMillis()}_${(0..9999).random()}.$suffix")
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return
            target
        }.getOrNull() ?: return
        val entry = mapOf(
            "path" to staged.absolutePath,
            "name" to if (name.isNotEmpty()) name else if (looksJar) "import.jar" else "import.py",
            "size" to staged.length(),
            "kind" to if (looksJar) "jar" else "py"
        )
        if (looksJar) pendingJarFiles.add(entry) else pendingPyFiles.add(entry)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        stageIncomingIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(VideoSurfacePlugin())
        flutterEngine.plugins.add(TvboxPlayerPlugin())
        flutterEngine.plugins.add(IjkPlayerPlugin())
        JarBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        FloatingWindowPlugin.register(flutterEngine.dartExecutor.binaryMessenger, this)
        AudioMediaPlugin.register(flutterEngine.dartExecutor.binaryMessenger, this)
        AudioCapsulePlugin.register(flutterEngine.dartExecutor.binaryMessenger, this)
        AppUpdateBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        ProxyKernelBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        TorrentBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        val bridge = PyBridge(this)
        pyBridge = bridge
        pyChannel = bridge.register(flutterEngine.dartExecutor.binaryMessenger)
        val quickJS = QuickJSBridge()
        quickJSBridge = quickJS
        quickJSChannel = quickJS.register(flutterEngine.dartExecutor.binaryMessenger)
        deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moyi/device")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "deviceInfo" -> {
                            val version = packageManager.getPackageInfo(packageName, 0).versionName
                            result.success(mapOf("television" to isTelevisionDevice(), "version" to version))
                        }
                        "setTelevisionMode" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_display_mode", "缺少电视模式状态", null)
                            } else {
                                val changed = televisionMode != enabled
                                televisionMode = enabled
                                if (enabled || changed) {
                                    requestedOrientation = if (enabled) {
                                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                    } else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                                }
                                result.success(null)
                            }
                        }
                        "playbackPower" -> result.success(runCatching { playbackPower() }.getOrNull())
                        "signatureSha256" -> result.success(signatureSha256())
                        "compatibleRendering" -> result.success(compatibleRendering())
                        "setCompatibleRendering" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_rendering_mode", "缺少兼容渲染模式状态", null)
                            } else if (!renderingPreferences().edit()
                                    .putBoolean("compatibleRendering", enabled).commit()) {
                                result.error("rendering_mode_not_saved", "兼容渲染模式未能保存", null)
                            } else {
                                result.success(null)
                                restartApplication()
                            }
                        }
                        "systemProxy" -> {
                            val connection = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                            val proxy = connection.defaultProxy
                            val host = proxy?.host.orEmpty()
                            val address = if (host.isNotEmpty() && (proxy?.port ?: 0) > 0) {
                                "http://${if (host.contains(':')) "[$host]" else host}:${proxy!!.port}"
                            } else ""
                            result.success(mapOf(
                                "http" to address,
                                "https" to address,
                                "bypass" to (proxy?.exclusionList?.toList() ?: emptyList<String>()),
                                "pac" to (proxy != null && proxy.pacFileUrl != Uri.EMPTY)
                            ))
                        }
                        "pictureInPictureStatus" -> result.success(pictureInPictureStatus())
                        "screenBrightness" -> result.success(effectiveScreenBrightness())
                        "setScreenBrightness" -> {
                            val value = call.argument<Double>("value")
                            if (value == null || value.isNaN() || value.isInfinite()) {
                                result.error("invalid_brightness", "缺少亮度值", null)
                            } else {
                                applyScreenBrightness(value.toFloat())
                                result.success(null)
                            }
                        }
                        "resetScreenBrightness" -> {
                            val attributes = window.attributes
                            attributes.screenBrightness =
                                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            window.attributes = attributes
                            result.success(null)
                        }
                        "enterPictureInPicture" -> {
                            val width = call.argument<Int>("width") ?: 16
                            val height = call.argument<Int>("height") ?: 9
                            result.success(enterPlayerPictureInPicture(
                                width,
                                height,
                                call.argument<Int>("left"),
                                call.argument<Int>("top"),
                                call.argument<Int>("right"),
                                call.argument<Int>("bottom")
                            ))
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        pyImportChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moyi/pyimport")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "takePending") {
                        val pending = pendingPyFiles.toList() + pendingJarFiles.toList()
                        pendingPyFiles.clear()
                        pendingJarFiles.clear()
                        result.success(pending)
                    } else {
                        result.notImplemented()
                    }
                }
            }
        stageIncomingIntent(intent)
    }

    @Suppress("DEPRECATION")
    private fun signatureSha256(): String? {
        return runCatching {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
            }
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION") info.signatures
            } ?: return null
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            signatures.firstOrNull()?.let { signature ->
                digest.digest(signature.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 0xff) }
            }
        }.getOrNull()
    }

    private fun pictureInPictureSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun pictureInPictureStatus(): Map<String, Any> {
        return mapOf(
            "supported" to pictureInPictureSupported(),
            "active" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)
        )
    }

    private fun enterPlayerPictureInPicture(
        width: Int,
        height: Int,
        left: Int?,
        top: Int?,
        right: Int?,
        bottom: Int?
    ): Map<String, Any> {
        if (!pictureInPictureSupported()) return pictureInPictureStatus()
        val safeWidth = width.coerceIn(1, 10000)
        val safeHeight = height.coerceIn(1, 10000)
        return runCatching {
            val builder = PictureInPictureParams.Builder()
            builder.setAspectRatio(Rational(safeWidth, safeHeight))
            if (left != null && top != null && right != null && bottom != null &&
                right > left && bottom > top) {
                builder.setSourceRectHint(Rect(left, top, right, bottom))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(true)
            }
            val entered = enterPictureInPictureMode(builder.build())
            pictureInPictureStatus() + ("requested" to entered)
        }.getOrElse { pictureInPictureStatus() }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        deviceChannel?.invokeMethod(
            "pictureInPictureChanged",
            mapOf("active" to isInPictureInPictureMode)
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        deviceChannel?.setMethodCallHandler(null)
        deviceChannel = null
        pyImportChannel?.setMethodCallHandler(null)
        pyImportChannel = null
        pyChannel?.setMethodCallHandler(null)
        pyChannel = null
        pyBridge?.shutdown()
        pyBridge = null
        quickJSChannel?.setMethodCallHandler(null)
        quickJSChannel = null
        quickJSBridge?.shutdown()
        quickJSBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
