// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import WiFiRemoteInput

final class MouseCaptureTests: XCTestCase {
    func testRepeatedReleaseAndDestructionRestoreCursorExactlyOnce() {
        var associations: [Bool] = []; var hidden = 0; var shown = 0
        var capture: MouseCaptureLease? = MouseCaptureLease(associate: { associations.append($0); return true }, hide: { hidden += 1 }, show: { shown += 1 })
        XCTAssertTrue(capture!.acquire()); XCTAssertTrue(capture!.acquire())
        capture!.release(); capture!.release()
        XCTAssertEqual(associations, [false, true]); XCTAssertEqual(hidden, 1); XCTAssertEqual(shown, 1)
        XCTAssertTrue(capture!.acquire()); capture = nil
        XCTAssertEqual(associations, [false, true, false, true]); XCTAssertEqual(hidden, 2); XCTAssertEqual(shown, 2)
    }
    func testCaptureFailureDoesNotHideCursorOrRequireRelease() {
        var calls: [Bool] = []; var hidden = false; var shown = false
        let capture = MouseCaptureLease(associate: { calls.append($0); return false }, hide: { hidden = true }, show: { shown = true })
        XCTAssertFalse(capture.acquire()); capture.release()
        XCTAssertFalse(hidden); XCTAssertFalse(shown); XCTAssertEqual(calls, [false])
    }
}
