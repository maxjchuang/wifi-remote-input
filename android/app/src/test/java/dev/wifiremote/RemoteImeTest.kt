// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.text.Editable
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class RemoteImeTest {
    class TestIme : RemoteIme() {
        val info = EditorInfo().apply { inputType = 1 }
        val buffer: Editable = Editable.Factory.getInstance().newEditable("")
        val events = mutableListOf<Int>()
        var action = -1
        private val connection by lazy { object : BaseInputConnection(View(this), true) {
            override fun getEditable() = buffer
            override fun sendKeyEvent(event: KeyEvent): Boolean { events.add(event.keyCode); return true }
            override fun performEditorAction(code: Int): Boolean { action = code; return true }
        } }
        override fun getCurrentInputEditorInfo(): EditorInfo = info
        override fun getCurrentInputConnection(): InputConnection = connection
    }
    @Test fun unicodeReachesInputConnectionAndFinishedEditorRejects() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get()
        ime.onStartInput(ime.info, false)
        assertEquals("ok", ime.apply("text.commit", "你好，小米 13 👋"))
        assertEquals("你好，小米 13 👋", ime.buffer.toString())
        ime.onFinishInput()
        assertEquals("no_editor", ime.apply("text.commit", "blocked"))
        controller.destroy()
    }
    @Test fun allPasswordTypesBlockBothTextAndKeys() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get()
        for (type in listOf(129, 145, 225, 18, 0)) {
            ime.info.inputType = type; ime.onStartInput(ime.info, false)
            assertEquals("password_blocked", ime.apply("text.commit", "secret"))
            assertEquals("password_blocked", ime.apply("key.press", "Enter"))
        }
        assertEquals("", ime.buffer.toString()); assertTrue(ime.events.isEmpty()); assertEquals(-1, ime.action)
        controller.destroy()
    }
    @Test fun enterHonorsEditorActionAndKeysUseDownUpPairs() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get(); ime.onStartInput(ime.info, false)
        ime.info.imeOptions = EditorInfo.IME_ACTION_SEARCH
        assertEquals("ok", ime.apply("key.press", "Enter")); assertEquals(EditorInfo.IME_ACTION_SEARCH, ime.action)
        ime.info.imeOptions = EditorInfo.IME_FLAG_NO_ENTER_ACTION
        for (key in listOf("Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown")) assertEquals("ok", ime.apply("key.press", key))
        assertEquals(listOf(66,66,67,67,21,21,22,22,19,19,20,20), ime.events)
        controller.destroy()
    }
}
