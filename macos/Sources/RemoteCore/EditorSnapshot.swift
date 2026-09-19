// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreFoundation

public struct EditorSnapshot: Equatable {
    public let editorId: String
    public let text: String
    public let selection: NSRange
    public init(editorId: String, text: String, selection: NSRange) { self.editorId = editorId; self.text = text; self.selection = selection }
    public init(response: [String: Any]) throws {
        func integer(_ key: String) -> Int? {
            guard let n = response[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue) else { return nil }
            return n.intValue
        }
        guard response["status"] as? String == "snapshot",
              let id = response["editorId"] as? String, !id.isEmpty, id.count <= 64,
              let value = response["text"] as? String, value.utf16.count <= 2048,
              let start = integer("selectionStart"), let end = integer("selectionEnd"),
              start >= 0, end >= 0, start <= value.utf16.count, end <= value.utf16.count else { throw RemoteError.malformedResponse }
        editorId = id; text = value
        selection = NSRange(location: min(start, end), length: abs(end - start))
    }
}
