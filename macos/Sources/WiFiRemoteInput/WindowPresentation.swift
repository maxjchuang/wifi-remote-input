// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import RemoteCore

/// A single status item and transient popover share the workspace's connection.
@MainActor final class WindowPresentation: NSObject, ObservableObject, NSPopoverDelegate {
    enum Panel { case input, scanner }
    @Published var requestedPanel: Panel?
    private let client: Client
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var heartbeat: Timer?
    private var workspace: NSWindow?

    init(client: Client) { self.client = client; super.init() }
    func register(_ window: NSWindow) {
        workspace = window
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = AppIcon.statusImage()
        item.button?.toolTip = "WiFi Remote Input"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.client.checkConnection() }
        }
    }
    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover?.isShown == true { popover?.performClose(nil) }
        else { showPopover(anchor: sender) }
    }
    func showPopover(hideWorkspace: Bool = false, anchor: NSStatusBarButton? = nil) {
        guard let button = anchor ?? statusItem?.button, button.window != nil else { return }
        client.pauseInput()
        if hideWorkspace { workspace?.orderOut(nil) }
        // Do not activate the workspace before resolving the clicked menu bar's anchor.
        // With separate Spaces per display that can switch the active menu bar to the
        // workspace's display. A fresh popover also avoids a previous display's window.
        popover?.close()
        let panel = NSPopover()
        panel.behavior = .transient
        panel.delegate = self
        panel.animates = false
        panel.contentSize = NSSize(width: 360, height: 270)
        panel.contentViewController = NSHostingController(rootView: WorkspaceView(client: client, presentation: self, compact: true))
        popover = panel
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard panel.isShown else { return }
        // A menu-bar popover must not activate the application's workspace/Space.
        // Activation can close this transient popover and briefly raise the workspace
        // on another display. Only explicit showWorkspace() activates the application.
        panel.contentViewController?.view.window?.makeKey()
    }

    func showWorkspace(panel: Panel? = .input) {
        client.pauseInput()
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspace?.makeKeyAndOrderFront(nil)
        // Wait for the workspace to become key before navigating to the scanner.
        DispatchQueue.main.async { self.requestedPanel = panel }
    }
    func popoverWillClose(_ notification: Notification) { client.pauseInput() }
    func quit() { client.disconnectAll(); NSApp.terminate(nil) }
}

struct WorkspaceRegistration: NSViewRepresentable {
    let presentation: WindowPresentation
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { presentation.register(window) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the running application's Dock/app-switcher icon after local updates.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
