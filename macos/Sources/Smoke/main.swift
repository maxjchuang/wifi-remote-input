// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin
import ImageIO
import RemoteCore

@main struct Smoke {
    static func main() async throws {
        setbuf(stdout, nil)
        // Test secrets are supplied through a private fixture file, never command-line arguments or logs.
        guard CommandLine.arguments.count == 2 else { fatalError("fixture path required") }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
        let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: fixture["qrImage"]!) as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        let offer = try PairingQR.decode(image: image, allowLoopback: true)
        precondition(offer.address == fixture["address"] && offer.fingerprint == fixture["fingerprint"])
        print("PASS Android-generated QR decoded by macOS Vision")
        let address = offer.address, pin = offer.fingerprint
        let bad = try Transport(address: address, fingerprint: String(repeating: "0", count: 64), allowLoopback: true)
        do { _ = try await bad.exchange("pair", ["code": offer.code]); fatalError("pin mismatch accepted") } catch { print("PASS certificate mismatch rejected") }; bad.close()
        let unauth = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let rejected = try await unauth.exchange("text.commit", ["text": "must not arrive"])
        precondition(rejected["status"] as? String == "unauthorized"); unauth.close()
        print("PASS unpaired input rejected")
        let paired = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let result = try await paired.exchange("pair", ["code": offer.code])
        precondition(result["status"] as? String == "paired")
        let token = result["token"] as! String; paired.close()
        let reused = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let reuse = try await reused.exchange("pair", ["code": offer.code])
        precondition(reuse["status"] as? String == "authentication_failed"); reused.close()
        print("PASS scanned QR cannot be reused")
        let reconnect = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let auth = try await reconnect.exchange("auth", ["token": token])
        precondition(auth["status"] as? String == "authenticated")
        let text = try await reconnect.exchange("text.commit", ["text": "你好，小米 13 👋"])
        precondition(text["status"] as? String == "ok")
        for key in ["Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"] {
            let response = try await reconnect.exchange("key.press", ["key": key]); precondition(response["status"] as? String == "ok")
        }
        reconnect.close(); print("PASS pairing, reconnect authentication, Unicode and all six keys over pinned TLS WebSocket")
    }
}
