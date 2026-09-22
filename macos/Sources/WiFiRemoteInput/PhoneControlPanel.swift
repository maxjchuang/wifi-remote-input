// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Combine
import RemoteCore

struct PhoneControlPanel: View {
    @ObservedObject var client: Client
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 8 : 18) {
            if !compact {
                HStack {
                    Text("键鼠协同 · 点中手机输入框即可打字").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    EnterModeControl(selection: $client.enterMode)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.primary.opacity(0.035))
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: compact ? 20 : 36, weight: .light))
                    Text(client.active.controlActive ? "鼠标捕获中" : "点击捕获鼠标").font(.system(size: compact ? 13 : 18, weight: .medium))
                    if !compact { Text("移动鼠标 → 移动手机指针\n左键  点击／按住拖动     右键  返回\n点中手机输入框后直接打字\nEsc  退出捕获 · 请看手机屏幕").font(.system(size: 12)).lineSpacing(10).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }.opacity(client.active.controlActive && client.active.editorSnapshot != nil ? 0 : 1).allowsHitTesting(false)
                ControlKeyArea(client: client)
            }.frame(maxHeight: .infinity).frame(minHeight: compact ? 65 : 180)
            HStack(spacing: 16) {
                action("返回", "arrow.uturn.backward", "back")
                action("主页", "house", "home")
                action("最近任务", "square.on.square", "recents")
                Spacer(minLength: 0)
                if client.active.controlActive { Button("暂停") { client.active.stopControl() }.buttonStyle(.plain) }
            }.font(.system(size: 11)).disabled(!client.active.controlActive)
            Text(client.active.controlActive ? (client.active.editorSnapshot != nil ? "键鼠协同中 · " + client.active.controlStatus : client.active.snapshotStatus + " · " + client.active.controlStatus) : client.active.controlStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if !client.active.connected { Button("连接当前手机") { client.connect() }.buttonStyle(.plain) }
        }
        .onDisappear { client.active.stopControl() }
    }
    private func action(_ title: String, _ icon: String, _ command: String) -> some View {
        Button { client.active.sendControl(command) } label: { Label(title, systemImage: icon) }.buttonStyle(.plain)
    }
}

private struct ControlKeyArea: NSViewRepresentable {
    let client: Client
    func makeNSView(context: Context) -> ControlKeysView { let view = ControlKeysView(); view.client = client; view.configureEditor(); return view }
    func updateNSView(_ view: ControlKeysView, context: Context) { view.client = client; view.synchronizeEditor() }
    static func dismantleNSView(_ view: ControlKeysView, coordinator: ()) { view.stop() }
}

final class ControlKeysView: CommitTextView {
    private var snapshotTask: Task<Void, Never>?
    private var synchronizedEditorID: String?
    func configureEditor() {
        mirrorsEditor = true; isRichText = false; drawsBackground = false; allowsUndo = false
        font = .systemFont(ofSize: 18); textContainerInset = NSSize(width: 20, height: 20)
        autoresizingMask = [.width, .height]; textContainer?.widthTracksTextView = true
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false; isAutomaticSpellingCorrectionEnabled = false
        permitted = { [weak self] in
            guard let self, self.capturing, self.window?.isKeyWindow == true, self.window?.firstResponder === self,
                  let device = self.capturedDevice else { return false }
            return device.acceptsAutoInput && device.editorSnapshot != nil
        }
        onEdit = { [weak self] payload in
            guard let self, self.permitted(), let data = try? JSONEncoder().encode(payload),
                  let value = String(data: data, encoding: .utf8) else { return false }
            self.capturedDevice?.send("editor.edit", value: value); return true
        }
        onCommit = { [weak self] in self?.capturedDevice?.send("text.commit", value: $0) }
        onKey = { [weak self] in self?.capturedDevice?.send("key.press", value: $0) }
        onPause = { [weak self] in self?.stop() }
        client?.active.registerInputView(self)
    }
    func synchronizeEditor() {
        textColor = .labelColor; insertionPointColor = .labelColor
        guard let device = capturedDevice else { synchronize(nil, pending: false, blocked: true); return }
        if synchronizedEditorID != device.editorSnapshot?.editorId { discardComposition(); synchronizedEditorID = device.editorSnapshot?.editorId }
        synchronize(device.editorSnapshot, pending: device.mirrorPending, blocked: !capturing || device.paused)
    }
    private func invalidateEditor() {
        discardComposition(); capturedDevice?.pauseInput(notify: false); synchronizeEditor()
    }
    weak var client: Client?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var captureWatch: AnyCancellable?
    private(set) var capturing = false
    var mouseCapture = MouseCaptureLease()
    private var captureRequested = false
    private weak var capturedDevice: DeviceSession?
    private var previousMouseEvents = false
    private var pointerX = 5000.0
    private var pointerY = 5000.0
    private var dirtyPointer = false
    private var leftPressed = false
    private var movementTimer: Timer?
    private func coordinates() -> [String: String] { ["x": String(Int(pointerX.rounded())), "y": String(Int(pointerY.rounded()))] }
    private func beginCapture() {
        if capturing { return }
        // The initiating mouseDown already belongs to this view. Re-reading the global
        // cursor after a network round trip is unreliable across displays and cursor warps.
        guard captureRequested, let window, window.isKeyWindow, window.firstResponder === self else { stop(); return }
        guard mouseCapture.acquire() else { stop(); return }
        capturing = true; pointerX = 5000; pointerY = 5000; dirtyPointer = false; leftPressed = false
        capturedDevice?.registerInputView(self)
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.capturing else { return }
                if !self.leftPressed { await self.capturedDevice?.refreshSnapshot(); self.synchronizeEditor() }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
        previousMouseEvents = window.acceptsMouseMovedEvents; window.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel, .otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, self.capturing else { return event }
            guard self.window?.isKeyWindow == true, self.window?.firstResponder === self else { self.stop(); return event }
            switch event.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
                self.pointerX = min(10000, max(0, self.pointerX + event.deltaX * 14))
                self.pointerY = min(10000, max(0, self.pointerY + event.deltaY * 14))
                self.dirtyPointer = true
            case .leftMouseDown:
                self.dirtyPointer = false
                self.leftPressed = true
                self.invalidateEditor()
                self.capturedDevice?.sendControl("pointer_down", coordinates: self.coordinates())
            case .leftMouseUp:
                if self.leftPressed {
                    self.leftPressed = false; self.dirtyPointer = false
                    self.capturedDevice?.sendControl("pointer_up", coordinates: self.coordinates())
                }
            case .rightMouseDown:
                if !self.leftPressed { self.invalidateEditor(); self.capturedDevice?.sendControl("back") }
            default: break
            }
            return nil
        }
        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, self.capturing, self.dirtyPointer else { return }
            self.dirtyPointer = false; self.capturedDevice?.sendControl(self.leftPressed ? "pointer_drag" : "pointer_move", coordinates: self.coordinates())
        } }
    }
    private func releaseCapture() {
        snapshotTask?.cancel(); snapshotTask = nil
        discardComposition(); capturedDevice?.pauseInput(notify: false)
        captureRequested = false
        captureWatch?.cancel(); captureWatch = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        movementTimer?.invalidate(); movementTimer = nil
        if capturing { mouseCapture.release(); window?.acceptsMouseMovedEvents = previousMouseEvents }
        capturing = false; dirtyPointer = false; leftPressed = false
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { requestCapture() }
    func requestCapture() {
        guard !capturing, let client, client.active.connected else { return }
        window?.makeFirstResponder(self)
        captureRequested = true; capturedDevice = client.active
        client.startControl(mouse: true)
        captureWatch = client.active.pointerControlStates.receive(on: RunLoop.main).sink { [weak self] active in
            guard let self else { return }
            if active && self.captureRequested { self.beginCapture() }
            else if self.capturing { self.releaseCapture() }
        }
    }
    override func becomeFirstResponder() -> Bool { super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { stop(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        timer?.invalidate(); timer = nil
        guard let window else { stop(); return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, self.window?.isKeyWindow == true, self.window?.firstResponder === self else { return }
            self.client?.active.sendControl("ping")
        } }
        setAccessibilityLabel("点击捕获鼠标，左键点击手机，右键返回，Esc 退出捕获")
    }
    func stop() { releaseCapture(); capturedDevice?.stopControl(); capturedDevice = nil; client?.active.stopControl() }
    override func keyDown(with event: NSEvent) {
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return }
        if hasMarkedText() { super.keyDown(with: event); return }
        if event.keyCode == 53 { stop(); window?.makeFirstResponder(nil); return }
        if permitted() { super.keyDown(with: event); return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        let shift = event.modifierFlags.contains(.shift)
        let action: String?
        switch event.keyCode {
        case 123: action = "left"
        case 124: action = "right"
        case 125: action = "down"
        case 126: action = "up"
        case 48: action = shift ? "previous" : "next"
        case 36, 76: action = shift ? "long_click" : "click"
        case 116: action = "scroll_up"
        case 121: action = "scroll_down"
        default: action = nil
        }
        if let action { client?.active.sendControl(action) }
    }
    deinit { snapshotTask?.cancel(); mouseCapture.release(); if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; movementTimer?.invalidate(); timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}


/// Balances cursor association and visibility, including repeated teardown paths.
final class MouseCaptureLease {
    private let associate: (Bool) -> Bool
    private let hide: () -> Void
    private let show: () -> Void
    private(set) var active = false
    init(associate: @escaping (Bool) -> Bool = { CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0) == .success },
         hide: @escaping () -> Void = { NSCursor.hide() }, show: @escaping () -> Void = { NSCursor.unhide() }) {
        self.associate = associate; self.hide = hide; self.show = show
    }
    func acquire() -> Bool {
        if active { return true }
        guard associate(false) else { return false }
        active = true; hide(); return true
    }
    func release() {
        guard active else { return }
        active = false; _ = associate(true); show()
    }
    deinit { release() }
}
