// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import org.java_websocket.WebSocket
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.server.WebSocketServer
import org.java_websocket.server.CustomSSLWebSocketServerFactory
import org.java_websocket.drafts.Draft_6455
import org.java_websocket.extensions.DefaultExtension
import org.java_websocket.protocols.Protocol as WireProtocol
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext

class InputServer(address: InetSocketAddress, tls: SSLContext, private val pairing: Pairing, private val input: (String, String, () -> Boolean) -> String, private val status: (String) -> Unit, private val snapshot: (() -> Boolean) -> org.json.JSONObject = { org.json.JSONObject().put("status", "snapshot_unavailable") }, private val deviceName: () -> String = { "Android 手机" }, private val peersChanged: (Set<String>) -> Unit = {}) : WebSocketServer(address, 2, listOf(Draft_6455(listOf(DefaultExtension()), listOf(WireProtocol("")), 16_384))) {
    private val sessions = ConcurrentHashMap<WebSocket, Protocol>()
    private val deadlines = Executors.newSingleThreadScheduledExecutor()
    init {
        // TLS 1.3 is required: TLS 1.2-only reconnects stalled in URLSession/JVM interoperability tests.
        setWebSocketFactory(CustomSSLWebSocketServerFactory(tls, arrayOf("TLSv1.3"), null))
        connectionLostTimeout = 20
        isReuseAddr = true
    }
    override fun onOpen(conn: WebSocket, handshake: ClientHandshake) {
        if (handshake.resourceDescriptor != "/input" || sessions.size >= 4) { conn.close(1008, "rejected"); return }
        lateinit var protocol: Protocol
        protocol = Protocol(pairing, snapshot = { snapshot { protocol.credential?.let(pairing::authenticate) == true } }, deviceName = deviceName) { type, value -> input(type, value) { protocol.credential?.let(pairing::authenticate) == true } }
        sessions[conn] = protocol
        deadlines.schedule({ if (protocol.credential == null) conn.close(1008, "authentication_required") }, 10, TimeUnit.SECONDS)
    }
    override fun onMessage(conn: WebSocket, message: String) {
        val protocol = sessions[conn] ?: return
        val response = protocol.handle(message)
        conn.send(response.toString())
        publishPeers()
        if (response.optString("status") in setOf("authentication_failed", "unauthorized", "rate_limited", "too_large")) conn.close(1008, "rejected")
    }
    override fun onMessage(conn: WebSocket, message: java.nio.ByteBuffer) { conn.close(1003, "text_only") }
    override fun onClose(conn: WebSocket, code: Int, reason: String, remote: Boolean) { sessions.remove(conn); publishPeers() }
    override fun onError(conn: WebSocket?, ex: Exception) { if (conn == null) status("服务启动或网络失败，请停止后重试") }
    override fun onStart() { status("接收中 · TLS · 端口 8765") }
    private fun publishPeers() { peersChanged(sessions.values.mapNotNull { p -> p.credential?.takeIf(pairing::authenticate)?.let { pairing.peerName() } }.toSet()) }
    fun shutdown() { deadlines.shutdownNow(); stop(1000) }
}
