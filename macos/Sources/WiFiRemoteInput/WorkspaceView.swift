// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import RemoteCore

struct WorkspaceView: View {
    @ObservedObject var client: Client
    @ObservedObject var presentation: WindowPresentation
    var compact = false
    private enum Page { case input, scanner }
    @State private var page: Page = .input
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { scheme == .dark ? Color(red: 0.45, green: 0.89, blue: 0.8) : Color(red: 0.02, green: 0.43, blue: 0.37) }
    private var canvas: Color { scheme == .dark ? Color(red: 0.08, green: 0.12, blue: 0.17) : Color(red: 0.94, green: 0.96, blue: 0.97) }
    var body: some View {
        Group {
            if compact { compactContent } else { workspaceContent }
        }
        .background(canvas).tint(accent)
        .frame(width: compact ? 360 : 860, height: compact ? 270 : 560)
        .onReceive(presentation.$requestedPanel) { panel in
            guard !compact, let panel else { return }
            client.pauseInput()
            switch panel {
            case .input: page = .input
            case .scanner: page = .scanner
            }
            presentation.requestedPanel = nil
        }
    }
    private var panelColor: Color { scheme == .dark ? Color(red: 0.11, green: 0.16, blue: 0.22) : .white.opacity(0.8) }
    private var lineColor: Color { scheme == .dark ? Color(red: 0.19, green: 0.26, blue: 0.32) : Color(red: 0.83, green: 0.88, blue: 0.90) }
    private var workspaceContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Text("REMOTE\nINPUT").font(.system(size: 14, weight: .bold, design: .rounded)).tracking(1.5).lineSpacing(3).padding(.horizontal, 10)
                VStack(spacing: 5) {
                    SidebarAction(title: "输入工作台", symbol: "rectangle.and.pencil.and.ellipsis", accent: accent, selected: page == .input) { selectPage(.input) }
                    SidebarAction(title: "扫码配对", symbol: "qrcode.viewfinder", accent: accent, selected: page == .scanner) { openScanner() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("我的手机").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button { client.newDevice(); page = .scanner } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).help("添加手机")
                    }.padding(.horizontal, 10)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(client.devices) { device in
                                HStack(spacing: 6) {
                                    if client.broadcasting {
                                        Button { client.toggleRecipient(device) } label: {
                                            Image(systemName: client.recipients.contains(device.id) ? "checkmark.circle.fill" : "circle")
                                        }.buttonStyle(.plain).foregroundStyle(accent).help("同步输入到 \(device.name)")
                                    }
                                    Button { client.select(device); page = .input } label: {
                                        HStack(spacing: 7) {
                                            Circle().fill(device.connected ? accent : .secondary).frame(width: 5, height: 5)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                                Text(device.connected ? "已连接" : "未连接").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                                if client.broadcasting { Text(device.status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(8).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .background(client.selectedID == device.id ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    Button { client.forget(device) } label: {
                                        Image(systemName: "trash").font(.system(size: 11)).padding(6).contentShape(Rectangle())
                                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                                        .help("忘记「\(device.name)」；再次连接需要扫码")
                                        .accessibilityLabel("忘记手机：" + device.name)
                                }
                            }
                        }
                    }
                    Toggle("多机同步输入", isOn: Binding(get: { client.broadcasting }, set: { client.setBroadcast($0) }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                    if client.broadcasting {
                        Button("连接勾选的手机") { client.connectTargets() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                    }
                }.frame(maxHeight: .infinity)
                ShortcutControl(shortcut: presentation.shortcut)
                Rectangle().fill(lineColor).frame(height: 1)
                Label("本地加密连接", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10)
            }.padding(.horizontal, 16).padding(.vertical, 30).frame(width: 190)
                .background(.primary.opacity(0.02))
            Rectangle().fill(lineColor).frame(width: 1)
            Group {
                switch page {
                case .input: inputContent
                case .scanner:
                    QRScannerPage { offer in
                        guard page == .scanner else { return }
                        page = .input
                        client.pair(offer)
                    }.padding(28)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var inputContent: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(client.targetTitle).font(.system(size: 11, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().frame(width: 5, height: 5)
                        Text(client.connected ? (client.paused ? "PAUSED" : "LIVE") : "未连接")
                    }.font(.system(size: 10, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(accent).background(accent.opacity(0.12), in: Capsule())
                    Button { presentation.showPopover(hideWorkspace: true) } label: { Image(systemName: "menubar.arrow.up.rectangle") }
                        .buttonStyle(QuietControl(color: accent, line: lineColor)).help("切换到状态栏").accessibilityLabel("切换到状态栏")
                }
                if client.broadcasting {
                    Text("接收：\(client.targetNames.isEmpty ? "请勾选手机" : client.targetNames)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(accent).lineLimit(2)
                }
                HStack(spacing: 4) {
                    modeButton("实时输入", automatic: true)
                    modeButton("整段发送", automatic: false)
                }.padding(4).background(lineColor.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(client.autoMode ? "中文选词确认后自动送达" : "编辑完成后整段发送")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if client.autoMode { LiveInputArea(client: client).id(client.selectedID) }
                        else { TextEditor(text: $client.text).font(.system(size: 18)).scrollContentBackground(.hidden) }
                    }.padding(18).frame(maxHeight: .infinity)
                    Rectangle().fill(lineColor).frame(height: 1)
                    HStack(spacing: 12) {
                        Text(client.status).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(client.status)
                        if !client.connected {
                            Button(client.busy ? "连接中…" : "连接") { if client.broadcasting { client.connectTargets() } else { client.address.isEmpty ? openScanner() : client.connect() } }
                                .buttonStyle(QuietControl(color: accent, line: lineColor)).disabled(client.busy)
                        } else if !client.autoMode && !client.paused {
                            Button("发送 ↗") { client.send("text.commit", value: client.text) }
                                .keyboardShortcut(.return, modifiers: .command)
                                .buttonStyle(QuietControl(color: accent, line: lineColor)).disabled(client.text.isEmpty)
                        } else {
                            Button(client.paused ? "继续输入" : "暂停") { client.paused ? client.resumeInput() : client.pauseInput() }
                                .buttonStyle(QuietControl(color: accent, line: lineColor))
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }.background(panelColor, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(lineColor, lineWidth: 1))
                HStack(spacing: 7) {
                    Label("仅当前输入区接收键盘 · 密码框保护", systemImage: "lock")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if client.connected { Button("断开") { client.disconnect() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }.padding(28)
    }

    private func modeButton(_ title: String, automatic: Bool) -> some View {
        Button { client.setMode(automatic) } label: {
            Text(title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                .foregroundStyle(client.autoMode == automatic ? .primary : .secondary)
                .background(client.autoMode == automatic ? panelColor : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(client.autoMode == automatic ? .isSelected : [])
    }
    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(client.connected ? accent : .secondary).frame(width: 6, height: 6)
                Menu {
                    ForEach(client.devices) { device in
                        Button(device.name + (device.connected ? " · 已连接" : " · 未连接")) { client.select(device) }
                    }
                } label: {
                    Text(client.targetTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { presentation.showWorkspace() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(accent)
                    .help("展开工作台").accessibilityLabel("展开工作台")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(client.broadcasting ? "接收：\(client.targetNames.isEmpty ? "请在工作台勾选手机" : client.targetNames)" : (client.autoMode ? "实时输入 · 中文选词后自动送达" : "整段发送 · ⌘Return 发送"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                if client.autoMode {
                    LiveInputArea(client: client).id(client.selectedID).frame(height: 100)
                } else {
                    TextEditor(text: $client.text).font(.system(size: 16))
                        .scrollContentBackground(.hidden).frame(height: 100)
                }
            }.padding(12).background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            HStack(alignment: .top, spacing: 10) {
                Text(client.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).help(client.status)
                if client.autoMode && client.connected {
                    Button(client.paused ? "继续" : "暂停") { client.paused ? client.resumeInput() : client.pauseInput() }
                        .buttonStyle(.plain).foregroundStyle(accent)
                }
                if !client.autoMode {
                    Button("发送") { client.send("text.commit", value: client.text) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.plain).foregroundStyle(accent)
                        .disabled(!client.connected || client.paused || client.text.isEmpty)
                }
            }
            Spacer(minLength: 0)
        }.padding(18)
    }
    private func selectPage(_ destination: Page) {
        client.pauseInput()
        page = destination
    }
    private func openScanner() {
        client.pauseInput()
        if compact { presentation.showWorkspace(panel: .scanner) } else { selectPage(.scanner) }
    }


}

private struct LiveInputArea: View {
    @ObservedObject var client: Client
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(client.broadcasting ? "预览：\(client.active.name) · 各手机使用自己的光标" : "\(client.active.name) · 实时同步")
                    .lineLimit(1).help(client.active.name)
                Spacer()
                EnterModeControl(selection: $client.enterMode)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            LiveInput(client: client)
                .overlay(alignment: .topLeading) {
                    if let guidance = client.inputGuidance {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "iphone.and.arrow.forward").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(guidance.title).font(.system(size: 13, weight: .semibold))
                                Text(guidance.detail).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            .padding(4).allowsHitTesting(false)
                    } else if client.editorSnapshot == nil && !client.mirrorPending {
                        Text(client.connected ? (client.paused ? "点击此处继续 · " + client.snapshotStatus : client.snapshotStatus) : "请先连接手机")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(8).allowsHitTesting(false)
                    }
                }
        }
        .task {
            while !Task.isCancelled {
                await client.refreshSnapshot()
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
            }
        }
        .onDisappear { client.clearSnapshot("返回输入页后同步") }
    }
}

private struct EnterModeControl: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme
    private let modes = [(id: "auto", title: "自动", hint: "执行手机输入框的默认动作"),
                         (id: "send", title: "发送", hint: "请求手机应用发送；微信需开启回车发送"),
                         (id: "newline", title: "换行", hint: "插入换行，不执行发送")]
    private var accent: Color { scheme == .dark ? Color(red: 0.45, green: 0.89, blue: 0.8) : Color(red: 0.02, green: 0.43, blue: 0.37) }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "return").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                ForEach(modes, id: \.id) { mode in
                    Button { selection = mode.id } label: {
                        Text(mode.title).font(.system(size: 10, weight: selection == mode.id ? .semibold : .medium))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(EnterModeButtonStyle(selected: selection == mode.id, accent: accent))
                    .accessibilityLabel("回车模式：" + mode.title)
                    .accessibilityAddTraits(selection == mode.id ? .isSelected : [])
                    .help(mode.hint + "。Shift+Enter 始终换行；设置仅影响当前手机。")
                }
            }.padding(3)
                .background(.primary.opacity(scheme == .dark ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
        }.fixedSize()
    }
}

private struct EnterModeButtonStyle: ButtonStyle {
    let selected: Bool
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? accent : .secondary)
            .background(selected ? accent.opacity(configuration.isPressed ? 0.25 : 0.14) : Color.primary.opacity(configuration.isPressed ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}

private final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        editor.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, editor.frame.height)))
    }
}

private struct LiveInput: NSViewRepresentable {
    @ObservedObject var client: Client
    final class Coordinator { var focus = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let view = CommitTextView()
        client.registerInputView(view)
        view.mirrorsEditor = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isRichText = false; view.drawsBackground = false; view.allowsUndo = false
        view.font = .systemFont(ofSize: 18); view.textContainerInset = NSSize(width: 6, height: 8)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.permitted = { [weak view, weak client] in client?.acceptsAutoInput == true && view?.window?.isKeyWindow == true && view?.window?.firstResponder === view }
        view.onInputClick = { [weak client] in client?.resumeInput() }
        view.onEdit = { [weak client] in client?.sendEdit($0) ?? false }
        view.onCommit = { [weak client] in client?.send("text.commit", value: $0) }
        view.onKey = { [weak client] in client?.send("key.press", value: $0) }
        view.onPause = { [weak client] in client?.pauseInput() }
        view.setAccessibilityLabel("实时同步输入框")
        let scroll = EditorScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { (scroll.documentView as? CommitTextView)?.discardComposition() }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CommitTextView else { return }
        view.textColor = .labelColor; view.insertionPointColor = .labelColor; view.broadcast = client.broadcasting
        view.synchronize(client.editorSnapshot, pending: client.mirrorPending, blocked: !client.connected || client.paused)
        if context.coordinator.focus != client.focusToken {
            context.coordinator.focus = client.focusToken
            if client.acceptsAutoInput { DispatchQueue.main.async { if view.window?.isKeyWindow == true { view.window?.makeFirstResponder(view) } } }
        }
    }
}

private struct SidebarAction: View {
    let title: String
    let symbol: String
    let accent: Color
    var selected = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }.padding(10).contentShape(Rectangle())
                .foregroundStyle(hovered || selected ? accent : .primary)
                .background(accent.opacity(selected ? 0.12 : hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct QuietControl: ButtonStyle {
    let color: Color
    let line: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(color.opacity(enabled ? 1 : 0.35))
            .background(line.opacity(configuration.isPressed ? 0.45 : 0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(line.opacity(enabled ? 1 : 0.5), lineWidth: 1))
    }
}
