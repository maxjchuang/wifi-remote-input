// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.*
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.*

class MainActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var content: LinearLayout
    private var displayedCode: String? = null
    private var displayedAddress: String? = null
    private var notice = ""
    private var lastState = ""
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable {
        override fun run() { render(); handler.postDelayed(this, 1500) }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        ui = Ui(this)
        content = ui.column(24)
        val scroll = ScrollView(this).apply {
            setBackgroundColor(ui.background); isFillViewport = true; addView(content)
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                insets
            }
        }
        setContentView(scroll)
        render()
    }
    private fun render(force: Boolean = false) {
        val pairing = ReceiverState.pairing(this)
        val peer = pairing.peerName()
        val receiving = ReceiverState.status.startsWith("接收中")
        val preparing = ReceiverState.status.startsWith("正在准备")
        val connected = receiving && peer != null && peer in ReceiverState.connectedPeers
        val manager = getSystemService(InputMethodManager::class.java)
        val enabled = manager.enabledInputMethodList.any { it.packageName == packageName }
        val selected = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)?.startsWith("$packageName/") == true
        displayedCode?.let {
            if (!pairing.isPending(it) || !receiving || displayedAddress !in LanAddresses.find(this)) {
                clearQr(); notice = if (connected) "配对成功" else "二维码已使用或失效，需要时请重新生成"
            }
        }
        val name = ReceiverState.deviceName(this)
        val state = listOf(PhoneControlService.active != null, peer, receiving, preparing, connected, enabled, selected, name, displayedCode, notice, ReceiverState.status).joinToString("|")
        if (!force && state == lastState) return
        lastState = state
        content.removeAllViews()
        content.addView(ui.label("REMOTE INPUT", 13f, true).apply { letterSpacing = .14f })
        content.addView(ui.orbit(connected))
        fun centered(text: String, size: Float = 14f, muted: Boolean = false) = ui.label(text, size, muted).apply { gravity = Gravity.CENTER }
        content.addView(centered(if (receiving) "●  接收已开启" else if (preparing) "正在准备连接…" else "接收已暂停", 13f).apply { setTextColor(ui.accent) })
        content.addView(centered(if (connected) "键盘已接入" else if (peer != null) "等待电脑连接" else "连接你的 Mac", 26f).apply { setTypeface(typeface, android.graphics.Typeface.BOLD) })
        content.addView(centered("${peer ?: "你的 Mac"}  →  $name", 15f, true))
        content.addView(centered(if (connected && selected) "打开任意普通输入框，即可从 Mac 输入" else "手机与 Mac 请连接同一 Wi-Fi", 13f, true))
        space(24)
        if (displayedCode != null) {
            val card = ui.card()
            card.addView(centered("在 Mac 打开「扫码配对」", 18f))
            card.addView(centered("将二维码对准 Mac 摄像头 · 两分钟内有效", 12f, true))
            val matrix = PairingQr.matrix(displayedAddress!!, ReceiverState.identity!!.fingerprint, displayedCode!!)
            val pixels = IntArray(matrix.width * matrix.height) { i -> if (matrix[i % matrix.width, i / matrix.width]) Color.BLACK else Color.WHITE }
            val bitmap = Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
            val size = minOf(resources.displayMetrics.widthPixels - ui.dp(96), ui.dp(280)).coerceAtLeast(ui.dp(100))
            card.addView(ImageView(this).apply { setImageBitmap(bitmap); contentDescription = "一次性配对二维码" }, LinearLayout.LayoutParams(size, size).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = ui.dp(16); bottomMargin = ui.dp(12) })
            card.addView(centered("配对后，Mac 可输入并同步当前普通输入框的内容。密码框始终受保护。", 12f, true))
            card.addView(ui.button("收起二维码") { clearQr(); render(true) })
            content.addView(card)
        }
        val setup = ui.card()
        setup.addView(ui.label("输入法", 12f, true))
        setup.addView(ui.label(if (selected) "已就绪  ✓" else if (enabled) "还需选择 Remote Input" else "首次使用需启用输入法", 17f).apply { if (selected) setTextColor(ui.accent) })
        if (!selected) setup.addView(ui.button(if (enabled) "选择输入法" else "启用输入法") {
            if (enabled) manager.showInputMethodPicker() else startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        })
        content.addView(setup)
        val control = ui.card()
        control.addView(ui.label("手机控制 · 可选", 12f, true))
        control.addView(ui.label(if (PhoneControlService.active != null) "辅助功能已开启 ✓" else "用 Mac 鼠标和键盘操作手机", 17f))
        control.addView(ui.label("鼠标移动指针，左键点击、右键返回。仅操作当前手机；无需开启也能输入文字。", 12f, true))
        control.addView(ui.button(if (PhoneControlService.active != null) "管理辅助功能" else "开启辅助功能") { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) })
        if (PhoneControlService.active != null) control.addView(ui.button("暂停手机控制") { PhoneControlService.active?.stop() })
        content.addView(control)
        if (notice.isNotEmpty()) content.addView(centered(notice, 13f, true))
        val primary = when {
            preparing -> "正在开启…"
            !receiving -> "开启接收"
            peer == null && displayedCode == null -> "显示配对二维码"
            else -> "暂停接收"
        }
        content.addView(ui.button(primary, true) {
            when {
                !receiving -> startReceiver()
                peer == null && displayedCode == null -> showPairingQr()
                else -> { stopService(Intent(this, ReceiverService::class.java)); clearQr(); render(true) }
            }
        }.apply { isEnabled = !preparing })
        if (receiving && displayedCode == null && peer != null) content.addView(ui.button("连接另一台 Mac") { showPairingQr() })
        if (receiving && peer == null && displayedCode == null) content.addView(ui.button("暂停接收") { stopService(Intent(this, ReceiverService::class.java)); clearQr(); render(true) })
        space(24)
        val deviceRow = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        deviceRow.addView(ui.label("此手机\n$name", 13f, true), LinearLayout.LayoutParams(0, -2, 1f))
        deviceRow.addView(ui.button("改名") { renamePhone() }.apply { layoutParams = LinearLayout.LayoutParams(ui.dp(72), ui.dp(48)) })
        content.addView(deviceRow)
        if (peer != null) content.addView(ui.button("忘记 $peer") {
            AlertDialog.Builder(this).setTitle("忘记这台电脑？").setMessage("$peer 将无法继续输入，需要重新扫码配对。")
                .setNegativeButton("取消", null).setPositiveButton("忘记") { _, _ -> pairing.revoke(); clearQr(); notice = "已忘记电脑"; render(true) }.show()
        })
        space(20)
        content.addView(centered("本地加密连接 · 密码框保护", 12f, true))
    }
    private fun space(height: Int) { content.addView(View(this), LinearLayout.LayoutParams(1, ui.dp(height))) }
    private fun startReceiver() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        notice = ""; startForegroundService(Intent(this, ReceiverService::class.java))
    }
    private fun renamePhone() {
        val field = EditText(this).apply { setText(ReceiverState.deviceName(this@MainActivity)); filters = arrayOf(android.text.InputFilter.LengthFilter(80)) }
        AlertDialog.Builder(this).setTitle("手机名称").setView(field).setNegativeButton("取消", null)
            .setNeutralButton("自动命名") { _, _ -> getSharedPreferences("devices", MODE_PRIVATE).edit().remove("deviceName").apply(); render(true) }
            .setPositiveButton("保存") { _, _ ->
                val name = field.text.toString().trim().filterNot { it.isISOControl() || it in '\u202a'..'\u202e' || it in '\u2066'..'\u2069' }
                if (name.isNotEmpty()) getSharedPreferences("devices", MODE_PRIVATE).edit().putString("deviceName", name).apply()
                render(true)
            }.show()
    }
    private fun clearQr() {
        if (displayedCode != null) ReceiverState.pairing(this).cancel()
        displayedCode = null; displayedAddress = null
    }
    private fun showPairingQr() {
        if (ReceiverState.identity == null || !ReceiverState.status.startsWith("接收中")) { notice = "请先开启接收"; render(true); return }
        val addresses = LanAddresses.find(this)
        if (addresses.isEmpty()) { notice = "未找到 Wi-Fi 网络，请连接后重试"; render(true); return }
        clearQr(); displayedAddress = addresses.first(); displayedCode = ReceiverState.pairing(this).begin(); notice = ""; render(true)
    }
    override fun onResume() { super.onResume(); handler.post(refresh) }
    override fun onPause() { handler.removeCallbacks(refresh); super.onPause() }
    override fun onDestroy() { clearQr(); handler.removeCallbacksAndMessages(null); super.onDestroy() }
}
