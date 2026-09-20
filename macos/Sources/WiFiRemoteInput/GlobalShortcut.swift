// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Carbon
import SwiftUI

struct Shortcut: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String
    static let standard = Shortcut(key: 34, modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘I")
    static func capture(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control), event.keyCode != 53,
              let character = event.charactersIgnoringModifiers?.uppercased(),
              character.count == 1, character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        var mask: UInt32 = 0
        var prefix = ""
        for (flag, carbon, symbol): (NSEvent.ModifierFlags, Int, String) in [(.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { mask |= UInt32(carbon); prefix += symbol }
        }
        return Shortcut(key: UInt32(event.keyCode), modifiers: mask, label: prefix + character)
    }
}

/// Registers just one system hot key; never monitors ordinary typing in other apps.
@MainActor final class GlobalShortcut: ObservableObject {
    @Published private(set) var shortcut: Shortcut?
    @Published private(set) var message = ""
    var action: () -> Void = {}
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { message = "无法启用快捷键，请重新启动应用"; return }
        let saved = defaults.data(forKey: "globalInputShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        if !defaults.bool(forKey: "globalInputShortcutDisabled") { set(saved ?? .standard) }
    }
    @discardableResult func set(_ value: Shortcut?) -> Bool {
        if value == shortcut { return true }
        var replacement: EventHotKeyRef?
        if let value {
            guard RegisterEventHotKey(value.key, value.modifiers, EventHotKeyID(signature: 0x57524948, id: 1), GetApplicationEventTarget(), 0, &replacement) == noErr else {
                message = "这个快捷键无法注册，可能已被占用；请换一组"; return false
            }
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement; shortcut = value; message = ""
        defaults.set(value == nil, forKey: "globalInputShortcutDisabled")
        if let value { defaults.set(try? JSONEncoder().encode(value), forKey: "globalInputShortcut") }
        return true
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct ShortcutControl: View {
    @ObservedObject var shortcut: GlobalShortcut
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("呼出小窗").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                ShortcutRecorder(title: shortcut.shortcut?.label ?? "设置快捷键") { value in shortcut.set(value) }
                    .frame(width: 83, height: 28)
            }
            Text("点击录入 ⌘ / ⌃ + 字母或数字，Esc 取消")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !shortcut.message.isEmpty { Text(shortcut.message).font(.system(size: 10)).foregroundStyle(.orange) }
            if shortcut.shortcut != nil {
                Button("停用快捷键") { shortcut.set(nil) }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}
private struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    let save: (Shortcut) -> Bool
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ view: RecorderButton, context: Context) { view.savedTitle = title; view.save = save; if !view.recording { view.title = title } }
}
private final class RecorderButton: NSButton {
    var savedTitle = ""
    var save: (Shortcut) -> Bool = { _ in false }
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        target = self; action = #selector(beginRecording)
        isBordered = false; wantsLayer = true; layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        setAccessibilityLabel("设置呼出小窗的全局快捷键")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() { window?.makeFirstResponder(self); recording = true; title = "请按快捷键" }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = savedTitle; return }
        if let value = Shortcut.capture(event) { if save(value) { recording = false; title = value.label } }
        else { title = "需 ⌘ / ⌃" }
    }
    override func resignFirstResponder() -> Bool { recording = false; title = savedTitle; return super.resignFirstResponder() }
}
