import NetToysCore
import SwiftUI

let diagnoseRed = Color(nsColor: .systemRed)

/// Record type picker shared by DNS Lookup and DNS Propagation.
private struct DNSTypePicker: View {
    @Binding var type: NetToysDNSRecordType
    var types: [NetToysDNSRecordType] = [.a, .aaaa, .mx, .txt, .ns, .cname, .soa, .ptr]

    var body: some View {
        Picker("Record type", selection: $type) {
            ForEach(types) { Text($0.name).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
    }
}

// MARK: DNS Lookup

struct NetToysDNSLookupView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var type = NetToysDNSRecordType.a
    @State private var run: DiagnoseRun<NetToysDNSAnswer?>

    /// `run` seeds the state once; renders pass a finished run.
    init(tool: NetToysTool, input: Binding<String>, type: NetToysDNSRecordType = .a,
         run: DiagnoseRun<NetToysDNSAnswer?> = .init(nil)) {
        self.tool = tool
        _input = input
        _type = State(initialValue: type)
        _run = State(initialValue: run)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: run.running, run: { run.toggle(lookup) }) {
            VStack(alignment: .leading, spacing: 12) {
                DNSTypePicker(type: $type)
                if let answer = run.value {
                    HStack(spacing: 10) {
                        NetToysSummaryCard(title: "Status", value: answer.status,
                                           tone: answer.status == "NOERROR" ? Dense.green : Dense.amber)
                        NetToysSummaryCard(title: "Records", value: "\(answer.records.count)")
                        NetToysSummaryCard(title: "Time", value: String(format: "%.1f", answer.milliseconds), unit: "ms")
                        NetToysSummaryCard(title: "Resolver", value: answer.resolver)
                    }
                }
            }
        } results: {
            DiagnoseResults(run: run, hasContent: run.value != nil, idle: "Enter a domain and press Run",
                            busy: "Asking the resolver") {
                if let answer = run.value {
                    let rows = answer.records.map { ($0, "Answer") } + answer.authority.map { ($0, "Authority") }
                    DiagnoseTable(columns: [.init(title: "Name", width: 220), .init(title: "Type", width: 60),
                                            .init(title: "TTL", width: 70, trailing: true), .init(title: "Section", width: 80),
                                            .init(title: "Value")],
                                  rows: rows.enumerated().map { index, item in
                                      DiagnoseRow(id: "\(index)", cells: [
                                          .init(item.0.name, strong: true), .init(item.0.typeName),
                                          .init("\(item.0.ttl)", tone: Dense.secondary),
                                          .init(item.1, tone: Dense.secondary), .init(item.0.value, mono: true),
                                      ])
                                  },
                                  emptyLine: "No \(type.name) records for this name.")
                }
            }
        }
        .onChange(of: type) { if run.ran { run.start(lookup) } }
        .onDisappear { run.stop() }
    }

    private var subtitle: String? {
        guard let answer = run.value else { return nil }
        return "\(answer.records.count) \(type.name) records · \(diagnoseMilliseconds(answer.milliseconds))"
            + (answer.truncated ? " · reply was cut short" : "")
    }

    private func lookup(_ run: DiagnoseRun<NetToysDNSAnswer?>) async throws {
        run.value = try await NetToysDNSLookup.lookup(try diagnoseInput(input, "a domain"), type: type)
    }
}

// MARK: DNS Propagation

struct NetToysDNSPropagationView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var type = NetToysDNSRecordType.a
    @State private var run: DiagnoseRun<[NetToysPropagationResult]>

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<[NetToysPropagationResult]> = .init([])) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
    }

    private var resolvers: [NetToysPublicResolver] { NetToysDNSPropagation.resolvers }
    private var answered: [NetToysPropagationResult] { run.value.filter { $0.error == nil } }
    /// The answer most resolvers give; a resolver agrees when its sorted values equal it.
    private var majority: [String]? {
        Dictionary(grouping: answered, by: \.values).max { $0.value.count < $1.value.count }?.key
    }

    private func agrees(_ result: NetToysPropagationResult) -> Bool { result.error == nil && result.values == majority }
    /// All 16 rows show from the first moment of a run, so answers fill in place.
    private var started: Bool { run.running || !run.value.isEmpty }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: run.running, run: { run.toggle(check) }) {
            VStack(alignment: .leading, spacing: 12) {
                DNSTypePicker(type: $type, types: [.a, .aaaa, .mx, .txt, .ns, .cname, .soa])
                if started { summary }
            }
        } results: {
            DiagnoseResults(run: run, hasContent: started, idle: "Enter a domain and press Run", busy: "") {
                DiagnoseTable(columns: [.init(title: "Resolver", width: 170), .init(title: "Country", width: 130),
                                        .init(title: "Address", width: 120), .init(title: "Time", width: 64, trailing: true),
                                        .init(title: "Result", width: 70), .init(title: "Answer")],
                              rows: resolvers.map(row))
            }
        }
        .onChange(of: type) { if run.ran { run.start(check) } }
        .onDisappear { run.stop() }
    }

    private var summary: some View {
        let agreeing = run.value.filter(agrees).count
        let countries = resolvers.reduce(into: [String]()) { if !$0.contains($1.country) { $0.append($1.country) } }
        return HStack(alignment: .top, spacing: 10) {
            DiagnoseCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resolvers that agree").font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(agreeing)/\(resolvers.count)").font(.system(size: 28, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(agreeing == resolvers.count ? Dense.green : Dense.label)
                            .contentTransition(.numericText())
                        Text(verdict(agreeing)).font(.system(size: 12)).foregroundStyle(Dense.secondary)
                    }
                    ProgressView(value: Double(run.value.count), total: Double(resolvers.count))
                        .progressViewStyle(.linear).controlSize(.small).tint(Dense.accent)
                    Text(majority.map { $0.isEmpty ? "Most resolvers return no records" : "Most say \($0.joined(separator: ", "))" } ?? " ")
                        .font(.system(size: 12)).foregroundStyle(Dense.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(width: 300)
            DiagnoseCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("By country").font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading), count: 3),
                              alignment: .leading, spacing: 5) {
                        ForEach(countries, id: \.self) { country in countryRow(country) }
                    }
                }
            }
        }
        .animation(Dense.spring, value: run.value.count)
    }

    private func countryRow(_ country: String) -> some View {
        let total = resolvers.filter { $0.country == country }.count
        let results = run.value.filter { $0.resolver.country == country }
        let agree = results.filter(agrees).count
        let done = results.count == total
        return HStack(spacing: 6) {
            Text(diagnoseCountry(country)).font(.system(size: 12)).foregroundStyle(Dense.label).lineLimit(1)
            Spacer(minLength: 4)
            Text(done ? "\(agree) of \(total)" : "waiting").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(!done ? Dense.tertiary : agree == total ? Dense.green : Dense.amber)
        }
    }

    private func verdict(_ agreeing: Int) -> String {
        if run.value.count < resolvers.count { return "\(run.value.count) of \(resolvers.count) answered" }
        return agreeing == resolvers.count ? "Every resolver gives the same answer" : "Some resolvers differ"
    }

    private func row(_ resolver: NetToysPublicResolver) -> DiagnoseRow {
        let country = DiagnoseCell(diagnoseCountry(resolver.country), tone: Dense.secondary)
        guard let result = run.value.first(where: { $0.resolver == resolver }) else {
            return DiagnoseRow(id: resolver.id, cells: [.init(resolver.name, strong: true), country,
                                                        .init(resolver.address, tone: Dense.secondary, mono: true),
                                                        .init(""), .init(run.running ? "Waiting" : "No reply", tone: Dense.tertiary)])
        }
        let answer: String
        if let error = result.error { answer = error }
        else if result.values.isEmpty { answer = result.answer?.status ?? "" }
        else { answer = result.values.joined(separator: ", ") }
        let state: DiagnoseCell = result.error != nil ? .init("Failed", tone: diagnoseRed)
            : agrees(result) ? .init("Agrees", tone: Dense.green) : .init("Differs", tone: Dense.amber)
        return DiagnoseRow(id: resolver.id, cells: [
            .init(resolver.name, strong: true), country, .init(resolver.address, tone: Dense.secondary, mono: true),
            .init(result.answer.map { diagnoseMilliseconds($0.milliseconds) } ?? "", tone: Dense.secondary),
            state, .init(answer, tone: result.error == nil ? Dense.label : Dense.secondary, mono: result.error == nil),
        ])
    }

    private var subtitle: String? {
        guard started else { return nil }
        return "\(run.value.count) of \(resolvers.count) answered · \(run.value.filter(agrees).count) agree"
    }

    private func check(_ run: DiagnoseRun<[NetToysPropagationResult]>) async throws {
        for await result in NetToysDNSPropagation.check(try diagnoseInput(input, "a domain"), type: type) {
            run.value.append(result)
        }
    }
}

// MARK: Whois

struct NetToysWhoisView: View {
    let tool: NetToysTool
    @Binding var input: String
    @State private var run: DiagnoseRun<NetToysWhoisResult?>
    @State private var showRaw: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tool: NetToysTool, input: Binding<String>, run: DiagnoseRun<NetToysWhoisResult?> = .init(nil), showRaw: Bool = false) {
        self.tool = tool
        _input = input
        _run = State(initialValue: run)
        _showRaw = State(initialValue: showRaw)
    }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: run.value.map { "Answer from \($0.servers.last ?? "whois")" },
                        running: run.running, run: { run.toggle(lookup) }) {
            if let result = run.value {
                HStack(spacing: 10) {
                    NetToysSummaryCard(title: "Registrar", value: result.registrar ?? "Not listed")
                    NetToysSummaryCard(title: "Created", value: Self.day(result.created) ?? "Not listed")
                    NetToysSummaryCard(title: "Expires", value: Self.day(result.expires) ?? "Not listed",
                                       unit: Self.daysLeft(result.expires).map { "in \($0) days" } ?? "",
                                       tone: (Self.daysLeft(result.expires) ?? 999) < 30 ? Dense.amber : Dense.label)
                }
                .lineLimit(1)
            }
        } results: {
            DiagnoseResults(run: run, hasContent: run.value != nil, idle: "Enter a domain or IP address and press Run",
                            busy: "Asking whois.iana.org, then the registry") {
                if let result = run.value {
                    VStack(spacing: 0) {
                        DiagnoseFieldTable(fields: [("Query", result.query), ("Registrar", result.registrar ?? ""),
                                                    ("Created", result.created ?? ""), ("Expires", result.expires ?? "")]
                            + result.nameServers.enumerated().map { ("Name server \($0.offset + 1)", $0.element) }
                            + [("Servers asked", result.servers.joined(separator: " → "))])
                        raw(result.raw)
                    }
                }
            }
        }
        .onDisappear { run.stop() }
    }

    private func raw(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DenseHairline()
            Button {
                withAnimation(Dense.spring(reduceMotion)) { showRaw.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showRaw ? 90 : 0))
                    Text("Raw reply").font(.system(size: 12, weight: .semibold))
                    Text("\(text.split(separator: "\n").count) lines").font(.system(size: 11)).foregroundStyle(Dense.tertiary)
                    Spacer()
                }
                .foregroundStyle(Dense.secondary).frame(height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 28)
            if showRaw {
                ScrollView {
                    Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Dense.label)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Dense.group))
                .padding(.horizontal, 20).padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .clipped()
    }

    /// "2025-08-13T04:00:00Z" shows as "2025-08-13"; other formats stay as the registry wrote them.
    static func day(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.count >= 10 && text.dropFirst(4).first == "-" ? String(text.prefix(10)) : text
    }

    static func daysLeft(_ text: String?) -> Int? {
        guard let day = day(text), let date = try? Date(day, strategy: .iso8601.year().month().day()) else { return nil }
        return Calendar.current.dateComponents([.day], from: .now, to: date).day
    }

    private func lookup(_ run: DiagnoseRun<NetToysWhoisResult?>) async throws {
        run.value = try await NetToysWhois.lookup(try diagnoseInput(input, "a domain or IP address"))
    }
}
