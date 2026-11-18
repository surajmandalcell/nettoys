import AppKit
import NetToysCore
import SwiftUI

/// One stop of the folded path row: this Mac, one hop (index into the hop list), or a "+N" run of quiet hops.
enum NetToysPathStop: Equatable {
    case mac
    case hop(Int)
    case fold(ClosedRange<Int>)
}

/// Which hops a long path keeps in its folded row (specs/product.md, Utilities expansion).
enum NetToysPathFold {
    /// A hop whose average is this much above the previous answering hop is a latency jump.
    static let jumpMilliseconds = 20.0
    /// Paths up to this many hops never fold.
    static let foldAbove = 8

    /// Hops that lose replies or add a latency jump. Silent hops (no reply at all) are routers that drop pings, not problems.
    static func problems(_ hops: [NetToysHop]) -> Set<Int> {
        var out = Set<Int>()
        var previous: Double?
        for (index, hop) in hops.enumerated() {
            guard hop.address != nil, let average = hop.stats.average else { continue }
            if hop.stats.lossPercent > 0 || previous.map({ average - $0 >= jumpMilliseconds }) == true { out.insert(index) }
            previous = average
        }
        return out
    }

    /// Keeps this Mac, the first hop, the last hop, and every problem hop; runs of two or more quiet hops become one fold.
    static func stops(_ hops: [NetToysHop]) -> [NetToysPathStop] {
        guard hops.count > foldAbove else { return [.mac] + hops.indices.map { .hop($0) } }
        let problems = problems(hops)
        var out: [NetToysPathStop] = [.mac, .hop(0)]
        var run: [Int] = []
        func flush() {
            if let first = run.first, let last = run.last, run.count > 1 { out.append(.fold(first...last)) } else { out += run.map { .hop($0) } }
            run = []
        }
        for index in 1..<(hops.count - 1) {
            if problems.contains(index) { flush(); out.append(.hop(index)) } else { run.append(index) }
        }
        flush()
        out.append(.hop(hops.count - 1))
        return out
    }
}

/// Folded row and expanded snake positions. Node 0 is this Mac; node k is hop k - 1.
struct NetToysPathLayout {
    static let side: CGFloat = 34
    static let rowHeight: CGFloat = 92
    static let nodeY: CGFloat = 18
    static let slotHeight: CGFloat = 74
    static let ring: CGFloat = 28

    let stops: [NetToysPathStop]
    /// Node index to the index of the stop that shows it.
    let stopOf: [Int]
    let nodeCount: Int
    let width: CGFloat
    /// False until the view has its real width.
    let measured: Bool
    let perRow: Int

    init(hops: [NetToysHop], width: CGFloat) {
        stops = NetToysPathFold.stops(hops)
        nodeCount = hops.count + 1
        var map = [Int](repeating: 0, count: hops.count + 1)
        for (stop, item) in stops.enumerated() {
            switch item {
            case .mac: map[0] = stop
            case .hop(let index): map[index + 1] = stop
            case .fold(let range): for index in range { map[index + 1] = stop }
            }
        }
        stopOf = map
        measured = width > 0
        self.width = max(width, 320)
        perRow = max(4, min(10, Int((self.width - 2 * Self.side) / 100)))
    }

    var canFold: Bool { stops.count < nodeCount }
    /// Too many problem hops to fit one row: the path always shows as a snake.
    var snakeOnly: Bool { measured && CGFloat(stops.count) * 76 > width }
    var stopWidth: CGFloat { min(112, width / CGFloat(stops.count)) }
    var snakeWidth: CGFloat { (width - 2 * Self.side) / CGFloat(perRow) }
    var rows: Int { (nodeCount + perRow - 1) / perRow }

    func isHidden(_ node: Int) -> Bool { if case .fold = stops[stopOf[node]] { true } else { false } }
    func row(_ node: Int) -> Int { node / perRow }

    func stopPoint(_ stop: Int) -> CGPoint { CGPoint(x: stopWidth * (CGFloat(stop) + 0.5), y: Self.nodeY) }

    func snakePoint(_ node: Int) -> CGPoint {
        let row = node / perRow, column = node % perRow
        let slot = row % 2 == 0 ? column : perRow - 1 - column
        return CGPoint(x: Self.side + snakeWidth * (CGFloat(slot) + 0.5), y: CGFloat(row) * Self.rowHeight + Self.nodeY)
    }

    func point(_ node: Int, expanded: Bool) -> CGPoint { expanded ? snakePoint(node) : stopPoint(stopOf[node]) }

    func height(expanded: Bool) -> CGFloat { expanded ? CGFloat(rows - 1) * Self.rowHeight + Self.slotHeight : Self.slotHeight }

    /// Straight on one row; two rounded corners (real arcs) where the snake turns.
    func segment(_ from: CGPoint, _ to: CGPoint, row: Int) -> Path {
        Path { path in
            path.move(to: from)
            let dy = to.y - from.y
            guard abs(dy) >= 1 else { path.addLine(to: to); return }
            let reach = min(snakeWidth / 2 - 4, abs(dy) * 0.6)
            let edge = row % 2 == 0 ? max(from.x, to.x) + reach : min(from.x, to.x) - reach
            let radius = min(18, abs(dy) / 2, reach)
            path.addArc(tangent1End: CGPoint(x: edge, y: from.y), tangent2End: CGPoint(x: edge, y: to.y), radius: radius)
            path.addArc(tangent1End: CGPoint(x: edge, y: to.y), tangent2End: to, radius: radius)
            path.addLine(to: to)
        }
    }

    /// Drawn length of each segment, so the line draws at one speed and pauses at no fold.
    func lengths(expanded: Bool) -> [CGFloat] {
        (0..<max(nodeCount - 1, 0)).map { k in
            let a = point(k, expanded: expanded), b = point(k + 1, expanded: expanded)
            return abs(b.x - a.x) + abs(b.y - a.y) + (abs(b.y - a.y) >= 1 ? snakeWidth * 0.6 : 0)
        }
    }
}

private enum PathInk {
    static let raised = Color(light: .white, dark: .init(white: 0.2, alpha: 1))
    static let ringEdge = Color(light: .init(white: 0, alpha: 0.14), dark: .init(white: 1, alpha: 0.16))
    static let problem = Dense.amber
}

/// Path diagram, look "Quiet rings" (round 13 option 3), motion "Line draws through".
/// Rings move with a critically damped spring and fade in with ease-out: no overshoot, bounce, or bob.
struct NetToysPathDiagram: View {
    let hops: [NetToysHop]
    var reached = true
    let expanded: Bool
    var expand: () -> Void = {}
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = NetToysPathLayout(hops: hops, width: width)
        let open = expanded || layout.snakeOnly
        KeyframeAnimator(initialValue: 1.0, trigger: open) { drawn in
            canvas(layout, open: open, drawn: drawn)
        } keyframes: { _ in
            if reduceMotion {
                MoveKeyframe(1.0)
            } else {
                MoveKeyframe(0.0)
                LinearKeyframe(1.0, duration: 0.32, timingCurve: .easeOut)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: layout.height(expanded: open), alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(Dense.spring(reduceMotion), value: open)
    }

    private var ringMotion: Animation? { reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 1) }

    private func canvas(_ layout: NetToysPathLayout, open: Bool, drawn: Double) -> some View {
        let points = (0..<layout.nodeCount).map { layout.point($0, expanded: open) }
        let lengths = layout.lengths(expanded: open)
        let total = max(lengths.reduce(0, +), 1)
        var start: CGFloat = 0
        let shares: [Double] = lengths.map { length in
            defer { start += length }
            return length < 0.5 ? (drawn * total >= start ? 1 : 0) : min(max((drawn * total - start) / length, 0), 1)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shares.indices), id: \.self) { k in
                if shares[k] > 0 {
                    layout.segment(points[k], points[k + 1], row: layout.row(k)).trim(from: 0, to: shares[k])
                        .stroke(segmentColor(k + 1), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(0..<layout.nodeCount, id: \.self) { node in
                let hidden = layout.isHidden(node)
                let share = node == 0 ? 1 : shares[node - 1]
                let shown = !hidden || (open && share > 0)
                nodeView(node, layout: layout)
                    .scaleEffect(hidden ? (open ? 0.55 + 0.45 * share : 0.55) : 1,
                                 anchor: UnitPoint(x: 0.5, y: NetToysPathLayout.ring / 2 / NetToysPathLayout.slotHeight))
                    .opacity(shown ? (hidden ? share : 1) : 0)
                    .animation(.easeOut(duration: 0.14), value: open)
                    .position(x: points[node].x, y: points[node].y - NetToysPathLayout.ring / 2 + NetToysPathLayout.slotHeight / 2)
                    .animation(ringMotion, value: open)
                    .allowsHitTesting(shown)
            }
            ForEach(Array(layout.stops.indices), id: \.self) { stop in
                if case .fold(let range) = layout.stops[stop] {
                    foldStop(range, width: layout.stopWidth)
                        .scaleEffect(open ? 0.8 : 1)
                        .opacity(open ? 0 : 1)
                        .animation(.easeOut(duration: open ? 0.12 : 0.2), value: open)
                        .position(x: layout.stopPoint(stop).x,
                                  y: NetToysPathLayout.nodeY - NetToysPathLayout.ring / 2 + NetToysPathLayout.slotHeight / 2)
                        .allowsHitTesting(!open)
                }
            }
        }
        .frame(width: layout.width, height: layout.height(expanded: open), alignment: .topLeading)
    }

    private func segmentColor(_ node: Int) -> Color {
        NetToysPathFold.problems(hops).contains(node - 1) ? PathInk.problem.opacity(0.85) : Dense.track
    }

    @ViewBuilder
    private func nodeView(_ node: Int, layout: NetToysPathLayout) -> some View {
        let slot = layout.snakeOnly || expanded ? layout.snakeWidth : max(layout.stopWidth, layout.snakeWidth)
        VStack(spacing: 4) {
            if node == 0 {
                NetToysPathRing(glyph: "laptopcomputer", end: true)
                label("This Mac", "Start", Dense.secondary, width: slot)
            } else {
                let index = node - 1, hop = hops[index], last = index == hops.count - 1
                let problem = NetToysPathFold.problems(hops).contains(index)
                NetToysPathRing(glyph: Self.glyph(hop, index: index, last: last), end: last && reached,
                                problem: problem, dead: hop.address == nil)
                label(hop.address == nil ? "No reply" : Self.shortName(hop), Self.detail(hop, hops: hops, index: index),
                      problem ? PathInk.problem : Dense.secondary, dim: hop.address == nil, width: slot)
            }
        }
        .frame(width: slot, height: NetToysPathLayout.slotHeight, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private func label(_ title: String, _ detail: String, _ tone: Color, dim: Bool = false, width: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(dim ? Dense.tertiary : Dense.label)
                .lineLimit(1).truncationMode(.middle)
            Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(tone).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: width - 6)
    }

    private func foldStop(_ range: ClosedRange<Int>, width: CGFloat) -> some View {
        Button(action: expand) {
            VStack(spacing: 4) {
                ZStack {
                    stacked.offset(x: 8).opacity(0.5)
                    stacked.offset(x: 4).opacity(0.8)
                    Circle().fill(PathInk.raised).overlay(Circle().strokeBorder(PathInk.ringEdge, lineWidth: 0.75))
                        .frame(width: NetToysPathLayout.ring, height: NetToysPathLayout.ring)
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    Text("+\(range.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Dense.label).monospacedDigit()
                }
                .offset(x: -4)
                VStack(spacing: 1) {
                    Text("\(range.lowerBound + 1)–\(range.upperBound + 1)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Dense.label).monospacedDigit()
                    Text("Show").font(.system(size: 10, weight: .medium)).foregroundStyle(Dense.accent)
                }
            }
            .frame(width: max(width, 60), height: NetToysPathLayout.slotHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show hops \(range.lowerBound + 1) to \(range.upperBound + 1)")
    }

    private var stacked: some View {
        Circle().fill(PathInk.raised).overlay(Circle().stroke(Dense.stroke, lineWidth: 0.75))
            .frame(width: NetToysPathLayout.ring, height: NetToysPathLayout.ring)
    }

    // Stops: router, ISP, backbone, destination.
    static func glyph(_ hop: NetToysHop, index: Int, last: Bool) -> String {
        if hop.address == nil { return "questionmark" }
        if last { return "server.rack" }
        return index == 0 ? "wifi.router" : index == 1 ? "building.2" : "globe"
    }

    /// The first two labels of a reverse name ("ae2.fra"), else the address.
    static func shortName(_ hop: NetToysHop) -> String {
        guard let name = hop.hostname, !name.isEmpty else { return hop.address ?? "No reply" }
        return name.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// "3% loss" or "+72 ms" for a problem hop, else nil.
    static func problem(_ hop: NetToysHop, hops: [NetToysHop], index: Int) -> String? {
        guard hop.address != nil, let average = hop.stats.average else { return nil }
        if hop.stats.lossPercent > 0 { return String(format: "%.0f%% loss", hop.stats.lossPercent) }
        let previous = hops[..<index].last { $0.address != nil }?.stats.average
        if let previous, average - previous >= NetToysPathFold.jumpMilliseconds { return String(format: "+%.0f ms", average - previous) }
        return nil
    }

    static func detail(_ hop: NetToysHop, hops: [NetToysHop], index: Int) -> String {
        guard hop.address != nil, let average = hop.stats.average else { return "hop \(hop.ttl)" }
        return "\(hop.ttl) · " + (problem(hop, hops: hops, index: index) ?? String(format: "%.1f ms", average))
    }
}

/// One "Quiet rings" stop: a small raised disc with a hairline ring, gray glyph, and an amber dot for a problem.
struct NetToysPathRing: View {
    let glyph: String
    var end = false
    var problem = false
    var dead = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle().fill(end ? AnyShapeStyle(Dense.accent) : AnyShapeStyle(PathInk.raised))
                    .overlay(Circle().strokeBorder(end ? Color.clear : dead ? Dense.tertiary : PathInk.ringEdge,
                                                   style: StrokeStyle(lineWidth: 1, dash: dead ? [2, 2] : [])))
                Image(systemName: glyph).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(end ? Color.white : dead ? Dense.tertiary : Dense.secondary)
            }
            .frame(width: NetToysPathLayout.ring, height: NetToysPathLayout.ring)
            if problem {
                Circle().fill(PathInk.problem).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Dense.content, lineWidth: 2)).offset(x: 2, y: -2)
            }
        }
    }
}
