import AppKit
import Charts
import CoreLocation
import NetToysCore
import OnePlusUI
import SwiftUI

// Network Monitor, Wi-Fi Analyzer, and Wi-Fi Signal. Each takes synthetic data for offscreen renders;
// with data passed, nothing reads the network or Wi-Fi.

// MARK: - Network Monitor

struct NetToysTrafficView: View {
    private struct Row: Identifiable {
        var id: String { name }
        let name: String
        let now: NetToysTrafficSample?
        let peakIn: Double
        let peakOut: Double
        let totalIn: Double
        let totalOut: Double
    }

    let tool: NetToysTool
    private let live: Bool
    @State private var history: NetToysTrafficHistory
    @State private var running: Bool
    @State private var selected: String?
    @State private var input = ""

    init(tool: NetToysTool, history: NetToysTrafficHistory? = nil, selected: String? = nil) {
        self.tool = tool
        live = history == nil
        _history = State(initialValue: history ?? NetToysTrafficHistory())
        _running = State(initialValue: history == nil)
        _selected = State(initialValue: selected)
    }

    var body: some View {
        let rows = rows
        let shown = selected ?? rows.first?.name
        let series = shown.flatMap { history.samples[$0] } ?? []
        let totalIn = rows.compactMap(\.now?.bytesInPerSecond).reduce(0, +)
        let totalOut = rows.compactMap(\.now?.bytesOutPerSecond).reduce(0, +)
        NetToysToolPage(tool: tool, input: $input,
                        subtitle: running ? "Live, one reading a second, last 10 min" : "Paused",
                        running: running, run: { running.toggle() }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    rateCard("Download now", totalIn)
                    rateCard("Upload now", totalOut)
                    rateCard("Peak download", rows.map(\.peakIn).max() ?? 0)
                    NetToysSummaryCard(title: "Interfaces", value: "\(rows.count)", unit: "moving data")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(shown.map { "Traffic on \($0)" } ?? "Traffic").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Dense.secondary)
                        Spacer()
                        legend("Download", Dense.accent)
                        legend("Upload", Dense.green)
                    }
                    Chart(series, id: \.date) { sample in
                        AreaMark(x: .value("Time", sample.date), y: .value("Mbps", sample.bytesInPerSecond * 8 / 1_000_000),
                                 series: .value("Kind", "Download"))
                            .foregroundStyle(Dense.accent.opacity(0.22))
                        LineMark(x: .value("Time", sample.date), y: .value("Mbps", sample.bytesInPerSecond * 8 / 1_000_000),
                                 series: .value("Kind", "Download"))
                            .foregroundStyle(Dense.accent).lineStyle(StrokeStyle(lineWidth: 1.5))
                        LineMark(x: .value("Time", sample.date), y: .value("Mbps", sample.bytesOutPerSecond * 8 / 1_000_000),
                                 series: .value("Kind", "Upload"))
                            .foregroundStyle(Dense.green).lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartYAxisLabel("Mbps")
                    .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Dense.hair); AxisValueLabel() } }
                    .chartXAxis { AxisMarks(values: .stride(by: .minute)) { AxisGridLine().foregroundStyle(Dense.hair); AxisValueLabel(format: .dateTime.hour().minute()) } }
                    .frame(height: 180)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
            }
        } results: {
            UtilityTable(columns: columns, rows: rows, empty: running ? "Waiting for the second reading…" : "Paused",
                         open: { selected = $0.name }) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.name == shown ? "chart.xyaxis.line" : "circle").font(.system(size: 9))
                        .foregroundStyle(row.name == shown ? Dense.accent : Color.clear)
                    Text(row.name).fontWeight(.medium)
                }
                .cell(columns[0])
                Text(rate(row.now?.bytesInPerSecond ?? 0)).cell(columns[1])
                Text(rate(row.now?.bytesOutPerSecond ?? 0)).cell(columns[2])
                Text(rate(row.peakIn)).foregroundStyle(Dense.secondary).cell(columns[3])
                Text(rate(row.peakOut)).foregroundStyle(Dense.secondary).cell(columns[4])
                Text(bytes(row.totalIn + row.totalOut)).foregroundStyle(Dense.secondary).cell(columns[5])
            } menu: { row in
                Button("Show in Chart") { selected = row.name }
            }
        }
        .task(id: running) {
            guard live, running else { return }
            for await update in NetToysTrafficMonitor.live() { history = update }
        }
    }

    private let columns = [
        UtilityColumn(title: "Interface", width: 120), UtilityColumn(title: "Download", width: 110, trailing: true),
        UtilityColumn(title: "Upload", width: 110, trailing: true), UtilityColumn(title: "Peak download", width: 110, trailing: true),
        UtilityColumn(title: "Peak upload", width: 110, trailing: true), UtilityColumn(title: "Moved, last 10 min", trailing: true),
    ]

    /// Busiest interface first.
    private var rows: [Row] {
        history.samples.map { name, series in
            Row(name: name, now: series.last, peakIn: series.map(\.bytesInPerSecond).max() ?? 0,
                peakOut: series.map(\.bytesOutPerSecond).max() ?? 0,
                totalIn: series.map(\.bytesInPerSecond).reduce(0, +), totalOut: series.map(\.bytesOutPerSecond).reduce(0, +))
        }
        .sorted { ($0.totalIn + $0.totalOut, $1.name) > ($1.totalIn + $1.totalOut, $0.name) }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        let value = UtilityFormat.rate(bytesPerSecond)
        return "\(value.value) \(value.unit)"
    }

    private func bytes(_ count: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }

    private func rateCard(_ title: String, _ bytesPerSecond: Double) -> some View {
        let value = UtilityFormat.rate(bytesPerSecond)
        return NetToysSummaryCard(title: title, value: value.value, unit: value.unit)
    }
}

private func legend(_ title: String, _ tone: Color) -> some View {
    HStack(spacing: 5) {
        Capsule().fill(tone).frame(width: 10, height: 3)
        Text(title).font(.system(size: 11)).foregroundStyle(Dense.secondary)
    }
}

// MARK: - Location permission (Wi-Fi names)

/// Reads the Location permission without asking. Asks only when the user clicks Allow Location.
@Observable
@MainActor
final class NetToysLocationGate: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private let manager: CLLocationManager?

    /// `status` set: a fixed state for offscreen renders, with no location manager at all.
    init(status: CLAuthorizationStatus? = nil) {
        manager = status == nil ? CLLocationManager() : nil
        self.status = status ?? manager?.authorizationStatus ?? .notDetermined
        super.init()
        manager?.delegate = self
    }

    static let shared = NetToysLocationGate()

    var allowed: Bool { status != .notDetermined && status != .denied && status != .restricted }

    func allow() {
        switch NetToysLocationAction(status: status, requestFailed: false) {
        case .request:
            manager?.requestWhenInUseAuthorization()
        case .openSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        case .none: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { status = manager.authorizationStatus }
}

private struct LocationNote: View {
    let gate: NetToysLocationGate
    var body: some View {
        UtilityNote(symbol: "location.slash", text: "macOS hides Wi-Fi names until this app may use Location. Channels and signal still show.",
                    tone: Dense.amber, action: (title: gate.status == .notDetermined ? "Allow Location" : "Open Settings", run: gate.allow))
    }
}

// MARK: - Wi-Fi Analyzer

struct NetToysWiFiAnalyzerView: View {
    let tool: NetToysTool
    private let live: Bool
    @State private var scan: NetToysWiFiScan?
    @State private var scanning = false
    @State private var band: NetToysWiFiBand
    @State private var gate: NetToysLocationGate
    @State private var input = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tool: NetToysTool, scan: NetToysWiFiScan? = nil, band: NetToysWiFiBand = .ghz5, location: CLAuthorizationStatus? = nil) {
        self.tool = tool
        live = scan == nil
        _scan = State(initialValue: scan)
        _band = State(initialValue: band)
        _gate = State(initialValue: location.map { NetToysLocationGate(status: $0) } ?? .shared)
    }

    var body: some View {
        let advice = scan?.advice.first { $0.band == band }
        let usage = bars(advice)
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: scanning, run: { Task { await rescan() } }) {
            VStack(alignment: .leading, spacing: 12) {
                if let state = scan?.state, state != .ok, state != .namesHidden {
                    UtilityNote(symbol: "wifi.slash", text: stateText(state), tone: Dense.amber)
                }
                if scan?.state == .namesHidden || !gate.allowed { LocationNote(gate: gate) }
                HStack(spacing: 10) {
                    NetToysSummaryCard(title: "Networks nearby", value: "\(scan?.networks.count ?? 0)")
                    NetToysSummaryCard(title: "Your channel", value: scan?.currentChannel.map(String.init) ?? "None",
                                       unit: scan?.currentBand?.rawValue ?? "")
                    NetToysSummaryCard(title: "Best on \(band.rawValue)", value: advice.map { String($0.channel) } ?? "None",
                                       unit: advice.map { $0.overlapping == 0 ? "free" : "\($0.overlapping) nearby" } ?? "", tone: Dense.accent)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Busy channels").font(.system(size: 12, weight: .semibold)).foregroundStyle(Dense.secondary)
                        Spacer()
                        OnePlusLinearSegmented(choices: NetToysWiFiBand.allCases.map { ($0, $0.rawValue) }, selection: $band,
                                               accessibilityLabel: "Band", sizing: .snug)
                    }
                    Chart(usage, id: \.channel) { item in
                        BarMark(x: .value("Channel", String(item.channel)), y: .value("Networks", item.overlapping))
                            .foregroundStyle(item.channel == advice?.channel ? Dense.accent
                                : item.channel == scan?.currentChannel && band == scan?.currentBand ? Dense.green : Dense.secondary.opacity(0.45))
                            .cornerRadius(3)
                            .annotation(position: .top) {
                                Text("\(item.overlapping)").font(.system(size: 10)).foregroundStyle(Dense.secondary)
                            }
                    }
                    .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Dense.hair); AxisValueLabel() } }
                    .chartYAxisLabel("Networks on or overlapping")
                    .overlay { if usage.isEmpty { Text("No networks on \(band.rawValue)").font(.system(size: 12)).foregroundStyle(Dense.tertiary) } }
                    .animation(Dense.spring(reduceMotion), value: band)
                    .frame(height: 150)
                    if let advice {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Dense.accent).font(.system(size: 12))
                            Text(advice.reason).font(.system(size: 12)).foregroundStyle(Dense.label).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(NetToysWiFiScan.limitNote).font(.system(size: 11)).foregroundStyle(Dense.tertiary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
            }
        } results: {
            let networks = (scan?.networks ?? []).filter { $0.band == band }
            UtilityTable(columns: columns, rows: networks, empty: scanning ? "Scanning…" : "No networks on \(band.rawValue)") { network in
                Text(network.ssid ?? "Hidden name").fontWeight(.medium)
                    .foregroundStyle(network.ssid == nil ? Dense.tertiary : Dense.label).cell(columns[0])
                MonoText(network.bssid ?? "").cell(columns[1])
                Text("\(network.rssi) dBm").cell(columns[2])
                Text("\(network.channel)").cell(columns[3])
                Text("\(network.widthMHz) MHz").foregroundStyle(Dense.secondary).cell(columns[4])
                Text(signalWord(network.rssi)).foregroundStyle(Dense.secondary).cell(columns[5])
            }
        }
        .task {
            guard live, scan == nil else { return }
            await rescan()
            if let current = scan?.currentBand { band = current }
        }
    }

    private let columns = [
        UtilityColumn(title: "Network", width: 220), UtilityColumn(title: "BSSID", width: 160),
        UtilityColumn(title: "Signal", width: 80, trailing: true), UtilityColumn(title: "Channel", width: 64, trailing: true),
        UtilityColumn(title: "Width", width: 74, trailing: true), UtilityColumn(title: "Strength"),
    ]

    /// Channels in use on the band, plus the best channel, which is often free and so has no usage row.
    private func bars(_ advice: NetToysChannelAdvice?) -> [(channel: Int, overlapping: Int)] {
        var bars = (scan?.usage ?? []).filter { $0.band == band }.map { (channel: $0.channel, overlapping: $0.overlapping) }
        if let advice, !bars.contains(where: { $0.channel == advice.channel }) {
            bars.append((channel: advice.channel, overlapping: advice.overlapping))
            bars.sort { $0.channel < $1.channel }
        }
        return bars
    }

    private var subtitle: String {
        guard let scan else { return scanning ? "Scanning, this takes a few seconds" : tool.line }
        return "\(scan.networks.count) networks heard, \(scan.usage.count) channels in use"
    }

    private func stateText(_ state: NetToysWiFiScan.State) -> String {
        switch state {
        case .wifiOff: "Wi-Fi is off. Turn it on to scan."
        case .noInterface: "This Mac has no Wi-Fi interface."
        case .failed(let message): "The scan failed: \(message)"
        case .ok, .namesHidden: ""
        }
    }

    private func rescan() async {
        guard live, !scanning else { return }
        scanning = true
        scan = await NetToysWiFiAnalyzer.scan()
        scanning = false
    }
}

private func signalWord(_ rssi: Int) -> String {
    if rssi >= -55 { return "Excellent" }
    if rssi >= -67 { return "Good" }
    return rssi >= -75 ? "Fair" : "Weak"
}

// MARK: - Wi-Fi Signal

struct NetToysWiFiSignalView: View {
    let tool: NetToysTool
    private let live: Bool
    @State private var samples: [NetToysWiFiSignalSample]
    @State private var connected = true
    @State private var running: Bool
    @State private var gate: NetToysLocationGate
    @State private var input = ""
    @Environment(\.toolPageActive) private var active

    init(tool: NetToysTool, samples: [NetToysWiFiSignalSample]? = nil, location: CLAuthorizationStatus? = nil) {
        self.tool = tool
        live = samples == nil
        _samples = State(initialValue: samples ?? [])
        _running = State(initialValue: samples == nil)
        _gate = State(initialValue: location.map { NetToysLocationGate(status: $0) } ?? .shared)
    }

    var body: some View {
        let last = samples.last
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: running, run: { running.toggle() }) {
            VStack(alignment: .leading, spacing: 12) {
                if !connected { UtilityNote(symbol: "wifi.slash", text: "This Mac is not on Wi-Fi.", tone: Dense.amber) }
                if last != nil, last?.ssid == nil, !gate.allowed { LocationNote(gate: gate) }
                HStack(spacing: 10) {
                    NetToysSummaryCard(title: "Signal", value: last.map { "\($0.rssi)" } ?? "None",
                                       unit: last.map { "dBm, \(signalWord($0.rssi).lowercased())" } ?? "")
                    NetToysSummaryCard(title: "Noise", value: last.map { "\($0.noise)" } ?? "None", unit: "dBm")
                    NetToysSummaryCard(title: "Signal over noise", value: last.map { "\($0.snr)" } ?? "None", unit: "dB",
                                       tone: last.map { $0.snr >= 25 ? Dense.green : $0.snr >= 15 ? Dense.label : Dense.amber } ?? Dense.label)
                    NetToysSummaryCard(title: "Link rate", value: last.map { "\(Int($0.transmitRateMbps))" } ?? "None", unit: "Mbps")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Last 5 min").font(.system(size: 12, weight: .semibold)).foregroundStyle(Dense.secondary)
                        Spacer()
                        legend("Signal", Dense.accent)
                        legend("Noise", Dense.secondary)
                    }
                    Chart(samples, id: \.date) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("dBm", sample.rssi), series: .value("Kind", "Signal"))
                            .foregroundStyle(Dense.accent).lineStyle(StrokeStyle(lineWidth: 1.5))
                        LineMark(x: .value("Time", sample.date), y: .value("dBm", sample.noise), series: .value("Kind", "Noise"))
                            .foregroundStyle(Dense.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    .chartYScale(domain: -100 ... -20)
                    .chartYAxisLabel("dBm")
                    .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Dense.hair); AxisValueLabel() } }
                    .chartXAxis { AxisMarks(values: .stride(by: .minute)) { AxisGridLine().foregroundStyle(Dense.hair); AxisValueLabel(format: .dateTime.hour().minute()) } }
                    .frame(height: 180)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
            }
        } results: {
            UtilityTable(columns: pairColumnsSignal, rows: details(last)) { row in
                Text(row.label).foregroundStyle(Dense.secondary).cell(pairColumnsSignal[0])
                Text(row.value).fontWeight(.medium).foregroundStyle(row.tone).cell(pairColumnsSignal[1])
                Text(row.note).foregroundStyle(Dense.secondary).cell(pairColumnsSignal[2])
            }
        }
        // Reading the radio pauses while the page is hidden; the samples stay.
        .task(id: running && active) {
            guard live, running, active else { return }
            for await sample in NetToysWiFiSignal.live() {
                connected = sample != nil
                guard let sample else { continue }
                samples.append(sample)
                if samples.count > 300 { samples.removeFirst(samples.count - 300) }
            }
        }
    }

    private let pairColumnsSignal = [UtilityColumn(title: "Item", width: 180), UtilityColumn(title: "Value", width: 200),
                                     UtilityColumn(title: "What it means")]

    private var subtitle: String {
        guard let last = samples.last else { return running ? "Reading the signal…" : "Paused" }
        return "\(last.ssid ?? "Wi-Fi") on channel \(last.channel.map(String.init) ?? "unknown"), \(running ? "live" : "paused")"
    }

    private func details(_ sample: NetToysWiFiSignalSample?) -> [UtilityPair] {
        guard let sample else { return [] }
        let signals = samples.map(\.rssi)
        return [
            UtilityPair(label: "Network", value: sample.ssid ?? "Hidden name", note: sample.ssid == nil ? "Needs Location permission." : ""),
            UtilityPair(label: "Channel", value: sample.channel.map(String.init) ?? "Unknown",
                        note: [sample.band?.rawValue, sample.widthMHz.map { "\($0) MHz wide" }].compactMap { $0 }.joined(separator: ", ")),
            UtilityPair(label: "Signal", value: "\(sample.rssi) dBm",
                        note: "\(signalWord(sample.rssi)). Closer to 0 is stronger; below -75 dBm calls drop."),
            UtilityPair(label: "Signal over noise", value: "\(sample.snr) dB",
                        note: sample.snr >= 25 ? "Clean: fast and steady." : sample.snr >= 15 ? "Usable, with some slowdowns." : "Too noisy: expect drops."),
            UtilityPair(label: "Range, last 5 min", value: "\(signals.min() ?? 0) to \(signals.max() ?? 0) dBm",
                        note: "A wide range means the signal swings, for example when people move."),
            UtilityPair(label: "Link rate", value: "\(Int(sample.transmitRateMbps)) Mbps",
                        note: "The radio's own rate. Real downloads reach about half of it."),
        ]
    }
}
