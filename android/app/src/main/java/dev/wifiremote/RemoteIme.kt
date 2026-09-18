// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

open class RemoteIme : InputMethodService() {
    companion object { var active: RemoteIme? = null }
    private var editing = false
    override fun onStartInput(info: EditorInfo?, restarting: Boolean) { super.onStartInput(info, restarting); active = this; editing = true }
    override fun onFinishInput() { editing = false; super.onFinishInput() }
    override fun onDestroy() { if (active === this) active = null; super.onDestroy() }
    override fun onCreateInputView(): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(20, 16, 20, 16)
        addView(TextView(context).apply { text = "WiFi Remote Input · 仅接收已配对 Mac\n密码框禁止远程输入" })
        addView(Button(context).apply { text = "切换输入法"; setOnClickListener { (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).showInputMethodPicker() } })
    }
    fun apply(type: String, value: String): String {
        if (getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) return "device_locked"
        if (!editing) return "no_editor"
        val info = currentInputEditorInfo ?: return "no_editor"
        if (!EditorPolicy.allows(info.inputType)) return "password_blocked"
        val connection = currentInputConnection ?: return "no_editor"
        val ok = if (type == "text.commit") connection.commitText(value, 1) else {
            if (value == "Enter" && info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION == 0 && info.imeOptions and EditorInfo.IME_MASK_ACTION !in setOf(EditorInfo.IME_ACTION_NONE, EditorInfo.IME_ACTION_UNSPECIFIED)) {
                connection.performEditorAction(info.imeOptions and EditorInfo.IME_MASK_ACTION)
            } else {
                val code = when (value) { "Enter" -> KeyEvent.KEYCODE_ENTER; "Backspace" -> KeyEvent.KEYCODE_DEL; "ArrowLeft" -> KeyEvent.KEYCODE_DPAD_LEFT; "ArrowRight" -> KeyEvent.KEYCODE_DPAD_RIGHT; "ArrowUp" -> KeyEvent.KEYCODE_DPAD_UP; else -> KeyEvent.KEYCODE_DPAD_DOWN }
                val down = connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                val up = connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
                down && up
            }
        }
        return if (ok) "ok" else "editor_rejected"
    }
}
