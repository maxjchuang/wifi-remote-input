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
