// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import RemoteCore
import AppKit
@testable import WiFiRemoteInput

private final class FakeConnection: SessionConnection {
    var inputs: [InputEvent] = []
    var controls: [[String: String]] = []
    var name: String
    var inputDelay: UInt64 = 0
    var rejection: String?
    var snapshot: [String: Any] = ["status": "no_editor"]
    var lastComputerName: String?
    init(_ name: String) { self.name = name }
    func close() {}
    func exchange(_ type: String, _ payload: [String: String]) async throws -> [String: Any] {
        if type == "pair" || type == "auth" {
            lastComputerName = payload["deviceName"]
            return ["status": type == "pair" ? "paired" : "authenticated", "token": "test-only", "deviceName": name]
        }
        if type == "session.ping" { return ["status": "pong"] }
        if type == "editor.snapshot" { return snapshot }
        if inputDelay > 0 { try await Task.sleep(nanoseconds: inputDelay) }
        if let rejection { return ["status": rejection] }
        if type == "control.action" { controls.append(payload) }
        inputs.append(InputEvent(type, payload["text"] ?? payload["action"] ?? payload["key"]!))
        return ["status": "ok"]
    }
}

private final class SnapshotTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}

final class ClientTests: XCTestCase {
    @MainActor func testControlTypingResumesFromSnapshotWithoutBroadcastAndMissingEditorKeepsMouse() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        client.startControl(mouse: true)
        try await Task.sleep(nanoseconds: 60_000_000)
        let window = SnapshotTestWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView = view; client.active.registerInputView(view)
        await client.active.refreshSnapshot()
        XCTAssertTrue(client.active.controlActive); XCTAssertTrue(client.active.paused)
        fakes[0].snapshot = ["status": "snapshot", "editorId": "one", "text": "你好", "selectionStart": 2, "selectionEnd": 2]
        await client.active.refreshSnapshot()
        XCTAssertFalse(client.active.paused); XCTAssertEqual(client.active.editorSnapshot?.text, "你好")
        client.active.send("text.commit", value: "中文")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fakes[0].inputs.contains { $0.type == "text.commit" && $0.value == "中文" })
        XCTAssertFalse(fakes[1].inputs.contains { $0.type == "text.commit" })
        for status in ["password_blocked", "no_editor"] {
            fakes[0].snapshot = ["status": status]
            await client.active.refreshSnapshot()
            XCTAssertTrue(client.active.controlActive); XCTAssertTrue(client.active.paused)
            XCTAssertNil(client.active.editorSnapshot)
        }
        client.disconnectAll(); window.close()
    }

    @MainActor func testCaptureStartsAfterDelayedAcknowledgementWithoutGlobalCursorHitTest() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        fakes[0].inputDelay = 80_000_000
        let window = SnapshotTestWindow(contentRect: NSRect(x: -2400, y: 1200, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ControlKeysView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var associations: [Bool] = []
        view.mouseCapture = MouseCaptureLease(associate: { associations.append($0); return true }, hide: {}, show: {})
        view.client = client; view.configureEditor(); window.contentView = view
        view.requestCapture()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(view.capturing); XCTAssertTrue(client.active.controlActive)
        XCTAssertEqual(associations, [false])
        // Focus loss while the server is confirming must not resurrect capture.
        view.stop()
        XCTAssertEqual(associations, [false, true])
        view.requestCapture(); _ = window.makeFirstResponder(nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(view.capturing); XCTAssertEqual(associations, [false, true])
        view.stop(); client.disconnectAll(); window.close()
    }
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
    @MainActor func testCancelledDragKeepsCaptureAndWaitsForReleaseBeforeNewTouch() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        var states: [Bool] = []
        let observer = client.active.pointerControlStates.sink { states.append($0) }
        client.startControl(mouse: true); try await Task.sleep(nanoseconds: 50_000_000)
        client.active.sendControl("pointer_down", coordinates: ["x": "100", "y": "100"])
        try await Task.sleep(nanoseconds: 60_000_000)
        fakes[0].rejection = "touch_not_down"
        client.active.sendControl("pointer_drag", coordinates: ["x": "200", "y": "200"])
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(client.active.controlActive); XCTAssertEqual(states, [false, true])
        fakes[0].rejection = nil
        client.active.sendControl("pointer_drag", coordinates: ["x": "300", "y": "300"])
        client.active.sendControl("ping")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(fakes[0].controls.last?["action"], "pointer_move")
        XCTAssertTrue(client.active.controlStatus.contains("松开左键"))
        client.active.sendControl("pointer_up", coordinates: ["x": "300", "y": "300"])
        client.active.sendControl("pointer_down", coordinates: ["x": "400", "y": "400"])
        client.active.sendControl("pointer_drag", coordinates: ["x": "500", "y": "500"])
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(fakes[0].controls.suffix(3).compactMap { $0["action"] }, ["pointer_up", "pointer_down", "pointer_drag"])
        XCTAssertFalse(fakes[0].controls.contains { $0["action"] == "stop" })
        XCTAssertEqual(states, [false, true]); XCTAssertFalse(client.active.controlStatus.contains("取消"))
        client.pauseInput(); XCTAssertEqual(states, [false, true, false])
        observer.cancel(); client.disconnectAll()
    }
    @MainActor func testDragCoalescingPreservesPressAndReleaseBoundaries() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        client.startControl(mouse: true); try await Task.sleep(nanoseconds: 50_000_000)
        fakes[0].inputDelay = 50_000_000
        client.active.sendControl("pointer_down", coordinates: ["x": "100", "y": "100"])
        for x in [200, 300, 400] { client.active.sendControl("pointer_drag", coordinates: ["x": String(x), "y": "200"]) }
        client.active.sendControl("pointer_up", coordinates: ["x": "500", "y": "300"])
        client.active.sendControl("pointer_move", coordinates: ["x": "600", "y": "400"])
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(fakes[0].controls.compactMap { $0["action"] }, ["pointer_start", "pointer_down", "pointer_drag", "pointer_up", "pointer_move"])
        XCTAssertEqual(fakes[0].controls.compactMap { $0["x"] }, ["100", "400", "500", "600"])
        XCTAssertTrue(fakes[1].controls.isEmpty); client.disconnectAll()
    }
    @MainActor func testSuccessfulMovementAndHeartbeatDoNotRestartMouseCapture() async throws {
        let (client, _, _) = fixture(); try await connect(client)
        var states: [Bool] = []
        let observer = client.active.pointerControlStates.sink { states.append($0) }
        client.startControl(mouse: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(states, [false, true])
        for action in ["pointer_move", "ping", "pointer_tap", "back", "ping"] {
            client.active.sendControl(action, coordinates: action.hasPrefix("pointer_") ? ["x": "5000", "y": "5000"] : [:])
            try await Task.sleep(nanoseconds: 65_000_000)
        }
        XCTAssertTrue(client.active.controlActive)
        XCTAssertEqual(states, [false, true], "Acknowledgements must not restart an existing capture")
        client.pauseInput()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(states, [false, true, false])
        observer.cancel(); client.disconnectAll()
    }
    @MainActor func testPointerMovementCoalescesWithoutReorderingClicksAndStopDropsQueue() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        client.setControlMode(true); client.startControl(mouse: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(client.active.pointerMode)
        fakes[0].inputDelay = 60_000_000
        client.active.sendControl("pointer_move", coordinates: ["x": "100", "y": "100"])
        for x in [200, 300] { client.active.sendControl("pointer_move", coordinates: ["x": String(x), "y": "100"]) }
        client.active.sendControl("pointer_tap", coordinates: ["x": "400", "y": "200"])
        client.active.sendControl("pointer_move", coordinates: ["x": "500", "y": "200"])
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(fakes[0].controls.compactMap { $0["x"] }, ["100", "300", "400", "500"])
        XCTAssertTrue(fakes[1].controls.isEmpty)
        client.active.sendControl("pointer_move", coordinates: ["x": "600", "y": "200"])
        client.active.sendControl("pointer_tap", coordinates: ["x": "700", "y": "200"])
        client.pauseInput()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(client.active.controlActive); XCTAssertFalse(client.active.pointerMode)
        XCTAssertFalse(fakes[0].controls.contains { $0["x"] == "700" })
        XCTAssertEqual(fakes[0].controls.last?["action"], "stop")
        client.disconnectAll()
    }
    @MainActor func testControlsNeverBroadcastAndDeviceSwitchStopsPreviousPhone() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        client.setBroadcast(true); client.setControlMode(true); client.startControl()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(client.active.controlActive); XCTAssertTrue(client.paused)
        client.active.sendControl("home")
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(fakes[0].inputs.map(\.value), ["start", "home"])
        XCTAssertTrue(fakes[1].inputs.isEmpty)
        client.select(client.devices[1])
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(client.devices[0].controlActive)
        XCTAssertEqual(fakes[0].inputs.last?.value, "stop")
        client.disconnectAll()
    }
    @MainActor func testControlPermissionFailureAndPauseDuringStartCannotReactivate() async throws {
        let (client, fakes, _) = fixture(); try await connect(client)
        fakes[0].rejection = "accessibility_disabled"
        client.startControl(); try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(client.active.controlActive)
        XCTAssertTrue(client.active.controlStatus.contains("开启辅助功能"))
        fakes[0].rejection = nil; fakes[0].inputDelay = 100_000_000
        client.startControl(); try await Task.sleep(nanoseconds: 20_000_000)
        client.pauseInput(); try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(client.active.controlActive)
        XCTAssertEqual(fakes[0].inputs.last?.value, "stop")
        client.disconnectAll()
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
    @MainActor func testPopoverConnectsSavedTargetsOnceAndKeepsInputPaused() async throws {
        let (client, _, _) = fixture()
        client.connectFromPopover(); client.connectFromPopover()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(client.active.connected); XCTAssertTrue(client.paused)
        XCTAssertFalse(client.devices[1].connected)
        client.connectFromPopover()
        XCTAssertTrue(client.active.connected); XCTAssertFalse(client.active.busy)
        client.setBroadcast(true); client.toggleRecipient(client.devices[1])
        client.connectFromPopover()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(client.devices.allSatisfy(\.connected)); XCTAssertTrue(client.paused)
        client.newDevice(); client.connectFromPopover()
        XCTAssertFalse(client.hasSavedInputTargets); XCTAssertFalse(client.active.busy)
        client.disconnectAll()
    }

}
