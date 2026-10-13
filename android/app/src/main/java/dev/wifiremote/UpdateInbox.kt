// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.Base64

/** A single opt-in upload owned by one authenticated WebSocket. No remote installation. */
object UpdateInbox {
    const val MAX_SIZE = 80 * 1024 * 1024
    private var allowedUntil = 0L
    private var owner: String? = null
    private var expectedSize = 0
    private var expectedHash = ""
    private var received = 0
    private var lastActivity = 0L
    @Volatile var status = "未接收更新"
        private set
    fun file(context: Context) = File(context.noBackupFilesDir, "incoming-update.apk")
    private fun partial(context: Context) = File(context.noBackupFilesDir, "incoming-update.part")
    @Synchronized fun allow(context: Context) {
        cancel(context); file(context).delete(); allowedUntil = SystemClock.elapsedRealtime() + 600_000
        status = "等待 Mac 推送 · 10 分钟内有效"
    }
    @Synchronized fun cancel(context: Context, connection: String? = null) {
        if (connection != null && connection != owner) return
        owner = null; partial(context).delete(); allowedUntil = 0
        if (!file(context).exists()) status = "未接收更新"
    }
    @Synchronized fun discard(context: Context) { cancel(context); file(context).delete(); status = "未接收更新" }
    @Synchronized fun handle(context: Context, connection: String, type: String, payload: JSONObject, authorized: () -> Boolean): String {
        if (!authorized()) { cancel(context, connection); return "unauthorized" }
        val now = SystemClock.elapsedRealtime()
        if (now >= allowedUntil) { cancel(context); return "update_not_allowed" }
        if (owner != null && now - lastActivity > 60_000) { cancel(context); return "update_expired" }
        if (owner != null && owner != connection) return "update_busy"
        fun reject(): String { cancel(context); status = "更新校验失败，请重新允许接收后重试"; DiagnosticLog.record(context, DiagnosticLog.Event.UPDATE_REJECTED); return "update_rejected" }
        return try {
            when (type) {
                "update.begin" -> {
                    if (owner != null || payload.length() != 2) return "update_busy"
                    val size = (payload.get("size") as? String)?.toIntOrNull() ?: return reject()
                    val hash = payload.get("sha256") as? String ?: return reject()
                    if (size !in 1..MAX_SIZE || !hash.matches(Regex("[0-9a-f]{64}"))) return reject()
                    partial(context).writeBytes(byteArrayOf()); owner = connection
                    expectedSize = size; expectedHash = hash; received = 0; lastActivity = now
                    status = "接收更新 0%"; DiagnosticLog.record(context, DiagnosticLog.Event.UPDATE_BEGIN); "ok"
                }
                "update.chunk" -> {
                    if (owner != connection || payload.length() != 2) return reject()
                    val offset = (payload.get("offset") as? String)?.toIntOrNull()
                    val encoded = payload.get("data") as? String ?: return reject()
                    if (offset != received || encoded.length > 10924) return reject()
                    val bytes = Base64.getDecoder().decode(encoded)
                    if (bytes.isEmpty() || bytes.size > 8192 || received + bytes.size > expectedSize) return reject()
                    partial(context).appendBytes(bytes); received += bytes.size; lastActivity = now
                    status = "接收更新 ${received * 100L / expectedSize}%"; "ok"
                }
                "update.finish" -> {
                    if (owner != connection || payload.length() != 0 || received != expectedSize) return reject()
                    val source = partial(context)
                    val digest = MessageDigest.getInstance("SHA-256")
                    source.inputStream().use { stream -> val buffer = ByteArray(8192); while (true) { val n = stream.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) } }
                    val hash = digest.digest().joinToString("") { "%02x".format(it) }
                    if (hash != expectedHash || !validApk(context, source) || !authorized()) return reject()
                    file(context).delete()
                    if (!source.renameTo(file(context))) return reject()
                    owner = null; allowedUntil = 0; status = "新版已就绪 · 请确认安装"
                    DiagnosticLog.record(context, DiagnosticLog.Event.UPDATE_READY); "update_ready"
                }
                else -> "invalid_message"
            }
        } catch (_: Exception) { reject() }
    }
    @Suppress("DEPRECATION") fun validApk(context: Context, file: File): Boolean {
        val flags = PackageManager.GET_SIGNING_CERTIFICATES
        val installed = context.packageManager.getPackageInfo(context.packageName, flags)
        val incoming = context.packageManager.getPackageArchiveInfo(file.path, flags) ?: return false
        val currentSigners = installed.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet() ?: return false
        val newSigners = incoming.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet() ?: return false
        return incoming.packageName == context.packageName && incoming.longVersionCode > installed.longVersionCode && currentSigners.isNotEmpty() && currentSigners == newSigners
    }
}
