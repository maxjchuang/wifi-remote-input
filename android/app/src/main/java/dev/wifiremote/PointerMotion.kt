// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

/** Display-only interpolation. Touch dispatch always uses the exact command coordinates. */
internal class PointerMotion {
    var x = 5000f; private set
    var y = 5000f; private set
    private var fromX = x
    private var fromY = y
    private var targetX = x
    private var targetY = y
    private var started = 0L
    private var moving = false
    fun snap(x: Int, y: Int) {
        this.x = x.toFloat(); this.y = y.toFloat()
        fromX = this.x; fromY = this.y; targetX = this.x; targetY = this.y
        moving = false
    }
    fun moveTo(x: Int, y: Int, now: Long) {
        advance(now)
        fromX = this.x; fromY = this.y
        targetX = x.toFloat(); targetY = y.toFloat(); started = now
        moving = fromX != targetX || fromY != targetY
    }
    fun advance(now: Long): Boolean {
        if (!moving) return false
        val progress = ((now - started).coerceAtLeast(0) / 32_000_000f).coerceAtMost(1f)
        x = fromX + (targetX - fromX) * progress
        y = fromY + (targetY - fromY) * progress
        moving = progress < 1f
        return moving
    }
}
