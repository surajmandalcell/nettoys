import AppKit
import Network
import NetToysCore
import SwiftUI
import XCTest
@testable import NetToysKit

/// Offscreen renders of the shell for a look check. Runs only with NETTOYS_RENDER_DIR set; no window opens.
@MainActor
final class NetToysShellRenderTests: XCTestCase {
    func testRenderShell() throws {
        guard let out = ProcessInfo.processInfo.environment["NETTOYS_RENDER_DIR"] else { throw XCTSkip("render only") }
        let wallDir = ProcessInfo.processInfo.environment["NETTOYS_WALL_DIR"] ?? ""
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nettoys.tests.render"))
        defaults.removePersistentDomain(forName: "nettoys.tests.render")
        let shell = NetToysShell(defaults: defaults)
        ["speed-test", "wake-on-lan", "ssl-certificate"].forEach(shell.togglePin)
        shell.selection = "traceroute"
        shell.inputs["traceroute"] = "files.example.com"
        shell.devices = [("192.168.50.1", "rtr-gw.lan"), ("192.168.50.4", "nas-01.lan"), ("192.168.50.31", "nas-backup.lan")].map {
            NetToysScanResult(address: IPv4Address($0.0)!, isReachable: true, responseMilliseconds: 2, hostname: $0.1,
                              macAddress: nil, vendor: nil, openPorts: [])
        }
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            let wall = NSImage(contentsOfFile: wallDir + (dark ? "dark.jpg" : "light.jpg"))
            let sidebar = HStack(spacing: 0) {
                NetToysSidebar(shell: shell, deviceCount: 16) { Text("Pause all actions").font(.system(size: 12)) }
                NetToysToolPage(placeholder: NetToysTool.tool("traceroute")!, input: .constant("files.example.com"))
                    .background(Dense.content)
            }
            .frame(width: 1100, height: 820)
            .background { if let wall { Image(nsImage: wall).resizable().aspectRatio(contentMode: .fill).blur(radius: 40) } }
            .clipped()
            try render(sidebar, dark: dark, to: "\(out)/window-\(name).png")
            for (file, query) in [("palette", ""), ("palette-host", "nas-01.lan")] {
                let palette = NetToysPaletteView(shell: shell, initialQuery: query) { _ in }
                    .padding(40).background(Dense.content)
                try render(palette, dark: dark, to: "\(out)/\(file)-\(name).png")
            }
        }
        defaults.removePersistentDomain(forName: "nettoys.tests.render")
    }

    private func render(_ view: some View, dark: Bool, to path: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
