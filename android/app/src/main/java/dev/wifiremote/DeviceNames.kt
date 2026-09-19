// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.Context
import android.os.Build
import android.provider.Settings

object DeviceNames {
    private fun clean(value: String?): String? {
        val text = value?.filterNot { it.isISOControl() || it in '\u202a'..'\u202e' || it in '\u2066'..'\u2069' }?.trim().orEmpty()
        var end = minOf(text.length, 80)
        if (end > 0 && end < text.length && Character.isHighSurrogate(text[end - 1])) end--
        return text.substring(0, end).takeIf { it.isNotBlank() }
    }
    fun choose(custom: String?, system: String?, model: String, manufacturer: String): String {
        clean(custom)?.let { return it }
        clean(system)?.takeUnless { it == model && opaque(it) }?.let { return it }
        clean(model)?.takeUnless(::opaque)?.let { return it }
        return when (manufacturer.lowercase()) {
            "xiaomi" -> "小米手机"
            "samsung" -> "三星手机"
            "huawei" -> "华为手机"
            "honor" -> "荣耀手机"
            "google" -> "Google 手机"
            else -> clean(manufacturer)?.let { "$it 手机" } ?: "Android 手机"
        }
    }
    private fun opaque(name: String) = name.matches(Regex("[A-Z0-9_-]{6,}")) && name.any(Char::isDigit)
    fun resolve(context: Context): String {
        val custom = context.getSharedPreferences("devices", Context.MODE_PRIVATE).getString("deviceName", null)
        val system = try { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) } catch (_: SecurityException) { null }
        return choose(custom, system, Build.MODEL, Build.MANUFACTURER)
    }
}
