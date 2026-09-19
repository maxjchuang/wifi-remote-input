// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote
import org.junit.Assert.*
import org.junit.Test
class DeviceNamesTest {
    @Test fun preferCustomThenSystemThenReadableModel() {
        assertEquals("工作手机", DeviceNames.choose("工作手机", "小米 13", "2211133C", "Xiaomi"))
        assertEquals("小米 13", DeviceNames.choose(null, "小米 13", "2211133C", "Xiaomi"))
        assertEquals("Pixel 9", DeviceNames.choose(null, null, "Pixel 9", "Google"))
        assertEquals("小米手机", DeviceNames.choose(null, "2211133C", "2211133C", "Xiaomi"))
        assertEquals("三星手机", DeviceNames.choose(null, null, "SM-S9110", "Samsung"))
    }
    @Test fun nameRemainsBoundedAndDoesNotSplitEmoji() {
        val name = DeviceNames.choose("a".repeat(79) + "👋", null, "", "")
        assertEquals(79, name.length)
        assertEquals("小米 13", DeviceNames.choose(null, "\n小米 13\u202e", "2211133C", "Xiaomi"))
    }
}
