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
        let unread = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let deniedRead = try await unread.exchange("editor.snapshot", [:])
        precondition(deniedRead["status"] as? String == "unauthorized" && deniedRead["text"] == nil)
        unread.close()
        let paired = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let result = try await paired.exchange("pair", ["code": offer.code, "deviceName": "测试 Mac"])
        precondition(result["status"] as? String == "paired")
        precondition(result["deviceName"] as? String == "测试手机 A")
        let token = result["token"] as! String; paired.close()
        let reused = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let reuse = try await reused.exchange("pair", ["code": offer.code])
        precondition(reuse["status"] as? String == "authentication_failed"); reused.close()
        print("PASS scanned QR cannot be reused")
        let reconnect = try Transport(address: address, fingerprint: pin, allowLoopback: true)
        let auth = try await reconnect.exchange("auth", ["token": token])
        precondition(auth["status"] as? String == "authenticated")
        let initialSnapshot = try EditorSnapshot(response: await reconnect.exchange("editor.snapshot", [:]))
        precondition(initialSnapshot.text == "手机已有文字")
        let text = try await reconnect.exchange("text.commit", ["text": "你好，小米 13 👋"])
        precondition(text["status"] as? String == "ok")
        for key in ["Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"] {
            let response = try await reconnect.exchange("key.press", ["key": key]); precondition(response["status"] as? String == "ok")
        }
        let updatedSnapshot = try EditorSnapshot(response: await reconnect.exchange("editor.snapshot", [:]))
        precondition(updatedSnapshot.text == "手机已有文字你好，小米 13 👋")
        precondition(updatedSnapshot.selection.location == updatedSnapshot.text.utf16.count)
        print("PASS authenticated editor snapshots and existing text over TLS")
        let editPayload = EditorEdit.payload(from: updatedSnapshot, text: "同框编辑👋", selection: NSRange(location: 6, length: 0))!
        let editResponse = try await reconnect.exchange("editor.edit", editPayload)
        precondition(editResponse["status"] as? String == "ok")
        let staleEdit = try await reconnect.exchange("editor.edit", editPayload)
        precondition(staleEdit["status"] as? String == "editor_conflict")
        let editedSnapshot = try EditorSnapshot(response: await reconnect.exchange("editor.snapshot", [:]))
        precondition(editedSnapshot.text == "同框编辑👋")
        print("PASS mirror edit payload, cross-language content hash and stale edit rejection over TLS")
        let second = try Transport(address: fixture["secondAddress"]!, fingerprint: fixture["secondPin"]!, allowLoopback: true)
        let secondPair = try await second.exchange("pair", ["code": fixture["secondCode"]!, "deviceName": "测试 Mac"])
        precondition(secondPair["status"] as? String == "paired" && secondPair["deviceName"] as? String == "测试手机 B")
        let wrongCredential = try Transport(address: fixture["secondAddress"]!, fingerprint: fixture["secondPin"]!, allowLoopback: true)
        let wrongAuth = try await wrongCredential.exchange("auth", ["token": token])
        precondition(wrongAuth["status"] as? String == "authentication_failed"); wrongCredential.close()
        let onlyB = try await second.exchange("text.commit", ["text": "仅 B"])
        precondition(onlyB["status"] as? String == "ok")
        async let firstDelivery = reconnect.exchange("text.commit", ["text": "同步中文 👋"])
        async let secondDelivery = second.exchange("text.commit", ["text": "同步中文 👋"])
        let deliveries = try await [firstDelivery, secondDelivery]
        precondition(deliveries.allSatisfy { $0["status"] as? String == "ok" })
        second.close()
        print("PASS two independent TLS receivers, device names, credential isolation and concurrent Unicode delivery")
        reconnect.close(); print("PASS pairing, reconnect authentication, Unicode and all six keys over pinned TLS WebSocket")
    }
}
