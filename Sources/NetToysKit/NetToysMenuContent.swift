import AppKit
import NetToysCore
import SwiftUI

/// What the menu bar panel shows. Loaded from the stores and a few quick probes.
public struct NetToysTraySnapshot: Sendable {
    var configuration = NetToysConfiguration()
    var helperStatus: NetToysHelperStatus?
    var route: DefaultRoute?
    var localNetwork: LocalIPv4Network?
    var ssid: String?
    var gatewayMilliseconds: Double?
    /// The last hour of the runtime's gateway series, oldest first. Nil is a lost ping.
    var latencySamples: [Double?] = []
    var latencyStamp: Date?
    /// When the current online (or offline) stretch began, from Network History.
    var stateSince: Date?
    var outagesToday = 0
    var outageSecondsToday: TimeInterval = 0
    var deviceCount: Int?
    var offlineDeviceCount = 0
    var isLoaded = false

    public init() {}

    var isOnline: Bool { helperStatus?.network?.internet != .unreachable && route != nil }

    nonisolated static func load(keeping previous: Self) async -> Self {
        var result = await Task.detached(priority: .utility) {
            var snapshot = Self()
            snapshot.configuration = NetToysConfigurationStore.load()
            snapshot.helperStatus = NetToysConfigurationStore.status()
            let events = NetToysConfigurationStore.history().events
            snapshot.applyHistory(events, now: Date())
            let runs = NetToysScannerStore.archive().runs
            if let latest = runs.last {
                let seen = Set(runs.flatMap { $0.results.filter(\.isReachable).map(\.id) })
                let up = Set(latest.results.filter(\.isReachable).map(\.id))
                snapshot.deviceCount = seen.count
                snapshot.offlineDeviceCount = seen.subtracting(up).count
            }
            // The latency file changes every 2 min at most; decode it only then.
            let latency = NetToysRuntimePaths.standard.latency
            snapshot.latencyStamp = (try? FileManager.default.attributesOfItem(atPath: latency.path))?[.modificationDate] as? Date
            if snapshot.latencyStamp == previous.latencyStamp, previous.isLoaded {
                snapshot.latencySamples = previous.latencySamples
            } else {
                let hourAgo = Date().addingTimeInterval(-3_600)
                snapshot.latencySamples = (NetToysLatencyStore.load(from: latency).series[NetToysLatencyHistory.gateway] ?? [])
                    .filter { $0.date > hourAgo }.map(\.milliseconds)
            }
            snapshot.isLoaded = true
            return snapshot
        }.value
        guard !Task.isCancelled else { return result }
        let routeData = try? await TailscalePeerCatalog.runStatusCommand(
            executableURL: URL(fileURLWithPath: "/sbin/route"), arguments: ["-n", "get", "default"],
            maximumOutputBytes: 8_192, timeout: 2
        )
        guard !Task.isCancelled else { return result }
        result.route = routeData.flatMap { DefaultRoute.parse(String(decoding: $0, as: UTF8.self)) }
        if let route = result.route {
            let local = await Task.detached(priority: .utility) {
                (LocalIPv4Network.active(preferredInterfaceName: route.interfaceName),
                 NetworkSSID.current(interfaceName: route.interfaceName))
            }.value
            result.localNetwork = local.0?.interfaceName == route.interfaceName ? local.0 : nil
            result.ssid = local.1
            guard !Task.isCancelled else { return result }
            if let gateway = IPv4Address(route.gateway) {
                result.gatewayMilliseconds = await PingProbe.check(address: gateway, count: 1, timeoutMilliseconds: 1_000)?
                    .averageMilliseconds
            }
        }
        return result
    }

    /// Finds when the current state began and counts today's internet outages.
    nonisolated mutating func applyHistory(_ events: [NetworkTransitionEvent], now: Date) {
        let start = Calendar.current.startOfDay(for: now)
        var outageStart: Date?
        outagesToday = 0
        outageSecondsToday = 0
        stateSince = nil
        for event in events.sorted(by: { $0.date < $1.date }) {
            for change in event.changes {
                guard case .internet(_, let to) = change else {
                    if case .network = change { stateSince = event.date }
                    continue
                }
                stateSince = event.date
                guard event.date >= start else { continue }
                if to == .unreachable, outageStart == nil {
                    outageStart = event.date
                    outagesToday += 1
                } else if to == .reachable, let began = outageStart {
                    outageSecondsToday += event.date.timeIntervalSince(began)
                    outageStart = nil
                }
            }
        }
        if let outageStart { outageSecondsToday += now.timeIntervalSince(outageStart) }
    }
}

extension NetToysTraySnapshot {
    /// The saved pause and safe mode win over the runtime's last status, so Pause and Resume show at once.
    var system: NetToysSystemHealth {
        if let reason = configuration.safeModeReason { return .failed(reason: reason) }
        if configuration.actionsPaused { return .paused }
        return helperStatus?.system ?? .running
    }
}

/// The menu bar panel: loads the snapshot while open and runs the panel actions.
public struct NetToysMenuContent: View {
    @Binding private var snapshot: NetToysTraySnapshot
    private let openPage: (NetToysPage) -> Void
    @State private var speedTest: NetToysSpeedTest
    @State private var visible = false

    public init(snapshot: Binding<NetToysTraySnapshot>, host: NetToysHost, openPage: @escaping (NetToysPage) -> Void) {
        _snapshot = snapshot
        self.openPage = openPage
        _speedTest = State(initialValue: NetToysSpeedTest(defaults: host.defaults))
    }

    public var body: some View {
        NetToysMenuPanel(snapshot: snapshot, speedTest: speedTest, system: snapshot.system,
                         visible: visible, openPage: openPage, toggleSystem: {
                             // The row toggles only from Running (Pause) or Paused (Resume).
                             if let saved = try? NetToysConfigurationStore.setActionsPaused(snapshot.system != .paused) {
                                 snapshot.configuration = saved
                             }
                         })
            .background(NetToysKeyWindowReader { visible = $0 })
            .task(id: visible) {
                while visible, !Task.isCancelled {
                    snapshot = await NetToysTraySnapshot.load(keeping: snapshot)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}

// MARK: - Panel

private enum Panel {
    static let edge: CGFloat = 20
    static let card = Color(light: .init(white: 1, alpha: 0.6), dark: .init(white: 1, alpha: 0.07))
    static let fill = Color(light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 0.74),
                            dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 0.66))
    static let well = Color(light: .init(white: 0, alpha: 0.07), dark: .init(white: 1, alpha: 0.13))
    static let hover = Color(light: .init(white: 0, alpha: 0.06), dark: .init(white: 1, alpha: 0.09))
    static let separator = Color(light: .init(white: 0, alpha: 0.1), dark: .init(white: 1, alpha: 0.1))
    static let red = Color(light: NSColor(srgbRed: 0.79, green: 0.28, blue: 0.25, alpha: 1),
                           dark: NSColor(srgbRed: 1, green: 0.54, blue: 0.5, alpha: 1))
}

struct NetToysMenuPanel: View {
    let snapshot: NetToysTraySnapshot
    let speedTest: NetToysSpeedTest
    let system: NetToysSystemHealth
    var visible = true
    let openPage: (NetToysPage) -> Void
    let toggleSystem: () -> Void
    var now = Date()
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failover = snapshot.helperStatus?.wifiFailover, snapshot.configuration.wifiPriority.isEnabled,
               failover.state == .waiting, let next = failover.next, let joinAt = failover.joinAt {
                TimelineView(.periodic(from: now, by: 1)) { context in
                    autoJoinCard(next: next, joinAt: joinAt, now: max(context.date, now))
                }
                .padding(.bottom, 8)
            }
            latencyCard
            Color.clear.frame(height: 8)
            statusCard
            separator
            speedRow
            copyRow
            systemRow
            separator
            NetToysMenuItem(title: "Open Sam's Network Utilities", key: "⌘O") { openPage(.scanner) }
                .keyboardShortcut("o")
            NetToysMenuItem(title: "Settings…", key: "⌘,") { openPage(.settings) }
                .keyboardShortcut(",")
        }
        .padding(.bottom, 6)
        .frame(width: 360)
        .background(Panel.fill)
        .scaleEffect(visible || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.9), value: visible)
    }

    // MARK: Header: headline and subtitle only.

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline).font(.system(size: 20, weight: .semibold)).foregroundStyle(Dense.label)
                .monospacedDigit().lineLimit(1)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Dense.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Panel.edge).padding(.top, 16).padding(.bottom, 12)
    }

    private var headline: String {
        guard snapshot.isLoaded else { return "Checking…" }
        let state = snapshot.isOnline ? "Online" : "Offline"
        guard let since = snapshot.stateSince else { return state }
        return "\(state) for \(NetToysDuration.text(now.timeIntervalSince(since)))"
    }

    private var subtitle: String {
        let network = snapshot.ssid ?? snapshot.route.map { NetworkIdentity(networkID: $0.networkID, ssid: nil).displayName }
        return [network, snapshot.localNetwork?.address.description,
                snapshot.gatewayMilliseconds.map { "\(Int($0.rounded())) ms" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Outage auto-join

    /// The runtime's countdown. Join Now and Stay go to the runtime, which still applies pause, dry run, and cooldown.
    private func autoJoinCard(next: String, joinAt: Date, now: Date) -> some View {
        let threshold = snapshot.configuration.wifiPriority.outageThreshold
        let left = max(0, joinAt.timeIntervalSince(now))
        let current = snapshot.ssid ?? snapshot.helperStatus?.network?.ssid ?? "this network"
        let held: Bool = switch system { case .paused, .failed: true; default: false }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wifi").font(.system(size: 13, weight: .semibold)).foregroundStyle(Dense.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(left > 0 ? "Joining \(next) in \(NetToysDuration.text(left.rounded(.up)))" : "Joining \(next)…")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Dense.label).monospacedDigit()
                    Text("Next network in your Wi-Fi Priority list").font(.system(size: 11)).foregroundStyle(Dense.secondary)
                }
            }
            Capsule().fill(Dense.track).frame(height: 4).overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Dense.accent)
                        .frame(width: proxy.size.width * (threshold > 0 ? min(max(1 - left / threshold, 0), 1) : 1))
                }
            }
            HStack(spacing: 8) {
                Button("Join Now") { try? NetToysFailoverRequest.joinNow.send() }
                    .buttonStyle(DenseCapsuleButtonStyle(prominent: true))
                Button("Stay on \(current)") { try? NetToysFailoverRequest.stay.send() }
                    .buttonStyle(DenseCapsuleButtonStyle())
            }
            .disabled(held)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Panel.card))
        .padding(.horizontal, 10)
    }

    // MARK: Cards

    private var latencyCard: some View {
        let values = snapshot.latencySamples.compactMap { $0 }
        let lost = snapshot.latencySamples.filter { $0 == nil }.count
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let loss = snapshot.latencySamples.isEmpty ? 0 : Double(lost) / Double(snapshot.latencySamples.count) * 100
        return VStack(spacing: 0) {
            NetToysLatencyChart(values: snapshot.latencySamples.map { $0 ?? 0 })
                .frame(height: 42).padding(.top, 8)
            HStack {
                Text("Latency, gateway").foregroundStyle(Dense.secondary)
                Spacer()
                Text(average.map { "Avg \(Int($0.rounded())) ms · Loss \(loss.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "No samples yet")
                    .foregroundStyle(Dense.secondary).monospacedDigit()
            }
            .font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 7)
        }
        .background(Panel.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
    }

    private var statusCard: some View {
        let internet = snapshot.helperStatus?.network?.internet
        let monitored = snapshot.configuration.monitoredAnchors
        let statuses = snapshot.helperStatus?.anchors ?? []
        let failing = monitored.filter { anchor in
            statuses.first { $0.anchorID == anchor.id }.map { [.fallbackUnavailable, .notFound, .ambiguous].contains($0.state) } ?? false
        }.count
        return VStack(spacing: 0) {
            statusRow("Internet", internet == .reachable ? "Working" : internet == .unreachable ? "Down" : "Unknown",
                      tone: internet == .unreachable ? Panel.red : nil)
            statusRow("DNS", dnsText, tone: dnsFailed ? Panel.red : nil)
            statusRow("Outages today", snapshot.outagesToday == 0 ? "None"
                      : "\(snapshot.outagesToday), for \(NetToysDuration.text(snapshot.outageSecondsToday))")
            statusRow("SSH Anchor", monitored.isEmpty ? "Off" : "\(monitored.count - failing) of \(monitored.count) hosts",
                      tone: failing > 0 ? Dense.amber : nil)
            statusRow("Devices", snapshot.deviceCount.map { "\($0), \(snapshot.offlineDeviceCount) offline" } ?? "No scan yet",
                      last: true)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Panel.card))
        .padding(.horizontal, 10)
    }

    /// A check older than 5 min is stale: the runtime stopped.
    private var dns: NetToysDNSCheck? {
        snapshot.helperStatus?.dns.flatMap { now.timeIntervalSince($0.checkedAt) < 300 ? $0 : nil }
    }
    private var dnsFailed: Bool { dns != nil && dns?.milliseconds == nil }
    private var dnsText: String {
        guard let dns else { return "Not checked" }
        return dns.milliseconds.map { "\(max(1, Int($0.rounded()))) ms" } ?? "Not answering"
    }

    private func statusRow(_ label: String, _ value: String, tone: Color? = nil, last: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Dense.label)
            Spacer(minLength: 8)
            if let tone { Circle().fill(tone).frame(width: 6, height: 6) }
            Text(value).foregroundStyle(tone ?? Dense.secondary).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(height: 28)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Panel.separator).frame(height: 0.5).padding(.horizontal, 10) }
        }
    }

    private var separator: some View {
        Rectangle().fill(Panel.separator).frame(height: 0.5).padding(.horizontal, Panel.edge).padding(.vertical, 6)
    }

    // MARK: Action rows

    @ViewBuilder private var speedRow: some View {
        if case .running(let started) = speedTest.phase {
            TimelineView(.periodic(from: started, by: 0.25)) { context in
                let fraction = min(context.date.timeIntervalSince(started) / NetToysSpeedTest.maximumSeconds, 0.97)
                NetToysWellRow(symbol: "gauge.with.dots.needle.67percent", title: "Testing speed…",
                               detail: speedTest.liveMbps.map { "Download \(Int($0.rounded())) Mbps" } ?? "Measuring download",
                               value: "Stop", valueIsAction: true, ring: fraction) {
                    speedTest.stop()
                }
            }
        } else {
            let failed: Bool = if case .failed = speedTest.phase { true } else { false }
            NetToysWellRow(symbol: "gauge.with.dots.needle.67percent", title: "Run Speed Test",
                           detail: failed ? "The last test did not finish" : nil,
                           value: speedTest.lastMbps.map { "Last \(Int($0.rounded())) Mbps" }) {
                speedTest.start()
            }
        }
    }

    private var copyRow: some View {
        let address = snapshot.localNetwork?.address.description
        return NetToysWellRow(symbol: copied ? "checkmark" : "doc.on.doc",
                              title: copied ? "Copied" : "Copy IP Address",
                              value: address ?? "None", tone: copied ? Dense.green : nil) {
            guard let address else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .disabled(address == nil)
    }

    private var systemRow: some View {
        let (symbol, tone, title, action): (String, Color, String, String) = switch system {
        case .running: ("checkmark", Dense.green, "System Up", "Pause")
        case .warning(let count): ("exclamationmark", Dense.amber, "System Up, \(count) \(count == 1 ? "Warning" : "Warnings")", "Details")
        case .paused: ("pause.fill", Dense.secondary, "System Paused", "Resume")
        case .failed: ("xmark", Panel.red, "System Failed", "Details")
        }
        return NetToysWellRow(symbol: symbol, title: title, value: action, valueIsAction: true, softTone: tone) {
            switch system {
            case .running, .paused: toggleSystem()
            case .warning, .failed: openPage(.history)
            }
        }
    }
}

/// Reports whether the hosting window is on screen, so the panel loads and animates only while open.
private struct NetToysKeyWindowReader: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(changed: changed) }
    func updateNSView(_ view: ReaderView, context: Context) { view.changed = changed }

    final class ReaderView: NSView {
        var changed: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) == true
            DispatchQueue.main.async { [changed] in changed(visible) }
        }
    }
}

// MARK: - Rows

/// Wi-Fi menu style row: a 26 pt round icon well, a label, and a value or a blue action.
private struct NetToysWellRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var value: String?
    var valueIsAction = false
    /// A solid well, such as the green copied check.
    var tone: Color?
    /// A soft tinted well whose glyph carries the state.
    var softTone: Color?
    var ring: Double?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                well
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Dense.label)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Dense.secondary).monospacedDigit() }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(.system(size: 13)).foregroundStyle(valueIsAction ? Dense.accent : Dense.secondary)
                        .monospacedDigit().lineLimit(1)
                }
            }
            .padding(.horizontal, 14).frame(height: detail == nil ? 34 : 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Panel.hover).opacity(hovered && isEnabled ? 1 : 0))
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Dense.fast, value: hovered)
    }

    private var well: some View {
        ZStack {
            if let ring {
                Circle().fill(Panel.well)
                Circle().stroke(Dense.track, lineWidth: 2.5).padding(1.25)
                Circle().trim(from: 0, to: ring).stroke(Dense.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(1.25)
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.accent)
            } else if let softTone {
                Circle().fill(softTone.opacity(0.18))
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(softTone)
            } else {
                Circle().fill(tone ?? Panel.well)
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tone == nil ? Dense.label : .white)
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// NSMenu style item: 24 pt high, a blue highlight inset 6 pt with an 8 pt radius.
private struct NetToysMenuItem: View {
    let title: String
    let key: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(hovered ? Color.white : Dense.label)
                Spacer(minLength: 8)
                Text(key).foregroundStyle(hovered ? Color.white.opacity(0.8) : Dense.tertiary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Dense.accent).opacity(hovered ? 1 : 0))
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Latency, edge to edge, with a soft fill. The panel draws the gateway; the device modal draws one device.
struct NetToysLatencyChart: View {
    let values: [Double]

    var body: some View {
        let top = max(20, (values.max() ?? 0) * 1.3)
        ZStack {
            LineShape(values: values, top: top, closed: true)
                .fill(LinearGradient(colors: [Dense.accent.opacity(0.28), Dense.accent.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            LineShape(values: values, top: top, closed: false)
                .stroke(Dense.accent, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
    }

    private struct LineShape: Shape {
        let values: [Double]
        let top: Double
        let closed: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard values.count > 1 else { return path }
            let step = rect.width / CGFloat(values.count - 1)
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: rect.minX + CGFloat(index) * step,
                                    y: rect.maxY - CGFloat(min(value / top, 1)) * rect.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            if closed {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
            return path
        }
    }
}
