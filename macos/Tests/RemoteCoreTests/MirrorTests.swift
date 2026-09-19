// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
@testable import RemoteCore

final class MirrorTests: XCTestCase {
    @MainActor func testOneEditorKeepsConfirmedTextAndCompositionDoesNotSendEarly() async {
        let view = CommitTextView(); view.mirrorsEditor = true; view.permitted = { true }
        let original = EditorSnapshot(editorId: "1", text: "已有", selection: NSRange(location: 2, length: 0))
        var edits: [[String: String]] = []
        view.onEdit = { edits.append($0); return true }
        view.synchronize(original, pending: false, blocked: false)
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.synchronize(original, pending: false, blocked: false)
        XCTAssertTrue(edits.isEmpty); XCTAssertTrue(view.hasMarkedText())
        view.insertText("你好👋", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "已有你好👋"); XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0]["expectedHash"], EditorEdit.hash(text: original.text, selection: original.selection))
        XCTAssertEqual(edits[0]["selectionStart"], "6")
        view.synchronize(original, pending: true, blocked: false)
        XCTAssertEqual(view.string, "已有你好👋")
    }
    @MainActor func testNativeSelectionReplacementAndDeletionStayInSameEditor() async {
        let view = CommitTextView(); view.mirrorsEditor = true; view.permitted = { true }
        var edits: [[String: String]] = []; view.onEdit = { edits.append($0); return true }
        view.synchronize(EditorSnapshot(editorId: "7", text: "abc", selection: NSRange(location: 1, length: 1)), pending: false, blocked: false)
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "a中c")
        view.doCommand(by: NSSelectorFromString("deleteBackward:"))
        XCTAssertEqual(view.string, "ac"); XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[1]["expectedHash"], EditorEdit.hash(text: "a中c", selection: NSRange(location: 2, length: 0)))
    }
    @MainActor func testPhoneUpdateNeverEchoesAndFocusLossDropsOnlyComposition() async {
        let view = CommitTextView(); view.mirrorsEditor = true; view.permitted = { true }
        var edits = 0; var pauses = 0
        view.onEdit = { _ in edits += 1; return true }; view.onPause = { pauses += 1 }
        view.synchronize(EditorSnapshot(editorId: "1", text: "手机已有", selection: NSRange(location: 4, length: 0)), pending: false, blocked: false)
        view.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = view.resignFirstResponder()
        XCTAssertEqual(view.string, "手机已有"); XCTAssertEqual(edits, 0); XCTAssertEqual(pauses, 1)
        view.synchronize(nil, pending: false, blocked: true)
        XCTAssertEqual(view.string, ""); XCTAssertFalse(view.hasMarkedText())
        view.synchronize(EditorSnapshot(editorId: "2", text: "另一个框", selection: NSRange(location: 1, length: 0)), pending: false, blocked: false)
        XCTAssertEqual(view.string, "另一个框"); XCTAssertEqual(edits, 0)
    }
    @MainActor func testRegainingNativeFocusRequestsResume() async {
        let view = CommitTextView(); view.mirrorsEditor = true
        var resumes = 0; view.onInputClick = { resumes += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view)); XCTAssertGreaterThan(resumes, 0)
        let before = resumes
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertGreaterThan(resumes, before)
        window.close()
    }
    @MainActor func testBackgroundPausedRefreshLeavesOtherEditorCompositionUntouched() async {
        let remote = CommitTextView(); remote.mirrorsEditor = true; remote.permitted = { true }
        var sent: [String] = []; remote.onCommit = { sent.append($0) }
        remote.setMarkedText("unfinished", selectedRange: NSRange(location: 10, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = remote.resignFirstResponder()
        let other = NSTextView()
        other.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<100 { remote.synchronize(nil, pending: false, blocked: true); remote.discardComposition() }
        XCTAssertFalse(remote.hasMarkedText()); XCTAssertEqual(remote.string, "")
        XCTAssertTrue(other.hasMarkedText()); XCTAssertEqual(other.string, "nihao")
        other.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(other.string, "你好"); XCTAssertTrue(sent.isEmpty)
    }
    @MainActor func testReturnAndExplicitLineBreakDoNotReplaceDocument() async {
        let view = CommitTextView(); view.mirrorsEditor = true; view.permitted = { true }
        var keys: [String] = []; view.onKey = { keys.append($0) }; view.onEdit = { _ in XCTFail(); return false }
        view.synchronize(EditorSnapshot(editorId: "1", text: "hello", selection: NSRange(location: 5, length: 0)), pending: false, blocked: false)
        view.doCommand(by: NSSelectorFromString("insertNewline:")); view.doCommand(by: NSSelectorFromString("insertLineBreak:"))
        XCTAssertEqual(keys, ["Enter", "LineBreak"]); XCTAssertEqual(view.string, "hello")
    }
}
