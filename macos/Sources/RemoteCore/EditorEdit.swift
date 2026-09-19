// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

public struct EditorEdit {
    public static func hash(text: String, selection: NSRange) -> String {
        let value = text + "\u{0}" + String(selection.location) + "," + String(NSMaxRange(selection))
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func payload(from snapshot: EditorSnapshot, text: String, selection: NSRange) -> [String: String]? {
        guard text.utf16.count <= 2048, selection.location >= 0, selection.length >= 0,
              selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location else { return nil }
        return ["editorId": snapshot.editorId, "expectedHash": hash(text: snapshot.text, selection: snapshot.selection),
                "text": text, "selectionStart": String(selection.location), "selectionEnd": String(NSMaxRange(selection))]
    }
}
