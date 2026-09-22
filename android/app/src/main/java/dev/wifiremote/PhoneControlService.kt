// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.graphics.*
import android.os.*
import android.view.*
import android.view.accessibility.*

/** Optional, local-only accessibility navigation. No screen images or node text leave the phone. */
open class PhoneControlService : AccessibilityService() {
    companion object { var active: PhoneControlService? = null; private set }
    private val handler = Handler(Looper.getMainLooper())
    private var owner: String? = null
    private var authorization: () -> Boolean = { false }
    private var expires = 0L
    private var selected: AccessibilityNodeInfo? = null
    private var overlay: View? = null
    private var badge: View? = null
    private val bounds = Rect()
    private var pointerMode = false
    private var pointerX = 5000
    private var pointerY = 5000
    private val pointerMotion = PointerMotion()
    private var frameScheduled = false
    private val pointerFrame = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            frameScheduled = false
            if (!pointerMode || owner == null) return
            val moving = pointerMotion.advance(frameTimeNanos)
            overlay?.invalidate()
            if (moving) schedulePointerFrame()
        }
    }
    private fun schedulePointerFrame() {
        if (!frameScheduled) { frameScheduled = true; Choreographer.getInstance().postFrameCallback(pointerFrame) }
    }
    private fun cancelPointerAnimation() {
        Choreographer.getInstance().removeFrameCallback(pointerFrame); frameScheduled = false
    }
    private var gesturePending = false
    private var gestureEpoch = 0
    private val drag by lazy { PointerDrag(
        { gesture, callback -> dispatchGesture(gesture, callback, handler) },
        { owner != null && pointerMode && authorization() && !locked() && SystemClock.elapsedRealtime() <= expires }
    ) }
    @Suppress("DEPRECATION")
    private fun screenSize() = Point().also { getSystemService(WindowManager::class.java).defaultDisplay.getRealSize(it) }
    private fun pointerPosition(): PointF { val size = screenSize(); return PointF(pointerX / 10000f * (size.x - 1).coerceAtLeast(0), pointerY / 10000f * (size.y - 1).coerceAtLeast(0)) }
    private fun passwordAtPointer(point: PointF): Boolean {
        // Protect password nodes even though pointer clicks do not require accessible click targets.
        var visited = 0
        fun passwordAt(node: AccessibilityNodeInfo, depth: Int): Boolean {
            if (++visited > 1000 || depth > 40) return true
            val rect = Rect(); node.getBoundsInScreen(rect)
            if (node.isVisibleToUser && node.isPassword && rect.contains(point.x.toInt(), point.y.toInt())) return true
            for (i in 0 until node.childCount) if (node.getChild(i)?.let { passwordAt(it, depth + 1) } == true) return true
            return false
        }
        return rootInActiveWindow?.let { passwordAt(it, 0) } == true
    }
    private fun tapPointer(): String {
        if (gesturePending || drag.holding) return "gesture_busy"
        val point = pointerPosition()
        if (passwordAtPointer(point)) return "password_blocked"
        val path = Path().apply { moveTo(point.x, point.y) }
        val gesture = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 40)).build()
        val epoch = gestureEpoch
        gesturePending = true
        val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) { if (epoch == gestureEpoch) gesturePending = false }
            override fun onCancelled(gestureDescription: GestureDescription?) { if (epoch == gestureEpoch) gesturePending = false }
        }, handler)
        if (!accepted) gesturePending = false
        return if (accepted) "ok" else "gesture_unavailable"
    }
    private val watchdog = object : Runnable {
        override fun run() {
            if (owner != null && (!authorization() || SystemClock.elapsedRealtime() > expires || locked())) stop()
            handler.postDelayed(this, 500)
        }
    }
    override fun onServiceConnected() { active = this; handler.post(watchdog) }
    override fun onInterrupt() { stop() }
    override fun onDestroy() { stop(); handler.removeCallbacksAndMessages(null); if (active === this) active = null; super.onDestroy() }
    private fun locked() = getSystemService(KeyguardManager::class.java).isKeyguardLocked
    fun stop(session: String? = null) {
        if (session != null && owner != session) return
        drag.up()
        cancelPointerAnimation()
        pointerMode = false; gestureEpoch++; gesturePending = false
        owner = null; selected = null; authorization = { false }
        overlay?.let { try { getSystemService(WindowManager::class.java).removeView(it) } catch (_: IllegalArgumentException) { /* Already detached by the system. */ } }; overlay = null
        badge?.let { try { getSystemService(WindowManager::class.java).removeView(it) } catch (_: IllegalArgumentException) { /* Already detached by the system. */ } }; badge = null
    }
    fun command(session: String, action: String, x: Int? = null, y: Int? = null, authorized: () -> Boolean): String {
        if (!authorized()) { stop(session); return "unauthorized" }
        if (action == "stop") { stop(session); return "ok" }
        if (locked()) { stop(); return "device_locked" }
        if (action == "start" || action == "pointer_start") {
            if (owner != null && owner != session || drag.holding) return "control_busy"
            owner = session; authorization = authorized; expires = SystemClock.elapsedRealtime() + 6000
            cancelPointerAnimation(); pointerMotion.snap(5000, 5000)
            pointerMode = action == "pointer_start"; pointerX = 5000; pointerY = 5000
            if (pointerMode) clearSelection() else select("next")
            showOutline(); return "ok"
        }
        if (owner != session || SystemClock.elapsedRealtime() > expires) { stop(session); return "control_paused" }
        expires = SystemClock.elapsedRealtime() + 6000
        if (action == "ping") return "ok"
        if (action in setOf("pointer_move", "pointer_tap", "pointer_down", "pointer_drag", "pointer_up")) {
            if (!pointerMode) return "control_paused"
            if (x == null || y == null || x !in 0..10000 || y !in 0..10000) return "invalid_action"
            pointerX = x; pointerY = y
            if (action in setOf("pointer_tap", "pointer_down", "pointer_up")) {
                cancelPointerAnimation(); pointerMotion.snap(x, y); overlay?.invalidate()
            } else { pointerMotion.moveTo(x, y, System.nanoTime()); schedulePointerFrame() }
            return when (action) {
                "pointer_tap" -> tapPointer()
                "pointer_down" -> if (gesturePending) "gesture_busy" else if (passwordAtPointer(pointerPosition())) "password_blocked" else drag.down(pointerPosition())
                "pointer_drag" -> drag.move(pointerPosition())
                "pointer_up" -> drag.up(pointerPosition())
                else -> "ok"
            }
        }
        if (action in setOf("back", "home", "recents")) {
            if (drag.holding) { drag.up(); return "gesture_busy" }
            clearSelection()
            val id = when(action) { "back" -> GLOBAL_ACTION_BACK; "home" -> GLOBAL_ACTION_HOME; else -> GLOBAL_ACTION_RECENTS }
            return if (performGlobalAction(id)) "ok" else "action_unavailable"
        }
        if (action in setOf("next", "previous", "left", "right", "up", "down")) return select(action)
        val root = rootInActiveWindow ?: return "no_controls"
        val node = selected
        if (node == null || !node.refresh() || node.windowId != root.windowId || !node.isVisibleToUser) { clearSelection(); return "selection_changed" }
        if (node.isPassword) { clearSelection(); return "password_blocked" }
        val id = when(action) {
            "click" -> AccessibilityNodeInfo.ACTION_CLICK
            "long_click" -> AccessibilityNodeInfo.ACTION_LONG_CLICK
            "scroll_up" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            "scroll_down" -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            else -> return "invalid_action"
        }
        var target: AccessibilityNodeInfo? = node
        if (action.startsWith("scroll_")) { while (target != null && !target.isScrollable) target = target.parent }
        val done = target?.performAction(id) == true
        clearSelection()
        return if (done) "ok" else "action_unavailable"
    }
    private fun clearSelection() { selected = null; bounds.setEmpty(); overlay?.invalidate() }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (owner == null) return
        if (locked()) { stop(); return }
        // Never act on stale geometry after an application updates its window.
        if (event?.eventType in setOf(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, AccessibilityEvent.TYPE_VIEW_SCROLLED)) clearSelection()
    }
    private fun select(direction: String): String {
        val root = rootInActiveWindow ?: return "no_controls"
        val nodes = mutableListOf<AccessibilityNodeInfo>()
        var visited = 0
        fun walk(n: AccessibilityNodeInfo, depth: Int) {
            if (++visited > 1000 || depth > 40) return
            if (n.isVisibleToUser && n.isEnabled && !n.isPassword && (n.isClickable || n.isLongClickable || n.isScrollable)) nodes.add(n)
            for (i in 0 until n.childCount) n.getChild(i)?.let { walk(it, depth + 1) }
        }
        walk(root, 0)
        if (nodes.isEmpty()) { clearSelection(); return "no_controls" }
        val old = selected?.takeIf { it.refresh() && it.windowId == root.windowId }
        val index = nodes.indexOf(old)
        val next = if (direction in setOf("next", "previous") || old == null) {
            nodes[if (index < 0) 0 else Math.floorMod(index + if (direction == "previous") -1 else 1, nodes.size)]
        } else {
            val a = Rect(); old.getBoundsInScreen(a)
            nodes.filter { it != old }.map { n -> val b = Rect(); n.getBoundsInScreen(b); n to b }
                .filter { (_, b) -> when(direction) { "left" -> b.centerX() < a.centerX(); "right" -> b.centerX() > a.centerX(); "up" -> b.centerY() < a.centerY(); else -> b.centerY() > a.centerY() } }
                .minByOrNull { (_, b) -> val dx = (b.centerX() - a.centerX()).toDouble(); val dy = (b.centerY() - a.centerY()).toDouble(); if (direction in setOf("left", "right")) dx*dx + 3*dy*dy else 3*dx*dx + dy*dy }?.first ?: old
        }
        selected = next; next.getBoundsInScreen(bounds); showOutline(); return "ok"
    }
    private fun showOutline() {
        if (badge == null) {
            val button = android.widget.TextView(this).apply {
                text = "Remote Input · 控制中  ⏸"; textSize = 12f
                setTextColor(Color.WHITE); setPadding(20, 12, 20, 12)
                background = android.graphics.drawable.GradientDrawable().apply { setColor(Color.rgb(24, 77, 68)); cornerRadius = 18f }
                contentDescription = "暂停 Remote Input 手机控制"; setOnClickListener { stop() }
            }
            // This visible overlay exists only for the authenticated control session.
            // Removing it in stop() also releases keep-screen-on without changing system settings.
            val params = WindowManager.LayoutParams(-2, -2, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON, PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.END; y = 48 }
            getSystemService(WindowManager::class.java).addView(button, params); badge = button
        }
        if (overlay == null) {
            val view = object : View(this) {
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(46, 199, 168); style = Paint.Style.STROKE; strokeWidth = 3 * resources.displayMetrics.density }
                val location = IntArray(2)
                val outline = RectF()
                var extent = screenSize()
                override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { extent = screenSize() }
                override fun onDraw(canvas: Canvas) {
                    getLocationOnScreen(location)
                    if (pointerMode) {
                        val x = pointerMotion.x / 10000f * (extent.x - 1).coerceAtLeast(0) - location[0]
                        val y = pointerMotion.y / 10000f * (extent.y - 1).coerceAtLeast(0) - location[1]
                        canvas.drawCircle(x, y, 9 * resources.displayMetrics.density, paint)
                        canvas.drawLine(x - 5, y, x + 5, y, paint); canvas.drawLine(x, y - 5, x, y + 5, paint)
                    }
                    if (!bounds.isEmpty) { outline.set(bounds); canvas.save(); canvas.translate(-location[0].toFloat(), -location[1].toFloat()); canvas.drawRoundRect(outline, 8f, 8f, paint); canvas.restore() } }
            }
            val params = WindowManager.LayoutParams(-1, -1, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSLUCENT)
            getSystemService(WindowManager::class.java).addView(view, params); overlay = view
        }
        overlay?.invalidate()
    }
}
