// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import RemoteCore
@testable import WiFiRemoteInput

private final class FakeConnection: SessionConnection {
    var inputs: [InputEvent] = []
    var name: String
    var inputDelay: UInt64 = 0
    var rejection: String?
    var lastComputerName: String?
    init(_ name: String) { self.name = name }
    func close() {}
    func exchange(_ type: String, _ payload: [String: String]) async throws -> [String: Any] {
        if type == "pair" || type == "auth" {
            lastComputerName = payload["deviceName"]
            return ["status": type == "pair" ? "paired" : "authenticated", "token": "test-only", "deviceName": name]
        }
        if type == "session.ping" { return ["status": "pong"] }
        if type == "editor.snapshot" { return ["status": "no_editor"] }
        if inputDelay > 0 { try await Task.sleep(nanoseconds: inputDelay) }
        if let rejection { return ["status": rejection] }
        inputs.append(InputEvent(type, payload["text"] ?? payload["key"]!))
        return ["status": "ok"]
    }
}

final class ClientTests: XCTestCase {
    @MainActor private func fixture() -> (Client, [FakeConnection], UserDefaults) {
        let defaults = UserDefaults(suiteName: "wri-tests-" + UUID().uuidString)!
        let records = [DeviceRecord(name: "Phone A", address: "192.168.1.2:8765", fingerprint: String(repeating: "a", count: 64)),
                       DeviceRecord(name: "Phone B", address: "192.168.1.3:8765", fingerprint: String(repeating: "b", count: 64))]
        defaults.set(try! JSONEncoder().encode(records), forKey: "phones")
        let fakes = [FakeConnection("小米 13"), FakeConnection("备用手机")]
        let client = Client(defaults: defaults, makeSession: { record in
            DeviceSession(record: record, makeConnection: { _, pin in pin.first == "a" ? fakes[0] : fakes[1] }, loadKey: { _ in "test-only" }, saveKey: { _, _ in }, removeKey: { _ in })
        })
        return (client, fakes, defaults)
    }
    @MainActor private func connect(_ client: Client) async throws {
        for device in client.devices { device.connect() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(client.devices.allSatisfy(\.connected))
    }
    @MainActor func testFocusResumeIsNotBlockedByAnInFlightAcknowledgement() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        fakes[0].inputDelay = 200_000_000
        client.resumeInput(); client.send("text.commit", value: "已发出")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(client.active.inputIdle)
        client.pauseInput(); client.resumeInput()
        XCTAssertTrue(client.acceptsAutoInput)
        try await Task.sleep(nanoseconds: 250_000_000)
        client.disconnectAll()
    }
    @MainActor func testMissingPhoneEditorHasActionablePersistentGuidance() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        fakes[0].rejection = "no_editor"
        client.resumeInput(); client.send("text.commit", value: "test")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(client.paused)
        XCTAssertEqual(client.inputGuidance?.title, "已暂停：手机未选中输入框")
        XCTAssertTrue(client.inputGuidance?.detail.contains("小米 13") == true)
        XCTAssertTrue(client.inputGuidance?.detail.contains("WiFi Remote Input") == true)
        client.pauseInput(); XCTAssertNotNil(client.inputGuidance)
        client.disconnect(); XCTAssertNil(client.inputGuidance)
    }
    @MainActor func testForgetFromListDoesNotSwitchOrDisconnectOtherPhone() async throws {
        let (client, _, defaults) = fixture(); try await connect(client)
        let kept = client.active; let removed = client.devices[1]
        client.setBroadcast(true); client.toggleRecipient(removed)
        client.forget(removed)
        XCTAssertTrue(client.active === kept); XCTAssertTrue(kept.connected)
        XCTAssertFalse(removed.connected); XCTAssertFalse(client.recipients.contains(removed.id))
        let records = try JSONDecoder().decode([DeviceRecord].self, from: defaults.data(forKey: "phones")!)
        XCTAssertEqual(records.map(\.fingerprint), [kept.fingerprint])
        client.forget(kept)
        XCTAssertTrue(client.devices.isEmpty); XCTAssertFalse(client.connected)
        XCTAssertTrue(client.active.address.isEmpty); XCTAssertFalse(client.broadcasting)
    }
    @MainActor func testSwitchDiscardsOldQueueAndKeepsConnectionsSeparate() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        client.resumeInput(); client.send("text.commit", value: "discard before switch")
        client.select(client.devices[1]); client.resumeInput()
        client.send("text.commit", value: "只到 B")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(fakes[0].inputs.isEmpty)
        XCTAssertEqual(fakes[1].inputs, [InputEvent("text.commit", "只到 B")])
        XCTAssertTrue(client.devices.allSatisfy(\.connected))
        client.disconnectAll()
    }
    @MainActor func testBroadcastExplicitRecipientsAndPerPhoneOrderedKeys() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        client.setBroadcast(true); client.toggleRecipient(client.devices[1]); client.resumeInput()
        client.send("text.commit", value: "同步中文 👋"); client.send("key.press", value: "Backspace")
        try await Task.sleep(nanoseconds: 200_000_000)
        let expected = [InputEvent("text.commit", "同步中文 👋"), InputEvent("key.press", "Backspace")]
        XCTAssertEqual(fakes[0].inputs, expected); XCTAssertEqual(fakes[1].inputs, expected)
        client.toggleRecipient(client.devices[1]); client.resumeInput(); client.send("key.press", value: "Enter")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(fakes[0].inputs.last, InputEvent("key.press", "Enter")); XCTAssertEqual(fakes[1].inputs, expected)
        client.disconnectAll()
    }
    @MainActor func testUnavailableTargetPreventsSendingToRemainingPhone() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        client.setBroadcast(true); client.toggleRecipient(client.devices[1]); client.devices[1].disconnect()
        client.resumeInput(); client.send("text.commit", value: "must not arrive")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fakes.allSatisfy { $0.inputs.isEmpty }); XCTAssertTrue(client.paused)
        client.disconnectAll()
    }
    @MainActor func testPasswordRejectionPausesGroupWithoutRetry() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        fakes[1].rejection = "password_blocked"
        client.setBroadcast(true); client.toggleRecipient(client.devices[1]); client.resumeInput()
        client.send("text.commit", value: "first"); client.send("key.press", value: "Enter")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(client.devices.allSatisfy(\.paused)); XCTAssertTrue(fakes[1].inputs.isEmpty)
        XCTAssertFalse(fakes[0].inputs.contains { $0.type == "key.press" })
        client.disconnectAll()
    }
    @MainActor func testNamesPersistenceDuplicatePairingAndForgetIsolation() async throws {
        let (client, _, defaults) = fixture(); try await connect(client)
        XCTAssertEqual(client.devices.map(\.name), ["小米 13", "备用手机"])
        let saved = try JSONDecoder().decode([DeviceRecord].self, from: defaults.data(forKey: "phones")!)
        XCTAssertEqual(saved.map(\.name), ["小米 13", "备用手机"])
        client.newDevice(); client.address = "192.168.1.20:8765"; client.fingerprint = saved[0].fingerprint; client.code = "12345678"; client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.devices.count, 2)
        XCTAssertEqual(client.devices.filter { $0.fingerprint == saved[0].fingerprint }.first?.address, "192.168.1.20:8765")
        client.forget(); XCTAssertEqual(client.devices.count, 1); XCTAssertEqual(client.devices.first?.fingerprint, saved[1].fingerprint)
        client.disconnectAll()
    }
}
