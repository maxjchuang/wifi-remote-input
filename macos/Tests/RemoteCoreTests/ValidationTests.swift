// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import RemoteCore
final class ValidationTests: XCTestCase {
    func testRejectsNonLocalOrMalformedAddresses() {
        for address in ["example.com:8765", "8.8.8.8:8765", "127.0.0.1:8765", "192.168.1.x.20:8765", "192.168.1.20/path:8765", "192.168.1.256:8765", "+192.168.1.20:8765", "192.168.1.20:0", "192.168.1.20:65536", "192.168.1.20"] {
            XCTAssertThrowsError(try Transport(address: address, fingerprint: String(repeating: "a", count: 64)))
        }
    }
    func testFingerprintMustBeCompleteHex() throws {
        XCTAssertEqual(try Transport.normalizedFingerprint(String(repeating: "AB:", count: 32)), String(repeating: "ab", count: 32))
        for value in ["", "abc", String(repeating: "z", count: 64), String(repeating: "a", count: 65)] { XCTAssertThrowsError(try Transport.normalizedFingerprint(value)) }
    }
}
