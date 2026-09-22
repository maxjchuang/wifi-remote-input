// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import org.junit.Assert.*
import org.junit.Test

class PointerMotionTest {
    @Test fun intermediateFramesRemainBoundedAndStopAtExactTarget() {
        val motion = PointerMotion(); motion.snap(0, 10000)
        motion.moveTo(10000, 0, 100L)
        assertTrue(motion.advance(16_000_100L))
        assertEquals(5000f, motion.x, .01f); assertEquals(5000f, motion.y, .01f)
        assertFalse(motion.advance(32_000_100L))
        assertEquals(10000f, motion.x, .01f); assertEquals(0f, motion.y, .01f)
        assertFalse(motion.advance(100_000_100L))
    }
    @Test fun refreshRateDoesNotChangePositionAtSameElapsedTime() {
        val slow = PointerMotion(); val fast = PointerMotion()
        for (motion in listOf(slow, fast)) motion.moveTo(8000, 2000, 0)
        fast.advance(8_000_000); fast.advance(16_000_000); fast.advance(24_000_000)
        slow.advance(24_000_000)
        assertEquals(slow.x, fast.x, .01f); assertEquals(slow.y, fast.y, .01f)
    }
    @Test fun RetargetUsesCurrentPositionAndClickSnapCancelsAnimation() {
        val motion = PointerMotion(); motion.moveTo(9000, 1000, 0)
        motion.moveTo(1000, 9000, 16_000_000)
        assertEquals(7000f, motion.x, .01f)
        motion.advance(32_000_000); assertEquals(4000f, motion.x, .01f)
        motion.snap(1234, 5678)
        assertFalse(motion.advance(100_000_000))
        assertEquals(1234f, motion.x, .01f); assertEquals(5678f, motion.y, .01f)
    }
}
