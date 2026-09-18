// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.app.Activity
import android.os.*
import android.content.Intent
import android.provider.Settings
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.*
import android.app.AlertDialog
import android.graphics.Bitmap
import android.graphics.Color
import android.view.View

class MainActivity : Activity() {
    private lateinit var serviceStatus: TextView
    private lateinit var status: TextView
    private lateinit var code: TextView
    private var qrDialog: AlertDialog? = null
    private var displayedCode: String? = null
    private var displayedAddress: String? = null
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable {
        override fun run() {
            serviceStatus.text = ReceiverState.status
            val addresses = LanAddresses.find(this@MainActivity)
            status.text = "${ReceiverState.status}\n\n手机地址：\n${addresses.joinToString("\n")}\n\n证书 SHA-256（手动配对备用）：\n${ReceiverState.identity?.fingerprint ?: "启动后显示"}"
            displayedCode?.let {
                if (!ReceiverState.pairing(this@MainActivity).isPending(it) || displayedAddress !in addresses) {
                    clearQr()
                    code.text = "二维码已使用或失效；需要时重新生成"
                }
            }
            handler.postDelayed(this, 1500)
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 48, 32, 32) }
        fun button(label: String, action: () -> Unit) { layout.addView(Button(this).apply { text = label; setOnClickListener { action() } }) }
        layout.addView(TextView(this).apply { text = "WiFi Remote Input"; textSize = 24f })
        layout.addView(TextView(this).apply { text = "两端连接同一 Wi-Fi。启用并选中此输入法后，在普通输入框接收中文。密码框始终拒绝。" })
        button("1. 启用输入法") { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }
        button("2. 选择输入法") { getSystemService(InputMethodManager::class.java).showInputMethodPicker() }
        button("3. 启动接收") {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
            startForegroundService(Intent(this, ReceiverService::class.java))
        }
        serviceStatus = TextView(this).apply { text = ReceiverState.status }; layout.addView(serviceStatus)
        status = TextView(this).apply { setTextIsSelectable(true); textSize = 14f }; layout.addView(status)
        status.visibility = View.GONE
        button("显示 / 隐藏手动配对信息") { status.visibility = if (status.visibility == View.GONE) View.VISIBLE else View.GONE }
        code = TextView(this).apply { textSize = 22f }; layout.addView(code)
        button("4. 显示配对二维码") { showPairingQr() }
        button("撤销已配对 Mac") { ReceiverState.pairing(this).revoke(); clearQr(); code.text = "已撤销全部配对" }
        val stopIntent = Intent(this, ReceiverService::class.java)
        button("停止接收") { stopService(stopIntent); clearQr(); code.text = "" }
        layout.addView(EditText(this).apply { hint = "普通测试框：从 Mac 发送 你好，小米 13 👋"; inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE; minLines = 3 })
        layout.addView(EditText(this).apply { hint = "密码测试框：远程输入应被拒绝"; inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD })
        setContentView(ScrollView(this).apply { addView(layout) })
    }
    private fun clearQr() {
        qrDialog?.dismiss(); qrDialog = null
        displayedCode = null; displayedAddress = null
    }
    private fun showPairingQr() {
        val identity = ReceiverState.identity
        val addresses = LanAddresses.find(this)
        if (identity == null || !ReceiverState.status.startsWith("接收中")) { code.text = "请先启动接收，稍候再生成二维码"; return }
        if (addresses.isEmpty()) { code.text = "未找到局域网地址，请连接 Wi-Fi 后重试"; return }
        fun show(address: String) {
            clearQr()
            val pairingCode = ReceiverState.pairing(this).begin()
            displayedCode = pairingCode; displayedAddress = address
            val matrix = PairingQr.matrix(address, identity.fingerprint, pairingCode)
            val pixels = IntArray(matrix.width * matrix.height) { i -> if (matrix[i % matrix.width, i / matrix.width]) Color.BLACK else Color.WHITE }
            val bitmap = Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
            val content = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL; setPadding(24, 12, 24, 12)
                addView(TextView(context).apply { text = "在 Mac 点击「扫码配对」，将此二维码对准 Mac 摄像头。\n两分钟内有效，使用一次即失效。" })
                val size = minOf(resources.displayMetrics.widthPixels - 100, (360 * resources.displayMetrics.density).toInt())
                addView(ImageView(context).apply { setImageBitmap(bitmap); contentDescription = "一次性配对二维码" }, LinearLayout.LayoutParams(size, size).apply { gravity = android.view.Gravity.CENTER_HORIZONTAL })
                addView(TextView(context).apply { text = "手动配对备用码：$pairingCode\n地址：$address" })
            }
            val dialog = AlertDialog.Builder(this).setTitle("扫码配对").setView(content).setNegativeButton("关闭", null)
            if (addresses.size > 1) dialog.setNeutralButton("更换地址") { _, _ ->
                AlertDialog.Builder(this).setTitle("选择其他局域网地址")
                    .setItems(addresses.toTypedArray()) { _, index -> show(addresses[index]) }.show()
            }
            qrDialog = dialog.create().also {
                it.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                it.show()
                it.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            code.text = "二维码已生成；在 Mac 扫描即可连接"
        }
        show(addresses.first())
    }
    override fun onResume() { super.onResume(); handler.post(refresh) }
    override fun onPause() { handler.removeCallbacks(refresh); super.onPause() }
    override fun onDestroy() { clearQr(); handler.removeCallbacksAndMessages(null); super.onDestroy() }
}
