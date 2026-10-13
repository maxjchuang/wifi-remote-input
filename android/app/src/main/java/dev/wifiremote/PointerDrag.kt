// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.accessibilityservice.AccessibilityService.GestureResultCallback
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.PointF

/** One continuous finger; coalesce motion, but never discard its release. Main thread only. */
internal class PointerDrag(
    private val dispatch: (GestureDescription, GestureResultCallback) -> Boolean,
    private val permitted: () -> Boolean
) {
    private var stroke: GestureDescription.StrokeDescription? = null
    private var endpoint = PointF()
    private val pending = mutableListOf<PointF>()
    private var busy = false
    private var ending = false
    val holding: Boolean get() = stroke != null

    fun down(point: PointF): String {
        if (holding) return "gesture_busy"
        if (!permitted()) return "control_paused"
        endpoint = PointF(point.x, point.y); pending.clear(); ending = false
        val path = Path().apply { moveTo(point.x, point.y) }
        return if (send(GestureDescription.StrokeDescription(path, 0, 1, true), false)) "ok" else "gesture_unavailable"
    }
    fun move(point: PointF): String {
        if (!holding || ending) return "touch_not_down"
        if (pending.size >= 64) return "gesture_busy"
        pending.add(PointF(point.x, point.y)); pump(); return "ok"
    }
    fun up(point: PointF? = null): String {
        if (!holding) return "ok"
        if (point == null) pending.clear() else pending.add(PointF(point.x, point.y))
        ending = true; pump(); return "ok"
    }
    private fun pump() {
        val previous = stroke ?: return
        if (busy) return
        if (!permitted()) { pending.clear(); ending = true }
        if (pending.isEmpty() && !ending) return
        // Each waypoint must be a stroke endpoint. Folding a reversal into a short
        // polyline lets the framework's time sampling skip the turning point entirely.
        val point = if (pending.isNotEmpty()) pending.removeAt(0) else endpoint
        val path = Path().apply { moveTo(endpoint.x, endpoint.y); lineTo(point.x, point.y) }
        endpoint = point
        val finish = ending && pending.isEmpty()
        send(previous.continueStroke(path, 0, 24, !finish), finish)
    }
    private fun send(next: GestureDescription.StrokeDescription, finish: Boolean): Boolean {
        stroke = next; busy = true
        val gesture = GestureDescription.Builder().addStroke(next).build()
        val accepted = dispatch(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                if (stroke !== next) return
                busy = false
                if (finish) clear() else pump()
            }
            override fun onCancelled(gestureDescription: GestureDescription?) { if (stroke === next) clear() }
        })
        if (!accepted) clear()
        return accepted
    }
    private fun clear() { stroke = null; pending.clear(); busy = false; ending = false }
}
