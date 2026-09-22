// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Combine
import RemoteCore

/// Each phone owns a separate authenticated transport, queue and editor snapshot.
@MainActor final class Client: ObservableObject {
    @Published var controlMode = false
    func setControlMode(_ enabled: Bool) { pauseInput(); controlMode = enabled }
    func startControl(mouse: Bool = false) { pauseInput(); active.sendControl(mouse ? "pointer_start" : "start") }
    @Published private(set) var devices: [DeviceSession] = []
    @Published private(set) var active: DeviceSession
    @Published private(set) var broadcasting = false
    @Published private(set) var recipients: Set<String> = []
    @Published var computerName: String {
        didSet { defaults.set(computerName, forKey: "computerName") }
    }
    private var subscriptions: [String: AnyCancellable] = [:]
    private var groupStatus: String?
    private var discovered: [String: (address: String, seen: Date)] = [:]
    private var lastDiscoveryAttempt: [String: Date] = [:]
    func discoveredDevice(fingerprint: String, address: String) {
        guard devices.contains(where: { $0.fingerprint == fingerprint }),
              (try? Transport.endpoint(address: address)) != nil else { return }
        discovered[fingerprint] = (address, Date())
        reconnectDiscovered()
    }
    private func candidate(for device: DeviceSession) -> String? {
        guard let hint = discovered[device.fingerprint], Date().timeIntervalSince(hint.seen) < 35 else { return nil }
        return hint.address
    }
    private func reconnectDiscovered() {
        for device in devices where device.wantsReconnect && !device.connected && !device.busy {
            guard let address = candidate(for: device), Date().timeIntervalSince(lastDiscoveryAttempt[device.id] ?? .distantPast) >= 30 else { continue }
            lastDiscoveryAttempt[device.id] = Date()
            device.connect(candidateAddress: address)
        }
    }
    private let defaults: UserDefaults
    private let makeSession: @MainActor (DeviceRecord?) -> DeviceSession
    init(defaults: UserDefaults = .standard, makeSession: @escaping @MainActor (DeviceRecord?) -> DeviceSession = { DeviceSession(record: $0) }) {
        self.defaults = defaults; self.makeSession = makeSession
        computerName = defaults.string(forKey: "computerName") ?? DeviceNames.computerName()
        let records = defaults.data(forKey: "phones").flatMap { try? JSONDecoder().decode([DeviceRecord].self, from: $0) } ?? []
        var pins = Set<String>()
        var loaded = records.filter { pins.insert($0.fingerprint).inserted }.map { makeSession($0) }
        if loaded.isEmpty, let address = defaults.string(forKey: "address"),
           let pin = defaults.string(forKey: "fingerprint"), !pin.isEmpty {
            loaded = [makeSession(DeviceRecord(name: "已配对手机", address: address, fingerprint: pin))]
        }
        active = loaded.first ?? makeSession(nil)
        devices = loaded
        for device in devices { observe(device) }
        observe(active)
    }
    private func observe(_ device: DeviceSession) {
        guard subscriptions[device.id] == nil else { return }
        subscriptions[device.id] = device.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        device.computerName = { [weak self] in DeviceNames.cleaned(self?.defaults.string(forKey: "computerName") ?? DeviceNames.computerName(), fallback: "Mac") }
        device.onConnected = { [weak self, weak device] in
            guard let self, let device else { return }
            // Re-scanning the same certificate updates its address, not a duplicate phone.
            let duplicates = self.devices.filter { $0.id != device.id && $0.fingerprint == device.fingerprint }
            for old in duplicates { old.disconnect(); self.subscriptions.removeValue(forKey: old.id); self.recipients.remove(old.id) }
            self.devices.removeAll { $0.id != device.id && $0.fingerprint == device.fingerprint }
            if !self.devices.contains(where: { $0.id == device.id }) { self.devices.append(device) }
            self.persist()
            self.pauseInput()
            self.groupStatus = "已连接 \(device.name) · 点击输入区开始"
            self.objectWillChange.send()
        }
        device.onPause = { [weak self, weak device] in
            guard let self, let device, self.targetIDs.contains(device.id) else { return }
            self.pauseInput()
        }
    }
    private func record(for device: DeviceSession) -> DeviceRecord {
        var record = DeviceRecord(name: device.name, address: device.address, fingerprint: device.fingerprint)
        record.enterMode = device.enterMode; return record
    }
    private func persist() {
        let records = devices.map { record(for: $0) }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "phones") }
        defaults.removeObject(forKey: "address"); defaults.removeObject(forKey: "fingerprint")
    }
    private var plan: InputTargets { InputTargets(selected: active.id, broadcast: broadcasting ? recipients : nil) }
    private var targetIDs: Set<String> { plan.ids }
    private var targets: [DeviceSession] { ([active] + devices.filter { $0.id != active.id }).filter { targetIDs.contains($0.id) } }
    var targetTitle: String { broadcasting ? "同步输入 · \(recipients.count) 台手机" : active.name }
    var targetNames: String { targets.map(\.name).joined(separator: "、") }
    var selectedID: String { active.id }
    func select(_ device: DeviceSession) {
        guard active !== device else { return }
        pauseInput(); active.clearSnapshot(); active = device; active.clearSnapshot()
        groupStatus = nil; objectWillChange.send()
    }
    func newDevice() {
        pauseInput(); broadcasting = false; active.clearSnapshot()
        let draft = makeSession(nil); observe(draft); active = draft; groupStatus = nil
    }
    func setBroadcast(_ enabled: Bool) {
        pauseInput(); broadcasting = enabled
        if enabled && recipients.isEmpty && devices.contains(where: { $0.id == active.id }) { recipients = [active.id] }
        groupStatus = enabled ? "勾选目标手机，然后点击输入区开始" : nil
    }
    func toggleRecipient(_ device: DeviceSession) {
        pauseInput()
        if recipients.contains(device.id) { recipients.remove(device.id) } else { recipients.insert(device.id) }
        groupStatus = "接收对象已更改 · 点击输入区继续"
    }
    var address: String { get { active.address } set { active.address = newValue } }
    var fingerprint: String { get { active.fingerprint } set { active.fingerprint = newValue } }
    var code: String { get { active.code } set { active.code = newValue } }
    var editorSnapshot: EditorSnapshot? { active.editorSnapshot }
    var mirrorPending: Bool { active.mirrorPending }
    var enterMode: String { get { active.enterMode } set { active.enterMode = newValue; persist() } }
    func sendEdit(_ payload: [String: String]) -> Bool {
        guard !broadcasting, acceptsAutoInput, let data = try? JSONEncoder().encode(payload) else { return false }
        send("editor.edit", value: String(decoding: data, as: UTF8.self)); return !paused
    }
    var inputGuidance: (title: String, detail: String)? {
        guard let device = targets.first(where: { $0.connected && $0.blockingReason == "no_editor" }) else { return nil }
        return ("已暂停：手机未选中输入框", "请在「\(device.name)」点击要输入的位置，并选择 WiFi Remote Input 输入法，再回到这里继续。")
    }
    var snapshotStatus: String { active.snapshotStatus }
    var paused: Bool { targets.isEmpty || targets.contains { $0.paused } }
    var focusToken: Int { active.focusToken }
    var connected: Bool { plan.ready(available: Set(targets.filter { $0.connected }.map(\.id))) }
    var busy: Bool { broadcasting ? targets.contains { $0.busy } : active.busy }
    var status: String {
        if broadcasting, let failed = targets.first(where: { $0.inputProblem != nil }) {
            return "\(failed.name)：\(failed.inputProblem!) · 整组暂停，请检查各手机"
        }
        if broadcasting, let failed = targets.first(where: { !$0.connected || $0.paused }) {
            return "\(failed.name)：\(failed.status)"
        }
        return groupStatus ?? active.status
    }
    var acceptsAutoInput: Bool { !controlMode && !paused && plan.ready(available: Set(targets.filter { $0.connected }.map(\.id))) }
    func useAutomaticComputerName() {
        computerName = DeviceNames.computerName()
        defaults.removeObject(forKey: "computerName")
    }
    func registerInputView(_ view: NSView) { active.registerInputView(view) }
    func clearSnapshot(_ message: String = "等待同步手机输入框") { active.clearSnapshot(message) }
    func refreshSnapshot() async { await active.refreshSnapshot() }
    func pauseInput() { for device in devices + [active] { device.pauseInput(notify: false); device.stopControl() }; groupStatus = nil }
    func resumeInput() {
        let available = Set(targets.filter { $0.connected }.map(\.id))
        guard plan.ready(available: available) else {
            groupStatus = broadcasting ? "请先连接所有勾选手机" : "请先连接手机"; objectWillChange.send(); return
        }
        groupStatus = nil
        for device in targets { device.resumeInput() }
        // The preview phone can differ from the broadcast recipients.
        if !targetIDs.contains(active.id) { active.focusToken += 1 }
    }
    func disconnect() { active.disconnect(); groupStatus = nil }
    func disconnectAll() { for device in devices + [active] { device.disconnect() } }
    func pair(_ offer: PairingOffer) { newDevice(); active.pair(offer) }
    func connect() { groupStatus = nil; active.connect(candidateAddress: candidate(for: active)) }
    var hasSavedInputTargets: Bool { !targets.isEmpty && targets.allSatisfy { target in devices.contains { $0.id == target.id } } }
    func connectFromPopover() {
        guard hasSavedInputTargets else { return }
        groupStatus = nil
        for device in targets where !device.connected && !device.busy {
            device.connect(candidateAddress: candidate(for: device))
        }
    }
    func connectTargets() { for device in targets where !device.connected && !device.busy { device.connect(candidateAddress: candidate(for: device)) } }
    func send(_ type: String, value: String) {
        let recipientsNow = targets
        guard plan.ready(available: Set(recipientsNow.filter { $0.connected && !$0.paused }.map(\.id))) else {
            pauseInput(); groupStatus = "输入已暂停：请检查所有目标手机"; objectWillChange.send(); return
        }
        groupStatus = nil
        for device in recipientsNow { device.send(type, value: value) }
    }
    func checkConnection() async { for device in devices { await device.checkConnection() }; reconnectDiscovered() }
    func forget(_ device: DeviceSession? = nil) {
        let forgotten = device ?? active
        discovered.removeValue(forKey: forgotten.fingerprint); lastDiscoveryAttempt.removeValue(forKey: forgotten.id)
        pauseInput(); forgotten.forget(); devices.removeAll { $0.id == forgotten.id }; recipients.remove(forgotten.id)
        subscriptions.removeValue(forKey: forgotten.id)
        if recipients.isEmpty { broadcasting = false }
        if active === forgotten { active = devices.first ?? makeSession(nil); observe(active) }
        persist(); groupStatus = nil
    }
}
