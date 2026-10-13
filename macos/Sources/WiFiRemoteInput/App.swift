// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Combine
import CryptoKit
import RemoteCore

protocol SessionConnection: AnyObject {
    func exchange(_ type: String, _ payload: [String: String]) async throws -> [String: Any]
    func close()
}
extension Transport: SessionConnection {}

@MainActor final class DeviceSession: ObservableObject, Identifiable {
    let id = UUID().uuidString
    @Published var name = "未命名手机"
    var onConnected: (() -> Void)?
    private(set) var wantsReconnect = false
    var onPause: (() -> Void)?
    var computerName: () -> String = { "Mac" }
    private let makeConnection: (String, String) throws -> SessionConnection
    private let loadKey: (String) -> String?
    private let saveKey: (String, String) throws -> Void
    private let removeKey: (String) -> Void
    init(record: DeviceRecord? = nil,
         makeConnection: @escaping (String, String) throws -> SessionConnection = { try Transport(address: $0, fingerprint: $1) },
         loadKey: @escaping (String) -> String? = DeviceKeychain.load,
         saveKey: @escaping (String, String) throws -> Void = { try DeviceKeychain.save($0, pin: $1) },
         removeKey: @escaping (String) -> Void = DeviceKeychain.remove) {
        self.makeConnection = makeConnection; self.loadKey = loadKey; self.saveKey = saveKey; self.removeKey = removeKey
        enterMode = record?.enterMode ?? "auto"
        address = record?.address ?? ""; fingerprint = record?.fingerprint ?? ""; name = record?.name ?? "未命名手机"
    }
    @Published var address = ""
    @Published var fingerprint = ""
    @Published var code = ""
    @Published var mirrorPending = false
    @Published var enterMode = "auto"
    @Published var editorSnapshot: EditorSnapshot?
    @Published var snapshotStatus = "连接后同步手机输入框"
    private let inputViews = NSHashTable<NSView>.weakObjects()
    private var lastSnapshot = Date.distantPast
    private var snapshotEpoch = UUID()
    @Published var paused = false
    @Published var focusToken = 0
    @Published var status = "未连接"
    @Published var blockingReason: String?
    @Published var inputProblem: String?
    @Published var connected = false
    @Published var busy = false
    @Published private(set) var controlActive = false
    @Published private(set) var controlStarting = false
    @Published private(set) var pointerMode = false
    var pointerControlStates: AnyPublisher<Bool, Never> {
        $controlActive.combineLatest($pointerMode)
            .map { $0 && $1 }.removeDuplicates().eraseToAnyPublisher()
    }
    private var controlQueue: [(String, [String: String])] = []
    @Published private(set) var controlStatus = "点击捕获鼠标 · 请看手机上的圆形指针"
    private var controlTask: Task<Void, Never>?
    private var controlEpoch = UUID()
    private var controlTaskID = UUID()
    private var lastPointerSend = Date.distantPast
    private var lastControlCoordinates: [String: String] = [:]
    private var dragInterrupted = false
    private var dragNotice: String?
    func stopControl() {
        guard controlActive || controlTask != nil else { return }
        controlActive = false; controlStarting = false; pointerMode = false; dragInterrupted = false; dragNotice = nil; controlQueue.removeAll(); controlEpoch = UUID()
        controlStatus = "控制已暂停 · 点击控制区继续"
        sendControl("stop")
    }
    func sendControl(_ action: String, coordinates: [String: String] = [:]) {
        guard connected, !updating || action == "stop" else { return }
        guard action == "start" || action == "pointer_start" || action == "stop" || controlActive else { return }
        if controlTask != nil && !["stop", "start", "pointer_start"].contains(action) {
            guard controlActive, action != "ping", action != "start", action != "pointer_start" else { return }
            if controlQueue.last?.0 == action {
                if action == "pointer_move" { controlQueue.removeLast() }
                else if action == "pointer_drag", let tail = controlQueue.last {
                    let origin = controlQueue.dropLast().last?.1 ?? lastControlCoordinates
                    if Self.sameDirection(origin, tail.1, coordinates) { controlQueue.removeLast() }
                }
            }
            guard controlQueue.count < 32 else { stopControl(); controlStatus = "操作积压，已退出捕获；请重新开始"; return }
            controlQueue.append((action, coordinates)); return
        }
        if action == "start" || action == "pointer_start" {
            controlStarting = true; controlStatus = "正在请求手机控制…"
        }
        let previous = controlTask
        let taskID = UUID(); controlTaskID = taskID
        let epoch = controlEpoch
        let current = generation
        controlTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            while self.busy || self.sending || !self.pipeline.isIdle {
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard current == self.generation, epoch == self.controlEpoch else { return }
            }
            guard current == self.generation, let transport = self.transport else { return }
            if action != "stop" && epoch != self.controlEpoch { return }
            self.busy = true
            defer {
                if current == self.generation {
                    self.busy = false
                    if epoch == self.controlEpoch && taskID == self.controlTaskID {
                        self.controlTask = nil; self.controlStarting = false
                        if self.controlActive && !self.controlQueue.isEmpty {
                            let next = self.controlQueue.removeFirst(); self.sendControl(next.0, coordinates: next.1)
                        } else { self.controlQueue.removeAll() }
                    }
                }
            }
            if self.pointerMode && action != "stop" {
                let wait = (1.0 / 30.0) - Date().timeIntervalSince(self.lastPointerSend)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard current == self.generation, epoch == self.controlEpoch else { return }
                self.lastPointerSend = Date()
            }
            do {
                // Once a stroke is cancelled, move only the visible pointer until the physical release.
                // Never synthesize another touch-down for an interrupted gesture.
                let wireAction = action == "pointer_drag" && self.dragInterrupted ? "pointer_move" : action
                if coordinates["x"] != nil { self.lastControlCoordinates = coordinates }
                let result = try await transport.exchange("control.action", coordinates.merging(["action": wireAction]) { _, new in new })
                guard current == self.generation, epoch == self.controlEpoch else { return }
                switch result["status"] as? String {
                case "ok":
                    if action == "pointer_up" { self.dragInterrupted = false }
                    if ["pointer_down", "pointer_start", "stop"].contains(action) { self.dragInterrupted = false; self.dragNotice = nil }
                    self.controlActive = action != "stop"
                    if action == "pointer_start" { self.pointerMode = true }
                    if action == "start" || action == "stop" { self.pointerMode = false }
                    self.controlStatus = self.dragNotice ?? (action == "stop" ? "控制已暂停" : (self.pointerMode ? "鼠标捕获中 · 左键点击 · 右键返回 · Esc 退出" : "键盘控制中 · Esc 退出"))
                case "touch_not_down":
                    self.dragInterrupted = true
                    self.dragNotice = "本次拖动已被手机取消 · 松开左键后重新按下，鼠标仍在捕获中"
                    self.controlStatus = self.dragNotice!
                case "gesture_unavailable": self.controlActive = false; self.controlStatus = "手机无法执行触控，请在更新 App 后重新开启辅助功能"
                case "gesture_busy":
                    if action == "pointer_down" {
                        self.dragInterrupted = true
                        self.dragNotice = "手机仍在结束上次触摸 · 请松开左键后重新按下"
                    }
                    self.controlStatus = self.dragNotice ?? "上一次点击尚未完成，请稍后再点"
                case "accessibility_disabled": self.controlActive = false; self.controlStatus = "请在手机 App → 手机控制 → 开启辅助功能"
                case "device_locked": self.controlActive = false; self.controlStatus = "请先解锁手机，再点击开始控制"
                case "control_paused": self.controlActive = false; self.controlStatus = "手机已暂停控制 · 点击重新开始"
                case "control_busy": self.controlActive = false; self.controlStatus = "另一连接正在控制手机"
                case "no_controls": self.controlStatus = "当前页面没有可选控件，仍可返回或回到主页"
                case "selection_changed": self.controlStatus = "页面已变化，请用方向键重新选择"
                case "action_unavailable": self.controlStatus = "此控件不支持该操作，请重新选择"
                case "password_blocked":
                    if action == "pointer_down" { self.dragInterrupted = true; self.dragNotice = "密码控件禁止远程操作 · 请松开左键" }
                    self.controlStatus = self.dragNotice ?? "密码控件禁止远程操作"
                case "unknown_type", "invalid_action": self.controlActive = false; self.controlStatus = "请更新手机 App 至 0.9.3 以使用鼠标控制"
                default: self.controlActive = false; self.controlStatus = "控制已暂停，请检查手机连接"
                }
            } catch { self.disconnect(allowReconnect: true); self.controlStatus = "连接中断，控制已停止；操作不会自动重发" }
        }
    }
    private static func sameDirection(_ a: [String: String], _ b: [String: String], _ c: [String: String]) -> Bool {
        guard let ax = Double(a["x"] ?? ""), let ay = Double(a["y"] ?? ""),
              let bx = Double(b["x"] ?? ""), let by = Double(b["y"] ?? ""),
              let cx = Double(c["x"] ?? ""), let cy = Double(c["y"] ?? "") else { return false }
        let dx = bx - ax, dy = by - ay, ex = cx - bx, ey = cy - by
        return dx * ex + dy * ey >= 0 && abs(dx * ey - dy * ex) < 0.001
    }
    @Published private(set) var updating = false
    @Published private(set) var updateStatus = ""
    private var updateTask: Task<Void, Never>?
    func pushUpdate(_ url: URL) {
        guard connected, !updating else { return }
        pauseInput(notify: false); stopControl()
        updating = true; updateStatus = "准备安装包…"
        let current = generation
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 80 * 1024 * 1024 else { throw UpdateFailure.invalidFile }
                let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                guard bytes.count <= 80 * 1024 * 1024 else { throw UpdateFailure.invalidFile }
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                while self.busy || self.sending || self.controlTask != nil || !self.pipeline.isIdle {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    guard current == self.generation else { throw CancellationError() }
                }
                guard let transport = self.transport, current == self.generation else { throw CancellationError() }
                self.busy = true
                defer { if current == self.generation { self.busy = false } }
                @MainActor func request(_ type: String, _ payload: [String: String]) async throws -> String {
                    try Task.checkCancellation()
                    guard current == self.generation else { throw CancellationError() }
                    let reply = try await transport.exchange(type, payload)
                    let status = reply["status"] as? String ?? "invalid_response"
                    guard status == "ok" || status == "update_ready" else { throw UpdateFailure.rejected(status) }
                    return status
                }
                _ = try await request("update.begin", ["size": String(bytes.count), "sha256": hash])
                for offset in stride(from: 0, to: bytes.count, by: 8192) {
                    try await Task.sleep(nanoseconds: 40_000_000)
                    let end = min(offset + 8192, bytes.count)
                    _ = try await request("update.chunk", ["offset": String(offset), "data": bytes.subdata(in: offset..<end).base64EncodedString()])
                    self.updateStatus = "推送更新 \(end * 100 / bytes.count)%"
                }
                try await Task.sleep(nanoseconds: 40_000_000)
                let result = try await request("update.finish", [:])
                guard result == "update_ready" else { throw UpdateFailure.invalidFile }
                self.updateStatus = "推送完成，请在手机确认安装"
            } catch {
                if current == self.generation {
                    if case UpdateFailure.rejected(let reason) = error {
                        switch reason {
                        case "unknown_type": self.updateStatus = "请先手动安装支持推送的手机版本"
                        case "update_not_allowed", "update_expired": self.updateStatus = "请在手机允许接收更新后重试"
                        case "update_rejected": self.updateStatus = "手机校验失败：需同签名、更高版本 APK"
                        default: self.updateStatus = "推送被拒绝，请在手机检查更新状态"
                        }
                    } else { self.updateStatus = "推送中断或文件不可读，请重新连接后重试" }
                    // Close the upload owner so Android removes incomplete data; never replay chunks.
                    self.disconnect()
                }
            }
            if current == self.generation { self.updating = false; self.updateTask = nil }
        }
    }
    private enum UpdateFailure: Error { case invalidFile, rejected(String) }
    private var transport: SessionConnection?
    private var generation = UUID()
    private var sending = false
    private var inputEpoch = UUID()
    private lazy var pipeline: InputPipeline = InputPipeline(exchange: { [weak self] event in
        guard let self, let transport = self.transport, self.connected else { throw RemoteError.rejected }
        let epoch = self.inputEpoch
        while self.busy {
            try await Task.sleep(nanoseconds: 10_000_000)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard !self.paused, epoch == self.inputEpoch else { return "discarded" }
        self.sending = true
        defer { self.sending = false }
        let current = self.generation
        let payload: [String: String]
        if event.type == "editor.edit" { payload = try JSONDecoder().decode([String: String].self, from: Data(event.value.utf8)) }
        else { payload = [event.type == "text.commit" ? "text" : "key": event.value] }
        let response = try await transport.exchange(event.type, payload)
        guard current == self.generation else { return "discarded" }
        if response["status"] as? String == "ok", !self.pipeline.hasPending, Date().timeIntervalSince(self.lastSnapshot) >= 0.3, self.hasVisibleInputWindow {
            await self.readSnapshot(using: transport)
        }
        return response["status"] as? String ?? "invalid_response"
    }, result: { [weak self] _ in
        self?.status = self?.paused == true ? "已暂停 · 最后一条输入已确认" : "手机已接受输入"
    }, failure: { [weak self] status in self?.inputFailed(status) })
    func registerInputView(_ view: NSView) { inputViews.add(view) }
    private var hasVisibleInputWindow: Bool {
        inputViews.allObjects.contains { view in
            view.window?.isVisible == true && view.window?.isKeyWindow == true && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
        }
    }
    func clearSnapshot(_ message: String = "等待同步手机输入框") {
        snapshotEpoch = UUID(); mirrorPending = false; editorSnapshot = nil; snapshotStatus = message
    }
    func refreshSnapshot() async {
        guard connected, !updating, controlTask == nil, !busy, !sending, pipeline.isIdle, let transport else { return }
        guard hasVisibleInputWindow else { clearSnapshot("返回窗口后同步"); return }
        busy = true
        let current = generation
        await readSnapshot(using: transport)
        if current == generation { busy = false }
    }
    private func readSnapshot(using transport: SessionConnection) async {
        let current = generation
        let epoch = snapshotEpoch
        lastSnapshot = Date()
        do {
            let response = try await transport.exchange("editor.snapshot", [:])
            guard current == generation, epoch == snapshotEpoch, hasVisibleInputWindow else { return }
            mirrorPending = false
            let state = response["status"] as? String ?? "invalid_response"
            if state == "snapshot" {
                editorSnapshot = try EditorSnapshot(response: response)
                if blockingReason == "no_editor" {
                    inputProblem = nil
                    status = "手机输入框已就绪 · 点击输入区继续"
                }
                blockingReason = nil
                snapshotStatus = "与手机同步"
                if controlActive && pointerMode { paused = false; inputProblem = nil }
            } else {
                editorSnapshot = nil
                switch state {
                case "password_blocked": snapshotStatus = "密码框禁止读取"; inputFailed(state)
                case "device_locked": snapshotStatus = "手机已锁屏"; inputFailed(state)
                case "no_editor": snapshotStatus = "请在手机选中输入框"; inputFailed(state)
                case "editor_too_large": snapshotStatus = "内容超过 2048 字符限制，无法完整显示"
                case "unknown_type": snapshotStatus = "请将 Android 更新至 0.4.0"
                case "unauthorized", "authentication_failed": disconnect(); snapshotStatus = "配对已失效"
                default: snapshotStatus = "当前应用不支持读取完整输入框"
                }
            }
        } catch {
            guard current == generation else { return }
            disconnect(allowReconnect: true); snapshotStatus = "连接中断，正在寻找已配对手机…"
        }
    }
    var acceptsAutoInput: Bool { connected && !paused }
    func pauseInput(notify: Bool = true) {
        if connected && !paused { status = "已暂停 · 点击输入区继续" }
        snapshotEpoch = UUID(); mirrorPending = false; editorSnapshot = nil
        if snapshotStatus == "与手机同步" { snapshotStatus = "等待同步手机输入框" }
        inputEpoch = UUID(); paused = true; pipeline.discardPending()
        if notify { onPause?() }
    }
    func resumeInput() { guard connected, !updating else { return }; inputProblem = nil; paused = false; status = "输入已就绪 · 中文选词确认后发送"; focusToken += 1 }
    private func inputFailed(_ response: String) {
        // Missing editors pause typing without releasing the mouse lease.
        pauseInput(notify: !controlActive)
        blockingReason = response
        switch response {
        case "editor_conflict": clearSnapshot("手机内容或光标已变化，正在重新同步"); status = "已暂停：手机内容已变化，请核对后继续"
        case "unknown_type": clearSnapshot("请更新手机 App 至 0.6.0"); status = "请更新手机 App 至 0.6.0"
        case "password_blocked": clearSnapshot("密码框禁止读取"); status = "已暂停：密码框禁止远程输入"
        case "device_locked": status = "已暂停：请先解锁手机"
        case "no_editor": status = "已暂停：手机未选中输入框，请先在手机点击输入位置"
        case "unauthorized", "authentication_failed": disconnect(); status = "配对已失效，请重新配对"
        case "delivery_unknown": disconnect(allowReconnect: true); status = "连接中断，输入结果未知；请检查手机后重连"
        default: status = "已暂停：手机未能接受输入，请检查输入框"
        }
        inputProblem = status
    }
    func disconnect(allowReconnect: Bool = false) { updateTask?.cancel(); updateTask = nil; updating = false; controlActive = false; controlStarting = false; pointerMode = false; dragInterrupted = false; dragNotice = nil; controlQueue.removeAll(); controlEpoch = UUID(); controlTask = nil; wantsReconnect = allowReconnect; blockingReason = nil; onPause?(); clearSnapshot("连接后同步手机输入框"); pipeline.reset(); paused = true; generation = UUID(); transport?.close(); transport = nil; connected = false; busy = false; status = "已断开" }
    func pair(_ offer: PairingOffer) {
        address = offer.address; fingerprint = offer.fingerprint; code = offer.code
        connect()
    }
    func connect(candidateAddress: String? = nil) {
        let destination = candidateAddress ?? address
        disconnect(allowReconnect: true); inputProblem = nil; busy = true; status = "正在验证手机身份…"
        let current = generation
        Task {
            do {
                let pin = try Transport.normalizedFingerprint(fingerprint)
                let connection = try makeConnection(destination.trimmingCharacters(in: .whitespacesAndNewlines), pin)
                transport = connection
                let result: [String: Any]
                if !code.isEmpty {
                    let pairingCode = code; code = ""
                    result = try await connection.exchange("pair", ["code": pairingCode, "deviceName": computerName()])
                } else if let token = loadKey(pin) {
                    result = try await connection.exchange("auth", ["token": token, "deviceName": computerName()])
                } else { throw RemoteError.rejected }
                guard current == generation else { return }
                guard let state = result["status"] as? String, ["paired", "authenticated"].contains(state) else { wantsReconnect = false; status = "认证失败：请在手机重新生成二维码并扫码"; transport?.close(); busy = false; return }
                if let token = result["token"] as? String { try saveKey(token, pin) }
                address = destination
                fingerprint = pin
                name = DeviceNames.cleaned(result["deviceName"] as? String ?? name, fallback: "未命名手机")
                connected = true; paused = false; focusToken += 1; status = "已连接 · 点击输入区开始，手机需选中普通输入框"; busy = false
                onConnected?()
            } catch {
                guard current == generation else { return }
                transport?.close(); transport = nil; connected = false; busy = false
                status = "连接失败：确认两端同一 Wi-Fi、手机接收已开启，或重新生成二维码"
            }
        }
    }
    func send(_ type: String, value: String) {
        guard connected, !updating, !paused else { return }
        snapshotEpoch = UUID(); mirrorPending = true
        let value = type == "key.press" && value == "Enter" ? (enterMode == "send" ? "Send" : enterMode == "newline" ? "LineBreak" : value) : value
        guard pipeline.enqueue(InputEvent(type, value)) else {
            pauseInput(); status = "已暂停：输入过长或积压，请检查手机后继续；内容不会自动重发"
            return
        }
    }
    var inputIdle: Bool { pipeline.isIdle && !sending }
    @Published private(set) var diagnosticFile: URL?
    @Published private(set) var diagnosticStatus = "连接后自动同步手机日志"
    func saveDiagnostics(_ text: String) {
        guard text.utf8.count <= 32_768, !fingerprint.isEmpty else { return }
        do {
            let directory = URL(fileURLWithPath: "/tmp/wifi-remote-input", isDirectory: true)
            let fm = FileManager.default
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw CocoaError(.fileWriteNoPermission) }
            let key = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent("phone-" + key + ".log")
            // Replace one bounded snapshot; never append duplicate history or use a peer-supplied path.
            try Data(text.utf8).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            diagnosticFile = file
            diagnosticStatus = text.isEmpty ? "手机日志同步已关闭" : "手机日志已同步至 /tmp"
        } catch { diagnosticStatus = "日志保存失败，请检查 /tmp 目录权限" }
    }
    func checkConnection() async {
        guard connected, !updating, controlTask == nil, !busy, !sending, pipeline.isIdle, let transport else { return }
        busy = true
        let current = generation
        do {
            let response = try await transport.exchange("session.ping", [:])
            guard current == generation else { return }
            if response["status"] as? String != "pong" { disconnect(); status = "设备认证已失效，请重新连接" }
            else if let logs = response["diagnostics"] as? String { saveDiagnostics(logs) }
        } catch {
            guard current == generation else { return }
            disconnect(allowReconnect: true); status = "连接已中断，正在寻找已配对手机…"
        }
        busy = false
    }
    func forget() { disconnect(); if let pin = try? Transport.normalizedFingerprint(fingerprint) { removeKey(pin) }; code = ""; status = "已清除本机设备密钥；可在手机撤销配对" }
}

@main struct WiFiRemoteInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var client: Client
    @StateObject private var presentation: WindowPresentation
    init() {
        let client = Client()
        _client = StateObject(wrappedValue: client)
        _presentation = StateObject(wrappedValue: WindowPresentation(client: client))
    }
    var body: some Scene {
        Window("WiFi Remote Input", id: "main") { WorkspaceView(client: client, presentation: presentation)
                .background(WorkspaceRegistration(presentation: presentation)) }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
            .commands { CommandGroup(after: .appInfo) {
                Button("呼出输入小窗") { presentation.summonInput() }
            } }
    }
}
