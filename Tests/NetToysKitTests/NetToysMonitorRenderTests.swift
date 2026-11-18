import AppKit
import SwiftUI
import XCTest
@testable import NetToysCore
@testable import NetToysKit

/// Offscreen renders of the Monitor, Local Network, and Wi-Fi tool pages with synthetic data.
/// Runs only with NETTOYS_RENDER_DIR set; no window opens and nothing touches the network or Location.
@MainActor
final class NetToysMonitorRenderTests: XCTestCase {
    func testRenderMonitorPages() throws {
        guard let out = ProcessInfo.processInfo.environment["NETTOYS_RENDER_DIR"] else { throw XCTSkip("render only") }
        let now = Date()
        func tool(_ id: String) -> NetToysTool { NetToysTool.tool(id)! }

        // Uptime
        let checks = [
            NetToysUptimeCheck(name: "nas-01", kind: .ping(host: "192.168.50.4"), latencyThresholdMilliseconds: 20),
            NetToysUptimeCheck(name: "Home Assistant", kind: .http(url: "https://ha.example.lan:8123", expectedStatus: 200)),
            NetToysUptimeCheck(name: "rtr-gw SSH", kind: .tcp(host: "192.168.50.1", port: 22)),
            NetToysUptimeCheck(name: "files.example.com", kind: .http(url: "https://files.example.com/health", expectedStatus: nil)),
            NetToysUptimeCheck(name: "printer", kind: .ping(host: "192.168.50.31"), isEnabled: false),
        ]
        var samples: [String: [NetToysUptimeSample]] = [:]
        var statuses: [UUID: NetToysUptimeStatus] = [:]
        for (index, check) in checks.enumerated() where check.isEnabled {
            var status = NetToysUptimeStatus()
            var series: [NetToysUptimeSample] = []
            for step in 0..<60 {
                let failed = index == 2 && step > 55
                let ms = [3.0, 48, 1.2, 31][index] * (1 + 0.3 * sin(Double(step) / 3 + Double(index)))
                let sample = NetToysUptimeSample(date: now.addingTimeInterval(Double(step - 60) * 60), milliseconds: failed ? nil : ms,
                                                 failure: failed ? "Connection refused" : nil,
                                                 certificateExpiry: index == 3 ? now.addingTimeInterval(9 * 86_400) : index == 1 ? now.addingTimeInterval(64 * 86_400) : nil)
                series.append(sample)
                _ = status.observe(sample, check: check)
            }
            samples[check.id.uuidString] = series
            statuses[check.id] = status
        }
        let uptime = NetToysUptimeView(tool: tool("uptime-monitor"), checks: checks, samples: samples, statuses: statuses)

        // Speed
        let records = (0..<24).map { index -> NetToysSpeedRecord in
            let date = now.addingTimeInterval(Double(index - 24) * 6 * 3_600)
            let evening = Calendar.current.component(.hour, from: date) >= 18
            return NetToysSpeedRecord(date: date, downloadMbps: (evening ? 280 : 420) + Double(index % 5) * 9,
                                      uploadMbps: 38 + Double(index % 4) * 2, responsivenessRPM: 900 + Double(index % 6) * 70,
                                      idleLatencyMilliseconds: 11 + Double(index % 3), interfaceName: "en0",
                                      networkName: index % 6 == 0 ? "HomeNet-5G" : "HomeNet", publicIP: "203.0.113.24",
                                      isp: "Example Fiber", server: "speed.example.net")
        }
        let speed = NetToysSpeedView(tool: tool("speed-test"), speedTest: NetToysSpeedTest(history: records), schedule: .daily(hour: 3, minute: 30))

        // Network Monitor
        var traffic = NetToysTrafficHistory()
        var counters: [String: (UInt32, UInt32)] = ["en0": (0, 0), "utun4": (0, 0), "en7": (0, 0)]
        for second in 0...240 {
            let wave = 1 + sin(Double(second) / 14)
            counters["en0"]!.0 &+= UInt32(2_600_000 * wave + 300_000)
            counters["en0"]!.1 &+= UInt32(240_000 * wave + 40_000)
            counters["utun4"]!.0 &+= UInt32(90_000 * (2 - wave))
            counters["utun4"]!.1 &+= 22_000
            counters["en7"]!.0 &+= 1_200
            counters["en7"]!.1 &+= 800
            traffic.add(counters, at: now.addingTimeInterval(Double(second - 240)))
        }
        let monitor = NetToysTrafficView(tool: tool("network-monitor"), history: traffic)

        // Local network
        var bonjour = [
            ("nas-01", "_smb._tcp", "nas-01.local.", 445, ["model": "DS920"]),
            ("nas-01", "_afpovertcp._tcp", "nas-01.local.", 548, [:]),
            ("Living Room TV", "_airplay._tcp", "living-room.local.", 7000, ["model": "AppleTV14,1", "features": "0x4A7FDFD5"]),
            ("Office Printer", "_ipp._tcp", "printer.local.", 631, ["ty": "Laser 2200", "rp": "ipp/print"]),
            ("Home Assistant", "_home-assistant._tcp", "ha.local.", 8123, ["version": "2026.11.1"]),
            ("Kitchen Speaker", "_raop._tcp", nil, nil, [:]),
        ].map { NetToysBonjourService(name: $0.0, type: $0.1, domain: "local.", host: $0.2, port: $0.3.map(UInt16.init), txt: $0.4) }
        bonjour.sort { ($0.type, $0.name) < ($1.type, $1.name) }
        let arp = [("192.168.50.1", "3c:22:fb:10:aa:01", "Example Networks"), ("192.168.50.4", "00:11:32:aa:bb:04", "Synology"),
                   ("192.168.50.12", "a4:83:e7:12:34:56", "Apple"), ("192.168.50.31", "64:4e:d7:01:02:03", "Printer Maker Ltd"),
                   ("192.168.50.44", "3a:91:0c:44:55:66", "Private address"), ("192.168.50.60", "b8:27:eb:60:61:62", nil)]
            .map { NetToysARPEntry(address: $0.0, mac: $0.1, interfaceName: "en0", vendor: $0.2) }
        let connection = NetToysConnectionInfo(
            publicIPv4: "203.0.113.24", publicIPv6: "2001:db8:4e1::24", isp: "Example Fiber",
            interfaces: [NetToysInterfaceInfo(name: "en0", kind: .wifi, ipv4: ["192.168.50.20"], ipv6: ["2001:db8:4e1:0:1c2a:9f3:52aa:20"], mac: "a4:83:e7:aa:bb:20", mtu: 1500),
                         NetToysInterfaceInfo(name: "en7", kind: .ethernet, ipv4: ["192.168.50.21"], ipv6: [], mac: "00:e0:4c:68:00:21", mtu: 1500),
                         NetToysInterfaceInfo(name: "utun4", kind: .vpn, ipv4: ["10.8.0.6"], ipv6: [], mac: nil, mtu: 1380)],
            router: "192.168.50.1", routerInterface: "en0", dnsServers: ["192.168.50.1", "1.1.1.1"], wifiName: "HomeNet")
        let ipv6 = NetToysIPv6Check(globalAddress: "2001:db8:4e1:0:1c2a:9f3:52aa:20", reachMilliseconds: 14.2, reachFailure: nil,
                                    aaaaAddresses: ["2001:db8:17::a"])
        let clockReadings = (0..<4).map { index in
            NetToysClockView.Reading(date: now.addingTimeInterval(Double(-index) * 90), server: "time.apple.com",
                                     check: NetToysClockCheck(server: "time.apple.com", offsetSeconds: 0.0124 - Double(index) * 0.0008,
                                                              delaySeconds: 0.021 + Double(index) * 0.002, stratum: 1), failure: nil)
        }
        let macLookups = [NetToysMACVendorView.Lookup(mac: "3C:22:FB:10:AA:01", vendor: "Example Networks"),
                          NetToysMACVendorView.Lookup(mac: "3A:91:0C:44:55:66", vendor: "Private address"),
                          NetToysMACVendorView.Lookup(mac: "02:00:00", vendor: nil)]

        // Wi-Fi
        let networks = [(String?("HomeNet"), 36, NetToysWiFiBand.ghz5, -48, 80), ("HomeNet", 6, .ghz2, -52, 20), ("Neighbor-5G", 44, .ghz5, -71, 80),
                        ("CafeGuest", 149, .ghz5, -78, 40), (nil, 1, .ghz2, -80, 20), ("Neighbor", 6, .ghz2, -69, 20),
                        ("Upstairs", 11, .ghz2, -74, 20), ("Upstairs-5G", 36, .ghz5, -76, 80), ("Lab6E", 37, .ghz6, -64, 160)]
            .enumerated().map { index, item in
                NetToysWiFiNetwork(ssid: item.0, bssid: String(format: "aa:bb:cc:00:00:%02x", index), rssi: item.3, noise: -92,
                                   channel: item.1, band: item.2, widthMHz: item.4)
            }
        let scan = NetToysWiFiScan(state: .ok, networks: networks, usage: NetToysWiFiAnalyzer.usage(networks),
                                   advice: NetToysWiFiAnalyzer.advice(networks), currentChannel: 36, currentBand: .ghz5)
        let hiddenScan = NetToysWiFiScan(state: .namesHidden,
                                         networks: networks.map { NetToysWiFiNetwork(ssid: nil, bssid: nil, rssi: $0.rssi, noise: $0.noise, channel: $0.channel, band: $0.band, widthMHz: $0.widthMHz) },
                                         usage: scan.usage, advice: scan.advice, currentChannel: 36, currentBand: .ghz5)
        let signal = (0..<300).map { second in
            NetToysWiFiSignalSample(date: now.addingTimeInterval(Double(second - 300)), ssid: "HomeNet",
                                    rssi: -52 + Int(6 * sin(Double(second) / 20)) - (second % 37 == 0 ? 6 : 0), noise: -92 + second % 3,
                                    transmitRateMbps: 864, channel: 36, band: .ghz5, widthMHz: 80)
        }

        let pages: [(String, AnyView, Bool)] = [
            ("uptime-monitor", AnyView(uptime), true),
            ("speed-test", AnyView(speed), true),
            ("network-monitor", AnyView(monitor), false),
            ("bonjour-browser", AnyView(NetToysBonjourView(tool: tool("bonjour-browser"), services: bonjour)), false),
            ("arp-table", AnyView(NetToysARPView(tool: tool("arp-table"), entries: arp)), false),
            ("mac-vendor", AnyView(NetToysMACVendorView(tool: tool("mac-vendor"), input: .constant("02:00:00"), lookups: macLookups)), false),
            ("my-connection", AnyView(NetToysMyConnectionView(tool: tool("my-connection"), info: connection)), false),
            ("ipv6-check", AnyView(NetToysIPv6View(tool: tool("ipv6-check"), result: ipv6)), false),
            ("clock-check", AnyView(NetToysClockView(tool: tool("clock-check"), input: .constant("time.apple.com"), readings: clockReadings)), false),
            ("wifi-analyzer", AnyView(NetToysWiFiAnalyzerView(tool: tool("wifi-analyzer"), scan: scan, location: .authorizedAlways)), true),
            ("wifi-analyzer-location", AnyView(NetToysWiFiAnalyzerView(tool: tool("wifi-analyzer"), scan: hiddenScan, band: .ghz2, location: .notDetermined)), false),
            ("wifi-signal", AnyView(NetToysWiFiSignalView(tool: tool("wifi-signal"), samples: signal, location: .authorizedAlways)), false),
            ("uptime-editor", AnyView(NetToysUptimeEditor(check: checks[1], isNew: false, save: { _ in }, delete: { _ in }, cancel: {})), false),
        ]
        for (name, page, light) in pages {
            for dark in light ? [true, false] : [true] {
                let framed = name == "uptime-editor" ? AnyView(page) : AnyView(page.frame(width: 1080, height: 760).background(Dense.content))
                try render(framed, dark: dark, to: "\(out)/\(name)-\(dark ? "dark" : "light").png")
            }
        }
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
