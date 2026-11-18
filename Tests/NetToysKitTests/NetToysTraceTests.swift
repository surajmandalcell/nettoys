import AppKit
import SwiftUI
import XCTest
@testable import NetToysCore
@testable import NetToysKit

/// Synthetic paths only: LAN 192.168.50.x, public hops from documentation ranges, fake names.
@MainActor
final class NetToysTraceTests: XCTestCase {
    /// Silent hops at 5, 12, 13, 23; latency jumps at 10 and 20; loss at 26 (as in the approved round 13 renders).
    static func path(_ count: Int) -> [NetToysHop] {
        let silent: Set<Int> = count == 8 ? [5] : count == 18 ? [5, 11] : [5, 12, 13, 23]
        let lossAt = count == 8 ? 6 : count == 18 ? 14 : 26
        let jumps: [Int: Double] = count == 8 ? [:] : count == 18 ? [8: 72] : [10: 72, 20: 24]
        let cities = ["ber", "fra", "ams", "lon", "nyc", "chi", "den", "slc", "sjc"]
        var ms = 0.0
        return (1...count).map { ttl in
            ms += (ttl == 1 ? 1.4 : ttl == 2 ? 5.4 : 0.5 + 1.3 * abs(sin(Double(ttl) * 1.7))) + (jumps[ttl] ?? 0)
            var hop = NetToysHop(ttl: ttl)
            for round in 0..<10 {
                let lost = silent.contains(ttl) || (ttl == lossAt && round == 3)
                hop.stats.record(lost ? nil : ms + Double((round * 7 + ttl) % 5) * 0.3)
            }
            guard !silent.contains(ttl) else { return hop }
            hop.address = ttl == 1 ? "192.168.50.1" : "198.51.100.\(ttl * 7)"
            hop.hostname = ttl == 1 ? "rtr-gw.lan" : ttl == 2 ? "cgnat-1.isp.example"
                : ttl == count ? "files.example.com" : "ae\(ttl).\(cities[ttl * cities.count / (count + 1)]).transit.example"
            return hop
        }
    }

    func testFoldKeepsFirstLastAndProblemHops() {
        let stops = NetToysPathFold.stops(Self.path(30))
        // Hop numbers are 1-based; indices are 0-based.
        XCTAssertEqual(stops, [.mac, .hop(0), .fold(1...8), .hop(9), .fold(10...18), .hop(19), .fold(20...24), .hop(25),
                               .fold(26...28), .hop(29)])
        XCTAssertEqual(stops.compactMap { if case .fold(let r) = $0 { r.count } else { nil } }, [8, 9, 5, 3])
        XCTAssertEqual(NetToysPathFold.stops(Self.path(8)).count, 9, "8 hops never fold")
        XCTAssertEqual(NetToysPathFold.stops(Self.path(18)), [.mac, .hop(0), .fold(1...6), .hop(7), .fold(8...12), .hop(13),
                                                              .fold(14...16), .hop(17)])
    }

    func testRenderPages() throws {
        guard let out = ProcessInfo.processInfo.environment["NETTOYS_TRACE_RENDER_DIR"] else { throw XCTSkip("render only") }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let trace = try XCTUnwrap(NetToysTool.tool("traceroute")), ping = try XCTUnwrap(NetToysTool.tool("ping"))
        let cases: [(String, Int, Bool, CGFloat)] = [("trace-8", 8, false, 760), ("trace-18", 18, false, 900),
                                                     ("trace-30", 30, false, 1140), ("trace-30-open", 30, true, 1440)]
        let samples = (1...90).map { n in
            NetToysPingSample(sequence: n, address: "203.0.113.200", milliseconds: n % 23 == 7 ? nil : 18 + 4 * sin(Double(n) * 0.4)
                + Double(n % 5), ttl: 54)
        }
        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            for (name, count, open, height) in cases {
                let hops = Self.path(count)
                let model = NetToysTraceModel(snapshot: NetToysTraceSnapshot(target: "203.0.113.200", round: 10, reachedTarget: true, hops: hops))
                let page = NetToysTraceView(tool: trace, input: .constant("files.example.com"), model: model, expanded: open)
                try render(page.frame(width: 1000, height: height).background(Dense.content), dark: dark, to: "\(out)/\(name)-\(look).png")
            }
            let page = NetToysPingView(tool: ping, input: .constant("files.example.com"), model: NetToysPingModel(samples: samples))
            try render(page.frame(width: 1000, height: 760).background(Dense.content), dark: dark, to: "\(out)/ping-\(look).png")
        }
    }

    private func render(_ view: some View, dark: Bool, to path: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6)) // measured width and keyframes settle
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
