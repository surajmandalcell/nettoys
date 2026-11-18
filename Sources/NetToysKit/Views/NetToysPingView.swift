import Charts
import NetToysCore
import Observation
import SwiftUI

/// Continuous ping: every sample, plus running statistics.
@Observable
@MainActor
final class NetToysPingModel {
    /// shortcut: keeps the last 3600 samples (one hour at 1 per second) for the table, stats cover the whole run; page or export if longer runs matter.
    static let keep = 3600
    private(set) var samples: [NetToysPingSample] = []
    private(set) var stats = NetToysLatencyStats()
    private(set) var running = false
    private(set) var error: String?
    private(set) var host = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(samples: [NetToysPingSample] = []) { for sample in samples { add(sample) } }

    func toggle(_ host: String) { running ? stop() : start(host) }

    func start(_ rawHost: String) {
        stop()
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        self.host = host
        error = nil
        samples = []
        stats = NetToysLatencyStats()
        running = true
        task = Task { [weak self] in
            do {
                for try await sample in NetToysPing.stream(host: host) { self?.add(sample) }
            } catch {
                if !Task.isCancelled { self?.error = error.localizedDescription }
            }
            if !Task.isCancelled { self?.running = false }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    private func add(_ sample: NetToysPingSample) {
        samples.append(sample)
        stats.record(sample.milliseconds)
        if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }
    }
}

struct NetToysPingView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var model: NetToysPingModel

    /// `model` seeds the page once; renders pass synthetic samples.
    init(tool: NetToysTool, input: Binding<String>, model: NetToysPingModel? = nil) {
        self.tool = tool
        _input = input
        _model = State(initialValue: model ?? NetToysPingModel())
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: model.running, run: { model.toggle(input) }) {
            summary
        } results: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    NetToysPingChart(samples: model.samples.suffix(60))
                    table
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .onDisappear { model.stop() }
    }

    private var subtitle: String {
        if let error = model.error { return error }
        guard let address = model.samples.last?.address else { return model.running ? "Pinging \(model.host)" : tool.line }
        return "\(address) · every 1 s" + (model.running ? "" : " · stopped")
    }

    private var summary: some View {
        let stats = model.stats, empty = stats.sent == 0
        return HStack(spacing: 10) {
            NetToysSummaryCard(title: "Sent", value: empty ? "–" : "\(stats.sent)")
            NetToysSummaryCard(title: "Lost", value: empty ? "–" : "\(stats.sent - stats.received)",
                               unit: empty ? "" : String(format: "%.1f%%", stats.lossPercent),
                               tone: stats.received < stats.sent ? Dense.amber : Dense.label)
            NetToysSummaryCard(title: "Min", value: NetToysHopTable.ms(stats.best), unit: "ms")
            NetToysSummaryCard(title: "Avg", value: NetToysHopTable.ms(stats.average), unit: "ms")
            NetToysSummaryCard(title: "Max", value: NetToysHopTable.ms(stats.worst), unit: "ms")
            NetToysSummaryCard(title: "Jitter", value: NetToysHopTable.ms(stats.jitter), unit: "ms")
        }
    }

    private static let columns: [NetToysTableColumn] = [
        .init("#", 44, .trailing), .init("Address", 140), .init("Time", 80, .trailing), .init("TTL", 44, .trailing), .init("Status", nil),
    ]

    private var table: some View {
        VStack(spacing: 0) {
            NetToysTableHeader(columns: Self.columns)
            LazyVStack(spacing: 0) {
                ForEach(model.samples.reversed(), id: \.sequence) { sample in
                    let lost = sample.milliseconds == nil
                    NetToysTableRow(columns: Self.columns, cells: [
                        .init("\(sample.sequence)", Dense.secondary),
                        .init(sample.address, Dense.secondary, mono: true),
                        .init(lost ? "–" : String(format: "%.1f ms", sample.milliseconds ?? 0), lost ? Dense.tertiary : Dense.label),
                        .init(sample.ttl.map(String.init) ?? "–", Dense.secondary),
                        .init(lost ? "No reply in 1 s" : "Reply", lost ? Dense.amber : Dense.secondary),
                    ])
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(sample.sequence % 2 == 0 ? Dense.zebra : .clear))
                }
            }
        }
    }
}

/// Live round trip of the last 60 pings. Lost pings show as amber rules.
struct NetToysPingChart: View {
    let samples: ArraySlice<NetToysPingSample>

    var body: some View {
        let first = samples.first?.sequence ?? 1
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Round trip").font(.system(size: 13, weight: .semibold)).foregroundStyle(Dense.label)
                Text("Last 60 pings").font(.system(size: 12)).foregroundStyle(Dense.secondary)
            }
            .frame(height: 24)
            Chart {
                ForEach(samples, id: \.sequence) { sample in
                    if let ms = sample.milliseconds {
                        AreaMark(x: .value("Ping", sample.sequence), y: .value("Time", ms))
                            .foregroundStyle(LinearGradient(colors: [Dense.accent.opacity(0.22), Dense.accent.opacity(0)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Ping", sample.sequence), y: .value("Time", ms))
                            .foregroundStyle(Dense.accent).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    } else {
                        RuleMark(x: .value("Ping", sample.sequence)).foregroundStyle(Dense.amber.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
            }
            .chartXScale(domain: first...(first + 59))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Dense.hair)
                    AxisValueLabel { if let ms = value.as(Double.self) { Text("\(ms, specifier: "%.0f") ms") } }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Round trip of the last 60 pings")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Dense.group))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Dense.groupStroke, lineWidth: 0.5))
    }
}
