// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.app.*
import android.content.*
import android.os.*
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object ReceiverState {
    @Volatile var connectedPeers: Set<String> = emptySet()
    fun deviceName(context: Context): String = DeviceNames.resolve(context)
    @Volatile var status = "已停止"
    @Volatile var identity: Identity? = null
    private var pairing: Pairing? = null
    // Persist before acknowledging pairing or revocation. Asynchronous apply() is not sufficient.
    @android.annotation.SuppressLint("ApplySharedPref")
    @Synchronized fun pairing(context: Context): Pairing {
        return pairing ?: context.getSharedPreferences("devices", Context.MODE_PRIVATE).let { prefs ->
            Pairing({ prefs.getString("tokenHash", null) }, { value -> check(prefs.edit().apply { if (value == null) remove("tokenHash") else putString("tokenHash", value) }.commit()); Unit }).also { pairing = it }
        }
    }
}

class ReceiverService : Service() {
    private var server: InputServer? = null
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var stopped = false
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("receiver", "局域网输入接收", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        startForeground(1, Notification.Builder(this, "receiver").setContentTitle("WiFi Remote Input").setContentText("局域网接收已开启；可在应用内停止").setSmallIcon(R.drawable.ic_keyboard).setContentIntent(open).build())
        ReceiverState.status = "正在准备加密服务…"
        Thread {
            try {
                val identity = Identity(noBackupFilesDir)
                ReceiverState.identity = identity
                val endpoint = InputServer(InetSocketAddress(8765), identity.tls, ReceiverState.pairing(this), { type, value, authorized ->
                    val done = CountDownLatch(1)
                    var result = "no_editor"
                    val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
                    main.post { if (!cancelled.get() && !stopped) result = if (authorized()) RemoteIme.active?.apply(type, value) ?: "no_editor" else "unauthorized"; done.countDown() }
                    if (done.await(2, TimeUnit.SECONDS)) result else { cancelled.set(true); "editor_timeout" }
                }, { ReceiverState.status = it }, snapshot = { authorized ->
                    val done = CountDownLatch(1)
                    val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
                    var result = org.json.JSONObject().put("status", "no_editor")
                    main.post {
                        try {
                            if (!cancelled.get() && !stopped) {
                                result = if (authorized()) RemoteIme.active?.snapshot() ?: org.json.JSONObject().put("status", "no_editor")
                                else org.json.JSONObject().put("status", "unauthorized")
                            }
                        } finally { done.countDown() }
                    }
                    if (!done.await(2, TimeUnit.SECONDS)) {
                        cancelled.set(true); org.json.JSONObject().put("status", "editor_timeout")
                    } else if (stopped || !authorized()) org.json.JSONObject().put("status", "unauthorized")
                    else result
                }, deviceName = { ReceiverState.deviceName(this) }, peersChanged = { ReceiverState.connectedPeers = it })
                synchronized(this) { if (stopped) endpoint.shutdown() else { server = endpoint; endpoint.start() } }
            } catch (_: Exception) { ReceiverState.status = "无法启动接收服务"; stopSelf() }
        }.start()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY
    override fun onDestroy() {
        stopped = true
        ReceiverState.pairing(this).cancel()
        synchronized(this) { server?.let { Thread { it.shutdown() }.start() }; server = null }
        ReceiverState.connectedPeers = emptySet()
        ReceiverState.status = "已停止"
        super.onDestroy()
    }
}
