import NetToysKit
import AppKit
import NetToysCore
import OnePlusUI
import SwiftUI

@main
struct NetToysApp: App {
    @NSApplicationDelegateAdaptor private var delegate: NetToysAppDelegate
    @State private var host = NetToysHost(id: .standalone)
    @State private var shell = NetToysShell()
    @State private var prefill: NetToysScanPrefill?
    @AppStorage("nettoys.enabled") private var enabled = false
    @State private var transitioning = false
    @State private var menuSnapshot = NetToysTraySnapshot()
    @Environment(\.openWindow) private var openWindow

    private var enablement: Binding<Bool> {
        Binding(get: { enabled }, set: { value in
            guard !transitioning else { return }
            transitioning = true
            Task {
                if await host.loginItems.setEnabled(value) { enabled = value }
                transitioning = false
            }
        })
    }

    var body: some Scene {
        Window("Sam's Network Utilities", id: "nettoys") {
            OnePlusWindowContent {
                NetToysWindowView(host: host, shell: shell, enabled: enablement, isTransitioning: transitioning) {
                    defer { prefill = nil }
                    return prefill
                }
                .background(NetToysWindowRestore())
            }
            .onOpenURL { url in
                guard let route = NetToysRoute(url) else { return }
                if let toolID = route.toolID { return shell.open(toolID, input: route.input) }
                if let destination = route.page { shell.selection = destination.selectionID }
                prefill = route.prefill
                if let prefill { NotificationCenter.default.post(name: .netToysPrefill, object: prefill) }
            }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        // The window opens only on a user launch; a login launch stays in the menu bar.
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            NetToysMenuContent(snapshot: $menuSnapshot, host: host) { destination in
                shell.selection = destination.selectionID
                openMainWindow()
            }
        } label: {
            Group {
                if let glyph = NetToysGlyph.menuBarImage { Image(nsImage: glyph) } else { Image(systemName: "network") }
            }
            .accessibilityLabel("Sam's Network Utilities")
            // The label exists from launch, so monitoring starts here even when no window opens.
            .task {
                guard delegate.reopen == nil else { return } // first appearance only
                delegate.reopen = openMainWindow
                NetToysPalettePanel.shared.shell = shell
                NetToysPalettePanel.shared.openWindow = openMainWindow
                let globalPalette = UserDefaults.standard.object(forKey: NetToysPalettePanel.hotKeyDefaultsKey) as? Bool ?? true
                NetToysPalettePanel.shared.setHotKey(enabled: globalPalette)
                // No activate here: a normal launch is already front, and `open -g` must stay in the background.
                if !delegate.launchedAtLogin { openWindow(id: "nettoys") }
                if enabled { enabled = await host.loginItems.setEnabled(true) }
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu panel brings the window forward, as the MacPowerToys tray did.
    private func openMainWindow() {
        openWindow(id: "nettoys")
        NSApp.activate()
    }
}

@MainActor
final class NetToysAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var launchedAtLogin = false
    var reopen: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SMAppService.mainApp launches carry the "launched as login item" property in the open event.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// A Dock click or a second launch opens the window when none is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { reopen?() }
        return true
    }
}

private struct NetToysWindowRestore: NSViewRepresentable {
    func makeNSView(context: Context) -> RestoreView { RestoreView() }
    func updateNSView(_ nsView: RestoreView, context: Context) {}

    final class RestoreView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !window.isVisible, window.identifier == nil else { return }
            window.identifier = NSUserInterfaceItemIdentifier("nettoys")
            window.setFrameUsingName("NetToys.window")
            window.setFrameAutosaveName("NetToys.window")
        }
    }
}
