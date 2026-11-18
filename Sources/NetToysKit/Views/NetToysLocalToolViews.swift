import NetToysCore
import SwiftUI

// Local Network tool pages: Bonjour Browser, ARP Table, MAC Vendor, My Connection, IPv6 Check, Clock Check.
// Each takes optional synthetic data for offscreen renders; with data passed, nothing reads the network.

/// A label, value, and plain note row for the small key-value tables.
struct UtilityPair: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var note = ""
    var tone: Color = Dense.label
}

private let pairColumns = [UtilityColumn(title: "Item", width: 180), UtilityColumn(title: "Value", width: 300),
                           UtilityColumn(title: "What it means")]

private struct PairTable: View {
    let rows: [UtilityPair]
    var body: some View {
        UtilityTable(columns: pairColumns, rows: rows) { row in
            Text(row.label).foregroundStyle(Dense.secondary).cell(pairColumns[0])
            Text(row.value).fontWeight(.medium).foregroundStyle(row.tone).textSelection(.enabled)
                .truncationMode(.middle).cell(pairColumns[1])
            Text(row.note).foregroundStyle(Dense.secondary).cell(pairColumns[2])
        }
    }
}

// MARK: - Bonjour Browser

struct NetToysBonjourView: View {
    let tool: NetToysTool
    private let live: Bool
    @State private var services: [NetToysBonjourService]
    @State private var browsing: Bool
    @State private var input = ""

    init(tool: NetToysTool, services: [NetToysBonjourService]? = nil) {
        self.tool = tool
        live = services == nil
        _services = State(initialValue: services ?? [])
        _browsing = State(initialValue: services == nil)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input,
                        subtitle: browsing ? "Listening for announcements on local." : "Stopped, \(services.count) services found",
                        running: browsing, run: { browsing.toggle() }) {
            HStack(spacing: 10) {
                NetToysSummaryCard(title: "Services", value: "\(services.count)")
                NetToysSummaryCard(title: "Service types", value: "\(Set(services.map(\.type)).count)")
                NetToysSummaryCard(title: "Devices", value: "\(Set(services.compactMap(\.host)).count)")
                NetToysSummaryCard(title: "Resolved", value: "\(services.filter { $0.host != nil }.count)",
                                   unit: "of \(services.count)")
            }
        } results: {
            UtilityTable(columns: columns, rows: services, empty: browsing ? "Listening…" : "No services found") { service in
                Text(service.name).fontWeight(.medium).cell(columns[0])
                MonoText(service.type).cell(columns[1])
                Text(service.host ?? "Resolving…").foregroundStyle(service.host == nil ? Dense.tertiary : Dense.secondary)
                    .truncationMode(.middle).cell(columns[2])
                Text(service.port.map(String.init) ?? "").cell(columns[3])
                Text(service.txt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                    .foregroundStyle(Dense.secondary).truncationMode(.tail).cell(columns[4])
            }
        }
        .task(id: browsing) {
            guard live, browsing else { return }
            for await list in NetToysBonjourBrowser.browse() { services = list }
        }
    }

    private let columns = [
        UtilityColumn(title: "Name", width: 220), UtilityColumn(title: "Type", width: 150), UtilityColumn(title: "Host", width: 200),
        UtilityColumn(title: "Port", width: 50, trailing: true), UtilityColumn(title: "TXT record"),
    ]
}

// MARK: - ARP Table

struct NetToysARPView: View {
    let tool: NetToysTool
    private let live: Bool
    @State private var entries: [NetToysARPEntry]
    @State private var loading = false
    @State private var input = ""

    init(tool: NetToysTool, entries: [NetToysARPEntry]? = nil) {
        self.tool = tool
        live = entries == nil
        _entries = State(initialValue: entries ?? [])
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: "\(entries.count) neighbors from arp -an", running: loading,
                        run: { Task { await load() } }) {
            HStack(spacing: 10) {
                NetToysSummaryCard(title: "Neighbors", value: "\(entries.count)")
                NetToysSummaryCard(title: "Interfaces", value: "\(Set(entries.map(\.interfaceName)).count)")
                NetToysSummaryCard(title: "Known makers", value: "\(entries.filter { $0.vendor != nil }.count)")
                NetToysSummaryCard(title: "Private addresses", value: "\(entries.filter { $0.vendor == "Private address" }.count)")
            }
        } results: {
            UtilityTable(columns: columns, rows: entries, empty: loading ? "Reading…" : "No neighbors") { entry in
                MonoText(entry.address, tone: Dense.label).cell(columns[0])
                MonoText(entry.mac).cell(columns[1])
                Text(entry.vendor ?? "Unknown").foregroundStyle(entry.vendor == nil ? Dense.tertiary : Dense.label).cell(columns[2])
                Text(entry.interfaceName).foregroundStyle(Dense.secondary).cell(columns[3])
            }
        }
        .task { if live { await load() } }
    }

    private let columns = [
        UtilityColumn(title: "IP Address", width: 140), UtilityColumn(title: "MAC Address", width: 160),
        UtilityColumn(title: "Maker", width: 260), UtilityColumn(title: "Interface"),
    ]

    private func load() async {
        guard live, !loading else { return }
        loading = true
        entries = await NetToysARPTable.load()
        loading = false
    }
}

// MARK: - MAC Vendor

struct NetToysMACVendorView: View {
    struct Lookup: Identifiable {
        let id = UUID()
        let mac: String
        let vendor: String?
    }

    let tool: NetToysTool
    @Binding var input: String
    @State private var lookups: [Lookup]

    init(tool: NetToysTool, input: Binding<String>, lookups: [Lookup] = []) {
        self.tool = tool
        _input = input
        _lookups = State(initialValue: lookups)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: "From the bundled IEEE list, no network needed", run: lookup) {
            HStack(spacing: 10) {
                NetToysSummaryCard(title: "Maker", value: lookups.first.map { $0.vendor ?? "Unknown" } ?? "None",
                                   tone: lookups.first?.vendor == nil ? Dense.secondary : Dense.label)
                NetToysSummaryCard(title: "Address", value: lookups.first?.mac ?? "None")
            }
        } results: {
            UtilityTable(columns: columns, rows: lookups, empty: "Type a MAC address or its first six digits, then press Return.") { row in
                MonoText(row.mac, tone: Dense.label).cell(columns[0])
                Text(row.vendor ?? "Unknown maker").foregroundStyle(row.vendor == nil ? Dense.tertiary : Dense.label).cell(columns[1])
            }
        }
    }

    private let columns = [UtilityColumn(title: "MAC Address", width: 200), UtilityColumn(title: "Maker")]

    private func lookup() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        withAnimation(Dense.spring) {
            lookups.insert(Lookup(mac: text.uppercased(), vendor: NetToysMACVendor.lookup(text)), at: 0)
        }
    }
}

// MARK: - My Connection

struct NetToysMyConnectionView: View {
    let tool: NetToysTool
    private let live: Bool
    @State private var info: NetToysConnectionInfo?
    @State private var loading = false
    @State private var input = ""

    init(tool: NetToysTool, info: NetToysConnectionInfo? = nil) {
        self.tool = tool
        live = info == nil
        _info = State(initialValue: info)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: loading, run: { Task { await load() } }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    NetToysSummaryCard(title: "Public IPv4", value: info?.publicIPv4 ?? "None")
                    NetToysSummaryCard(title: "Provider", value: info?.isp ?? "Unknown")
                    NetToysSummaryCard(title: "Router", value: info?.router ?? "None", unit: info?.routerInterface ?? "")
                    NetToysSummaryCard(title: "Wi-Fi", value: info?.wifiName ?? "Hidden or not on Wi-Fi")
                }
                HStack(spacing: 18) {
                    label("Public IPv6", info?.publicIPv6 ?? "None")
                    label("DNS servers", info.map { $0.dnsServers.isEmpty ? "None" : $0.dnsServers.joined(separator: ", ") } ?? "None")
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        } results: {
            UtilityTable(columns: columns, rows: info?.interfaces ?? [], empty: loading ? "Reading…" : "No active interfaces") { item in
                Text(item.name).fontWeight(.medium).cell(columns[0])
                Text(kind(item.kind)).foregroundStyle(Dense.secondary).cell(columns[1])
                MonoText(item.ipv4.joined(separator: ", "), tone: Dense.label).cell(columns[2])
                MonoText(item.ipv6.first ?? "").truncationMode(.middle).cell(columns[3])
                MonoText(item.mac ?? "").cell(columns[4])
                Text("\(item.mtu)").foregroundStyle(Dense.secondary).cell(columns[5])
            }
        }
        .task { if live { await load() } }
    }

    private let columns = [
        UtilityColumn(title: "Interface", width: 80), UtilityColumn(title: "Kind", width: 70), UtilityColumn(title: "IPv4", width: 140),
        UtilityColumn(title: "IPv6", width: 260), UtilityColumn(title: "MAC Address", width: 150),
        UtilityColumn(title: "MTU", trailing: true),
    ]

    private var subtitle: String {
        guard let info else { return loading ? "Reading addresses…" : tool.line }
        return "\(info.interfaces.count) interfaces up, router \(info.router ?? "not found")"
    }

    private func label(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Dense.secondary)
            MonoText(value, tone: Dense.label).lineLimit(1).truncationMode(.middle)
        }
    }

    private func kind(_ kind: NetToysInterfaceInfo.Kind) -> String {
        switch kind {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .vpn: "VPN"
        case .bridge: "Bridge"
        case .other: "Other"
        }
    }

    private func load() async {
        guard live, !loading else { return }
        loading = true
        info = await NetToysMyConnection.load()
        loading = false
    }
}

// MARK: - IPv6 Check

struct NetToysIPv6View: View {
    let tool: NetToysTool
    private let live: Bool
    @State private var result: NetToysIPv6Check?
    @State private var loading = false
    @State private var input = ""

    init(tool: NetToysTool, result: NetToysIPv6Check? = nil) {
        self.tool = tool
        live = result == nil
        _result = State(initialValue: result)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: loading, run: { Task { await load() } }) {
            HStack(spacing: 10) {
                NetToysSummaryCard(title: "IPv6", value: result.map { $0.isWorking ? "Working" : "Not working" } ?? "Checking",
                                   tone: result.map { $0.isWorking ? Dense.green : UtilityTone.red } ?? Dense.secondary)
                NetToysSummaryCard(title: "Global address", value: result?.globalAddress == nil ? "None" : "Yes")
                NetToysSummaryCard(title: "Reach Cloudflare", value: UtilityFormat.ms(result?.reachMilliseconds), unit: "ms")
                NetToysSummaryCard(title: "DNS AAAA answers", value: "\(result?.aaaaAddresses.count ?? 0)")
            }
        } results: {
            PairTable(rows: rows)
        }
        .task { if live { await load() } }
    }

    private var subtitle: String {
        guard let result else { return "Checking address, reach, and DNS…" }
        return result.isWorking ? "This Mac reaches the internet over IPv6" : "IPv6 does not work on this network"
    }

    private var rows: [UtilityPair] {
        guard let result else { return [] }
        return [
            UtilityPair(label: "1. Global address", value: result.globalAddress ?? "None",
                        note: result.globalAddress == nil ? "The router gives this Mac no public IPv6 address." : "The router hands out public IPv6 addresses.",
                        tone: result.globalAddress == nil ? UtilityTone.red : Dense.label),
            UtilityPair(label: "2. Reach Cloudflare over IPv6",
                        value: result.reachMilliseconds.map { "\(UtilityFormat.ms($0)) ms" } ?? (result.reachFailure ?? "Failed"),
                        note: result.reachMilliseconds == nil ? "A TCP connection over IPv6 to port 443 failed." : "A TCP connection over IPv6 to port 443 worked.",
                        tone: result.reachMilliseconds == nil ? UtilityTone.red : Dense.label),
            UtilityPair(label: "3. DNS AAAA for \(NetToysIPv6Check.testName)",
                        value: result.aaaaAddresses.first ?? "No answer",
                        note: result.aaaaAddresses.isEmpty ? "The network's DNS server gave no IPv6 address." : "The network's DNS server answers IPv6 lookups.",
                        tone: result.aaaaAddresses.isEmpty ? UtilityTone.red : Dense.label),
        ]
    }

    private func load() async {
        guard live, !loading else { return }
        loading = true
        result = await NetToysIPv6.check()
        loading = false
    }
}

// MARK: - Clock Check

struct NetToysClockView: View {
    struct Reading: Identifiable {
        let id = UUID()
        let date: Date
        let server: String
        let check: NetToysClockCheck?
        let failure: String?
    }

    let tool: NetToysTool
    @Binding var input: String
    private let live: Bool
    @State private var readings: [Reading]
    @State private var loading = false

    init(tool: NetToysTool, input: Binding<String>, readings: [Reading]? = nil) {
        self.tool = tool
        _input = input
        live = readings == nil
        _readings = State(initialValue: readings ?? [])
    }

    var body: some View {
        let last = readings.first?.check
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: loading, run: { Task { await check() } }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    NetToysSummaryCard(title: "Mac clock", value: last.map { Self.offsetWords($0.offsetSeconds) } ?? "None",
                                       tone: last.map { abs($0.offsetSeconds) > 1 ? Dense.amber : Dense.green } ?? Dense.secondary)
                    NetToysSummaryCard(title: "Offset", value: last.map { Self.milliseconds($0.offsetSeconds) } ?? "None", unit: "ms")
                    NetToysSummaryCard(title: "Round trip", value: last.map { UtilityFormat.ms($0.delaySeconds * 1_000) } ?? "None", unit: "ms")
                    NetToysSummaryCard(title: "Stratum", value: last.map { "\($0.stratum)" } ?? "None", unit: "hops from an atomic clock")
                }
                if let failure = readings.first?.failure {
                    UtilityNote(symbol: "exclamationmark.triangle.fill", text: failure, tone: Dense.amber)
                }
            }
        } results: {
            UtilityTable(columns: columns, rows: readings, empty: "Click Run to compare this Mac's clock with \(server).") { reading in
                Text(reading.date.formatted(date: .omitted, time: .standard)).cell(columns[0])
                Text(reading.server).foregroundStyle(Dense.secondary).cell(columns[1])
                Text(reading.check.map { Self.milliseconds($0.offsetSeconds) } ?? reading.failure ?? "").cell(columns[2])
                Text(reading.check.map { UtilityFormat.ms($0.delaySeconds * 1_000) } ?? "").foregroundStyle(Dense.secondary).cell(columns[3])
                Text(reading.check.map { "\($0.stratum)" } ?? "").foregroundStyle(Dense.secondary).cell(columns[4])
            }
        }
        .task {
            guard live else { return }
            if input.isEmpty { input = "time.apple.com" }
            if readings.isEmpty { await check() }
        }
    }

    private let columns = [
        UtilityColumn(title: "Time", width: 110), UtilityColumn(title: "Server", width: 200),
        UtilityColumn(title: "Offset ms", width: 90, trailing: true), UtilityColumn(title: "Round trip ms", width: 100, trailing: true),
        UtilityColumn(title: "Stratum"),
    ]

    private var server: String {
        let text = input.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "time.apple.com" : text
    }

    private var subtitle: String {
        guard let last = readings.first?.check else { return "Compares this Mac's clock with \(server)" }
        let words = Self.offsetWords(last.offsetSeconds)
        return words == "On time" ? "This Mac's clock matches \(last.server)" : "This Mac's clock is \(words) \(last.server)"
    }

    static func milliseconds(_ seconds: Double) -> String {
        let ms = seconds * 1_000
        return abs(ms) < 9.95 ? String(format: "%+.1f", ms) : String(format: "%+.0f", ms)
    }

    /// Positive offset: this Mac is behind the server.
    static func offsetWords(_ seconds: Double) -> String {
        let size = abs(seconds) < 1 ? "\(Int((abs(seconds) * 1_000).rounded())) ms" : String(format: "%.1f sec", abs(seconds))
        if abs(seconds) < 0.0005 { return "On time" }
        return seconds > 0 ? "\(size) behind" : "\(size) ahead"
    }

    private func check() async {
        guard live, !loading else { return }
        loading = true
        let server = server
        do {
            let result = try await NetToysClock.check(server: server)
            readings.insert(Reading(date: Date(), server: server, check: result, failure: nil), at: 0)
        } catch {
            readings.insert(Reading(date: Date(), server: server, check: nil, failure: error.localizedDescription), at: 0)
        }
        loading = false
    }
}
