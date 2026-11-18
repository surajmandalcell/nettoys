import AppKit
import NetToysCore
import SwiftUI

// Shared parts of the Monitor, Local Network, and Wi-Fi tool pages: a dense result table and small texts.

/// One table column. A nil width takes the rest of the row.
extension EnvironmentValues {
    /// False while a visited tool page stays mounted behind the selected one; live readers pause, their data stays.
    @Entry var toolPageActive = true
}

/// Keeps every visited page mounted (hidden when not selected), so switching tools keeps results and running rows.
/// Bounded: at most one page per tool id.
struct NetToysKeptPages<Page: View>: View {
    let selection: String
    let keeps: (String) -> Bool
    @ViewBuilder let page: (String) -> Page
    @State private var visited: [String] = []

    var body: some View {
        // The new page joins `visited` in onChange; listing it here too draws it on the first frame.
        let ids = keeps(selection) && !visited.contains(selection) ? visited + [selection] : visited
        ZStack(alignment: .topLeading) {
            ForEach(ids, id: \.self) { id in
                let active = id == selection
                page(id)
                    .opacity(active ? 1 : 0).allowsHitTesting(active).accessibilityHidden(!active).disabled(!active)
                    .environment(\.toolPageActive, active)
            }
        }
        .onChange(of: selection, initial: true) { _, id in
            if keeps(id), !visited.contains(id) { visited.append(id) }
        }
    }
}

struct UtilityColumn {
    let title: String
    var width: CGFloat?
    var trailing = false
}

extension View {
    /// Places a cell in its column, so header and rows line up.
    func cell(_ column: UtilityColumn) -> some View {
        Group {
            if let width = column.width {
                frame(width: width, alignment: column.trailing ? .trailing : .leading)
            } else {
                frame(maxWidth: .infinity, alignment: column.trailing ? .trailing : .leading)
            }
        }
        .padding(.trailing, 10)
    }
}

/// The result table under every tool summary: a header, then zebra rows that scroll.
/// A row with `open` opens on a double click; `menu` is its context menu.
struct UtilityTable<Row: Identifiable, Cells: View, MenuItems: View>: View {
    let columns: [UtilityColumn]
    let rows: [Row]
    var empty = "Nothing found"
    var open: ((Row) -> Void)?
    @ViewBuilder var cells: (Row) -> Cells
    @ViewBuilder var menu: (Row) -> MenuItems

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns.indices, id: \.self) { index in
                    Text(columns[index].title).font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.secondary)
                        .lineLimit(1).cell(columns[index])
                }
            }
            .padding(.horizontal, 8).frame(height: 28).padding(.horizontal, 20)
            DenseHairline().padding(.horizontal, 20)
            if rows.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(Dense.tertiary)
                    .frame(maxWidth: .infinity).padding(.top, 28)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 0) { cells(row) }
                                .font(.system(size: 13)).foregroundStyle(Dense.label).monospacedDigit().lineLimit(1)
                                .padding(.horizontal, 8).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index % 2 == 1 ? Dense.zebra : Color.clear))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open?(row) }
                                .contextMenu { menu(row) }
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

extension UtilityTable where MenuItems == EmptyView {
    init(columns: [UtilityColumn], rows: [Row], empty: String = "Nothing found", @ViewBuilder cells: @escaping (Row) -> Cells) {
        self.init(columns: columns, rows: rows, empty: empty, open: nil, cells: cells, menu: { _ in EmptyView() })
    }
}

/// Small last-N bars: height is the value, a failed sample is a short red bar.
struct UtilitySpark: View {
    let values: [Double?]
    var tone: Color = Dense.accent

    var body: some View {
        GeometryReader { proxy in
            let top = max(values.compactMap { $0 }.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(values.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(values[index] == nil ? UtilityTone.red : tone.opacity(0.35 + 0.65 * Double(index + 1) / Double(values.count)))
                        .frame(height: values[index].map { max(2, proxy.size.height * $0 / top) } ?? 4)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }
}

enum UtilityTone {
    static let red = Color(light: NSColor(srgbRed: 0.79, green: 0.28, blue: 0.25, alpha: 1),
                           dark: NSColor(srgbRed: 1, green: 0.54, blue: 0.5, alpha: 1))
}

/// A colored dot and a word, for row status.
struct UtilityStatus: View {
    let text: String
    let tone: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 7, height: 7)
            Text(text).foregroundStyle(tone == Dense.tertiary ? Dense.secondary : Dense.label)
        }
    }
}

/// Monospaced value text, such as an address.
struct MonoText: View {
    let text: String
    var tone: Color = Dense.secondary
    init(_ text: String, tone: Color = Dense.secondary) { self.text = text; self.tone = tone }
    var body: some View {
        Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(tone).textSelection(.enabled)
    }
}

/// A tinted note line under a summary, such as a permission state or a limit.
struct UtilityNote: View {
    let symbol: String
    let text: String
    var tone: Color = Dense.secondary
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tone)
            Text(text).font(.system(size: 12)).foregroundStyle(Dense.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run).buttonStyle(DenseCapsuleButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Dense.group))
    }
}

enum UtilityFormat {
    static func ms(_ value: Double?) -> String {
        guard let value else { return "None" }
        return value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    static func mbps(_ value: Double?) -> String {
        guard let value else { return "None" }
        return value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    /// Bytes per second as bits per second with a unit: "12.4 Mbps".
    static func rate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let bits = bytesPerSecond * 8
        switch bits {
        case ..<1_000: return (String(Int(bits)), "bps")
        case ..<1_000_000: return (String(format: "%.0f", bits / 1_000), "Kbps")
        case ..<1_000_000_000: return (String(format: bits < 10_000_000 ? "%.1f" : "%.0f", bits / 1_000_000), "Mbps")
        default: return (String(format: "%.2f", bits / 1_000_000_000), "Gbps")
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        return "\(NetToysDuration.text(seconds)) ago"
    }
}
