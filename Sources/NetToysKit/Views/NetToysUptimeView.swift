import NetToysCore
import OnePlusUI
import SwiftUI

/// Uptime Monitor: counts on top, one row per check with its status and a sparkline. Checks are added,
/// edited, and deleted in a sheet.
struct NetToysUptimeView: View {
    let tool: NetToysTool
    private let live: Bool
    @State private var checks: [NetToysUptimeCheck]
    @State private var samples: [String: [NetToysUptimeSample]]
    @State private var statuses: [UUID: NetToysUptimeStatus]
    @State private var editing: NetToysUptimeCheck?
    @State private var saveError: String?

    /// Offscreen renders pass synthetic checks, samples, and statuses; nothing then reads disk or runs probes.
    init(tool: NetToysTool, checks: [NetToysUptimeCheck]? = nil, samples: [String: [NetToysUptimeSample]] = [:],
         statuses: [UUID: NetToysUptimeStatus] = [:]) {
        self.tool = tool
        live = checks == nil
        _checks = State(initialValue: checks ?? [])
        _samples = State(initialValue: samples)
        _statuses = State(initialValue: statuses)
    }

    var body: some View {
        // Checks run on their own schedule; the page has no input and no Run, only Add Check.
        NetToysToolPage(tool: tool, input: .constant(""), subtitle: subtitle, run: {}, showsRun: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    NetToysSummaryCard(title: "Checks", value: "\(checks.count)")
                    NetToysSummaryCard(title: "Up", value: "\(count(.up))", tone: count(.up) > 0 ? Dense.green : Dense.label)
                    NetToysSummaryCard(title: "Down", value: "\(count(.down))", tone: count(.down) > 0 ? UtilityTone.red : Dense.label)
                    NetToysSummaryCard(title: "Slow or expiring", value: "\(count(.slow))", tone: count(.slow) > 0 ? Dense.amber : Dense.label)
                }
                HStack {
                    Text("Checks run on their own schedule while the app runs. Double-click a check to change it.")
                        .font(.system(size: 12)).foregroundStyle(Dense.secondary)
                    Spacer()
                    Button { editing = NetToysUptimeCheck(name: "", kind: .http(url: "https://", expectedStatus: nil)) } label: {
                        Label("Add Check", systemImage: "plus")
                    }
                    .buttonStyle(DenseCapsuleButtonStyle())
                }
                if let saveError { UtilityNote(symbol: "exclamationmark.triangle.fill", text: saveError, tone: Dense.amber) }
            }
        } results: {
            UtilityTable(columns: columns, rows: checks, empty: "No checks yet. Click Add Check.",
                         open: { editing = $0 }) { check in
                let state = state(of: check)
                UtilityStatus(text: state.text, tone: state.tone).cell(columns[0])
                Text(check.name).fontWeight(.medium).cell(columns[1])
                MonoText(target(check)).lineLimit(1).truncationMode(.middle).cell(columns[2])
                Text(kindName(check)).foregroundStyle(Dense.secondary).cell(columns[3])
                Text(UtilityFormat.ms(statuses[check.id]?.last?.milliseconds ?? samples[check.id.uuidString]?.last?.milliseconds))
                    .cell(columns[4])
                Text(uptime(check)).foregroundStyle(Dense.secondary).cell(columns[5])
                Text(certificate(check)).foregroundStyle(Dense.secondary).cell(columns[6])
                UtilitySpark(values: (samples[check.id.uuidString] ?? []).suffix(40).map(\.milliseconds),
                             tone: state.tone == Dense.amber ? Dense.amber : Dense.accent)
                    .frame(height: 16).cell(columns[7])
            } menu: { check in
                Button("Check Now") { checkNow(check) }
                Button("Edit…") { editing = check }
                Button(check.isEnabled ? "Pause" : "Resume") {
                    var changed = check
                    changed.isEnabled.toggle()
                    upsert(changed)
                }
                Divider()
                Button("Delete", role: .destructive) { delete(check) }
            }
        }
        .sheet(item: $editing) { check in
            NetToysUptimeEditor(check: check, isNew: !checks.contains { $0.id == check.id },
                                save: { upsert($0); editing = nil; checkNow($0) },
                                delete: { delete($0); editing = nil },
                                cancel: { editing = nil })
        }
        .task { await follow() }
    }

    private let columns = [
        UtilityColumn(title: "Status", width: 84), UtilityColumn(title: "Name", width: 150), UtilityColumn(title: "Target", width: 200),
        UtilityColumn(title: "Type", width: 44), UtilityColumn(title: "Last ms", width: 56, trailing: true),
        UtilityColumn(title: "Up, 24 hours", width: 84, trailing: true), UtilityColumn(title: "Certificate", width: 90, trailing: true),
        UtilityColumn(title: "Last 40 checks"),
    ]

    private var subtitle: String {
        let down = count(.down)
        if checks.isEmpty { return tool.line }
        return down == 0 ? "\(checks.count) checks, all up" : "\(checks.count) checks, \(down) down"
    }

    // MARK: State per check

    private enum Health { case up, down, slow, waiting, paused }

    private func health(_ check: NetToysUptimeCheck) -> Health {
        guard check.isEnabled else { return .paused }
        guard let status = statuses[check.id] else {
            guard let last = samples[check.id.uuidString]?.last else { return .waiting }
            return last.isUp ? .up : .down
        }
        if status.isDown { return .down }
        if status.isSlow || expiresSoon(check, status) { return .slow }
        return status.last == nil ? .waiting : .up
    }

    private func expiresSoon(_ check: NetToysUptimeCheck, _ status: NetToysUptimeStatus) -> Bool {
        guard let expiry = status.certificateExpiry, let days = check.sslWarningDays else { return false }
        return expiry.timeIntervalSinceNow < Double(days) * 86_400
    }

    private func count(_ health: Health) -> Int { checks.filter { self.health($0) == health }.count }

    private func state(of check: NetToysUptimeCheck) -> (text: String, tone: Color) {
        switch health(check) {
        case .up: ("Up", Dense.green)
        case .down: ("Down", UtilityTone.red)
        case .slow: (statuses[check.id]?.isSlow == true ? "Slow" : "Expiring", Dense.amber)
        case .waiting: ("Waiting", Dense.tertiary)
        case .paused: ("Paused", Dense.tertiary)
        }
    }

    private func target(_ check: NetToysUptimeCheck) -> String {
        switch check.kind {
        case .ping(let host): host
        case .tcp(let host, let port): "\(host):\(port)"
        case .http(let url, _): url
        }
    }

    private func kindName(_ check: NetToysUptimeCheck) -> String {
        switch check.kind {
        case .ping: "Ping"
        case .tcp: "TCP"
        case .http: "HTTP"
        }
    }

    private func uptime(_ check: NetToysUptimeCheck) -> String {
        let day = (samples[check.id.uuidString] ?? []).filter { $0.date.timeIntervalSinceNow > -86_400 }
        guard !day.isEmpty else { return "None" }
        let percent = Double(day.filter(\.isUp).count) / Double(day.count) * 100
        return percent == 100 ? "100%" : String(format: "%.1f%%", percent)
    }

    private func certificate(_ check: NetToysUptimeCheck) -> String {
        guard let expiry = statuses[check.id]?.certificateExpiry else { return "" }
        let days = Int((expiry.timeIntervalSinceNow / 86_400).rounded(.down))
        return days < 0 ? "Expired" : "\(days) days"
    }

    // MARK: Actions

    /// Default check name: the host of a URL or host:port.
    static func name(for text: String) -> String {
        URL(string: text)?.host ?? text.split(separator: ":").first.map(String.init) ?? text
    }

    private func checkNow(_ check: NetToysUptimeCheck) {
        guard live, check.isEnabled else { return }
        Task { await NetToysUptimeMonitor.shared.checkNow(check) }
    }

    private func upsert(_ check: NetToysUptimeCheck) {
        if let index = checks.firstIndex(where: { $0.id == check.id }) { checks[index] = check } else { checks.append(check) }
        persist()
    }

    private func delete(_ check: NetToysUptimeCheck) {
        checks.removeAll { $0.id == check.id }
        samples[check.id.uuidString] = nil
        statuses[check.id] = nil
        persist()
    }

    private func persist() {
        guard live else { return }
        do {
            try NetToysUptimeChecks.save(checks)
            saveError = nil
        } catch {
            saveError = "The checks were not saved: \(error.localizedDescription)"
        }
    }

    /// Loads the saved checks and 30 days of results, then follows the monitor's live results.
    private func follow() async {
        guard live else { return }
        let (saved, results) = await Task.detached(priority: .utility) {
            (NetToysUptimeChecks.load(), NetToysUptimeResults.load())
        }.value
        checks = saved
        samples = results
        statuses = await NetToysUptimeMonitor.shared.statuses(for: saved.map(\.id))
        for await update in await NetToysUptimeMonitor.shared.updates() {
            samples[update.checkID.uuidString, default: []].append(update.sample)
            statuses[update.checkID] = update.status
        }
    }
}

// MARK: - Editor sheet

struct NetToysUptimeEditor: View {
    enum Kind: String, CaseIterable { case ping = "Ping", tcp = "TCP Port", http = "HTTP(S)" }

    let original: NetToysUptimeCheck
    let isNew: Bool
    let save: (NetToysUptimeCheck) -> Void
    let delete: (NetToysUptimeCheck) -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var kind: Kind
    @State private var host: String
    @State private var port: String
    @State private var url: String
    @State private var expectedStatus: String
    @State private var sslDays: String
    @State private var interval: TimeInterval
    @State private var threshold: String
    @State private var failures: Int
    @State private var enabled: Bool

    init(check: NetToysUptimeCheck, isNew: Bool, save: @escaping (NetToysUptimeCheck) -> Void,
         delete: @escaping (NetToysUptimeCheck) -> Void, cancel: @escaping () -> Void) {
        original = check
        self.isNew = isNew
        self.save = save
        self.delete = delete
        self.cancel = cancel
        _name = State(initialValue: check.name)
        var kind = Kind.http, host = "", port = "443", url = "https://", expected = ""
        switch check.kind {
        case .ping(let value): kind = .ping; host = value
        case .tcp(let value, let number): kind = .tcp; host = value; port = String(number)
        case .http(let value, let status): url = value; expected = status.map(String.init) ?? ""
        }
        _kind = State(initialValue: kind)
        _host = State(initialValue: host)
        _port = State(initialValue: port)
        _url = State(initialValue: url)
        _expectedStatus = State(initialValue: expected)
        _sslDays = State(initialValue: check.sslWarningDays.map(String.init) ?? "")
        _interval = State(initialValue: check.intervalSeconds)
        _threshold = State(initialValue: check.latencyThresholdMilliseconds.map { String(Int($0)) } ?? "")
        _failures = State(initialValue: check.downAfterFailures)
        _enabled = State(initialValue: check.isEnabled)
    }

    private var builtKind: NetToysUptimeCheck.Kind? {
        let host = host.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .ping: return host.isEmpty ? nil : .ping(host: host)
        case .tcp: return host.isEmpty ? nil : UInt16(port).map { .tcp(host: host, port: $0) }
        case .http:
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased()), parsed.host != nil else { return nil }
            return .http(url: url, expectedStatus: Int(expectedStatus))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Check" : "Edit Check").font(.system(size: 15, weight: .semibold))
            DenseSection(title: "Target") {
                field("Name", text: $name, prompt: "Shown in alerts")
                HStack {
                    Text("Type").font(.system(size: 13))
                    Spacer()
                    OnePlusLinearSegmented(choices: Kind.allCases.map { ($0, $0.rawValue) }, selection: $kind,
                                           accessibilityLabel: "Type", sizing: .snug)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .overlay(alignment: .bottom) { DenseHairline().padding(.horizontal, 10) }
                switch kind {
                case .ping: field("Host", text: $host, prompt: "nas-01.lan or 192.168.50.4", last: true)
                case .tcp:
                    field("Host", text: $host, prompt: "nas-01.lan or 192.168.50.4")
                    field("Port", text: $port, prompt: "443", last: true)
                case .http:
                    field("URL", text: $url, prompt: "https://example.com/health")
                    field("Expected status", text: $expectedStatus, prompt: "Any 2xx or 3xx")
                    field("Warn before certificate expiry", text: $sslDays, prompt: "Days", last: true)
                }
            }
            .animation(Dense.spring, value: kind)
            DenseSection(title: "Schedule and alerts") {
                HStack {
                    Text("Check every").font(.system(size: 13))
                    Spacer()
                    OnePlusLinearSelect(choices: [(TimeInterval(30), "30 sec"), (60, "1 min"), (300, "5 min"),
                                                  (900, "15 min"), (3_600, "1 hour")],
                                        selection: $interval, accessibilityLabel: "Check every", width: 96)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .overlay(alignment: .bottom) { DenseHairline().padding(.horizontal, 10) }
                field("Alert when slower than", text: $threshold, prompt: "Milliseconds, empty for no alert")
                HStack {
                    Text("Down after").font(.system(size: 13))
                    Spacer()
                    OnePlusLinearStepper("Down after", canDecrement: failures > 1, canIncrement: failures < 10,
                                         decrement: { failures -= 1 }, increment: { failures += 1 }) {
                        Text("\(failures) failed \(failures == 1 ? "check" : "checks") in a row").font(.system(size: 13))
                            .foregroundStyle(Dense.secondary).monospacedDigit().fixedSize()
                    }
                    .fixedSize()
                    .accessibilityElement(children: .ignore).accessibilityLabel("Down after")
                    .accessibilityValue("\(failures) failed checks in a row")
                    .accessibilityAdjustableAction { $0 == .increment ? (failures = min(failures + 1, 10)) : (failures = max(failures - 1, 1)) }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .overlay(alignment: .bottom) { DenseHairline().padding(.horizontal, 10) }
                DenseSwitchRow(label: "Check on schedule", isOn: $enabled, last: true)
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { delete(original) }.buttonStyle(DenseCapsuleButtonStyle())
                }
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(DenseCapsuleButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Check" : "Save") {
                    guard let built = builtKind else { return }
                    var check = original
                    check.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? NetToysUptimeView.name(for: target) : name
                    check.kind = built
                    check.intervalSeconds = interval
                    check.latencyThresholdMilliseconds = Double(threshold)
                    check.downAfterFailures = failures
                    check.sslWarningDays = Int(sslDays)
                    check.isEnabled = enabled
                    save(check)
                }
                .buttonStyle(DenseCapsuleButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                .disabled(builtKind == nil)
            }
        }
        .padding(20).frame(width: 460)
        .background(Dense.modal)
    }

    private var target: String { kind == .http ? url : host }

    private func field(_ label: String, text: Binding<String>, prompt: String, last: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Dense.label).fixedSize()
            Spacer(minLength: 12)
            TextField(label, text: text, prompt: Text(prompt)).textFieldStyle(.plain).font(.system(size: 13))
                .multilineTextAlignment(.trailing).foregroundStyle(Dense.secondary)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .overlay(alignment: .bottom) { if !last { DenseHairline().padding(.horizontal, 10) } }
    }
}
