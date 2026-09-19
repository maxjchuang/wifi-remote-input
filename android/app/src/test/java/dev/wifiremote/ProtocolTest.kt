// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProtocolTest {
    private var hash: String? = null
    private var time = 1000L
    private val pairing = Pairing({ hash }, { hash = it }, { time })
    private val received = mutableListOf<Pair<String, String>>()
    private val protocol = Protocol(pairing) { type, value -> received.add(type to value); "ok" }
    private fun message(type: String, key: String, value: String) = JSONObject().put("version", 1).put("type", type).put("payload", JSONObject().put(key, value)).toString()
    private fun send(type: String, key: String, value: String) = protocol.handle(message(type, key, value))
    private fun pair(): String = send("pair", "code", pairing.begin()).getString("token")
    @Test fun editorEditsRequireAuthenticationAndBoundedStringPayloads() {
        val payload = JSONObject().put("editorId", "1").put("expectedHash", "a".repeat(64)).put("text", "你好")
            .put("selectionStart", "2").put("selectionEnd", "2")
        fun call() = protocol.handle(JSONObject().put("version", 1).put("type", "editor.edit").put("payload", payload).toString()).getString("status")
        assertEquals("unauthorized", call()); assertTrue(received.isEmpty())
        pair(); assertEquals("ok", call()); assertEquals("editor.edit", received.single().first)
        payload.put("selectionStart", "-1"); assertEquals("invalid_message", call())
        payload.put("selectionStart", "0").put("text", "x".repeat(2049)); assertEquals("invalid_message", call())
        payload.put("text", "你好").put("expectedHash", "bad"); assertEquals("invalid_message", call())
        assertEquals(1, received.size)
    }
    @Test fun namesAreAuthenticatedPersistentAndClearedOnRevocation() {
        val p = Protocol(pairing, deviceName = { "小米 13" }) { _, _ -> "ok" }
        fun request(type: String, payload: JSONObject) = p.handle(JSONObject().put("version", 1).put("type", type).put("payload", payload).toString())
        val rejected = request("auth", JSONObject().put("token", "0".repeat(64)).put("deviceName", "冒名电脑"))
        assertFalse(rejected.has("deviceName")); assertNull(pairing.peerName())
        val result = request("pair", JSONObject().put("code", pairing.begin()).put("deviceName", "工作 Mac"))
        assertEquals("小米 13", result.getString("deviceName")); assertEquals("工作 Mac", pairing.peerName())
        val token = result.getString("token")
        val restored = Pairing({ hash }, { hash = it })
        assertTrue(restored.authenticate(token)); assertEquals("工作 Mac", restored.peerName())
        request("auth", JSONObject().put("token", "wrong").put("deviceName", "冒名电脑"))
        assertEquals("工作 Mac", restored.peerName())
        request("auth", JSONObject().put("token", token).put("deviceName", "新名称"))
        assertEquals("新名称", restored.peerName())
        restored.revoke(); assertNull(restored.peerName()); assertFalse(restored.authenticate(token))
    }
    @Test fun legacyHashMigratesOnlyAfterSuccessfulAuthentication() {
        val token = Secrets.token(); hash = Secrets.hash(token)
        assertTrue(pairing.authenticate(token)); assertEquals("未命名 Mac", pairing.peerName())
        pairing.renameAuthenticated("wrong", "冒名"); assertEquals(Secrets.hash(token), hash)
        pairing.renameAuthenticated(token, "MacBook"); assertTrue(pairing.authenticate(token)); assertEquals("MacBook", pairing.peerName())
    }
    @Test fun invalidNameCannotConsumeCodeOrChangeSavedName() {
        val code = pairing.begin()
        for (name in listOf("", "x".repeat(81), "bad\nname", "bad\u202ename")) {
            val raw = JSONObject().put("version", 1).put("type", "pair").put("payload", JSONObject().put("code", code).put("deviceName", name)).toString()
            assertEquals("invalid_message", protocol.handle(raw).getString("status"))
            assertNull(pairing.peerName()); assertTrue(pairing.isPending(code))
        }
    }
    @Test fun snapshotsRequireLiveAuthenticationAndEmptyPayload() {
        var reads = 0
        val p = Protocol(pairing, snapshot = { reads++; JSONObject().put("status", "snapshot").put("text", "existing") }) { _, _ -> "ok" }
        val request = """{"version":1,"type":"editor.snapshot","payload":{}}"""
        assertEquals("unauthorized", p.handle(request).getString("status")); assertEquals(0, reads)
        p.handle(message("pair", "code", pairing.begin()))
        assertEquals("snapshot", p.handle(request).getString("status")); assertEquals(1, reads)
        assertEquals("invalid_message", p.handle(message("editor.snapshot", "text", "unexpected")).getString("status")); assertEquals(1, reads)
        pairing.revoke()
        val denied = p.handle(request)
        assertEquals("unauthorized", denied.getString("status")); assertFalse(denied.has("text")); assertEquals(1, reads)
    }
    @Test fun qrVisibilityTracksConsumptionExpiryAndRevocation() {
        val first = pairing.begin(); assertTrue(pairing.isPending(first))
        val second = pairing.begin(); assertFalse(pairing.isPending(first)); assertTrue(pairing.isPending(second))
        pairing.pair(second); assertFalse(pairing.isPending(second))
        val third = pairing.begin(); time += 120_000; assertFalse(pairing.isPending(third))
        val fourth = pairing.begin(); pairing.revoke(); assertFalse(pairing.isPending(fourth))
    }
    @Test fun unpairedCannotCommitOrPress() {
        assertEquals("unauthorized", send("text.commit", "text", "秘密").getString("status"))
        assertEquals("unauthorized", send("key.press", "key", "Enter").getString("status"))
        assertTrue(received.isEmpty())
    }
    @Test fun pairingReconnectAndUnicode() {
        val token = pair()
        assertNotEquals(token, hash)
        val other = Protocol(pairing) { t, v -> received.add(t to v); "ok" }
        assertEquals("authenticated", other.handle(message("auth", "token", token)).getString("status"))
        val unicode = "你好，小米 13 👋 café e\u0301\n下一行"
        assertEquals("ok", other.handle(message("text.commit", "text", unicode)).getString("status"))
        assertEquals(unicode, received.single().second)
    }
    @Test fun codeSingleUseAndExpiry() {
        val code = pairing.begin()
        assertNotNull(pairing.pair(code))
        assertNull(pairing.pair(code))
        val next = pairing.begin(); time += 120_000
        assertNull(pairing.pair(next))
    }
    @Test fun attemptsAreGlobalAcrossConnections() {
        val code = pairing.begin()
        repeat(5) { Protocol(pairing) { _, _ -> "ok" }.handle(message("pair", "code", "invalid")) }
        assertNull(pairing.pair(code))
    }
    @Test fun authFailureClearsSessionAndRevocationAppliesImmediately() {
        val token = pair()
        assertEquals("authentication_failed", send("auth", "token", "0".repeat(64)).getString("status"))
        assertEquals("unauthorized", send("text.commit", "text", "secret").getString("status"))
        assertEquals("authenticated", send("auth", "token", token).getString("status"))
        pairing.revoke()
        assertEquals("unauthorized", send("text.commit", "text", "secret").getString("status"))
        assertTrue(received.isEmpty())
    }
    @Test fun rotatingPairingRevokesOldToken() { val old = pair(); pair(); assertFalse(pairing.authenticate(old)) }
    @Test fun parserAndBoundsDoNotEchoPayload() {
        pair()
        for (raw in listOf("not json secret", "{}", "[]", "{\"version\":2}", message("unknown", "text", "secret"), message("key.press", "key", "DeleteAll"), message("text.commit", "text", "a".repeat(4097)), "a".repeat(16385))) {
            val result = protocol.handle(raw)
            assertNotEquals("ok", result.getString("status"))
            assertFalse(result.toString().contains("secret"))
        }
        assertTrue(received.isEmpty())
    }
    @Test fun keysAreAllowlisted() { pair(); listOf("Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown").forEach { assertEquals("ok", send("key.press", "key", it).getString("status")) }; assertEquals(6, received.size) }
    @Test fun passwordVariationsAndNullInputBlocked() {
        for (type in listOf(0, 1 or 128, 1 or 144, 1 or 224, 2 or 16, 1 or 128 or 0x20000)) assertFalse(EditorPolicy.allows(type))
        for (type in listOf(1, 1 or 0x20000, 2, 3, 1 or 32)) assertTrue(EditorPolicy.allows(type))
    }
    @Test fun rateLimitedBeforeInput() { pair(); repeat(39) { send("key.press", "key", "Enter") }; assertEquals("rate_limited", send("key.press", "key", "Enter").getString("status")); assertEquals(39, received.size) }
}
