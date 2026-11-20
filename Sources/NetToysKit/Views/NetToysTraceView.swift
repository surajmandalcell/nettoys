import NetToysCore
import Observation
import OnePlusUI
import SwiftUI

/// Runs traceroute (3 rounds) or live MTR (until stopped) and keeps the latest hop table.
@Observable
@MainActor
final class NetToysTraceModel {
    var snapshot: NetToysTraceSnapshot?
    /// Live MTR instead of a 3-round traceroute.
    var live = false
    private(set) var running = false
    private(set) var error: String?
    private(set) var host = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(snapshot: NetToysTraceSnapshot? = nil, live: Bool = false) {
        self.snapshot = snapshot
        self.live = live
    }

    func toggle(_ host: String) { running ? stop() : start(host) }

    func start(_ rawHost: String) {
        stop()
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        self.host = host
        error = nil
        snapshot = nil
        running = true
        let rounds: Int? = live ? nil : 3
        task = Task { [weak self] in
            do {
                for try await snapshot in NetToysTraceroute.run(host: host, rounds: rounds) { self?.snapshot = snapshot }
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
}

struct NetToysTraceView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var model: NetToysTraceModel
    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `model` and `expanded` seed the page once; renders pass synthetic hops.
    init(tool: NetToysTool, input: Binding<String>, model: NetToysTraceModel? = nil, expanded: Bool = false) {
        self.tool = tool
        _input = input
        _model = State(initialValue: model ?? NetToysTraceModel())
        _expanded = State(initialValue: expanded)
    }

    private var hops: [NetToysHop] { model.snapshot?.hops ?? [] }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: model.running, run: { model.toggle(input) }) {
            summary
        } results: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pathCard
                    NetToysHopTable(hops: hops, problems: NetToysPathFold.problems(hops))
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .onChange(of: model.live) { if model.running { model.start(model.host) } }
        .onDisappear { model.stop() }
    }

    private var subtitle: String {
        if let error = model.error { return error }
        guard let snapshot = model.snapshot else { return model.running ? "Tracing \(model.host)" : tool.line }
        let end = snapshot.hops.last?.stats.average.map { String(format: " · %.1f ms", $0) } ?? ""
        return "\(snapshot.hops.count) hops\(end) · round \(snapshot.round)" + (snapshot.reachedTarget ? "" : " · target not reached")
    }

    private var summary: some View {
        let last = hops.last
        let worst = worstHop
        return HStack(spacing: 10) {
            NetToysSummaryCard(title: "Hops", value: hops.isEmpty ? "–" : "\(hops.count)")
            NetToysSummaryCard(title: "Round trip", value: last?.stats.average.map { String(format: "%.1f", $0) } ?? "–", unit: "ms")
            NetToysSummaryCard(title: "Loss", value: last.map { String(format: "%.1f", $0.stats.lossPercent) } ?? "–", unit: "%",
                               tone: (last?.stats.lossPercent ?? 0) > 0 ? Dense.amber : Dense.label)
            NetToysSummaryCard(title: "Worst hop", value: worst.map { "\($0.ttl)" } ?? "–",
                               unit: worst.flatMap { NetToysPathDiagram.problem($0, hops: hops, index: $0.ttl - 1) } ?? "",
                               tone: worst == nil ? Dense.label : Dense.amber)
        }
    }

    /// The problem hop with the most loss, else the biggest latency jump.
    private var worstHop: NetToysHop? {
        NetToysPathFold.problems(hops).map { hops[$0] }.max { a, b in
            (a.stats.lossPercent, a.stats.average ?? 0) < (b.stats.lossPercent, b.stats.average ?? 0)
        }
    }

    private var pathCard: some View {
        let layout = NetToysPathLayout(hops: hops, width: 800)
        return VStack(alignment: .leading, spacing: 10) {
            // Light to heavy: title, readings, note, mode picker, fold button.
            HStack(spacing: 8) {
                Text("Path").font(.system(size: 13, weight: .semibold)).foregroundStyle(Dense.label)
                Text("\(hops.count) hops").font(.system(size: 12)).foregroundStyle(Dense.secondary).monospacedDigit()
                Text(note).font(.system(size: 11)).foregroundStyle(Dense.secondary).lineLimit(1).padding(.leading, 8)
                Spacer(minLength: 8)
                OnePlusLinearSegmented(choices: [(false, "List"), (true, "Live MTR")], selection: $model.live,
                                       accessibilityLabel: "Mode", sizing: .snug)
                if layout.canFold && !layout.snakeOnly {
                    Button { setExpanded(!expanded) } label: {
                        HStack(spacing: 5) {
                            Text(expanded ? "Fold quiet hops" : "Show all \(hops.count)").font(.system(size: 12, weight: .medium))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Dense.accent)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Dense.accent.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 24)
            NetToysPathDiagram(hops: hops, reached: model.snapshot?.reachedTarget ?? true, expanded: expanded) { setExpanded(true) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Dense.group))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Dense.groupStroke, lineWidth: 0.5))
    }

    private func setExpanded(_ value: Bool) { withAnimation(Dense.spring(reduceMotion)) { expanded = value } }

    /// One plain line about the path: the worst problem, else the first silent hop.
    private var note: String {
        if let worst = worstHop {
            return worst.stats.lossPercent > 0
                ? String(format: "Hop %d loses %.0f%% of replies.", worst.ttl, worst.stats.lossPercent)
                : "Hop \(worst.ttl) adds \(NetToysPathDiagram.problem(worst, hops: hops, index: worst.ttl - 1)?.dropFirst() ?? "")."
        }
        if let silent = hops.first(where: { $0.address == nil }) { return "Hop \(silent.ttl) gives no reply. Routers often drop pings." }
        return hops.isEmpty ? "Enter a host and press Run." : ""
    }
}

/// Hop table: hop, host, IP, loss, last, avg, best, worst, jitter. Rows stream in as hops answer.
struct NetToysHopTable: View {
    let hops: [NetToysHop]
    let problems: Set<Int>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            NetToysTableHeader(columns: Self.columns)
            LazyVStack(spacing: 0) {
                ForEach(hops) { hop in
                    row(hop).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hop.ttl % 2 == 0 ? Dense.zebra : .clear))
                        .transition(.opacity)
                }
            }
            .animation(Dense.spring(reduceMotion), value: hops.count)
        }
    }

    static let columns: [NetToysTableColumn] = [
        .init("#", 26, .trailing), .init("Host", nil), .init("IP Address", 128), .init("Loss", 52, .trailing),
        .init("Last", 56, .trailing), .init("Avg", 56, .trailing), .init("Best", 56, .trailing), .init("Worst", 56, .trailing),
        .init("Jitter", 56, .trailing),
    ]

    private func row(_ hop: NetToysHop) -> some View {
        let dead = hop.address == nil, stats = hop.stats
        let loss = stats.lossPercent
        return NetToysTableRow(columns: Self.columns, cells: [
            .init("\(hop.ttl)", Dense.secondary),
            .init(dead ? "No reply" : hop.hostname ?? hop.address ?? "", dead ? Dense.tertiary : Dense.label, weight: dead ? .regular : .medium),
            .init(hop.address ?? "* * *", dead ? Dense.tertiary : Dense.secondary, mono: true),
            .init(String(format: "%.0f%%", loss), dead ? Dense.tertiary : loss > 0 ? Dense.amber : Dense.secondary),
            .init(Self.ms(stats.last), Dense.label),
            .init(Self.ms(stats.average), problems.contains(hop.ttl - 1) ? Dense.amber : Dense.label),
            .init(Self.ms(stats.best), Dense.secondary),
            .init(Self.ms(stats.worst), Dense.secondary),
            .init(Self.ms(stats.jitter), Dense.secondary),
        ])
    }

    static func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
}

// MARK: Shared table pieces for the Ping and Traceroute pages

struct NetToysTableColumn {
    let title: String
    /// Nil takes the remaining width.
    let width: CGFloat?
    let alignment: Alignment
    init(_ title: String, _ width: CGFloat?, _ alignment: Alignment = .leading) {
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

struct NetToysTableCell {
    let text: String
    let tone: Color
    var weight: Font.Weight = .regular
    var mono = false
    init(_ text: String, _ tone: Color, weight: Font.Weight = .regular, mono: Bool = false) {
        self.text = text
        self.tone = tone
        self.weight = weight
        self.mono = mono
    }
}

struct NetToysTableHeader: View {
    let columns: [NetToysTableColumn]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index]
                Text(column.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.secondary)
                    .frame(width: column.width, alignment: column.alignment)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: column.alignment)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .overlay(alignment: .bottom) { DenseHairline() }
    }
}

struct NetToysTableRow: View {
    let columns: [NetToysTableColumn]
    let cells: [NetToysTableCell]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index], cell = cells[index]
                Text(cell.text)
                    .font(cell.mono ? .system(size: 12, design: .monospaced) : .system(size: 13, weight: cell.weight))
                    .foregroundStyle(cell.tone).monospacedDigit().lineLimit(1).truncationMode(.middle)
                    .frame(width: column.width, alignment: column.alignment)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: column.alignment)
            }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .textSelection(.enabled)
    }
}
