import AppKit
import OnePlusUI
import SwiftUI

/// "Dense pro" tokens for the main window (specs/product.md). Each color follows the system Light or Dark look.
enum Dense {
    static let label = Color(light: .init(white: 0, alpha: 0.86), dark: .init(white: 1, alpha: 0.88))
    static let secondary = Color(light: .init(white: 0, alpha: 0.54), dark: .init(white: 1, alpha: 0.56))
    static let tertiary = Color(light: .init(white: 0, alpha: 0.32), dark: .init(white: 1, alpha: 0.32))
    static let content = Color(light: rgb(0xFFFFFF), dark: rgb(0x1E1E1E))
    static let sidebar = Color(light: rgb(0xEDEDF0), dark: rgb(0x2A2A2D))
    static let zebra = Color(light: rgb(0xF6F6F7), dark: .init(white: 1, alpha: 0.03))
    static let hover = Color(light: .init(white: 0, alpha: 0.045), dark: .init(white: 1, alpha: 0.065))
    static let navSelection = Color(light: .init(white: 0, alpha: 0.075), dark: .init(white: 1, alpha: 0.11))
    /// Light selection is system blue; Dark selection stays a neutral gray.
    static let rowSelection = Color(light: rgb(0x007AFF), dark: .init(white: 1, alpha: 0.14))
    static let rowSelectionInk = Color(light: .white, dark: .init(white: 1, alpha: 0.92))
    static let hair = Color(light: .init(white: 0, alpha: 0.07), dark: .init(white: 1, alpha: 0.07))
    static let stroke = Color(light: .init(white: 0, alpha: 0.09), dark: .init(white: 1, alpha: 0.11))
    static let accent = Color(light: rgb(0x007AFF), dark: rgb(0x0A84FF))
    static let green = Color(light: rgb(0x3A9D5D), dark: rgb(0x6BD58C))
    static let amber = Color(light: rgb(0xA86F1C), dark: rgb(0xF0BC5A))
    static let yellow = Color(light: rgb(0xF5B400), dark: rgb(0xFFD60A))
    static let modal = Color(light: rgb(0xFBFBFC), dark: rgb(0x2A2A2D))
    static let group = Color(light: .init(white: 0, alpha: 0.032), dark: .init(white: 1, alpha: 0.045))
    static let groupStroke = Color(light: .init(white: 0, alpha: 0.055), dark: .init(white: 1, alpha: 0.06))
    static let button = Color(light: .white, dark: .init(white: 1, alpha: 0.09))
    static let buttonStroke = Color(light: .init(white: 0, alpha: 0.11), dark: .init(white: 1, alpha: 0.07))
    static let field = Color(light: .init(white: 0, alpha: 0.05), dark: .init(white: 1, alpha: 0.08))
    static let track = Color(light: .init(white: 0, alpha: 0.09), dark: .init(white: 1, alpha: 0.14))

    // Sidebar on glass: gray symbols, quiet headers, a light search field, a gray selection fill.
    static let sidebarSymbol = Color(light: .init(white: 0, alpha: 0.58), dark: .init(white: 1, alpha: 0.66))
    static let sidebarHeader = Color(light: .init(white: 0, alpha: 0.42), dark: .init(white: 1, alpha: 0.4))
    static let sidebarField = Color(light: .init(white: 0, alpha: 0.05), dark: .init(white: 1, alpha: 0.07))
    static let sidebarSelection = Color(light: .init(white: 0, alpha: 0.09), dark: .init(white: 1, alpha: 0.12))

    static let rowHeight: CGFloat = 26
    static let fast = Animation.easeOut(duration: 0.12)
    /// Every expand, collapse, and selection glide (specs/product.md, Utilities expansion).
    static let spring = Animation.spring(response: 0.30, dampingFraction: 0.86)
    static func spring(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : spring }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Compact bordered capsule push button, 26 pt high.
struct DenseCapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(prominent ? Color.white : Dense.label)
            .labelStyle(DenseLabelStyle())
            .padding(.horizontal, 11)
            .frame(minWidth: 26, minHeight: 26)
            .fixedSize()
            .background(Capsule().fill(prominent ? Dense.accent : Dense.button))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Dense.buttonStroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(prominent ? 0 : 0.05), radius: 0.5, y: 0.5)
            .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.4))
            .animation(Dense.fast, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct DenseLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 12, weight: .medium)).frame(width: 15)
            configuration.title.lineLimit(1).fixedSize()
        }
    }
}

/// Grouped inset section: a small title over a rounded group of rows.
struct DenseSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Dense.secondary)
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Dense.tertiary).monospacedDigit() }
            }
            .padding(.horizontal, 10)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Dense.groupStroke, lineWidth: 0.5))
        }
    }
}

/// Label left, value right, with a hairline under every row but the last.
struct DenseValueRow: View {
    let label: String
    let value: String
    var mono = false
    var last = false

    var body: some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Dense.label)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .monospacedDigit().foregroundStyle(Dense.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .overlay(alignment: .bottom) { if !last { DenseHairline().padding(.horizontal, 10) } }
    }
}

/// A switch row. A switch without a binding shows a feature that is not built yet: it stays off and disabled.
struct DenseSwitchRow: View {
    let label: String
    var detail: String?
    var isOn: Binding<Bool>?
    var last = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13)).foregroundStyle(Dense.label)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Dense.secondary).monospacedDigit() }
            }
            Spacer(minLength: 8)
            Toggle(label, isOn: isOn ?? .constant(false))
                .labelsHidden().toggleStyle(OnePlusLinearSwitchStyle())
                .disabled(isOn == nil)
        }
        .padding(.horizontal, 10).frame(height: detail == nil ? 30 : 40)
        .overlay(alignment: .bottom) { if !last { DenseHairline().padding(.horizontal, 10) } }
    }
}

struct DenseHairline: View {
    var body: some View { Rectangle().fill(Dense.hair).frame(height: 1) }
}

/// Toolbar search field, at least 300 pt wide.
struct DenseSearchField: View {
    let prompt: String
    @Binding var text: String
    var focusTrigger = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Dense.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(width: 300, height: 28)
        .background(Capsule().fill(Dense.field))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onChange(of: focusTrigger) { focused = true }
    }
}
