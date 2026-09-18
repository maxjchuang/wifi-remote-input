// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import RemoteCore

final class PairingQRTests: XCTestCase {
    private var valid: [String: Any] { ["kind": "wifi-remote-input", "version": 1, "address": "192.168.1.20:8765", "fingerprint": String(repeating: "ab", count: 32), "code": "00123456"] }
    private func json(_ values: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self) }
    func testScanRetainsLeadingZerosAndFullCertificatePin() throws {
        let offer = try PairingOffer.parse(json(valid))
        XCTAssertEqual(offer.address, "192.168.1.20:8765")
        XCTAssertEqual(offer.code, "00123456")
        XCTAssertEqual(offer.fingerprint.count, 64)
    }
    func testRejectsUnrelatedAndMalformedCodes() throws {
        for (key, value) in [("kind", "other" as Any), ("version", 2), ("version", true), ("address", "example.com:443"), ("address", "8.8.8.8:443"), ("address", "127.0.0.1:8765"), ("fingerprint", "short"), ("code", "1234567"), ("code", "１２３４５６７８"), ("code", 12345678)] {
            var fixture = valid; fixture[key] = value
            XCTAssertThrowsError(try PairingOffer.parse(json(fixture)), "Must reject invalid \(key)")
        }
        for key in valid.keys {
            var fixture = valid; fixture.removeValue(forKey: key)
            XCTAssertThrowsError(try PairingOffer.parse(json(fixture)))
        }
        for raw in ["https://example.com", "[]", String(repeating: "x", count: 2049)] { XCTAssertThrowsError(try PairingOffer.parse(raw)) }
    }
}
