// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.Collections

class InteropTest {
    // Emit a grayscale PNG without java.awt, which isn't in Android's compilation boot classpath.
    private fun writeQrPng(matrix: com.google.zxing.common.BitMatrix, file: File) {
        java.io.DataOutputStream(file.outputStream()).use { out ->
            out.write(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10))
            fun chunk(name: String, data: ByteArray) {
                val type = name.toByteArray(Charsets.US_ASCII)
                out.writeInt(data.size); out.write(type); out.write(data)
                val crc = java.util.zip.CRC32().apply { update(type); update(data) }
                out.writeInt(crc.value.toInt())
            }
            val header = java.io.ByteArrayOutputStream()
            java.io.DataOutputStream(header).use { it.writeInt(matrix.width); it.writeInt(matrix.height); it.write(byteArrayOf(8, 0, 0, 0, 0)) }
            chunk("IHDR", header.toByteArray())
            val pixels = java.io.ByteArrayOutputStream()
            java.util.zip.DeflaterOutputStream(pixels).use { compressed ->
                for (y in 0 until matrix.height) {
                    compressed.write(0)
                    for (x in 0 until matrix.width) compressed.write(if (matrix[x, y]) 0 else 255)
                }
            }
            chunk("IDAT", pixels.toByteArray()); chunk("IEND", byteArrayOf())
        }
    }
    @Test fun swiftClientAgainstProductionTlsServer() {
        val executable = System.getenv("WRI_SWIFT_SMOKE")
        assumeTrue("Set WRI_SWIFT_SMOKE to run real Swift/JVM interoperability test", executable != null)
        val directory = Files.createTempDirectory("wri-interop").toFile()
        var server: InputServer? = null
        var second: InputServer? = null
        try {
            val identity = Identity(directory)
            assertEquals(identity.fingerprint, Identity(directory).fingerprint)
            var hash: String? = null
            val pairing = Pairing({ hash }, { hash = it })
            val code = pairing.begin()
            val ready = CountDownLatch(1)
            val inputs = Collections.synchronizedList(mutableListOf<Pair<String, String>>())
            var editorText = "手机已有文字"
            server = InputServer(InetSocketAddress("127.0.0.1", 0), identity.tls, pairing, { type, value, authorized ->
                check(authorized())
                if (type == "editor.edit") {
                    val edit = JSONObject(value)
                    if (edit.getString("editorId") != "1" || edit.getString("expectedHash") != Secrets.hash(editorText + "\u0000" + editorText.length + "," + editorText.length)) "editor_conflict"
                    else { editorText = edit.getString("text"); inputs.add(type to value); "ok" }
                } else { inputs.add(type to value); if (type == "text.commit") editorText += value; "ok" }
            }, { ready.countDown() }, snapshot = { authorized ->
                check(authorized())
                JSONObject().put("status", "snapshot").put("editorId", "1").put("text", editorText)
                    .put("selectionStart", editorText.length).put("selectionEnd", editorText.length)
            }, deviceName = { "测试手机 A" })
            server.start()
            assertTrue(ready.await(10, TimeUnit.SECONDS))
            val qr = PairingQr.matrix("127.0.0.1:${server.port}", identity.fingerprint, code)
            val qrFile = File(directory, "pairing.png")
            writeQrPng(qr, qrFile)
            val secondIdentity = Identity(File(directory, "second").apply { mkdirs() })
            var secondHash: String? = null
            val secondPairing = Pairing({ secondHash }, { secondHash = it })
            val secondCode = secondPairing.begin()
            val secondReady = CountDownLatch(1)
            val secondInputs = Collections.synchronizedList(mutableListOf<Pair<String, String>>())
            second = InputServer(InetSocketAddress("127.0.0.1", 0), secondIdentity.tls, secondPairing,
                { t, v, authorized -> check(authorized()); secondInputs.add(t to v); "ok" }, { secondReady.countDown() }, deviceName = { "测试手机 B" })
            second.start(); assertTrue(secondReady.await(10, TimeUnit.SECONDS))
            val fixture = File(directory, "fixture.json")
            fixture.writeText(JSONObject().put("address", "127.0.0.1:${server.port}").put("fingerprint", identity.fingerprint).put("qrImage", qrFile.absolutePath).put("secondAddress", "127.0.0.1:${second.port}").put("secondPin", secondIdentity.fingerprint).put("secondCode", secondCode).toString())
            fixture.setReadable(false, false); fixture.setReadable(true, true)
            val process = ProcessBuilder(executable!!, fixture.absolutePath).redirectErrorStream(true).start()
            if (!process.waitFor(45, TimeUnit.SECONDS)) { process.destroyForcibly(); fail("Swift integration timed out") }
            val output = process.inputStream.bufferedReader().readText()
            assertEquals(output, 0, process.exitValue())
            println(output)
            assertEquals("你好，小米 13 👋", inputs.first().second)
            assertEquals(listOf("Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"), inputs.drop(1).take(6).map { it.second })
            assertEquals("同步中文 👋", inputs.last().second)
            assertEquals(listOf("仅 B", "同步中文 👋"), secondInputs.map { it.second })
            assertEquals("测试 Mac", pairing.peerName()); assertEquals("测试 Mac", secondPairing.peerName())
        } finally { second?.shutdown(); server?.shutdown(); directory.deleteRecursively() }
    }
}
