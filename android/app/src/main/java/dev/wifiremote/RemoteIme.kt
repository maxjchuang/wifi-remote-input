// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.inputmethodservice.InputMethodService
import android.content.Intent
import android.view.View
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

open class RemoteIme : InputMethodService() {
    companion object { var active: RemoteIme? = null }
    private var editing = false
    private var editorId = 0L
    override fun onStartInput(info: EditorInfo?, restarting: Boolean) { super.onStartInput(info, restarting); active = this; editing = true; editorId++ }
    override fun onFinishInput() { editing = false; super.onFinishInput() }
    override fun onDestroy() { if (active === this) active = null; super.onDestroy() }
    override fun onCreateInputView(): View {
        val ui = Ui(this)
        return ui.column(16).apply {
            setBackgroundColor(ui.background)
            // Child buttons consume their own clicks; labels and padding open the app.
            setOnClickListener {
                startActivity(Intent(this@RemoteIme, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                ))
            }
            contentDescription = "打开 WiFi Remote Input"
            isFocusable = true
            addView(ui.label("REMOTE INPUT", 13f).apply { setTextColor(ui.accent); letterSpacing = 0.12f })
            addView(ui.label("与已配对 Mac 同步输入框 · 密码框受保护\n点击此面板打开 App", 12f, true))
            addView(ui.button("切换输入法") { (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).showInputMethodPicker() })
        }
    }
    fun snapshot(): org.json.JSONObject {
        fun failure(status: String) = org.json.JSONObject().put("status", status)
        if (getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) return failure("device_locked")
        if (!editing) return failure("no_editor")
        val info = currentInputEditorInfo ?: return failure("no_editor")
        // Check protection BEFORE asking the target app for any text.
        if (!EditorPolicy.allows(info.inputType)) return failure("password_blocked")
        val connection = currentInputConnection ?: return failure("no_editor")
        val extracted = try {
            connection.getExtractedText(android.view.inputmethod.ExtractedTextRequest().apply {
                hintMaxChars = 2049; hintMaxLines = 100
            }, 0)
        } catch (_: Exception) { null } ?: return failure("snapshot_unavailable")
        val text = extracted.text ?: return failure("snapshot_unavailable")
        if (extracted.startOffset != 0 || extracted.partialStartOffset != -1) return failure("snapshot_unavailable")
        if (text.length > 2048) return failure("editor_too_large")
        if (extracted.selectionStart !in 0..text.length || extracted.selectionEnd !in 0..text.length) return failure("snapshot_unavailable")
        if (!editing || currentInputEditorInfo !== info) return failure("no_editor")
        if (getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) return failure("device_locked")
        return org.json.JSONObject().put("status", "snapshot").put("editorId", editorId.toString())
            .put("text", text.toString()).put("selectionStart", extracted.selectionStart).put("selectionEnd", extracted.selectionEnd)
    }
    fun apply(type: String, value: String): String {
        if (getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) return "device_locked"
        if (!editing) return "no_editor"
        val info = currentInputEditorInfo ?: return "no_editor"
        if (!EditorPolicy.allows(info.inputType)) return "password_blocked"
        val connection = currentInputConnection ?: return "no_editor"
        if (type == "editor.edit") {
            val request = try { org.json.JSONObject(value) } catch (_: Exception) { return "invalid_message" }
            val current = snapshot()
            if (current.optString("status") != "snapshot") return current.optString("status")
            val oldText = current.getString("text")
            val start = minOf(current.getInt("selectionStart"), current.getInt("selectionEnd"))
            val end = maxOf(current.getInt("selectionStart"), current.getInt("selectionEnd"))
            val expected = Secrets.hash(oldText + "\u0000" + start + "," + end)
            if (request.optString("editorId") != current.getString("editorId") || !Secrets.equal(request.optString("expectedHash"), expected)) return "editor_conflict"
            val text = request.optString("text")
            val selectionStart = request.optString("selectionStart").toIntOrNull() ?: return "invalid_message"
            val selectionEnd = request.optString("selectionEnd").toIntOrNull() ?: return "invalid_message"
            if (text.length > 2048 || selectionStart !in 0..text.length || selectionEnd !in selectionStart..text.length) return "invalid_message"
            // Compare before mutation on the IME thread. Never overwrite a different field/stale snapshot.
            connection.beginBatchEdit()
            return try {
                var prefix = 0
                while (prefix < minOf(oldText.length, text.length) && oldText[prefix] == text[prefix]) prefix++
                if (prefix > 0 && prefix < oldText.length && Character.isHighSurrogate(oldText[prefix - 1]) && Character.isLowSurrogate(oldText[prefix])) prefix--
                var oldEnd = oldText.length; var newEnd = text.length
                while (oldEnd > prefix && newEnd > prefix && oldText[oldEnd - 1] == text[newEnd - 1]) { oldEnd--; newEnd-- }
                if (oldEnd > prefix && oldEnd < oldText.length && Character.isHighSurrogate(oldText[oldEnd - 1]) && Character.isLowSurrogate(oldText[oldEnd])) { oldEnd++; newEnd++ }
                val changed = text == oldText || (connection.setSelection(prefix, oldEnd) && connection.commitText(text.substring(prefix, newEnd), 1))
                if (changed && connection.setSelection(selectionStart, selectionEnd)) "ok" else "editor_rejected"
            } finally { connection.endBatchEdit() }
        }
        if (type == "key.press" && value == "LineBreak") return if (connection.commitText("\n", 1)) "ok" else "editor_rejected"
        if (type == "key.press" && value == "Send") return if (connection.performEditorAction(if (info.actionLabel != null) info.actionId else EditorInfo.IME_ACTION_SEND)) "ok" else "editor_rejected"
        val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
        val ok = if (type == "text.commit") connection.commitText(value, 1) else {
            if (value == "Enter" && (action == EditorInfo.IME_ACTION_SEND || info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION == 0) && (info.actionLabel != null || action !in setOf(EditorInfo.IME_ACTION_NONE, EditorInfo.IME_ACTION_UNSPECIFIED))) {
                connection.performEditorAction(if (info.actionLabel != null) info.actionId else action)
            } else {
                val code = when (value) { "Enter" -> KeyEvent.KEYCODE_ENTER; "Backspace" -> KeyEvent.KEYCODE_DEL; "ArrowLeft" -> KeyEvent.KEYCODE_DPAD_LEFT; "ArrowRight" -> KeyEvent.KEYCODE_DPAD_RIGHT; "ArrowUp" -> KeyEvent.KEYCODE_DPAD_UP; else -> KeyEvent.KEYCODE_DPAD_DOWN }
                val now = android.os.SystemClock.uptimeMillis()
                val flags = KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
                val down = connection.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0, 0, android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, 0, flags))
                val up = connection.sendKeyEvent(KeyEvent(now, android.os.SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, 0, android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, 0, flags))
                down && up
            }
        }
        return if (ok) "ok" else "editor_rejected"
    }
}
