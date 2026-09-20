// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
import Carbon
@testable import WiFiRemoteInput

final class ShortcutTests: XCTestCase {
    @MainActor func testConflictPreservesWorkingShortcutAndDisabledSetting() {
        let name = "shortcut-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "globalInputShortcutDisabled")
        let first = GlobalShortcut(defaults: defaults)
        let second = GlobalShortcut(defaults: defaults)
        let one = Shortcut(key: 17, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), label: "⌃⌥⇧⌘T")
        let two = Shortcut(key: 32, modifiers: one.modifiers, label: "⌃⌥⇧⌘U")
        XCTAssertTrue(first.set(one)); XCTAssertTrue(second.set(two))
        XCTAssertFalse(second.set(one))
        XCTAssertEqual(second.shortcut, two)
        XCTAssertFalse(second.message.isEmpty)
        XCTAssertTrue(first.set(nil))
        XCTAssertTrue(second.set(one))
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: defaults.data(forKey: "globalInputShortcut")!), one)
        XCTAssertTrue(second.set(nil))
        XCTAssertTrue(defaults.bool(forKey: "globalInputShortcutDisabled"))
        XCTAssertNil(GlobalShortcut(defaults: defaults).shortcut)
    }
    @MainActor func testTypingAndOptionOnlyCannotBecomeGlobalShortcut() {
        func event(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        }
        XCTAssertNil(Shortcut.capture(event([])))
        XCTAssertNil(Shortcut.capture(event(.option)))
        XCTAssertEqual(Shortcut.capture(event([.command, .option])), .standard)
    }
}
