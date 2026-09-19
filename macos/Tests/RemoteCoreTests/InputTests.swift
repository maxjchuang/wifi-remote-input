// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
@testable import RemoteCore

final class InputTests: XCTestCase {
    @MainActor func testCompositionOnlySendsCommittedUnicode() async {
        let view = CommitTextView()
        view.permitted = { true }
        var received: [String] = []
        view.onCommit = { received.append($0) }
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(received.isEmpty)
        view.insertText("你好👋", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(received, ["你好👋"])
        XCTAssertEqual(view.string, "")
        XCTAssertFalse(view.hasMarkedText())
        view.setMarkedText("unfinished", selectedRange: NSRange(location: 10, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.discardComposition()
        XCTAssertEqual(received, ["你好👋"])
        XCTAssertFalse(view.hasMarkedText())
        view.permitted = { false }
        view.insertText("不可发送", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(received, ["你好👋"])
    }
    @MainActor func testKeysAndCompositionAreSeparate() async {
        let view = CommitTextView(); view.permitted = { true }
        var keys: [String] = []; view.onKey = { keys.append($0) }
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.doCommand(by: NSSelectorFromString("deleteBackward:"))
        XCTAssertTrue(keys.isEmpty)
        view.discardComposition()
        for command in ["insertNewline:", "deleteBackward:", "moveLeft:", "moveRight:", "moveUp:", "moveDown:"] { view.doCommand(by: NSSelectorFromString(command)) }
        XCTAssertEqual(keys, ["Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"])
    }
    @MainActor func testOrderedBurstCoalescesWithoutCrossingKeys() async throws {
        var sent: [InputEvent] = []; var confirmed: [InputEvent] = []; var inFlight = false
        let pipeline = InputPipeline(interval: 1, exchange: { event in
            XCTAssertFalse(inFlight); inFlight = true
            try await Task.sleep(nanoseconds: 1_000_000)
            sent.append(event); inFlight = false; return "ok"
        }, result: { confirmed.append($0) }, failure: { _ in XCTFail() })
        pipeline.enqueue(InputEvent("text.commit", "你")); pipeline.enqueue(InputEvent("text.commit", "好"))
        pipeline.enqueue(InputEvent("key.press", "Backspace")); pipeline.enqueue(InputEvent("text.commit", "👋"))
        for _ in 0..<100 { if pipeline.isIdle { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(pipeline.isIdle)
        XCTAssertEqual(confirmed, sent)
        XCTAssertEqual(sent, [InputEvent("text.commit", "你好"), InputEvent("key.press", "Backspace"), InputEvent("text.commit", "👋")])
    }
    @MainActor func testRejectionDiscardsFollowingInputWithoutRetry() async throws {
        for status in ["password_blocked", "no_editor", "unauthorized"] {
            var count = 0; var errors: [String] = []
            let pipeline = InputPipeline(interval: 1, exchange: { _ in count += 1; return status }, result: { _ in XCTFail() }, failure: { errors.append($0) })
            pipeline.enqueue(InputEvent("text.commit", "你好")); pipeline.enqueue(InputEvent("key.press", "Enter"))
            for _ in 0..<100 { if pipeline.isIdle { break }; try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(count, 1); XCTAssertEqual(errors, [status])
        }
    }
    @MainActor func testPauseClearsQueuedInputAndSizeIsBounded() async throws {
        var count = 0
        let pipeline = InputPipeline(interval: 1, exchange: { _ in count += 1; return "ok" }, result: { _ in }, failure: { _ in XCTFail() })
        XCTAssertFalse(pipeline.enqueue(InputEvent("text.commit", String(repeating: "👋", count: 2049))))
        pipeline.enqueue(InputEvent("text.commit", "不要发送")); pipeline.discardPending()
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(count, 0)
    }
    @MainActor func testUnknownDeliveryDoesNotRetry() async throws {
        var count = 0; var errors: [String] = []
        let pipeline = InputPipeline(interval: 1, exchange: { _ in count += 1; throw RemoteError.rejected }, result: { _ in XCTFail() }, failure: { errors.append($0) })
        pipeline.enqueue(InputEvent("text.commit", "你好")); pipeline.enqueue(InputEvent("key.press", "Enter"))
        for _ in 0..<100 { if pipeline.isIdle { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(count, 1); XCTAssertEqual(errors, ["delivery_unknown"])
    }
}
