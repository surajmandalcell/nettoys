import NetToysCore
import SwiftUI

// MARK: Port Scan

struct NetToysPortScanView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var run: DiagnoseRun<[NetToysPortResult]>

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<[NetToysPortResult]> = .init([])) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
    }

    private let ports = NetToysPortScan.commonPorts
    private func count(_ state: NetToysPortState) -> Int { run.value.filter { $0.state == state }.count }
    private var started: Bool { run.running || !run.value.isEmpty }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: run.running, run: { run.toggle(scan) }) {
            if started {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        NetToysSummaryCard(title: "Open", value: "\(count(.open))", unit: "ports", tone: count(.open) > 0 ? Dense.green : Dense.label)
                        NetToysSummaryCard(title: "Closed", value: "\(count(.closed))", unit: "refused")
                        NetToysSummaryCard(title: "Filtered", value: "\(count(.filtered))", unit: "no answer")
                        NetToysSummaryCard(title: "Scanned", value: "\(run.value.count)", unit: "of \(ports.count) common ports")
                    }
                    ProgressView(value: Double(run.value.count), total: Double(ports.count))
                        .progressViewStyle(.linear).controlSize(.mini).tint(Dense.accent)
                        .opacity(run.running ? 1 : 0)
                }
            }
        } results: {
            DiagnoseResults(run: run, hasContent: started, idle: "Enter a host and press Run", busy: "") {
                // Open ports first, then by number.
                let sorted = run.value.sorted { ($0.state == .open ? 0 : 1, $0.port) < ($1.state == .open ? 0 : 1, $1.port) }
                DiagnoseTable(columns: [.init(title: "Port", width: 70, trailing: true), .init(title: "Service", width: 180),
                                        .init(title: "State", width: 90), .init(title: "Time", width: 80, trailing: true),
                                        .init(title: "")],
                              rows: sorted.map { result in
                                  DiagnoseRow(id: "\(result.port)", cells: [
                                      .init("\(result.port)", strong: result.state == .open), .init(result.service ?? "Unknown"),
                                      .init(Self.stateName(result.state), tone: Self.tone(result.state)),
                                      .init(result.state == .filtered ? "" : diagnoseMilliseconds(result.milliseconds), tone: Dense.secondary),
                                  ])
                              },
                              emptyLine: "Waiting for the first port to answer.")
            }
        }
        .onDisappear { run.stop() }
    }

    static func stateName(_ state: NetToysPortState) -> String {
        switch state {
        case .open: "Open"
        case .closed: "Closed"
        case .filtered: "Filtered"
        }
    }

    static func tone(_ state: NetToysPortState) -> Color {
        switch state {
        case .open: Dense.green
        case .closed: Dense.secondary
        case .filtered: Dense.tertiary
        }
    }

    private var subtitle: String? {
        guard started else { return nil }
        return run.running ? "Scanning \(run.value.count) of \(ports.count) ports" : "\(count(.open)) open of \(ports.count) common ports"
    }

    private func scan(_ run: DiagnoseRun<[NetToysPortResult]>) async throws {
        for try await result in NetToysPortScan.scan(host: try diagnoseInput(input, "a host"), ports: ports) {
            run.value.append(result)
        }
    }
}

// MARK: SSL Certificate

struct NetToysSSLView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var run: DiagnoseRun<NetToysSSLResult?>

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<NetToysSSLResult?> = .init(nil)) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: run.value.map { "\($0.host):\($0.port) · \($0.tlsVersion)" },
                        running: run.running, run: { run.toggle(check) }) {
            if let result = run.value { summary(result) }
        } results: {
            DiagnoseResults(run: run, hasContent: run.value != nil, idle: "Enter a domain and press Run",
                            busy: "Opening a TLS connection") {
                if let result = run.value {
                    DiagnoseTable(columns: [.init(title: "Role", width: 90), .init(title: "Subject", width: 200),
                                            .init(title: "Issuer", width: 200), .init(title: "Expires", width: 90),
                                            .init(title: "Days", width: 50, trailing: true), .init(title: "Key", width: 70),
                                            .init(title: "SHA-256")],
                                  rows: result.chain.enumerated().map { index, cert in
                                      DiagnoseRow(id: cert.sha256, cells: [
                                          .init(index == 0 ? "Leaf" : index == result.chain.count - 1 ? "Root" : "Intermediate",
                                                tone: Dense.secondary),
                                          .init(cert.subject, strong: index == 0), .init(cert.issuer),
                                          .init(cert.notAfter?.formatted(.iso8601.year().month().day()) ?? ""),
                                          .init(cert.daysToExpiry.map(String.init) ?? "", tone: Self.tone(cert.daysToExpiry)),
                                          .init(cert.key ?? "", tone: Dense.secondary), .init(cert.sha256, tone: Dense.secondary, mono: true),
                                      ])
                                  })
                }
            }
        }
        .onDisappear { run.stop() }
    }

    private func summary(_ result: NetToysSSLResult) -> some View {
        let leaf = result.chain.first
        let days = leaf?.daysToExpiry ?? 0
        let span = leaf.flatMap { cert in cert.notBefore.flatMap { start in cert.notAfter.map { $0.timeIntervalSince(start) / 86_400 } } } ?? 90
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DiagnoseCard(stretch: true) {
                    HStack(spacing: 14) {
                        DiagnoseRing(fraction: Double(days) / max(span, 1), value: "\(days)", unit: days == 1 ? "day" : "days",
                                     tone: Self.tone(days))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Days to expiry").font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
                            Text(days < 0 ? "Expired" : "Expires \(leaf?.notAfter?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Dense.label)
                            Text("Valid for \(Int(span)) days in all").font(.system(size: 12)).foregroundStyle(Dense.secondary)
                        }
                    }
                }
                DiagnoseCard(stretch: true) {
                    HStack(spacing: 12) {
                        Image(systemName: result.trusted ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .font(.system(size: 30)).foregroundStyle(result.trusted ? Dense.green : diagnoseRed)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Trust").font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
                            Text(result.trusted ? "macOS trusts this certificate" : "macOS does not trust this certificate")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Dense.label)
                            Text(result.trustError ?? "Chain of \(result.chain.count) ends at a trusted root")
                                .font(.system(size: 12)).foregroundStyle(Dense.secondary).lineLimit(2)
                        }
                    }
                    .frame(minHeight: 76)
                }
                DiagnoseCard(stretch: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        smallFact("Protocol", result.tlsVersion)
                        smallFact("Handshake", diagnoseMilliseconds(result.milliseconds))
                    }
                }
                .frame(maxWidth: 200)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let names = leaf?.subjectAlternativeNames, !names.isEmpty {
                Text("Names: \(names.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(Dense.secondary)
                    .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            }
        }
    }

    private func smallFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(Dense.label).monospacedDigit()
        }
    }

    static func tone(_ days: Int?) -> Color {
        guard let days else { return Dense.secondary }
        return days < 0 ? diagnoseRed : days < 21 ? Dense.amber : Dense.green
    }

    private func check(_ run: DiagnoseRun<NetToysSSLResult?>) async throws {
        let text = try diagnoseInput(input, "a domain")
        // "example.com:8443" checks port 8443.
        let parts = text.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) {
            run.value = try await NetToysSSLCheck.check(host: String(parts[0]), port: port)
        } else {
            run.value = try await NetToysSSLCheck.check(host: text)
        }
    }
}

// MARK: HTTP Check

struct NetToysHTTPCheckView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var run: DiagnoseRun<NetToysHTTPResult?>

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<NetToysHTTPResult?> = .init(nil)) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: run.value.map { $0.url }, running: run.running,
                        run: { run.toggle(check) }) {
            if let result = run.value { summary(result) }
        } results: {
            DiagnoseResults(run: run, hasContent: run.value != nil, idle: "Enter a URL and press Run", busy: "Waiting for the server") {
                if let result = run.value {
                    DiagnoseTable(columns: [.init(title: "Header", width: 240), .init(title: "Value")],
                                  rows: result.headers.map {
                                      DiagnoseRow(id: $0.name, cells: [.init($0.name, strong: true), .init($0.value, tone: Dense.secondary)])
                                  },
                                  emptyLine: "The server sent no headers.")
                }
            }
        }
        .onDisappear { run.stop() }
    }

    private func summary(_ result: NetToysHTTPResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                NetToysSummaryCard(title: "Status", value: "\(result.status)", unit: Self.reason(result.status),
                                   tone: result.status < 300 ? Dense.green : result.status < 400 ? Dense.amber : diagnoseRed)
                NetToysSummaryCard(title: "Total", value: String(format: "%.0f", result.timing.total), unit: "ms")
                NetToysSummaryCard(title: "Protocol", value: result.httpVersion ?? "Unknown")
                NetToysSummaryCard(title: "Body", value: result.bodyBytes.formatted(.byteCount(style: .file)))
            }
            DiagnoseCard { HTTPWaterfall(timing: result.timing) }
            if !result.redirects.isEmpty {
                Text(result.redirects.map { "\($0.status) \($0.url)" }.joined(separator: "  →  ") + "  →  \(result.status) \(result.url)")
                    .font(.system(size: 12)).foregroundStyle(Dense.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    static func reason(_ status: Int) -> String {
        status == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: status).capitalized(with: nil)
    }

    private func check(_ run: DiagnoseRun<NetToysHTTPResult?>) async throws {
        run.value = try await NetToysHTTPCheck.check(try diagnoseInput(input, "a URL"))
    }
}

/// One bar split into the phases of the last request, with a legend of times below.
private struct HTTPWaterfall: View {
    let timing: NetToysHTTPTiming

    private var phases: [(String, Double, Color)] {
        let known: [(String, Double?, Color)] = [
            ("DNS", timing.dns, Color(nsColor: .systemTeal)), ("Connect", timing.connect, Dense.green),
            ("TLS", timing.tls, Color(nsColor: .systemPurple)), ("Wait", timing.firstByte, Dense.accent),
        ]
        let measured = known.compactMap { phase in phase.1.map { (phase.0, max(0, $0), phase.2) } }
        // Download and any redirects: whatever the total holds beyond the measured phases.
        let rest = max(0, timing.total - measured.reduce(0) { $0 + $1.1 })
        return measured + [("Download", rest, Dense.amber)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timing").font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
            GeometryReader { geometry in
                let total = max(phases.reduce(0) { $0 + $1.1 }, 0.001)
                HStack(spacing: 2) {
                    ForEach(phases, id: \.0) { phase in
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(phase.2)
                            .frame(width: max(2, (geometry.size.width - 8) * phase.1 / total))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 18) {
                ForEach(phases, id: \.0) { phase in
                    HStack(spacing: 5) {
                        Circle().fill(phase.2).frame(width: 7, height: 7)
                        Text(phase.0).font(.system(size: 12)).foregroundStyle(Dense.secondary)
                        Text(diagnoseMilliseconds(phase.1)).font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.label)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}
