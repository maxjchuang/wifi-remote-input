// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.app.KeyguardManager
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityEvent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class PhoneControlTest {
    class Service : PhoneControlService() {
        var root: AccessibilityNodeInfo? = null
        override fun getRootInActiveWindow(): AccessibilityNodeInfo? = root
        fun ready() { onServiceConnected() }
    }
    private fun node(password: Boolean = false) = AccessibilityNodeInfo.obtain().apply {
        isEnabled = true; isVisibleToUser = true; isClickable = true; isPassword = password
        setBoundsInScreen(Rect(10, 10, 90, 90))
        shadowOf(this).setRefreshReturnValue(true)
    }
    private fun keepsScreenOn(service: Service): Boolean {
        val windows = org.robolectric.shadow.api.Shadow.extract<org.robolectric.shadows.ShadowWindowManagerImpl>(service.getSystemService(android.view.WindowManager::class.java))
        return windows.views.any { view ->
            val params = view.layoutParams as? android.view.WindowManager.LayoutParams
            params != null && params.flags and android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
        }
    }
    @Test fun screenStaysOnOnlyDuringAuthenticatedControlAndReleasesOnStopOrTimeout() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        assertFalse(keepsScreenOn(service))
        service.command("a", "pointer_start") { false }; assertFalse(keepsScreenOn(service))
        service.command("a", "pointer_start") { true }; assertTrue(keepsScreenOn(service))
        service.stop("b"); assertTrue(keepsScreenOn(service))
        service.stop("a"); assertFalse(keepsScreenOn(service))
        service.command("a", "start") { true }; assertTrue(keepsScreenOn(service))
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(4))
        service.command("a", "ping") { true }
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(4))
        assertTrue(keepsScreenOn(service))
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(3))
        assertFalse(keepsScreenOn(service)); controller.destroy()
    }
    @Test fun screenOnReleasesOnRevocationManualLockAndServiceDestruction() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        var authorized = true
        service.command("a", "pointer_start") { authorized }; assertTrue(keepsScreenOn(service))
        authorized = false
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertFalse(keepsScreenOn(service))
        service.command("a", "pointer_start") { true }
        val keyguard = shadowOf(service.getSystemService(KeyguardManager::class.java))
        keyguard.setKeyguardLocked(true)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertFalse(keepsScreenOn(service))
        keyguard.setKeyguardLocked(false)
        service.command("a", "pointer_start") { true }; assertTrue(keepsScreenOn(service))
        controller.destroy(); assertFalse(keepsScreenOn(service))
    }
    @Test fun stoppingDuringInFlightDragReleasesFingerWithoutQueuedMovement() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        service.command("a", "pointer_start") { true }
        assertEquals("ok", service.command("a", "pointer_down", 1000, 2000) { true })
        assertEquals("ok", service.command("a", "pointer_drag", 5000, 6000) { true })
        assertEquals("ok", service.command("a", "stop") { true })
        val first = shadowOf(service).gesturesDispatched.single()
        first.callback().onCompleted(first.description())
        val gestures = shadowOf(service).gesturesDispatched
        assertEquals(2, gestures.size)
        assertFalse(gestures.last().description().getStroke(0).willContinue())
        gestures.last().callback().onCompleted(gestures.last().description())
        assertEquals("control_paused", service.command("a", "pointer_drag", 9000, 9000) { true })
        assertFalse(keepsScreenOn(service)); controller.destroy()
    }
    @Test fun pointerTapsWorkWithoutAccessibleNodesAndRequireLiveSession() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        fun tap(x: Int = 5000, y: Int = 5000) = service.command("a", "pointer_tap", x, y) { true }
        assertEquals("control_paused", tap())
        assertEquals("ok", service.command("a", "pointer_start") { true })
        assertEquals("invalid_action", tap(-1))
        assertEquals("ok", service.command("a", "pointer_move", 7000, 2500) { true })
        assertTrue(shadowOf(service).gesturesDispatched.isEmpty())
        assertEquals("ok", tap(7000, 2500))
        assertEquals(1, shadowOf(service).gesturesDispatched.size)
        val dispatch = shadowOf(service).gesturesDispatched.single()
        val bounds = android.graphics.RectF(); dispatch.description().getStroke(0).path.computeBounds(bounds, true)
        val size = android.graphics.Point()
        service.getSystemService(android.view.WindowManager::class.java).defaultDisplay.getRealSize(size)
        assertEquals((size.x - 1) * .7f, bounds.left, .1f)
        assertEquals((size.y - 1) * .25f, bounds.top, .1f)
        assertEquals("gesture_busy", tap())
        dispatch.callback().onCompleted(dispatch.description())
        shadowOf(service).setCanDispatchGestures(false)
        assertEquals("gesture_unavailable", tap())
        assertEquals("ok", service.command("a", "back") { true })
        assertEquals(listOf(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK), shadowOf(service).globalActionsPerformed)
        service.stop(); assertEquals("control_paused", tap()); controller.destroy()
    }
    @Test fun pointerCannotTapPasswordOrAfterRevocation() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        service.root = node(true).apply { setBoundsInScreen(Rect(0, 0, 10000, 10000)) }
        service.command("a", "pointer_start") { true }
        assertEquals("password_blocked", service.command("a", "pointer_tap", 5000, 5000) { true })
        assertTrue(shadowOf(service).gesturesDispatched.isEmpty())
        assertEquals("unauthorized", service.command("a", "pointer_tap", 5000, 5000) { false })
        assertEquals("control_paused", service.command("a", "pointer_tap", 5000, 5000) { true })
        controller.destroy()
    }
    @Test fun controlsNeedExplicitSessionAndLiveAuthentication() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get()
        service.ready()
        assertEquals("unauthorized", service.command("a", "start") { false })
        assertEquals("control_paused", service.command("a", "home") { true })
        assertEquals("ok", service.command("a", "start") { true })
        assertEquals("control_busy", service.command("b", "start") { true })
        assertEquals("control_paused", service.command("b", "home") { true })
        assertEquals("ok", service.command("a", "home") { true })
        assertEquals(1, shadowOf(service).globalActionsPerformed.size)
        assertEquals("unauthorized", service.command("a", "home") { false })
        assertEquals(1, shadowOf(service).globalActionsPerformed.size)
        controller.destroy()
    }
    @Test fun lockAndLeaseExpiryStopControl() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        service.command("a", "start") { true }
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(7))
        assertEquals("control_paused", service.command("a", "home") { true })
        shadowOf(service.getSystemService(KeyguardManager::class.java)).setKeyguardLocked(true)
        assertEquals("device_locked", service.command("a", "start") { true })
        assertTrue(shadowOf(service).globalActionsPerformed.isEmpty()); controller.destroy()
    }
    @Test fun passwordNodesAndChangedWindowsCannotBeClicked() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        val password = node(true); service.root = password
        service.command("a", "start") { true }
        assertEquals("no_controls", service.command("a", "next") { true })
        assertEquals("selection_changed", service.command("a", "click") { true })
        assertTrue(shadowOf(password).performedActions.isEmpty())
        val ordinary = node(); service.root = ordinary
        assertEquals("ok", service.command("a", "next") { true })
        service.onAccessibilityEvent(AccessibilityEvent.obtain(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED))
        assertEquals("selection_changed", service.command("a", "click") { true })
        assertTrue(shadowOf(ordinary).performedActions.isEmpty()); controller.destroy()
    }
    @Test fun clickAndLongClickUseSelectedNodeAndStopClearsSelection() {
        val controller = Robolectric.buildService(Service::class.java).create(); val service = controller.get(); service.ready()
        val button = node(); service.root = button
        shadowOf(button).setOnPerformActionListener { _, _ -> true }
        service.command("a", "start") { true }
        assertEquals("ok", service.command("a", "click") { true })
        service.command("a", "next") { true }
        assertEquals("ok", service.command("a", "long_click") { true })
        assertEquals(listOf(AccessibilityNodeInfo.ACTION_CLICK, AccessibilityNodeInfo.ACTION_LONG_CLICK), shadowOf(button).performedActions)
        service.stop("a")
        assertEquals("control_paused", service.command("a", "click") { true }); controller.destroy()
    }
}
