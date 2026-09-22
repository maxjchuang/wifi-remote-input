// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ServiceAdvertisementTest {
    @Test fun advertisementContainsOnlyPublicIdentityAndProtocolVersion() {
        val fingerprint = "a".repeat(64)
        val info = ServiceAdvertisement.info(fingerprint)
        assertEquals("_wri-input._tcp.", info.serviceType)
        assertEquals(8765, info.port)
        assertEquals(setOf("id", "v"), info.attributes.keys)
        assertEquals(fingerprint, String(info.attributes.getValue("id")))
        assertEquals("1", String(info.attributes.getValue("v")))
        assertFalse(info.serviceName.contains("手机名称"))
    }
}
