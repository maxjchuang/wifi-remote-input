// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom

object Secrets {
    private val random = SecureRandom()
    fun token(): String = ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it) }
    fun code(): String = "%08d".format(java.util.Locale.US, random.nextInt(100_000_000))
    fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    fun equal(a: String, b: String) = MessageDigest.isEqual(a.toByteArray(), b.toByteArray())
}

class Pairing(private val load: () -> String?, private val save: (String?) -> Unit, private val clock: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private var code: String? = null
    private var expires = 0L
    private var attempts = 0
    @Synchronized fun begin(): String { return Secrets.code().also { code = it; expires = clock() + 120_000; attempts = 0 } }
    @Synchronized fun pair(candidate: String, name: String = "未命名 Mac"): String? {
        val expected = code ?: return null
        if (clock() >= expires || attempts >= 5) { code = null; return null }
        attempts++
        if (!Secrets.equal(expected, candidate)) return null
        code = null
        return Secrets.token().also { save(JSONObject().put("hash", Secrets.hash(it)).put("name", name).toString()) }
    }
    @Synchronized fun authenticate(token: String): Boolean = token.length == 64 && load()?.let { Secrets.equal(storedHash(it), Secrets.hash(token)) } == true
    private fun storedHash(value: String): String = if (value.startsWith("{")) JSONObject(value).getString("hash") else value
    @Synchronized fun peerName(): String? = load()?.let { if (it.startsWith("{")) JSONObject(it).optString("name", "未命名 Mac") else "未命名 Mac" }
    @Synchronized fun renameAuthenticated(token: String, name: String) {
        if (authenticate(token)) save(JSONObject().put("hash", Secrets.hash(token)).put("name", name).toString())
    }
    @Synchronized fun isPending(candidate: String): Boolean = code == candidate && clock() < expires && attempts < 5
    @Synchronized fun cancel() { code = null }
    @Synchronized fun revoke() { code = null; save(null) }
}

object EditorPolicy {
    fun allows(inputType: Int): Boolean {
        val cls = inputType and 15
        val variation = inputType and 4080
        return cls in 1..4 && !(cls == 1 && variation in setOf(128, 144, 224)) && !(cls == 2 && variation == 16)
    }
}

class Protocol(private val pairing: Pairing, private val snapshot: () -> JSONObject = { JSONObject().put("status", "snapshot_unavailable") }, private val deviceName: () -> String = { "Android 手机" }, private val input: (String, String) -> String) {
    @Volatile var credential: String? = null
        private set
    private var count = 0
    private var window = System.nanoTime()
    fun handle(raw: String): JSONObject {
        fun response(status: String) = JSONObject().put("version", 1).put("type", "result").put("status", status)
        if (raw.toByteArray().size > 16_384) return response("too_large")
        val now = System.nanoTime()
        if (now - window >= 1_000_000_000) { window = now; count = 0 }
        if (++count > 40) return response("rate_limited")
        return try {
            val m = JSONObject(raw)
            if (m.get("version") != 1) return response("unsupported_version")
            val type = m.get("type") as? String ?: return response("invalid_message")
            val payload = m.getJSONObject("payload")
            fun string(key: String): String = payload.get(key) as? String ?: throw IllegalArgumentException()
            fun peerName(): String? {
                if (!payload.has("deviceName")) return null
                val name = string("deviceName").trim()
                require(name.isNotEmpty() && name.length <= 80 && name.none { it.isISOControl() || it in '\u202a'..'\u202e' || it in '\u2066'..'\u2069' })
                return name
            }
            when (type) {
                "pair" -> {
                    credential = null
                    val name = peerName() ?: "未命名 Mac"
                    val token = pairing.pair(string("code"), name) ?: return response("authentication_failed")
                    credential = token
                    response("paired").put("token", token).put("deviceName", deviceName())
                }
                "auth" -> {
                    credential = null
                    val name = peerName()
                    val token = string("token")
                    if (!pairing.authenticate(token)) response("authentication_failed")
                    else { if (name != null) pairing.renameAuthenticated(token, name); credential = token; response("authenticated").put("deviceName", deviceName()) }
                }
                else -> {
                    if (credential?.let(pairing::authenticate) != true) return response("unauthorized")
                    when (type) {
                        "control.action" -> {
                            val action = string("action")
                            if (action in setOf("pointer_move", "pointer_tap", "pointer_down", "pointer_drag", "pointer_up")) {
                                val x = string("x").toIntOrNull(); val y = string("y").toIntOrNull()
                                if (payload.length() != 3 || x == null || y == null || x !in 0..10000 || y !in 0..10000) response("invalid_action")
                                else response(input(type, payload.toString()))
                            } else if (payload.length() != 1 || action !in setOf("pointer_start", "start", "stop", "ping", "back", "home", "recents", "next", "previous", "left", "right", "up", "down", "click", "long_click", "scroll_up", "scroll_down")) response("invalid_action")
                            else response(input(type, action))
                        }
                        "text.commit" -> {
                            val text = string("text")
                            if (text.isEmpty() || text.length > 4096) response("invalid_text") else response(input(type, text))
                        }
                        "key.press" -> {
                            val key = string("key")
                            if (key !in setOf("Enter", "Send", "LineBreak", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown")) response("invalid_key") else response(input(type, key))
                        }
                        "editor.edit" -> {
                            val id = string("editorId")
                            val hash = string("expectedHash")
                            val text = string("text")
                            val start = string("selectionStart").toIntOrNull()
                            val end = string("selectionEnd").toIntOrNull()
                            if (payload.length() != 5 || id.isEmpty() || id.length > 64 || !hash.matches(Regex("[0-9a-f]{64}")) || text.length > 2048 || start == null || end == null || start !in 0..text.length || end !in start..text.length) response("invalid_message")
                            else response(input(type, payload.toString()))
                        }
                        "editor.snapshot" -> {
                            if (payload.length() != 0) response("invalid_message")
                            else snapshot().put("version", 1).put("type", "result")
                        }
                        "session.ping" -> response("pong")
                        else -> response("unknown_type")
                    }
                }
            }
        } catch (_: Exception) { response("invalid_message") }
    }
}
