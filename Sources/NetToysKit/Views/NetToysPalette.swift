import AppKit
import Carbon.HIToolbox
import NetToysCore
import OnePlusUI
import SwiftUI

/// One palette result: a tool, a known device, or an action on the typed host.
struct NetToysPaletteItem: Identifiable, Equatable {
    enum Kind: String { case tool = "Tool", device = "Device", action = "Action" }
    let id: String
    let kind: Kind
    let symbol: String
    let title: String
    var detail = ""
    /// The tool to open (tools and actions) and its input.
    var toolID: String?
    var input: String?
    var deviceID: String?

    /// Tools, then devices, then actions on the typed host, at most 40 rows.
    @MainActor
    static func results(_ rawQuery: String, pinned: [String], devices: [NetToysScanResult]) -> [NetToysPaletteItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let orderedTools = pinned.compactMap(NetToysTool.tool) + NetToysTool.all.filter { !pinned.contains($0.id) }
        let tools = orderedTools.filter { $0.matches(query) }.map {
            NetToysPaletteItem(id: "tool.\($0.id)", kind: .tool, symbol: $0.symbol, title: $0.name, toolID: $0.id)
        }
        guard !query.isEmpty else { return tools }
        let found = devices.filter {
            $0.address.description.hasPrefix(query) || ($0.hostname ?? "").localizedCaseInsensitiveContains(query)
        }
        let deviceItems = found.prefix(8).map {
            NetToysPaletteItem(id: "device.\($0.id)", kind: .device, symbol: "desktopcomputer",
                               title: $0.hostname ?? $0.address.description,
                               detail: $0.hostname == nil ? "" : $0.address.description, deviceID: $0.id)
        }
        var actions: [NetToysPaletteItem] = []
        if looksLikeHost(query) {
            let isAddress = query.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
            let verbs: [(String, String)] = [("ping", "Ping"), ("traceroute", "Trace"), ("port-scan", "Scan ports on")]
                + (isAddress ? [("geoip", "Locate")] : [("dns-lookup", "Look up DNS for"), ("ssl-certificate", "Check SSL on")])
            actions = verbs.compactMap { id, verb in
                NetToysTool.tool(id).map {
                    NetToysPaletteItem(id: "action.\(id)", kind: .action, symbol: $0.symbol, title: "\(verb) \(query)",
                                       toolID: id, input: query)
                }
            }
        }
        return Array((tools + deviceItems + actions).prefix(40))
    }

    /// A host name, IPv4, or IPv6 address: no spaces, and a dot or colon.
    static func looksLikeHost(_ query: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        return (query.contains(".") || query.contains(":")) && query.count <= 253
            && query.unicodeScalars.allSatisfy(allowed.contains) && !query.hasPrefix(".")
    }
}

/// Xcode Open Quickly style palette (round 12 option 4): 30 pt rows, 13 pt text, monochrome symbols.
struct NetToysPaletteView: View {
    let shell: NetToysShell
    /// True when the user picked a result, false on esc or a click outside.
    let close: (_ picked: Bool) -> Void
    @State private var query: String

    init(shell: NetToysShell, initialQuery: String = "", close: @escaping (_ picked: Bool) -> Void) {
        self.shell = shell
        self.close = close
        _query = State(initialValue: initialQuery)
    }
    @State private var selected = 0
    @FocusState private var focused: Bool

    static let width: CGFloat = 540
    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 10

    private var items: [NetToysPaletteItem] {
        NetToysPaletteItem.results(query, pinned: shell.pinned, devices: shell.devices)
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Dense.secondary)
                TextField("Open a tool, device, or host", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                    .onSubmit { open(items) }
                    .onKeyPress(.downArrow) { move(1, items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items.count); return .handled }
                    .onKeyPress(.escape) { close(false); return .handled }
                    .onKeyPress(characters: ["p"]) { press in
                        guard press.modifiers.contains(.command), let id = items[safe: selected]?.toolID else { return .ignored }
                        shell.togglePin(id)
                        return .handled
                    }
                    .accessibilityLabel("Search tools, devices, and hosts")
            }
            .padding(.horizontal, 16).frame(height: 40)
            Rectangle().fill(Dense.hair).frame(height: 0.5)
            if items.isEmpty {
                Text("No results").font(.system(size: 13)).foregroundStyle(Dense.tertiary)
                    .frame(maxWidth: .infinity).frame(height: 44)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selected).id(item.id)
                                    .onTapGesture { selected = index; open(items) }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight + 12)
                    .onChange(of: selected) { _, index in
                        if let id = items[safe: index]?.id { proxy.scrollTo(id) }
                    }
                }
            }
            Rectangle().fill(Dense.hair).frame(height: 0.5)
            footer
        }
        .frame(width: Self.width)
        .background(NetToysPaletteSurface())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Dense.stroke, lineWidth: 0.5))
        .onChange(of: query) { selected = 0 }
        .onAppear { focused = true }
        .task { await shell.loadDevicesIfNeeded() }
    }

    private func row(_ item: NetToysPaletteItem, selected: Bool) -> some View {
        let pinned = item.kind == .tool && item.toolID.map(shell.isPinned) == true
        // Light selection is system blue; Dark selection stays a neutral gray (owner taste rule).
        return HStack(spacing: 9) {
            Image(systemName: item.symbol).font(.system(size: 13))
                .foregroundStyle(selected ? Dense.rowSelectionInk : Dense.sidebarSymbol).frame(width: 18)
            Text(item.title).font(.system(size: 13)).foregroundStyle(selected ? Dense.rowSelectionInk : Dense.label).lineLimit(1)
            Spacer(minLength: 6)
            Text(item.detail.isEmpty ? (pinned ? "Pinned" : item.kind.rawValue) : item.detail)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(selected ? Dense.rowSelectionInk.opacity(0.8) : Dense.tertiary)
        }
        .padding(.horizontal, 9).frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected ? Dense.rowSelection : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            hint("Open", "↵")
            hint("Pin", "⌘P")
            hint("Move", "↑↓")
            hint("Close", "esc")
        }
        .padding(.horizontal, 14).frame(height: 26)
    }

    private func hint(_ title: String, _ key: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
            Text(title).font(.system(size: 11)).foregroundStyle(Dense.tertiary)
        }
    }

    private func move(_ step: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = (selected + step + count) % count
    }

    private func open(_ items: [NetToysPaletteItem]) {
        guard let item = items[safe: selected] else { return }
        if let deviceID = item.deviceID {
            shell.selection = "all-devices"
            shell.deviceRequest = deviceID
        } else if let toolID = item.toolID {
            shell.open(toolID, input: item.input)
        }
        close(true)
    }
}

/// A solid surface: the wallpaper must not show through (owner taste rule "Solid popovers").
private struct NetToysPaletteSurface: View {
    var body: some View {
        Rectangle().fill(.regularMaterial)
            .overlay(Color(light: .init(white: 0.985, alpha: 0.9), dark: .init(red: 0.14, green: 0.14, blue: 0.15, alpha: 0.92)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The ⌥Space palette from any app: a non-activating floating panel. Picking a result opens the main window.
@MainActor
public final class NetToysPalettePanel {
    public static let shared = NetToysPalettePanel()
    public static let hotKeyDefaultsKey = "nettoys.palette.globalHotKey"

    /// Set by the app: the shell to drive and how to bring the main window forward.
    public var shell: NetToysShell?
    public var openWindow: (() -> Void)?
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var resignObserver: NSObjectProtocol?

    /// Registers or removes ⌥Space. RegisterEventHotKey needs no Accessibility permission.
    public func setHotKey(enabled: Bool) {
        if !enabled {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            return
        }
        guard hotKey == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in NetToysPalettePanel.shared.toggle() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4E54_5059), id: 1) // "NTPY"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func toggle() {
        if let panel, panel.isVisible { hide() } else { show() }
    }

    private func show() {
        guard let shell else { return }
        let panel = NetToysKeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Picking a result opens the main window on it; activating the app then is the user's action.
        let hosting = NSHostingView(rootView: NetToysPaletteView(shell: shell) { [weak self] picked in
            self?.hide()
            if picked { self?.openWindow?() }
        }
        .onePlusAppAppearance())
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = hosting.fittingSize
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22 - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { NetToysPalettePanel.shared.hide() }
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil) // a non-activating panel takes keys without bringing the app forward
    }

    func hide() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class NetToysKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
