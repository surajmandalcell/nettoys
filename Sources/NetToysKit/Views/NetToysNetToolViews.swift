import NetToysCore
import SwiftUI

// MARK: GeoIP

struct NetToysGeoIPView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var run: DiagnoseRun<NetToysGeoIPResult?>

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<NetToysGeoIPResult?> = .init(nil)) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: run.value.map { $0.ip }, running: run.running,
                        run: { run.toggle(lookup) }) {
            VStack(alignment: .leading, spacing: 10) {
                if let result = run.value {
                    HStack(spacing: 10) {
                        NetToysSummaryCard(title: "Country", value: diagnoseCountry(result.countryCode ?? result.country))
                        NetToysSummaryCard(title: "City", value: result.city ?? "Not listed", unit: result.region ?? "")
                        NetToysSummaryCard(title: "Network", value: result.asn.map { "AS\($0)" } ?? "Not listed",
                                           unit: result.organization ?? result.isp ?? "")
                    }
                    .lineLimit(1)
                }
                Label("The lookup goes to ipwho.is, a third-party service.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Dense.secondary)
            }
        } results: {
            DiagnoseResults(run: run, hasContent: run.value != nil,
                            idle: "Enter an IP address, or leave it empty for this Mac, and press Run",
                            busy: "Asking ipwho.is") {
                if let result = run.value {
                    DiagnoseFieldTable(fields: [
                        ("IP address", result.ip), ("Country", result.country ?? ""), ("Region", result.region ?? ""),
                        ("City", result.city ?? ""),
                        ("Coordinates", result.latitude.flatMap { lat in result.longitude.map { String(format: "%.4f, %.4f", lat, $0) } } ?? ""),
                        ("Time zone", result.timeZone ?? ""), ("ASN", result.asn.map { "AS\($0)" } ?? ""),
                        ("Organization", result.organization ?? ""), ("ISP", result.isp ?? ""),
                    ])
                }
            }
        }
        .onDisappear { run.stop() }
    }

    private func lookup(_ run: DiagnoseRun<NetToysGeoIPResult?>) async throws {
        run.value = try await NetToysGeoIP.lookup(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: Path MTU

struct NetToysPathMTUView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var run: DiagnoseRun<NetToysPathMTUResult?>

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<NetToysPathMTUResult?> = .init(nil)) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
    }

    /// Packet sizes common links carry, biggest first.
    private static let links: [(Int, String)] = [
        (1500, "Ethernet and most Wi-Fi"), (1492, "PPPoE (DSL and some fiber)"), (1480, "IPv6 tunnel (6in4)"),
        (1420, "WireGuard"), (1400, "Most other VPNs"), (1280, "IPv6 minimum"), (576, "IPv4 safe minimum"),
    ]

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: run.value.map { "\($0.target) · \($0.probes) probes" },
                        running: run.running, run: { run.toggle(discover) }) {
            if let result = run.value {
                HStack(spacing: 10) {
                    NetToysSummaryCard(title: "Path MTU", value: "\(result.mtu)", unit: "bytes",
                                       tone: result.mtu >= 1500 ? Dense.green : Dense.amber)
                    NetToysSummaryCard(title: "Biggest ping payload", value: "\(result.mtu - 28)", unit: "bytes")
                    DiagnoseCard(stretch: true) { gauge(result.mtu) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } results: {
            DiagnoseResults(run: run, hasContent: run.value != nil, idle: "Enter a host and press Run",
                            busy: "Sending pings that may not be split, about 12 sizes") {
                if let result = run.value {
                    DiagnoseTable(columns: [.init(title: "Size", width: 80, trailing: true), .init(title: "Link", width: 240),
                                            .init(title: "Result")],
                                  rows: Self.links.map { size, link in
                                      DiagnoseRow(id: "\(size)", cells: [
                                          .init("\(size)", strong: true), .init(link, tone: Dense.secondary),
                                          size <= result.mtu ? .init("Gets through", tone: Dense.green) : .init("Too big, would be split", tone: Dense.amber),
                                      ])
                                  })
                }
            }
        }
        .onDisappear { run.stop() }
    }

    private func gauge(_ mtu: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mtu >= 1500 ? "Full Ethernet size gets through" : "\(1500 - mtu) bytes less than Ethernet")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
                Spacer()
                Text("of 1500 bytes").font(.system(size: 11)).foregroundStyle(Dense.tertiary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Dense.track)
                    Capsule().fill(mtu >= 1500 ? Dense.green : Dense.amber)
                        .frame(width: geometry.size.width * min(1, Double(mtu) / 1500))
                }
            }
            .frame(height: 8)
        }
    }

    private func discover(_ run: DiagnoseRun<NetToysPathMTUResult?>) async throws {
        run.value = try await NetToysPathMTU.discover(host: try diagnoseInput(input, "a host"))
    }
}

// MARK: Internet Check

struct NetToysInternetCheckView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var run: DiagnoseRun<[NetToysInternetStep]>

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<[NetToysInternetStep]> = .init([])) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
    }

    private static let steps: [(NetToysInternetStep.Kind, String, String)] = [
        (.router, "wifi.router", "Router answers pings"),
        (.dns, "text.magnifyingglass", "DNS finds apple.com"),
        (.https, "globe", "Web page loads over HTTPS"),
    ]

    private var started: Bool { run.running || !run.value.isEmpty }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: run.running, run: { run.toggle(check) }) {
            if started { diagram }
        } results: {
            DiagnoseResults(run: run, hasContent: started, idle: "Press Run to check the router, DNS, and the web", busy: "") {
                DiagnoseTable(columns: [.init(title: "Step", width: 200), .init(title: "Result", width: 90),
                                        .init(title: "Time", width: 70, trailing: true), .init(title: "Detail")],
                              rows: Self.steps.map { kind, _, title in
                                  let step = run.value.first { $0.kind == kind }
                                  return DiagnoseRow(id: kind.rawValue, cells: [
                                      .init(title, strong: true),
                                      step.map { $0.passed ? .init("Passed", tone: Dense.green) : .init("Failed", tone: diagnoseRed) }
                                          ?? .init(run.running ? "Waiting" : "Skipped", tone: Dense.tertiary),
                                      .init(step?.milliseconds.map(diagnoseMilliseconds) ?? "", tone: Dense.secondary),
                                      .init(step?.detail ?? "", tone: Dense.secondary),
                                  ])
                              })
            }
        }
        .task { if !run.ran { run.start(check) } }
        .onDisappear { run.stop() }
    }

    /// This Mac, then one ring per step; a line turns green as each step passes.
    private var diagram: some View {
        DiagnoseCard {
            HStack(spacing: 0) {
                stop(symbol: "laptopcomputer", title: "This Mac", detail: " ", tone: Dense.accent, filled: true)
                ForEach(Self.steps, id: \.0) { kind, symbol, _ in
                    let step = run.value.first { $0.kind == kind }
                    let tone = step.map { $0.passed ? Dense.green : diagnoseRed } ?? Dense.tertiary
                    Capsule().fill(tone.opacity(step == nil ? 0.4 : 0.7)).frame(height: 3).frame(maxWidth: .infinity)
                        .offset(y: -12)
                    stop(symbol: symbol, title: kind.rawValue,
                         detail: step.map { $0.passed ? ($0.milliseconds.map(diagnoseMilliseconds) ?? "Passed") : "Failed" }
                             ?? (run.running ? "Waiting" : " "),
                         tone: tone, filled: false)
                }
            }
            .animation(Dense.spring, value: run.value.count)
        }
    }

    private func stop(symbol: String, title: String, detail: String, tone: Color, filled: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(filled ? Color.white : Dense.label)
                .frame(width: 40, height: 40)
                .background(Circle().fill(filled ? Dense.accent : Dense.content))
                .overlay(Circle().strokeBorder(filled ? Color.clear : tone, lineWidth: 2))
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.label)
            Text(detail).font(.system(size: 11)).foregroundStyle(tone == diagnoseRed ? diagnoseRed : Dense.secondary).monospacedDigit()
        }
        .frame(width: 96)
    }

    private var subtitle: String? {
        guard !run.running, run.value.count == Self.steps.count else { return run.running ? "Checking step by step" : nil }
        return run.value.allSatisfy(\.passed) ? "Online: router, DNS, and web all pass" : "Offline at the \(run.value.first { !$0.passed }?.kind.rawValue ?? "") step"
    }

    private func check(_ run: DiagnoseRun<[NetToysInternetStep]>) async throws {
        for await step in NetToysInternetCheck.run() { run.value.append(step) }
    }
}

// MARK: Subnet Calculator

/// Calculates as you type; Run has nothing to wait for.
struct NetToysSubnetView: View {
    let tool: NetToysTool
    @Binding var input: String

    var body: some View {
        let subnet = NetToysSubnet.calculate(input)
        NetToysToolPage(tool: tool, input: $input, subtitle: subnet.map { "IPv\($0.version) · /\($0.prefix) · \($0.hostCount) hosts" },
                        run: {}) {
            if let subnet {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        NetToysSummaryCard(title: "First host", value: subnet.firstHost)
                        NetToysSummaryCard(title: "Last host", value: subnet.lastHost)
                        NetToysSummaryCard(title: "Usable hosts", value: subnet.hostCount)
                        NetToysSummaryCard(title: "Mask", value: subnet.version == 4 ? subnet.mask : "/\(subnet.prefix)")
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    Text("Network \(subnet.network)" + (subnet.broadcast.map { "  ·  Broadcast \($0)" } ?? "")
                        + "  ·  \(subnet.addressCount) addresses in all")
                        .font(.system(size: 12)).foregroundStyle(Dense.secondary).textSelection(.enabled)
                }
            }
        } results: {
            if let subnet {
                DiagnoseFieldTable(fields: [
                    ("Address", subnet.address), ("Version", "IPv\(subnet.version)"), ("Prefix", "/\(subnet.prefix)"),
                    ("Network", subnet.network), ("Broadcast", subnet.broadcast ?? ""), ("Mask", subnet.mask),
                    ("Wildcard", subnet.wildcard), ("First host", subnet.firstHost), ("Last host", subnet.lastHost),
                    ("Addresses", subnet.addressCount), ("Usable hosts", subnet.hostCount),
                ])
            } else if input.trimmingCharacters(in: .whitespaces).isEmpty {
                DiagnoseMessage(symbol: "square.grid.3x3", title: "Type a CIDR, such as 192.168.1.0/24",
                                line: "The range shows as you type. IPv6 works too.")
            } else {
                DiagnoseMessage(symbol: "exclamationmark.triangle", title: "This is not a valid address and prefix",
                                line: "Use an IPv4 or IPv6 address, then a slash and the prefix length, such as 10.0.0.0/8.",
                                tone: Dense.amber)
            }
        }
    }
}
