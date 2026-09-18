// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import RemoteCore

@MainActor final class Client: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey: "address") ?? ""
    @Published var fingerprint = UserDefaults.standard.string(forKey: "fingerprint") ?? ""
    @Published var code = ""
    @Published var text = "你好，小米 13 👋"
    @Published var status = "未连接"
    @Published var connected = false
    @Published var busy = false
    private var transport: Transport?
    private var generation = UUID()
    func disconnect() { generation = UUID(); transport?.close(); transport = nil; connected = false; busy = false; status = "已断开" }
    func pair(_ offer: PairingOffer) {
        address = offer.address; fingerprint = offer.fingerprint; code = offer.code
        connect()
    }
    func connect() {
        disconnect(); busy = true; status = "正在验证手机身份…"
        let current = generation
        Task {
            do {
                let pin = try Transport.normalizedFingerprint(fingerprint)
                let connection = try Transport(address: address.trimmingCharacters(in: .whitespacesAndNewlines), fingerprint: pin)
                transport = connection
                let result: [String: Any]
                if !code.isEmpty {
                    let pairingCode = code; code = ""
                    result = try await connection.exchange("pair", ["code": pairingCode])
                } else if let token = DeviceKeychain.load(pin) {
                    result = try await connection.exchange("auth", ["token": token])
                } else { throw RemoteError.rejected }
                guard current == generation else { return }
                guard let state = result["status"] as? String, ["paired", "authenticated"].contains(state) else { status = "认证失败：请在手机重新生成二维码或备用配对码"; transport?.close(); busy = false; return }
                if let token = result["token"] as? String { try DeviceKeychain.save(token, pin: pin) }
                UserDefaults.standard.set(address, forKey: "address"); UserDefaults.standard.set(pin, forKey: "fingerprint")
                connected = true; status = "已认证连接 · 请在手机选中普通输入框"; busy = false
            } catch {
                guard current == generation else { return }
                transport?.close(); transport = nil; connected = false; busy = false
                status = "连接失败：确认两端同一 Wi-Fi、手机接收已开启，或重新生成二维码"
            }
        }
    }
    func send(_ type: String, value: String) {
        guard connected, !busy, let transport else { return }
        busy = true
        let current = generation
        Task {
            do {
                let response = try await transport.exchange(type, [type == "text.commit" ? "text" : "key": value])
                guard current == generation else { return }
                switch response["status"] as? String {
                case "ok": status = "手机已接受输入"
                case "password_blocked": status = "已拒绝：密码输入框禁止远程输入"
                case "device_locked": status = "手机已锁屏，请先解锁"
                case "no_editor": status = "请启用并选中 WiFi Remote Input，再点击手机输入框"
                case "unauthorized", "authentication_failed": disconnect(); status = "配对已失效，请重新配对"
                default: status = "手机拒绝或未能确认输入，请检查输入框"
                }
            } catch {
                guard current == generation else { return }
                disconnect(); status = "连接已中断；输入结果未知，请检查手机后重连"
            }
            busy = false
        }
    }
    func checkConnection() async {
        guard connected, !busy, let transport else { return }
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
    func forget() { disconnect(); if let pin = try? Transport.normalizedFingerprint(fingerprint) { DeviceKeychain.remove(pin) }; code = ""; status = "已清除本机设备密钥；可在手机撤销配对" }
}

@main struct WiFiRemoteInputApp: App {
    @StateObject private var client = Client()
    @State private var showScanner = false
    @State private var showManual = false
    var body: some Scene {
        WindowGroup("WiFi Remote Input") {
            VStack(alignment: .leading, spacing: 14) {
                Text("WiFi Remote Input").font(.title)
                Text("中文通过加密局域网连接发送。手机需选中 WiFi Remote Input 输入法。").foregroundStyle(.secondary)
                HStack {
                    Button { showScanner = true } label: { Label("扫码配对", systemImage: "qrcode.viewfinder") }
                        .buttonStyle(.borderedProminent).disabled(client.connected || client.busy)
                    Button("连接已配对手机") { client.code = ""; client.connect() }
                        .disabled(client.connected || client.busy || client.address.isEmpty)
                    Button("断开") { client.disconnect() }
                    Button("忘记设备") { client.forget() }
                }
                DisclosureGroup("手动配对 / 连接设置", isExpanded: $showManual) {
                    VStack(spacing: 8) {
                        TextField("手机地址，例如 192.168.1.20:8765", text: $client.address)
                        TextField("手机显示的完整 SHA-256 证书指纹（64 位）", text: $client.fingerprint)
                        SecureField("首次配对填写 8 位验证码；已配对留空", text: $client.code)
                        Button("手动连接 / 配对") { client.connect() }
                    }.disabled(client.connected || client.busy)
                }
                Text(client.status).font(.callout).accessibilityIdentifier("connectionStatus")
                TextEditor(text: $client.text).font(.body).frame(minHeight: 140).border(Color.secondary.opacity(0.3))
                HStack {
                    Button("发送文本") { client.send("text.commit", value: client.text) }.keyboardShortcut(.return, modifiers: .command).disabled(client.text.isEmpty || client.text.utf16.count > 4096)
                    ForEach(["Enter", "Backspace", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"], id: \.self) { key in
                        Button(["ArrowLeft": "←", "ArrowRight": "→", "ArrowUp": "↑", "ArrowDown": "↓"][key] ?? key) { client.send("key.press", value: key) }
                    }
                }.disabled(!client.connected || client.busy)
                Text("密码框默认禁止输入 · ⌘Return 发送 · 不会自动重发输入").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(minWidth: 720, minHeight: 450)
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { offer in
                    // A queued camera callback must not pair after the user dismissed the sheet.
                    guard showScanner else { return }
                    showScanner = false
                    client.pair(offer)
                }
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    await client.checkConnection()
                }
            }
        }
    }
}
