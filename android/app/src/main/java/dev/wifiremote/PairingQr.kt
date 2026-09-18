// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import org.json.JSONObject
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

object PairingQr {
    fun payload(address: String, fingerprint: String, code: String): String = JSONObject()
        .put("kind", "wifi-remote-input").put("version", 1)
        .put("address", address).put("fingerprint", fingerprint).put("code", code).toString()
    fun matrix(address: String, fingerprint: String, code: String) = QRCodeWriter().encode(
        payload(address, fingerprint, code), BarcodeFormat.QR_CODE, 768, 768,
        mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 4))
}
