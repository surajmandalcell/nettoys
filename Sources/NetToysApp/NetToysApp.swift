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
        Window("NetToys", id: "nettoys") {
            OnePlusWindowContent {
                NetToysWindowView(host: host, page: $page, enabled: enablement, isTransitioning: transitioning) {
                    defer { prefill = nil }
                    return prefill
                }
                .background(NetToysWindowRestore())
            }
            .onOpenURL { url in
                guard url.scheme == "nettoys", url.host == "open",
                      let destination = NetToysPage.allCases.first(where: { $0.pageID == url.lastPathComponent }) else { return }
                page = destination
                prefill = NetToysScanPrefill.parse(url, schemes: ["nettoys"], toolPath: nil)
                if let prefill { NotificationCenter.default.post(name: .netToysPrefill, object: prefill) }
            }
            .task { if enabled { enabled = await host.loginItems.setEnabled(true) } }
        }
        .defaultSize(OnePlusWindowCanvas.netToys.size)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("NetToys", systemImage: "network") {
            OnePlusMenuPanel {
                Text("NetToys")
            } actions: {
                Button("Open NetToys") { openWindow(id: "nettoys") }
            } content: {
                NetToysMenuContent(snapshot: $menuSnapshot, host: host) { destination in
                    page = destination
                    openWindow(id: "nettoys")
                }
            }
        }
        .menuBarExtraStyle(.window)
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
