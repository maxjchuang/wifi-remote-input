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
    @Test fun queuedMotionPreservesEndpointsAndReleasesOnlyAfterFinalPosition() {
        drag.down(PointF(10f, 20f))
        drag.move(PointF(20f, 30f)); drag.move(PointF(30f, 40f))
        assertEquals(1, sent.size); complete()
        assertArrayEquals(floatArrayOf(20f, 30f), end(1), .01f)
        drag.move(PointF(40f, 50f)); drag.up(PointF(50f, 60f))
        complete(1); assertArrayEquals(floatArrayOf(30f, 40f), end(2), .01f)
        assertTrue(sent[2].first.getStroke(0).willContinue())
        complete(2); assertArrayEquals(floatArrayOf(40f, 50f), end(3), .01f)
        complete(3); assertArrayEquals(floatArrayOf(50f, 60f), end(4), .01f)
        assertFalse(sent[4].first.getStroke(0).willContinue()); complete(4)
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
    @Test fun reversalWhileBusyKeepsTheTurningPoint() {
        drag.down(PointF(10f, 100f))
        drag.move(PointF(10f, 20f)); drag.move(PointF(10f, 100f)); drag.up(PointF(10f, 120f))
        complete(0)
        // The turn is an explicit endpoint, not merely a vertex in a 24ms polyline.
        assertArrayEquals(floatArrayOf(10f, 20f), end(1), .01f)
        assertTrue(sent[1].first.getStroke(0).willContinue())
        complete(1)
        assertArrayEquals(floatArrayOf(10f, 100f), end(2), .01f)
        assertTrue(sent[2].first.getStroke(0).willContinue())
        complete(2)
        assertArrayEquals(floatArrayOf(10f, 120f), end(3), .01f)
        assertFalse(sent[3].first.getStroke(0).willContinue())
        complete(3); assertFalse(drag.holding)
    }
    @Test fun frameworkSamplingKeepsReversalAndContinuationIdentity() {
        drag.down(PointF(10f, 100f))
        drag.move(PointF(10f, 20f)); drag.move(PointF(10f, 100f))
        complete(0); complete(1); complete(2)
        val generator = Class.forName("android.accessibilityservice.GestureDescription\$MotionEventGenerator")
        val method = generator.getMethod("getGestureStepsFromGestureDescription", GestureDescription::class.java, Int::class.javaPrimitiveType)
        for (interval in listOf(8, 16, 100)) {
            val finalPoints = sent.map { (gesture, _) ->
                val steps = method.invoke(null, gesture, interval) as List<*>
                val step = steps.last()!!
                (step.javaClass.getField("touchPoints").get(step) as Array<*>).first()!!
            }
            assertEquals(20f, finalPoints[1].javaClass.getField("mY").getFloat(finalPoints[1]), .01f)
            assertEquals(100f, finalPoints[2].javaClass.getField("mY").getFloat(finalPoints[2]), .01f)
            for (i in 1..2) {
                val point = finalPoints[i]; val previous = finalPoints[i - 1]
                assertEquals(previous.javaClass.getField("mStrokeId").getInt(previous), point.javaClass.getField("mContinuedStrokeId").getInt(point))
                assertFalse(point.javaClass.getField("mIsEndOfPath").getBoolean(point))
            }
        }
        drag.up(); complete(); assertFalse(drag.holding)
    }
    @Test fun cancellationAndRejectionCannotLeaveSoftwareHoldingState() {
        accepted = false; assertEquals("gesture_unavailable", drag.down(PointF(10f, 20f))); assertFalse(drag.holding)
        accepted = true; drag.down(PointF(10f, 20f))
        sent.last().second.onCancelled(sent.last().first)
        assertFalse(drag.holding); assertEquals("touch_not_down", drag.move(PointF(30f, 40f)))
        complete(); assertFalse(drag.holding)
    }
}
