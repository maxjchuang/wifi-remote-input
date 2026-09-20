// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
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
    @Published var text = ""
    @Published var mirrorPending = false
    @Published var enterMode = "auto"
    @Published var editorSnapshot: EditorSnapshot?
    @Published var snapshotStatus = "连接后同步手机输入框"
    private let inputViews = NSHashTable<NSView>.weakObjects()
    private var lastSnapshot = Date.distantPast
    private var snapshotEpoch = UUID()
    @Published var autoMode = true
    @Published var paused = false
    @Published var focusToken = 0
    @Published var status = "未连接"
    @Published var blockingReason: String?
    @Published var inputProblem: String?
    @Published var connected = false
    @Published var busy = false
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
        guard connected, !busy, !sending, pipeline.isIdle, let transport else { return }
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
            disconnect(); snapshotStatus = "连接中断，无法同步"
        }
    }
    var acceptsAutoInput: Bool { connected && autoMode && !paused }
    func pauseInput(notify: Bool = true) {
        if connected && !paused { status = "已暂停 · 点击输入区继续" }
        snapshotEpoch = UUID(); mirrorPending = false; editorSnapshot = nil
        if snapshotStatus == "与手机同步" { snapshotStatus = "等待同步手机输入框" }
        inputEpoch = UUID(); paused = true; pipeline.discardPending()
        if notify { onPause?() }
    }
    func resumeInput() { guard connected else { return }; inputProblem = nil; paused = false; status = "输入已就绪 · 中文选词确认后发送"; focusToken += 1 }
    func setMode(_ automatic: Bool) { inputEpoch = UUID(); pipeline.discardPending(); autoMode = automatic; paused = false; focusToken += 1 }
    private func inputFailed(_ response: String) {
        pauseInput()
        blockingReason = response
        switch response {
        case "editor_conflict": clearSnapshot("手机内容或光标已变化，正在重新同步"); status = "已暂停：手机内容已变化，请核对后继续"
        case "unknown_type": clearSnapshot("请更新手机 App 至 0.6.0"); status = "请更新手机 App 至 0.6.0"
        case "password_blocked": clearSnapshot("密码框禁止读取"); status = "已暂停：密码框禁止远程输入"
        case "device_locked": status = "已暂停：请先解锁手机"
        case "no_editor": status = "已暂停：手机未选中输入框，请先在手机点击输入位置"
        case "unauthorized", "authentication_failed": disconnect(); status = "配对已失效，请重新配对"
        case "delivery_unknown": disconnect(); status = "连接中断，输入结果未知；请检查手机后重连"
        default: status = "已暂停：手机未能接受输入，请检查输入框"
        }
        inputProblem = status
    }
    func disconnect() { blockingReason = nil; onPause?(); clearSnapshot("连接后同步手机输入框"); pipeline.reset(); paused = true; generation = UUID(); transport?.close(); transport = nil; connected = false; busy = false; status = "已断开" }
    func pair(_ offer: PairingOffer) {
        address = offer.address; fingerprint = offer.fingerprint; code = offer.code
        connect()
    }
    func connect() {
        disconnect(); inputProblem = nil; busy = true; status = "正在验证手机身份…"
        let current = generation
        Task {
            do {
                let pin = try Transport.normalizedFingerprint(fingerprint)
                let connection = try makeConnection(address.trimmingCharacters(in: .whitespacesAndNewlines), pin)
                transport = connection
                let result: [String: Any]
                if !code.isEmpty {
                    let pairingCode = code; code = ""
                    result = try await connection.exchange("pair", ["code": pairingCode, "deviceName": computerName()])
                } else if let token = loadKey(pin) {
                    result = try await connection.exchange("auth", ["token": token, "deviceName": computerName()])
                } else { throw RemoteError.rejected }
                guard current == generation else { return }
                guard let state = result["status"] as? String, ["paired", "authenticated"].contains(state) else { status = "认证失败：请在手机重新生成二维码并扫码"; transport?.close(); busy = false; return }
                if let token = result["token"] as? String { try saveKey(token, pin) }
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
        guard connected, !paused else { return }
        snapshotEpoch = UUID(); mirrorPending = true
        let value = type == "key.press" && value == "Enter" ? (enterMode == "send" ? "Send" : enterMode == "newline" ? "LineBreak" : value) : value
        guard pipeline.enqueue(InputEvent(type, value)) else {
            pauseInput(); status = "已暂停：输入过长或积压，请检查手机后继续；内容不会自动重发"
            return
        }
    }
    var inputIdle: Bool { pipeline.isIdle && !sending }
    func checkConnection() async {
        guard connected, !busy, !sending, pipeline.isIdle, let transport else { return }
        busy = true
        let current = generation
        do {
            let response = try await transport.exchange("session.ping", [:])
            guard current == generation else { return }
            if response["status"] as? String != "pong" { disconnect(); status = "设备认证已失效，请重新连接" }
        } catch {
            guard current == generation else { return }
            disconnect(); status = "连接已中断，请重新连接"
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
