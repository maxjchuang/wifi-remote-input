// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.Context
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Only enumerated events cross this boundary; never pass payloads or exception messages. */
object DiagnosticLog {
    enum class Event {
        RECEIVER_START, RECEIVER_STOP, RECEIVER_ERROR, PAIRED, AUTHENTICATED,
        AUTHENTICATION_FAILED, UNAUTHORIZED, CONNECTION_CLOSED, NETWORK_ERROR,
        CONTROL_START, CONTROL_STOP, GESTURE_CANCELLED, GESTURE_REJECTED,
        NO_EDITOR, PASSWORD_BLOCKED, DEVICE_LOCKED, TOUCH_NOT_DOWN, GESTURE_BUSY,
        UPDATE_BEGIN, UPDATE_READY, UPDATE_REJECTED, UPDATE_CANCELLED
    }
    @Synchronized fun record(context: Context, event: Event) {
        val prefs = context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("enabled", true)) return
        val now = System.currentTimeMillis()
        if (prefs.getString("last", "") == event.name && now - prefs.getLong("time", 0) < 10_000) return
        val line = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(now)) + " " + event.name
        val lines = (prefs.getString("lines", "").orEmpty().lineSequence().filter { it.isNotBlank() }.toList() + line).takeLast(300)
        prefs.edit().putString("lines", lines.joinToString("\n")).putString("last", event.name).putLong("time", now).apply()
    }
    fun status(context: Context, value: String) {
        val event = Event.entries.firstOrNull { it.name == value.uppercase(Locale.ROOT) } ?: return
        record(context, event)
    }
    fun enabled(context: Context) = context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE).getBoolean("enabled", true)
    fun setEnabled(context: Context, enabled: Boolean) { context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE).edit().putBoolean("enabled", enabled).apply() }
    @Synchronized fun clear(context: Context) { context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE).edit().remove("lines").remove("last").remove("time").apply() }
    @Suppress("DEPRECATION") fun read(context: Context): String {
        val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName
        return "WiFi Remote Input $version · Android API ${android.os.Build.VERSION.SDK_INT}\n" +
            context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE).getString("lines", "").orEmpty()
    }
}
