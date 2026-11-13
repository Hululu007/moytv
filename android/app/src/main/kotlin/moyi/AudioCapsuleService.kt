package moyi

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.IBinder
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 听书灵动岛胶囊：切后台且在播时显示的小胶囊，点一下回应用听书页。
 *
 * 服务在前台时先拉起（本体藏着），切后台后只改悬浮窗显隐，不在后台拉服务。
 * 胶囊只显示书名 · 章节 + 一个播放状态点，不带播放按键。
 * 悬浮窗在鸿蒙 NEXT + 卓易通容器里能不能显示，树里验不了，标未验。
 */
class AudioCapsuleService : Service() {

    companion object {
        var instance: AudioCapsuleService? = null
            private set
        var isRunning = false
            private set

        // 服务拉起是异步的：Dart 侧 show 得比 onCreate 早时，先把参数存下，
        // onCreate 里再补显示，避免第一下胶囊丢了。
        var pendingTitle: String? = null
        var pendingChapter: String? = null
        var pendingPlaying = false
        var pendingShow = false
    }

    private var windowManager: WindowManager? = null
    private var capsule: View? = null
    private var capsuleParams: WindowManager.LayoutParams? = null
    private var titleView: TextView? = null
    private var dotView: View? = null
    private var downX = 0f
    private var downY = 0f
    private var moved = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        isRunning = true
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        if (pendingShow) {
            val title = pendingTitle ?: ""
            val chapter = pendingChapter ?: ""
            pendingShow = false
            showCapsule(title, chapter, pendingPlaying)
        }
    }

    override fun onDestroy() {
        removeCapsule()
        windowManager = null
        instance = null
        isRunning = false
        pendingShow = false
        super.onDestroy()
    }

    fun isCapsuleShowing(): Boolean = capsule != null

    fun showCapsule(title: String, chapter: String, playing: Boolean) {
        val view = capsule
        if (view == null) {
            buildCapsule(title, chapter, playing)
            return
        }
        titleView?.text = capsuleText(title, chapter)
        updateDot(playing)
    }

    fun hideCapsule() {
        pendingShow = false
        removeCapsule()
    }

    private fun capsuleText(title: String, chapter: String): String {
        return if (chapter.isEmpty()) title else "$title · $chapter"
    }

    private fun updateDot(playing: Boolean) {
        val dot = dotView ?: return
        val background = dot.background as? GradientDrawable ?: return
        background.setColor(
            Color.parseColor(if (playing) "#4CAF50" else "#9E9E9E"),
        )
    }

    private fun capsuleBackground(): GradientDrawable {
        val drawable = GradientDrawable()
        drawable.shape = GradientDrawable.RECTANGLE
        drawable.cornerRadius = 20 * resources.displayMetrics.density
        drawable.setColor(Color.parseColor("#E61F1F1F"))
        return drawable
    }

    private fun dotBackground(): GradientDrawable {
        val drawable = GradientDrawable()
        drawable.shape = GradientDrawable.OVAL
        drawable.setColor(Color.parseColor("#4CAF50"))
        return drawable
    }

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else 0
    }

    private fun buildCapsule(title: String, chapter: String, playing: Boolean) {
        val manager = windowManager ?: return
        val density = resources.displayMetrics.density
        val layout = LinearLayout(this)
        layout.orientation = LinearLayout.HORIZONTAL
        layout.gravity = Gravity.CENTER_VERTICAL
        layout.background = capsuleBackground()
        val horizontal = (14 * density).toInt()
        layout.setPadding(horizontal, 0, horizontal, 0)
        val dotSize = (8 * density).toInt()
        val dot = View(this)
        dot.background = dotBackground()
        layout.addView(dot, ViewGroup.LayoutParams(dotSize, dotSize))
        val text = TextView(this)
        text.text = capsuleText(title, chapter)
        text.setTextColor(Color.WHITE)
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        text.maxLines = 1
        text.ellipsize = android.text.TextUtils.TruncateAt.END
        val textParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        textParams.leftMargin = (8 * density).toInt()
        layout.addView(text, textParams)
        dotView = dot
        titleView = text
        updateDot(playing)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            (40 * density).toInt(),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        params.x = 0
        params.y = statusBarHeight() + (12 * density).toInt()
        layout.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - downX).toInt()
                    val dy = (event.rawY - downY).toInt()
                    if (dx * dx + dy * dy > 100) moved = true
                    params.x += dx
                    params.y += dy
                    downX = event.rawX
                    downY = event.rawY
                    windowManager?.updateViewLayout(layout, params)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) openApp()
                    true
                }
                else -> false
            }
        }
        manager.addView(layout, params)
        capsule = layout
        capsuleParams = params
    }

    private fun openApp() {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        launch?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (launch != null) startActivity(launch)
        // 不在这里藏胶囊：应用回前台后 Dart 侧收到 resumed 会藏。
    }

    private fun removeCapsule() {
        val view = capsule ?: return
        try {
            windowManager?.removeView(view)
        } catch (_: IllegalArgumentException) {
        }
        capsule = null
        capsuleParams = null
        titleView = null
        dotView = null
    }
}
