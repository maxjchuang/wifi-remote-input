// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security
import CryptoKit

public enum RemoteError: Error { case invalidAddress, invalidFingerprint, malformedResponse, rejected }

public final class PinDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let fingerprint: String
    public init(fingerprint: String) { self.fingerprint = fingerprint }
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let hash = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == fingerprint else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class Transport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    public static func normalizedFingerprint(_ value: String) throws -> String {
        let pin = value.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        guard pin.count == 64 && pin.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw RemoteError.invalidFingerprint }
        return pin
    }
    public static func endpoint(address: String, allowLoopback: Bool = false) throws -> URL {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { throw RemoteError.invalidAddress }
        let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ "0123456789".contains($0) }) }) else { throw RemoteError.invalidAddress }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168) || (allowLoopback && octets[0] == 127),
              let url = URL(string: "wss://\(octets.map(String.init).joined(separator: ".")):\(port)/input") else { throw RemoteError.invalidAddress }
        return url
    }
    public init(address: String, fingerprint: String, allowLoopback: Bool = false) throws {
        let pin = try Self.normalizedFingerprint(fingerprint)
        let url = try Self.endpoint(address: address, allowLoopback: allowLoopback)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: PinDelegate(fingerprint: pin), delegateQueue: nil)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16384
        socket.resume()
    }
    public func exchange(_ type: String, _ payload: [String: String]) async throws -> [String: Any] {
        let watchdog = Task { [socket] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000); socket.cancel(with: .goingAway, reason: nil) } catch { }
        }
        defer { watchdog.cancel() }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "type": type, "payload": payload])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        let message = try await socket.receive()
        let response: Data
        switch message { case .string(let s): response = Data(s.utf8); case .data(let d): response = d; @unknown default: throw RemoteError.malformedResponse }
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any], json["version"] as? Int == 1, json["type"] as? String == "result", json["status"] is String else { throw RemoteError.malformedResponse }
        return json
    }
    public func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { close() }
}

public enum DeviceKeychain {
    private static func query(_ pin: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.wifiremote.device", kSecAttrAccount as String: pin] }
    public static func load(_ pin: String) -> String? {
        var q = query(pin); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ token: String, pin: String) throws {
        let q = query(pin)
        let data = Data(token.utf8)
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw RemoteError.rejected }
        var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw RemoteError.rejected }
    }
    public static func remove(_ pin: String) { SecItemDelete(query(pin) as CFDictionary) }
}
