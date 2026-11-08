package moyi

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

class FloatingBallService : Service() {

    companion object {
        var isRunning = false
            private set
    }

    private var windowManager: WindowManager? = null
    private var ball: View? = null
    private var panel: View? = null
    private var ballParams: WindowManager.LayoutParams? = null
    private var panelParams: WindowManager.LayoutParams? = null
    private var downX = 0f
    private var downY = 0f
    private var moved = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        showBall()
    }

    override fun onDestroy() {
        removePanel()
        removeBall()
        windowManager = null
        isRunning = false
        super.onDestroy()
    }

    private fun ballBackground(): GradientDrawable {
        val drawable = GradientDrawable()
        drawable.shape = GradientDrawable.OVAL
        drawable.setColor(Color.parseColor("#6750A4"))
        return drawable
    }

    private fun showBall() {
        if (ball != null) return
        val view = TextView(this)
        view.text = "聚"
        view.setTextColor(Color.WHITE)
        view.textSize = 20f
        view.gravity = Gravity.CENTER
        view.background = ballBackground()
        val size = (56 * resources.displayMetrics.density).toInt()
        val params = WindowManager.LayoutParams(
            size,
            size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.START
        params.x = 100
        params.y = 300
        view.setOnTouchListener { _, event ->
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
                    windowManager?.updateViewLayout(view, params)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) togglePanel()
                    true
                }
                else -> false
            }
        }
        windowManager?.addView(view, params)
        ball = view
        ballParams = params
    }

    private fun removeBall() {
        val view = ball ?: return
        try {
            windowManager?.removeView(view)
        } catch (_: IllegalArgumentException) {
        }
        ball = null
        ballParams = null
    }

    private fun togglePanel() {
        if (panel != null) {
            removePanel()
            return
        }
        val layout = LinearLayout(this)
        layout.orientation = LinearLayout.VERTICAL
        layout.setBackgroundColor(Color.parseColor("#F2F0FA"))
        layout.setPadding(24, 24, 24, 24)
        val openButton = Button(this)
        openButton.text = "打开应用"
        openButton.setOnClickListener {
            val launch = packageManager.getLaunchIntentForPackage(packageName)
            launch?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (launch != null) startActivity(launch)
            removePanel()
        }
        val closeButton = Button(this)
        closeButton.text = "关闭悬浮窗"
        closeButton.setOnClickListener {
            stopSelf()
        }
        layout.addView(openButton)
        layout.addView(closeButton)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.START
        val ballPosition = ballParams
        params.x = (ballPosition?.x ?: 100) + 70
        params.y = ballPosition?.y ?: 300
        windowManager?.addView(layout, params)
        panel = layout
        panelParams = params
    }

    private fun removePanel() {
        val view = panel ?: return
        try {
            windowManager?.removeView(view)
        } catch (_: IllegalArgumentException) {
        }
        panel = null
        panelParams = null
    }
}
