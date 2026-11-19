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
                            result.error("switch_failed", e.message, null)
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
        pm.setComponentEnabledSetting(
            main,
            if (id == ICON_DEFAULT) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            flag
        )
        for ((aliasId, alias) in ALIASES) {
            pm.setComponentEnabledSetting(
                ComponentName(context.packageName, context.packageName + alias),
                if (aliasId == id) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                flag
            )
        }
    }
}
