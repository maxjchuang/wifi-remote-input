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
        val eventFlags = mutableListOf<Int>()
        var action = -1
        var extractionReads = 0
        var extractionAvailable = true
        var extractionOffset = 0
        var partialStart = -1
        private val connection by lazy { object : BaseInputConnection(View(this), true) {
            override fun getEditable() = buffer
            override fun getExtractedText(request: android.view.inputmethod.ExtractedTextRequest?, flags: Int): android.view.inputmethod.ExtractedText? {
                extractionReads++
                if (!extractionAvailable) return null
                return android.view.inputmethod.ExtractedText().apply {
                    text = buffer.toString(); startOffset = extractionOffset; partialStartOffset = partialStart
                    selectionStart = android.text.Selection.getSelectionStart(buffer).coerceAtLeast(0)
                    selectionEnd = android.text.Selection.getSelectionEnd(buffer).coerceAtLeast(0)
                }
            }
            override fun sendKeyEvent(event: KeyEvent): Boolean { events.add(event.keyCode); eventFlags.add(event.flags); return true }
            override fun performEditorAction(code: Int): Boolean { action = code; return true }
        } }
        override fun getCurrentInputEditorInfo(): EditorInfo = info
        override fun getCurrentInputConnection(): InputConnection = connection
    }
    private fun edit(snapshot: org.json.JSONObject, text: String, start: Int, end: Int = start): String {
        val a = minOf(snapshot.getInt("selectionStart"), snapshot.getInt("selectionEnd"))
        val b = maxOf(snapshot.getInt("selectionStart"), snapshot.getInt("selectionEnd"))
        return org.json.JSONObject().put("editorId", snapshot.getString("editorId"))
            .put("expectedHash", Secrets.hash(snapshot.getString("text") + "\u0000" + a + "," + b))
            .put("text", text).put("selectionStart", start.toString()).put("selectionEnd", end.toString()).toString()
    }
    @Test fun mirroredEditsReplaceSelectionAndRejectStalePhoneTextOrFocus() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get(); ime.onStartInput(ime.info, false)
        ime.apply("text.commit", "已有文字👋")
        val original = ime.snapshot()
        assertEquals("ok", ime.apply("editor.edit", edit(original, "已有中文👋", 4)))
        assertEquals("已有中文👋", ime.buffer.toString()); assertEquals(4, android.text.Selection.getSelectionStart(ime.buffer))
        assertEquals("editor_conflict", ime.apply("editor.edit", edit(original, "不应覆盖", 4)))
        val selected = ime.snapshot()
        assertEquals("ok", ime.apply("editor.edit", edit(selected, ime.buffer.toString(), 0, 2)))
        assertEquals(2, android.text.Selection.getSelectionEnd(ime.buffer))
        val beforeMove = ime.snapshot(); android.text.Selection.setSelection(ime.buffer, 1)
        assertEquals("editor_conflict", ime.apply("editor.edit", edit(beforeMove, "不应覆盖", 4)))
        val beforeSwitch = ime.snapshot(); ime.onStartInput(ime.info, false)
        assertEquals("editor_conflict", ime.apply("editor.edit", edit(beforeSwitch, "不应覆盖", 4)))
        assertEquals("已有中文👋", ime.buffer.toString())
        ime.info.inputType = 129
        val reads = ime.extractionReads
        assertEquals("password_blocked", ime.apply("editor.edit", edit(beforeSwitch, "不应覆盖", 4)))
        assertEquals(reads, ime.extractionReads)
        controller.destroy()
    }
    @Test fun explicitSendNewlineAndCustomActionUseDistinctPaths() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get(); ime.onStartInput(ime.info, false)
        ime.info.imeOptions = EditorInfo.IME_FLAG_NO_ENTER_ACTION or EditorInfo.IME_ACTION_SEND
        assertEquals("ok", ime.apply("key.press", "Enter")); assertEquals(EditorInfo.IME_ACTION_SEND, ime.action)
        ime.info.imeOptions = EditorInfo.IME_FLAG_NO_ENTER_ACTION
        assertEquals("ok", ime.apply("key.press", "Send")); assertEquals(EditorInfo.IME_ACTION_SEND, ime.action)
        assertEquals("ok", ime.apply("key.press", "LineBreak")); assertEquals("\n", ime.buffer.toString()); assertTrue(ime.events.isEmpty())
        ime.info.imeOptions = EditorInfo.IME_ACTION_UNSPECIFIED; ime.info.actionLabel = "提交"; ime.info.actionId = 100
        assertEquals("ok", ime.apply("key.press", "Enter")); assertEquals(100, ime.action)
        ime.info.actionLabel = null
        ime.apply("key.press", "Enter")
        assertTrue(ime.eventFlags.all { it and KeyEvent.FLAG_SOFT_KEYBOARD != 0 && it and KeyEvent.FLAG_KEEP_TOUCH_MODE != 0 })
        controller.destroy()
    }
    @Test fun snapshotUsesCurrentEditorTextSelectionAndSwitches() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get(); ime.onStartInput(ime.info, false)
        ime.buffer.append("已有中文👋"); android.text.Selection.setSelection(ime.buffer, 2, 4)
        val first = ime.snapshot()
        assertEquals("已有中文👋", first.getString("text")); assertEquals(2, first.getInt("selectionStart")); assertEquals(4, first.getInt("selectionEnd"))
        ime.buffer.delete(0, 2)
        assertEquals("中文👋", ime.snapshot().getString("text"))
        ime.onFinishInput(); assertEquals("no_editor", ime.snapshot().getString("status"))
        ime.buffer.clear(); ime.onStartInput(ime.info, false)
        val next = ime.snapshot()
        assertEquals("", next.getString("text")); assertNotEquals(first.getString("editorId"), next.getString("editorId"))
        controller.destroy()
    }
    @Test fun protectedEditorsAreNeverReadAndUnsupportedDoesNotLeakText() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get()
        for (type in listOf(129, 145, 225, 18, 0)) {
            ime.info.inputType = type; ime.onStartInput(ime.info, false)
            val denied = ime.snapshot()
            assertEquals("password_blocked", denied.getString("status")); assertFalse(denied.has("text"))
        }
        assertEquals(0, ime.extractionReads)
        ime.info.inputType = 1; ime.onStartInput(ime.info, false)
        ime.buffer.append("should not leak")
        ime.extractionAvailable = false
        assertEquals("snapshot_unavailable", ime.snapshot().getString("status"))
        ime.extractionAvailable = true; ime.extractionOffset = 3
        assertFalse(ime.snapshot().has("text"))
        ime.extractionOffset = 0; ime.partialStart = 0
        assertFalse(ime.snapshot().has("text"))
        ime.partialStart = -1; ime.buffer.append("x".repeat(2049))
        val large = ime.snapshot()
        assertEquals("editor_too_large", large.getString("status")); assertFalse(large.has("text"))
        controller.destroy()
    }
    @Test fun lockedDeviceNeverReadsEditorText() {
        val controller = Robolectric.buildService(TestIme::class.java).create()
        val ime = controller.get(); ime.onStartInput(ime.info, false)
        val keyguard = ime.getSystemService(android.app.KeyguardManager::class.java)
        org.robolectric.Shadows.shadowOf(keyguard).setKeyguardLocked(true)
        val denied = ime.snapshot()
        assertEquals("device_locked", denied.getString("status")); assertFalse(denied.has("text")); assertEquals(0, ime.extractionReads)
        controller.destroy()
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
