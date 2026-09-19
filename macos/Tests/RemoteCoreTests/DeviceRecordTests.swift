// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import RemoteCore
final class DeviceRecordTests: XCTestCase {
    func testFriendlyComputerNamePrefersSystemLabelAndReplacesAssetCode() {
        XCTAssertEqual(DeviceNames.automaticComputerName(systemName: "Max 的 MacBook", modelName: "MacBook Pro"), "Max 的 MacBook")
        XCTAssertEqual(DeviceNames.automaticComputerName(systemName: "KM61XPGFV6", modelName: "MacBook Pro"), "MacBook Pro")
        XCTAssertEqual(DeviceNames.automaticComputerName(systemName: nil, modelName: "Mac mini"), "Mac mini")
    }
    func testNameSanitizationUsesAndroidLengthAndRejectsDisplaySpoofing() {
        XCTAssertEqual(DeviceNames.cleaned("\n Mac\u{202e}\u{2066}\t ", fallback: "Mac"), "Mac")
        XCTAssertEqual(DeviceNames.cleaned("  ", fallback: "Mac"), "Mac")
        XCTAssertEqual(DeviceNames.cleaned(String(repeating: "👋", count: 80), fallback: "Mac").utf16.count, 80)
    }
    func testEmptyBroadcastDoesNotFallBackToSelectedPhone() {
        XCTAssertFalse(InputTargets(selected: "A", broadcast: []).ready(available: ["A"]))
        XCTAssertTrue(InputTargets(selected: "A").ready(available: ["A", "B"]))
        XCTAssertFalse(InputTargets(selected: "A", broadcast: ["A", "B"]).ready(available: ["A"]))
    }
}
