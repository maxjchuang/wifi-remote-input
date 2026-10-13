// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.pm.*
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.*
import org.robolectric.annotation.Config
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowSigningInfo
import org.robolectric.util.ReflectionHelpers
import java.io.File
import java.security.MessageDigest
import java.util.Base64

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MaintenanceTest {
    private val context get() = RuntimeEnvironment.getApplication()
    @Before fun reset() { UpdateInbox.discard(context); DiagnosticLog.clear(context); DiagnosticLog.setEnabled(context, true) }
    private val bytes = "test package content".toByteArray()
    private fun begin(hash: String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }) = JSONObject().put("size", bytes.size.toString()).put("sha256", hash)
    private fun chunk(offset: String = "0") = JSONObject().put("offset", offset).put("data", Base64.getEncoder().encodeToString(bytes))
    private fun send(type: String, data: JSONObject, owner: String = "a", authorized: Boolean = true) = UpdateInbox.handle(context, owner, type, data) { authorized }
    private fun packageInfo(version: Long, signer: String = "aa", name: String = context.packageName): PackageInfo {
        val signing = ReflectionHelpers.callConstructor(SigningInfo::class.java)
        Shadow.extract<ShadowSigningInfo>(signing).setSignatures(arrayOf(Signature(signer)))
        return PackageInfo().apply { packageName = name; setLongVersionCode(version); signingInfo = signing }
    }
    @Test fun uploadRequiresOptInAuthenticationAndConnectionOwnership() {
        assertEquals("update_not_allowed", send("update.begin", begin()))
        UpdateInbox.allow(context)
        assertEquals("unauthorized", send("update.begin", begin(), authorized = false))
        UpdateInbox.allow(context)
        assertEquals("ok", send("update.begin", begin()))
        assertEquals("update_busy", send("update.chunk", chunk(), owner = "b"))
        UpdateInbox.cancel(context, "b")
        assertEquals("ok", send("update.chunk", chunk()))
        UpdateInbox.cancel(context, "a")
        assertFalse(File(context.noBackupFilesDir, "incoming-update.part").exists())
    }
    @Test fun outOfOrderHashMismatchAndUnpairedProtocolNeverPublishApk() {
        UpdateInbox.allow(context); send("update.begin", begin())
        assertEquals("update_rejected", send("update.chunk", chunk("1")))
        UpdateInbox.allow(context); send("update.begin", begin("0".repeat(64))); send("update.chunk", chunk())
        assertEquals("update_rejected", send("update.finish", JSONObject()))
        assertFalse(UpdateInbox.file(context).exists())
        val protocol = Protocol(Pairing({ null }, {})) { _, _ -> fail("unauthenticated upload reached handler"); "ok" }
        assertEquals("unauthorized", protocol.handle(JSONObject().put("version", 1).put("type", "update.begin").put("payload", begin()).toString()).getString("status"))
    }
    @Test fun onlySamePackageSignerAndHigherVersionAreInstallable() {
        val pm = Shadows.shadowOf(context.packageManager)
        pm.installPackage(packageInfo(20))
        val source = File(context.noBackupFilesDir, "incoming-update.part")
        for (incoming in listOf(packageInfo(20), packageInfo(19), packageInfo(21, "bb"), packageInfo(21, name = "another.app"))) {
            pm.setPackageArchiveInfo(source.path, incoming)
            assertFalse(UpdateInbox.validApk(context, source))
        }
        pm.setPackageArchiveInfo(source.path, packageInfo(21))
        UpdateInbox.allow(context); assertEquals("ok", send("update.begin", begin()))
        assertEquals("ok", send("update.chunk", chunk()))
        assertEquals("update_ready", send("update.finish", JSONObject()))
        assertArrayEquals(bytes, UpdateInbox.file(context).readBytes())
        assertEquals("update_not_allowed", send("update.begin", begin()))
    }
    @Test fun expiredPermissionAndOversizedChunksAreRejected() {
        UpdateInbox.allow(context)
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofMinutes(11))
        assertEquals("update_not_allowed", send("update.begin", begin()))
        UpdateInbox.allow(context); send("update.begin", begin())
        assertEquals("update_rejected", send("update.chunk", JSONObject().put("offset", "0").put("data", "A".repeat(11000))))
        assertFalse(UpdateInbox.file(context).exists())
    }
    @Test fun maintenancePageCanOpenAndExportThroughDocumentPicker() {
        val controller = Robolectric.buildActivity(MaintenanceActivity::class.java).setup()
        val activity = controller.get()
        fun find(view: android.view.View): android.widget.Button? {
            if (view is android.widget.Button && view.text.toString() == "导出日志…") return view
            if (view is android.view.ViewGroup) for (i in 0 until view.childCount) find(view.getChildAt(i))?.let { return it }
            return null
        }
        find(activity.window.decorView)!!.performClick()
        val intent = Shadows.shadowOf(activity).nextStartedActivityForResult.intent
        assertEquals(android.content.Intent.ACTION_CREATE_DOCUMENT, intent.action)
        assertEquals("text/plain", intent.type)
        controller.pause().stop().destroy()
    }
    @Test fun logsAreBoundedOptOutAndRejectArbitraryPayloads() {
        DiagnosticLog.status(context, "secret text / code 12345678 / token")
        assertFalse(DiagnosticLog.read(context).contains("secret"))
        repeat(400) { DiagnosticLog.record(context, if (it % 2 == 0) DiagnosticLog.Event.CONTROL_START else DiagnosticLog.Event.CONTROL_STOP) }
        assertEquals(301, DiagnosticLog.read(context).lines().size)
        val before = DiagnosticLog.read(context)
        DiagnosticLog.setEnabled(context, false); DiagnosticLog.record(context, DiagnosticLog.Event.GESTURE_CANCELLED)
        assertEquals(before, DiagnosticLog.read(context))
        DiagnosticLog.clear(context); assertFalse(DiagnosticLog.read(context).contains("CONTROL_START"))
    }
}
