package moyi

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 应用图标切换桥：通过启用/停用启动组件来换桌面图标。
 *
 * 机制是安卓标准的 activity-alias 换图标：AndroidManifest 里除主 Activity
 * 外另有 5 个 activity-alias（默认全部停用），每个别名挂一张图标。
 * 切到某张图标 = 启用对应别名、停用主 Activity 与其余别名；切回默认 =
 * 启用主 Activity、停用全部别名。别名指向 MainActivity，停用主 Activity
 * 的启动组件不影响已运行的进程，也不影响从别名冷启动（目标 Activity
 * 照常拉起）。组件状态由系统持久化，重启后仍有效，无需每次启动重设。
 *
 * 切换用 DONT_KILL_APP，不杀进程。部分桌面启动器（尤其定制 ROM）刷新
 * 图标有延迟，属启动器行为，桥侧如实返回切换结果，不谎报已生效。
 * 别名类名须与 AndroidManifest 及 lib/app_icon_switcher.dart 一致。
 *
 * 顺序铁律：先开目标、再停其余，任何时刻至少留一个启动入口。旧顺序
 * 先停主 Activity，中间会出现“零个启动入口”的瞬间，部分桌面/容器
 * （鸿蒙 NEXT 的卓易通容器已实证拒绝）会拒掉这次停用或直接把应用
 * 图标摘掉，整个切换随之失败。换后回读全量校验，系统没真正切过
 * 去就当失败；失败时把原生异常类名原样带回（details），供 Dart 侧
 * 归类成一句准话，别只剩“可能不支持”。
 */
object IconSwitchBridge {

    private const val CHANNEL = "moyi/icon_switch"

    const val ICON_DEFAULT = "default"

    // 图标 id -> 别名类短名（ComponentName 用包名 + 短名拼）。
    val ALIASES = mapOf(
        "ant_flame" to ".IconAntFlame",
        "ant_lens" to ".IconAntLens",
        "ant_win12" to ".IconAntWin12",
        "ant_storm" to ".IconAntStorm",
        "ant_meadow" to ".IconAntMeadow"
    )

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "currentIcon" -> {
                    result.success(currentIconId(context))
                }
                "setIcon" -> {
                    val id = call.argument<String>("id")
                    if (id == null || (id != ICON_DEFAULT && !ALIASES.containsKey(id))) {
                        result.error("invalid_icon", "unknown icon id: $id", null)
                    } else {
                        try {
                            setIconId(context, id)
                            result.success(true)
                        } catch (e: Exception) {
                            // details 带原生异常类名（SecurityException 等），
                            // Dart 侧按它归类，界面才能给一句准话。
                            result.error("switch_failed", e.message, e.javaClass.simpleName)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun currentIconId(context: Context): String {
        val pm = context.packageManager
        for ((id, alias) in ALIASES) {
            val state = pm.getComponentEnabledSetting(
                ComponentName(context.packageName, context.packageName + alias)
            )
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                return id
            }
        }
        return ICON_DEFAULT
    }

    private fun setIconId(context: Context, id: String) {
        val pm = context.packageManager
        val flag = PackageManager.DONT_KILL_APP
        val main = ComponentName(context.packageName, context.packageName + ".MainActivity")
        // 先开目标、再停其余：任何时刻都至少留一个启动入口。
        val target = if (id == ICON_DEFAULT) {
            main
        } else {
            ComponentName(context.packageName, context.packageName + ALIASES.getValue(id))
        }
        pm.setComponentEnabledSetting(
            target,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            flag
        )
        if (target != main) {
            pm.setComponentEnabledSetting(
                main,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                flag
            )
        }
        for ((aliasId, alias) in ALIASES) {
            val component = ComponentName(context.packageName, context.packageName + alias)
            if (component == target) continue
            pm.setComponentEnabledSetting(
                component,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                flag
            )
        }
        // 回读全量校验：系统没真正切过去就当失败，别谎报成功（部分
        // 启动器/容器会静默忽略组件状态变更而不抛错）。
        if (!isApplied(context, id)) {
            throw IllegalStateException("icon switch not applied: want=$id")
        }
    }

    /** 全量核对 6 个启动组件的实际生效状态（DEFAULT 按 Manifest 默认值算）。 */
    private fun isApplied(context: Context, id: String): Boolean {
        val pm = context.packageManager
        fun effectiveEnabled(component: ComponentName, manifestEnabled: Boolean): Boolean {
            return when (pm.getComponentEnabledSetting(component)) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
                else -> manifestEnabled
            }
        }
        val main = ComponentName(context.packageName, context.packageName + ".MainActivity")
        // 主 Activity 在 Manifest 里没写 enabled，默认启用。
        if (effectiveEnabled(main, true) != (id == ICON_DEFAULT)) return false
        for ((aliasId, alias) in ALIASES) {
            val component = ComponentName(context.packageName, context.packageName + alias)
            // 别名在 Manifest 里 enabled=false，默认停用。
            if (effectiveEnabled(component, false) != (aliasId == id)) return false
        }
        return true
    }
}
