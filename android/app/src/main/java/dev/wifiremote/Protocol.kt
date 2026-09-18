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
    @Synchronized fun pair(candidate: String): String? {
        val expected = code ?: return null
        if (clock() >= expires || attempts >= 5) { code = null; return null }
        attempts++
        if (!Secrets.equal(expected, candidate)) return null
        code = null
        return Secrets.token().also { save(Secrets.hash(it)) }
    }
    @Synchronized fun authenticate(token: String): Boolean = token.length == 64 && load()?.let { Secrets.equal(it, Secrets.hash(token)) } == true
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

class Protocol(private val pairing: Pairing, private val input: (String, String) -> String) {
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
            when (type) {
                "pair" -> {
                    val token = pairing.pair(string("code")) ?: return response("authentication_failed")
                    credential = token
                    response("paired").put("token", token)
                }
                "auth" -> {
                    credential = null
                    val token = string("token")
                    if (!pairing.authenticate(token)) response("authentication_failed")
                    else { credential = token; response("authenticated") }
                }
                else -> {
                    if (credential?.let(pairing::authenticate) != true) return response("unauthorized")
                    when (type) {
                        "text.commit" -> {
                            val text = string("text")
                            if (text.isEmpty() || text.length > 4096) response("invalid_text") else response(input(type, text))
                        }
                        "key.press" -> {
                            val key = string("key")
                            if (key !in setOf("Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown")) response("invalid_key") else response(input(type, key))
                        }
                        "session.ping" -> response("pong")
                        else -> response("unknown_type")
                    }
                }
            }
        } catch (_: Exception) { response("invalid_message") }
    }
}
