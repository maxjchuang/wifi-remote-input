// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

/// One native editor for remote text and local IME composition. Remote updates never commit text.
open class CommitTextView: NSTextView {
    public var mirrorsEditor = false
    public var broadcast = false
    public var onEdit: ([String: String]) -> Bool = { _ in false }
    private var base: EditorSnapshot?
    private var compositionBase: EditorSnapshot?
    private var editingCommand = false
    public func synchronize(_ snapshot: EditorSnapshot?, pending: Bool, blocked: Bool) {
        guard mirrorsEditor else { return }
        if blocked { discardComposition(); base = nil; string = ""; return }
        guard !pending, !hasMarkedText(), !editingCommand else { return }
        guard base != snapshot || string != (snapshot?.text ?? "") else { return }
        base = snapshot
        string = snapshot?.text ?? ""
        setSelectedRange(snapshot?.selection ?? NSRange(location: 0, length: 0))
    }
    private func finishEdit(from previous: EditorSnapshot) {
        let range = selectedRange()
        guard previous.text != string || previous.selection != range else { return }
        guard let payload = EditorEdit.payload(from: previous, text: string, selection: range), onEdit(payload) else {
            string = previous.text; setSelectedRange(previous.selection); return
        }
        base = EditorSnapshot(editorId: previous.editorId, text: string, selection: range)
    }
    public var permitted: () -> Bool = { false }
    public var onCommit: (String) -> Void = { _ in }
    public var onKey: (String) -> Void = { _ in }
    public var onPause: () -> Void = { }
    public var onInputClick: () -> Void = { }
    open override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onInputClick() }
        return accepted
    }
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    open override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onInputClick()
        let previous = base
        editingCommand = true
        super.mouseDown(with: event)
        editingCommand = false
        if mirrorsEditor, !broadcast, permitted(), let previous, !hasMarkedText() { finishEdit(from: previous) }
        else if mirrorsEditor, let previous { setSelectedRange(previous.selection) }
    }
    private var discarding = false
    private var focusObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let window {
            activationObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, self.window?.firstResponder === self else { return }
                self.onInputClick()
            }
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.discardComposition(); self?.onPause()
            }
        }
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
    public func discardComposition() {
        guard !discarding else { return }
        discarding = true
        defer { discarding = false }
        // Never touch NSTextInputContext from background refresh/focus-loss callbacks.
        // The system input method may already belong to another application's editor.
        // Remove only this view's marked range; do not synthesize a new composition.
        if hasMarkedText() {
            // Resolve only the existing local marked range, bypassing our forwarding override.
            super.insertText("", replacementRange: markedRange())
            super.unmarkText()
        }
        if mirrorsEditor, let saved = compositionBase ?? base {
            if string != saved.text { string = saved.text }
            if selectedRange() != saved.selection { setSelectedRange(saved.selection) }
            base = saved
        } else if !string.isEmpty { string = ""; setSelectedRange(NSRange(location: 0, length: 0)) }
        compositionBase = nil
    }
    open override func resignFirstResponder() -> Bool {
        // Never let focus loss implicitly commit an unfinished candidate to the phone.
        discardComposition()
        onPause()
        return super.resignFirstResponder()
    }
    open override func setMarkedText(_ text: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !discarding, permitted() else { discardComposition(); return }
        if mirrorsEditor, !hasMarkedText() { compositionBase = base }
        super.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    open override func insertText(_ text: Any, replacementRange: NSRange) {
        guard !discarding, permitted() else { discardComposition(); return }
        let value = (text as? NSAttributedString)?.string ?? (text as? String ?? "")
        if mirrorsEditor, !broadcast, let previous = compositionBase ?? base {
            editingCommand = true
            super.insertText(text, replacementRange: replacementRange)
            editingCommand = false; compositionBase = nil
            finishEdit(from: previous)
        } else {
            super.insertText(text, replacementRange: replacementRange)
            discardComposition()
            if !value.isEmpty { onCommit(value) }
        }
    }
    open override func cut(_ sender: Any?) {
        guard mirrorsEditor, !broadcast, permitted(), let previous = base, !hasMarkedText() else { return }
        super.cut(sender); finishEdit(from: previous)
    }
    open override func selectAll(_ sender: Any?) {
        guard !broadcast else { return }
        let previous = base
        super.selectAll(sender)
        if mirrorsEditor, !editingCommand, permitted(), let previous { finishEdit(from: previous) }
    }
    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    open override func doCommand(by selector: Selector) {
        guard !discarding, permitted() else { discardComposition(); return }
        if hasMarkedText() { super.doCommand(by: selector); return }
        let mapping = ["insertNewline:": "Enter", "deleteBackward:": "Backspace", "moveLeft:": "ArrowLeft", "moveRight:": "ArrowRight", "moveUp:": "ArrowUp", "moveDown:": "ArrowDown"]
        let command = NSStringFromSelector(selector)
        if command == "insertNewline:" || command == "insertLineBreak:" || command == "insertNewlineIgnoringFieldEditor:" {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onKey(shift || command == "insertLineBreak:" ? "LineBreak" : "Enter")
        } else if mirrorsEditor, !broadcast, let previous = base,
                  mapping[command] != nil || command.hasPrefix("delete") || command.hasPrefix("move") || command == "selectAll:" {
            editingCommand = true; super.doCommand(by: selector); editingCommand = false
            finishEdit(from: previous)
        } else if let key = mapping[command] { onKey(key) }
        else if NSStringFromSelector(selector) == "cancelOperation:" { discardComposition(); onPause() }
        // Unsupported editing commands are intentionally local/no-op, not mapped to other keys.
    }
}
