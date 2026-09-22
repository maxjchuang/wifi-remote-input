// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import RemoteCore
@testable import WiFiRemoteInput

private final class DiscoveryConnection: SessionConnection {
    var fail = false
    func close() {}
    func exchange(_ type: String, _ payload: [String: String]) async throws -> [String: Any] {
        if fail { throw RemoteError.rejected }
        return ["status": "authenticated", "deviceName": "Phone"]
    }
}
final class DiscoveryTests: XCTestCase {
    @MainActor func testDiscoveryOnlyPersistsAuthenticatedAddressAndHonorsManualDisconnect() async throws {
        let name = "discovery-test-\(UUID())", pin = String(repeating: "a", count: 64)
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let old = "192.168.1.2:8765", fresh = "192.168.31.8:8765"
        defaults.set(try JSONEncoder().encode([DeviceRecord(name: "Phone", address: old, fingerprint: pin)]), forKey: "phones")
        let connection = DiscoveryConnection()
        var attempts: [(String, String)] = []
        let client = Client(defaults: defaults, makeSession: { record in
            DeviceSession(record: record, makeConnection: { address, fingerprint in attempts.append((address, fingerprint)); return connection }, loadKey: { _ in "saved-key" }, saveKey: { _, _ in XCTFail("Discovery must not replace pairing keys") }, removeKey: { _ in })
        })
        client.discoveredDevice(fingerprint: String(repeating: "b", count: 64), address: fresh)
        client.discoveredDevice(fingerprint: pin, address: "8.8.8.8:8765")
        client.connect()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(attempts.last?.0, old)
        client.disconnect()
        client.discoveredDevice(fingerprint: pin, address: fresh)
        XCTAssertEqual(attempts.count, 1, "Explicit disconnect must not be undone by discovery")
        connection.fail = true; client.connect()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(attempts.last?.0, fresh); XCTAssertEqual(attempts.last?.1, pin)
        XCTAssertEqual(client.active.address, old)
        let failedRecords = try JSONDecoder().decode([DeviceRecord].self, from: defaults.data(forKey: "phones")!)
        XCTAssertEqual(failedRecords.first?.address, old)
        connection.fail = false
        client.discoveredDevice(fingerprint: pin, address: fresh)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(client.connected); XCTAssertTrue(client.paused)
        XCTAssertEqual(client.active.address, fresh)
        let records = try JSONDecoder().decode([DeviceRecord].self, from: defaults.data(forKey: "phones")!)
        XCTAssertEqual(records.first?.address, fresh)
        client.forget()
        let count = attempts.count
        client.discoveredDevice(fingerprint: pin, address: fresh)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(attempts.count, count)
    }
}
