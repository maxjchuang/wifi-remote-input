// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper

/** Discovery is public routing information, never a credential or an input endpoint. */
internal class ServiceAdvertisement(context: Context, private val fingerprint: String) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.RegistrationListener? = null
    private var closed = false
    companion object {
        fun info(fingerprint: String) = NsdServiceInfo().apply {
            serviceName = "WiFi Remote Input-${fingerprint.take(12)}"
            serviceType = "_wri-input._tcp."
            port = 8765
            setAttribute("v", "1")
            setAttribute("id", fingerprint)
        }
    }
    fun start() {
        if (closed || listener != null) return
        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                main.post { if (listener === this) { listener = null; retry() } }
            }
        }
        listener = registration
        try { manager.registerService(info(fingerprint), NsdManager.PROTOCOL_DNS_SD, registration) }
        catch (_: RuntimeException) { listener = null; retry() }
    }
    private fun retry() { if (!closed) main.postDelayed({ start() }, 30_000) }
    fun close() {
        closed = true; main.removeCallbacksAndMessages(null)
        listener?.let { try { manager.unregisterService(it) } catch (_: RuntimeException) { } }
        listener = null
    }
}
