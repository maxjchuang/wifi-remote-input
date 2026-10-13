// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.view.WindowManager
import android.widget.*

class MaintenanceActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var status: TextView
    private lateinit var logs: TextView
    private lateinit var install: Button
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable { override fun run() { update(); handler.postDelayed(this, 1500) } }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        ui = Ui(this)
        val column = ui.column(24)
        setContentView(ScrollView(this).apply {
            setBackgroundColor(ui.background); addView(column)
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                insets
            }
        })
        column.addView(ui.button("返回") { finish() })
        column.addView(ui.label("诊断与更新", 24f))
        val card = ui.card()
        card.addView(ui.label("从 Mac 接收更新 · 调试功能", 18f))
        card.addView(ui.label("先开启接收并连接 Mac，再允许推送。在 Mac 点击「推送手机更新」选择 APK。仅接受同一应用、相同签名且版本更高的安装包；不会自动安装，也不访问 GitHub。", 13f, true))
        status = ui.label(UpdateInbox.status); card.addView(status)
        card.addView(ui.button("允许接收更新（10 分钟）") { UpdateInbox.allow(this); update() })
        install = ui.button("安装已收到的更新") {
            if (!UpdateInbox.file(this).exists()) return@button
            if (!UpdateInbox.validApk(this, UpdateInbox.file(this))) {
                UpdateInbox.discard(this); update()
                Toast.makeText(this, "此安装包不再适用，请重新推送更高版本", Toast.LENGTH_LONG).show()
                return@button
            }
            if (!packageManager.canRequestPackageInstalls()) {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                Toast.makeText(this, "允许此来源后，返回并再次点击安装", Toast.LENGTH_LONG).show()
            } else {
                try { startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(UpdateProvider.uri(this), "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)) }
                catch (_: android.content.ActivityNotFoundException) { Toast.makeText(this, "系统未提供安装程序", Toast.LENGTH_LONG).show() }
            }
        }; card.addView(install)
        card.addView(ui.button("取消接收／删除安装包") { UpdateInbox.discard(this); update() })
        column.addView(card)
        column.addView(ui.label("本机诊断日志", 18f))
        column.addView(ui.label("最多保留 300 条事件，默认开启，可随时关闭或清空。仅记录连接、认证、控制和错误状态；不记录文字、剪贴板、设备名称、地址、鼠标轨迹、配对码或密钥。连接已配对 Mac 后自动同步至电脑 /tmp/wifi-remote-input/，用于诊断分析；关闭记录后停止同步。", 13f, true))
        column.addView(Switch(this).apply {
            text = "记录诊断事件"; isChecked = DiagnosticLog.enabled(this@MaintenanceActivity)
            setOnCheckedChangeListener { _, enabled -> DiagnosticLog.setEnabled(this@MaintenanceActivity, enabled) }
        })
        column.addView(ui.button("导出日志…") {
            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).setType("text/plain").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, "wifi-remote-input-diagnostics.txt"), 1)
        })
        column.addView(ui.button("清空日志") { DiagnosticLog.clear(this); update() })
        logs = ui.label("", 12f, true).apply { typeface = android.graphics.Typeface.MONOSPACE; setTextIsSelectable(true) }
        column.addView(logs); update()
    }
    private fun update() {
        status.text = UpdateInbox.status; install.isEnabled = UpdateInbox.file(this).exists()
        val text = DiagnosticLog.read(this)
        if (logs.text.toString() != text) logs.text = text
    }
    @Deprecated("Legacy activity result supported by this Activity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1 && resultCode == RESULT_OK) data?.data?.let { uri ->
            try { contentResolver.openOutputStream(uri, "wt")!!.bufferedWriter().use { it.write(DiagnosticLog.read(this)) }; Toast.makeText(this, "日志已导出", Toast.LENGTH_SHORT).show() }
            catch (_: Exception) { Toast.makeText(this, "无法导出，请重试", Toast.LENGTH_SHORT).show() }
        }
    }
    override fun onResume() { super.onResume(); handler.post(refresh) }
    override fun onPause() { handler.removeCallbacks(refresh); super.onPause() }
}
