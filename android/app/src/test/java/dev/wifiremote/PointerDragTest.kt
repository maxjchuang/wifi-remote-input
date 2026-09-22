// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.accessibilityservice.AccessibilityService.GestureResultCallback
import android.accessibilityservice.GestureDescription
import android.graphics.PathMeasure
import android.graphics.PointF
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
class PointerDragTest {
    private val sent = mutableListOf<Pair<GestureDescription, GestureResultCallback>>()
    private var allowed = true
    private var accepted = true
    private val drag = PointerDrag({ gesture, callback -> sent.add(gesture to callback); accepted }, { allowed })
    private fun complete(index: Int = sent.lastIndex) { val (gesture, callback) = sent[index]; callback.onCompleted(gesture) }
    private fun end(index: Int): FloatArray { val path = PathMeasure(sent[index].first.getStroke(0).path, false); return FloatArray(2).also { path.getPosTan(path.length, it, null) } }
    @Test fun stationaryPressHoldsUntilReleaseWithoutAnotherTouchDown() {
        assertEquals("ok", drag.down(PointF(10f, 20f))); complete()
        assertTrue(drag.holding); assertTrue(sent.single().first.getStroke(0).willContinue())
        assertEquals("gesture_busy", drag.down(PointF(20f, 30f)))
        assertEquals("ok", drag.up()); assertEquals(2, sent.size)
        assertFalse(sent.last().first.getStroke(0).willContinue()); complete()
        assertFalse(drag.holding); assertEquals("ok", drag.up()); assertEquals(2, sent.size)
    }
    @Test fun motionCoalescesWhileBusyAndReleaseKeepsFinalCoordinates() {
        drag.down(PointF(10f, 20f))
        drag.move(PointF(20f, 30f)); drag.move(PointF(30f, 40f))
        assertEquals(1, sent.size); complete()
        assertEquals(2, sent.size); assertArrayEquals(floatArrayOf(30f, 40f), end(1), .01f)
        drag.move(PointF(40f, 50f)); drag.up(PointF(50f, 60f)); complete(1)
        assertEquals(3, sent.size); assertArrayEquals(floatArrayOf(50f, 60f), end(2), .01f)
        assertFalse(sent[2].first.getStroke(0).willContinue()); complete(2)
        assertFalse(drag.holding)
    }
    @Test fun revocationOrStopDropsQueuedMotionButReleasesFinger() {
        drag.down(PointF(10f, 20f)); drag.move(PointF(100f, 200f))
        allowed = false; complete()
        assertEquals(2, sent.size); assertFalse(sent[1].first.getStroke(0).willContinue())
        complete(); assertFalse(drag.holding)
        assertEquals("control_paused", drag.down(PointF(1f, 2f)))
        allowed = true; drag.down(PointF(10f, 20f)); drag.move(PointF(100f, 200f)); drag.up(); complete()
        assertFalse(sent.last().first.getStroke(0).willContinue()); complete(); assertFalse(drag.holding)
    }
    @Test fun cancellationAndRejectionCannotLeaveSoftwareHoldingState() {
        accepted = false; assertEquals("gesture_unavailable", drag.down(PointF(10f, 20f))); assertFalse(drag.holding)
        accepted = true; drag.down(PointF(10f, 20f))
        sent.last().second.onCancelled(sent.last().first)
        assertFalse(drag.holding); assertEquals("touch_not_down", drag.move(PointF(30f, 40f)))
        complete(); assertFalse(drag.holding)
    }
}
