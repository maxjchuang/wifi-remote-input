// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider

class Identity(directory: File) {
    val tls: SSLContext
    val fingerprint: String
    init {
        val store = KeyStore.getInstance("PKCS12")
        val file = File(directory, "identity.p12")
        // File is private to the application; no exported backup or plaintext LAN path.
        val password = "local-keystore".toCharArray()
        if (file.exists()) file.inputStream().use { store.load(it, password) } else {
            store.load(null, password)
            val keys = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
            val name = X500Name("CN=WiFi Remote Input")
            val provider = BouncyCastleProvider()
            val cert = JcaX509CertificateConverter().setProvider(provider).getCertificate(
                JcaX509v3CertificateBuilder(name, BigInteger(128, java.security.SecureRandom()), Date(System.currentTimeMillis()-86400000), Date(System.currentTimeMillis()+315360000000L), name, keys.public)
                    .build(JcaContentSignerBuilder("SHA256withRSA").setProvider(provider).build(keys.private)))
            store.setKeyEntry("server", keys.private, password, arrayOf(cert))
            file.outputStream().use { store.store(it, password) }
        }
        fingerprint = MessageDigest.getInstance("SHA-256").digest(store.getCertificate("server").encoded).joinToString("") { "%02x".format(it) }
        val manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, password) }
        tls = SSLContext.getInstance("TLSv1.3").apply { init(manager.keyManagers, null, null) }
    }
}
