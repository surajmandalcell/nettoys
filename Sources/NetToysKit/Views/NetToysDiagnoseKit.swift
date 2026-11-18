import AppKit
import NetToysCore
import SwiftUI

/// One run of a Diagnose engine: the latest value, whether it runs, and the error in plain words.
@MainActor @Observable
final class DiagnoseRun<Value> {
    var value: Value
    private(set) var running = false
    private(set) var error: String?
    private(set) var ran = false
    @ObservationIgnored private let empty: Value
    @ObservationIgnored private var task: Task<Void, Never>?

    init(_ empty: Value) {
        self.empty = empty
        value = empty
    }

    /// A finished or running state for offscreen renders.
    init(_ empty: Value, showing value: Value, running: Bool = false, error: String? = nil) {
        self.empty = empty
        self.value = value
        self.running = running
        self.error = error
        ran = true
    }

    /// Run when idle, stop when running: the toolbar Run button and Return both call this.
    func toggle(_ work: @escaping @MainActor (DiagnoseRun<Value>) async throws -> Void) {
        running ? stop() : start(work)
    }

    func start(_ work: @escaping @MainActor (DiagnoseRun<Value>) async throws -> Void) {
        task?.cancel()
        value = empty
        error = nil
        running = true
        ran = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { running = false }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }
}

extension NetToysShell {
    /// The toolbar field text of one tool, kept across tool switches.
    func diagnoseField(_ tool: NetToysTool) -> Binding<String> {
        Binding(get: { self.inputs[tool.id] ?? "" }, set: { self.inputs[tool.id] = $0 })
    }
}

/// The trimmed field text, or an error that says what to type.
func diagnoseInput(_ text: String, _ what: String) throws -> String {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw NetToysDiagnoseError.invalidInput("Enter \(what) first.") }
    return text
}

func diagnoseMilliseconds(_ value: Double) -> String {
    value < 100 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
}

func diagnoseCopy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Flag and name for an ISO country code, such as "🇩🇪 Germany".
func diagnoseCountry(_ code: String?) -> String {
    guard let code, code.count == 2 else { return code ?? "" }
    let flag = String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    return "\(flag) \(Locale.current.localizedString(forRegionCode: code) ?? code)"
}

// MARK: Result table

struct DiagnoseColumn {
    let title: String
    /// Nil fills the remaining width.
    var width: CGFloat?
    var trailing = false
}

struct DiagnoseCell {
    var text: String
    var tone: Color = Dense.label
    var mono = false
    var strong = false

    init(_ text: String, tone: Color = Dense.label, mono: Bool = false, strong: Bool = false) {
        self.text = text
        self.tone = tone
        self.mono = mono
        self.strong = strong
    }
}

struct DiagnoseRow: Identifiable {
    let id: String
    let cells: [DiagnoseCell]
}

/// The result table under every Diagnose summary: header, zebra rows that fade in, Copy on the context menu.
struct DiagnoseTable: View {
    let columns: [DiagnoseColumn]
    let rows: [DiagnoseRow]
    var emptyLine = "No results."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns.indices, id: \.self) { index in
                    Text(columns[index].title).font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.secondary)
                        .lineLimit(1).modifier(DiagnoseColumnFrame(column: columns[index]))
                }
            }
            .padding(.horizontal, 28).frame(height: 28)
            DenseHairline().padding(.horizontal, 20)
            if rows.isEmpty {
                Text(emptyLine).font(.system(size: 13)).foregroundStyle(Dense.secondary)
                    .padding(.horizontal, 28).padding(.top, 12)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        DiagnoseTableRow(columns: columns, row: row, zebra: index % 2 == 1)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
                .animation(.easeOut(duration: 0.08), value: rows.map(\.id))
            }
        }
    }
}

private struct DiagnoseTableRow: View {
    let columns: [DiagnoseColumn]
    let row: DiagnoseRow
    let zebra: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                let cell = index < row.cells.count ? row.cells[index] : DiagnoseCell("")
                Text(cell.text)
                    .font(cell.mono ? .system(size: 12, design: .monospaced) : .system(size: 13, weight: cell.strong ? .medium : .regular))
                    .foregroundStyle(cell.tone).monospacedDigit().lineLimit(1).truncationMode(.middle)
                    .modifier(DiagnoseColumnFrame(column: columns[index]))
            }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Dense.hover : (zebra ? Dense.zebra : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Dense.fast, value: hovering)
        .contextMenu {
            ForEach(columns.indices, id: \.self) { index in
                if index < row.cells.count, !row.cells[index].text.isEmpty {
                    Button("Copy \(columns[index].title)") { diagnoseCopy(row.cells[index].text) }
                }
            }
            Divider()
            Button("Copy Row") { diagnoseCopy(row.cells.map(\.text).joined(separator: "\t")) }
        }
    }
}

private struct DiagnoseColumnFrame: ViewModifier {
    let column: DiagnoseColumn

    func body(content: Content) -> some View {
        if let width = column.width {
            content.frame(width: width, alignment: column.trailing ? .trailing : .leading).padding(.trailing, 12)
        } else {
            content.frame(maxWidth: .infinity, alignment: column.trailing ? .trailing : .leading)
        }
    }
}

/// Two columns, Field and Value, for tools that answer with one record.
struct DiagnoseFieldTable: View {
    let fields: [(String, String)]

    var body: some View {
        DiagnoseTable(columns: [.init(title: "Field", width: 160), .init(title: "Value")],
                      rows: fields.filter { !$0.1.isEmpty }.map {
                          DiagnoseRow(id: $0.0, cells: [.init($0.0, tone: Dense.secondary), .init($0.1)])
                      })
    }
}

// MARK: States

/// The plain-words state in place of the table: before a run, while waiting, after an error.
struct DiagnoseMessage: View {
    let symbol: String
    let title: String
    var line = ""
    var tone: Color = Dense.tertiary
    var busy = false

    var body: some View {
        VStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(tone)
            }
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Dense.label)
            if !line.isEmpty {
                Text(line).font(.system(size: 12)).foregroundStyle(Dense.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

/// Error first, then idle or waiting text while there is nothing to show, then the content.
struct DiagnoseResults<Value, Content: View>: View {
    let run: DiagnoseRun<Value>
    let hasContent: Bool
    let idle: String
    let busy: String
    @ViewBuilder var content: Content

    var body: some View {
        if let error = run.error, !hasContent {
            DiagnoseMessage(symbol: "exclamationmark.triangle", title: "This check did not finish", line: error,
                            tone: Dense.amber)
        } else if !hasContent {
            if run.running {
                DiagnoseMessage(symbol: "", title: busy, busy: true)
            } else {
                DiagnoseMessage(symbol: "arrow.turn.down.left", title: idle)
            }
        } else {
            content
        }
    }
}

/// A small ring with a number inside, such as days to expiry.
struct DiagnoseRing: View {
    let fraction: Double
    let value: String
    let unit: String
    let tone: Color

    var body: some View {
        ZStack {
            Circle().stroke(Dense.track, lineWidth: 6)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tone, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(Dense.label).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(Dense.secondary)
            }
        }
        .frame(width: 76, height: 76)
    }
}

/// Grouped card container used by the richer summaries.
/// `stretch` fills the row height; use it only inside a row with `.fixedSize(horizontal: false, vertical: true)`.
struct DiagnoseCard<Content: View>: View {
    var stretch = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
    }
}
