import NetToysKit
import AppKit
import NetToysCore
import OnePlusUI
import SwiftUI

@main
struct NetToysApp: App {
    @State private var host = NetToysHost(id: .standalone)
    @State private var page = NetToysPage.scanner
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
        Window("Sam's NetToys", id: "nettoys") {
            OnePlusWindowContent {
                NetToysWindowView(host: host, page: $page, enabled: enablement, isTransitioning: transitioning) {
                    defer { prefill = nil }
                    return prefill
                }
                .background(NetToysWindowRestore())
            }
            .onOpenURL { url in
                guard let route = NetToysRoute(url) else { return }
                if let destination = route.page { page = destination }
                prefill = route.prefill
                if let prefill { NotificationCenter.default.post(name: .netToysPrefill, object: prefill) }
            }
            .task { if enabled { enabled = await host.loginItems.setEnabled(true) } }
        }
        .defaultSize(OnePlusWindowCanvas.netToys.size)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            OnePlusMenuPanel {
                Text("Sam's NetToys")
            } actions: {
                Button("Open Sam's NetToys") { openMainWindow() }
            } content: {
                NetToysMenuContent(snapshot: $menuSnapshot, host: host) { destination in
                    page = destination
                    openMainWindow()
                }
            }
        } label: {
            Group {
                if let glyph = NetToysGlyph.menuBarImage { Image(nsImage: glyph) } else { Image(systemName: "network") }
            }
            .accessibilityLabel("Sam's NetToys")
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu panel brings the window forward, as the MacPowerToys tray did.
    private func openMainWindow() {
        openWindow(id: "nettoys")
        NSApp.activate()
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
