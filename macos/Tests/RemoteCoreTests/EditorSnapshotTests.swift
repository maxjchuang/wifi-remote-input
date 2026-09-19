// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import RemoteCore
final class EditorSnapshotTests: XCTestCase {
    func testSnapshotReplacesContentIncludingEmptyEditorAndUTF16Selection() throws {
        var response: [String: Any] = ["status": "snapshot", "editorId": "1", "text": "你好👋", "selectionStart": 2, "selectionEnd": 4]
        let snapshot = try EditorSnapshot(response: response)
        XCTAssertEqual(snapshot.text, "你好👋"); XCTAssertEqual(snapshot.selection, NSRange(location: 2, length: 2))
        response["editorId"] = "2"; response["text"] = ""; response["selectionStart"] = 0; response["selectionEnd"] = 0
        XCTAssertEqual(try EditorSnapshot(response: response).text, "")
    }
    func testRejectsMalformedAndProtectedSnapshots() {
        let valid: [String: Any] = ["status": "snapshot", "editorId": "1", "text": "你好", "selectionStart": 0, "selectionEnd": 2]
        for (key, value) in [("status", "password_blocked" as Any), ("text", String(repeating: "x", count: 2049)), ("selectionStart", -1), ("selectionEnd", 3), ("selectionStart", true), ("selectionEnd", 1.5), ("editorId", "")] {
            var response = valid; response[key] = value
            XCTAssertThrowsError(try EditorSnapshot(response: response))
        }
    }
}
