import AppKit
import NetToysCore
import SwiftUI

/// The three Devices views in the sidebar. They share one table.
enum NetToysDeviceScope: String, CaseIterable, Identifiable {
    case all = "All Devices"
    case favorites = "Favorites"
    case offline = "Offline"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "desktopcomputer"
        case .favorites: "star"
        case .offline: "moon.zzz"
        }
    }
}

extension NetToysScannerViewModel {
    func devices(in scope: NetToysDeviceScope, from rows: [NetToysScanResult]) -> [NetToysScanResult] {
        rows.filter { result in
            guard isKnownDevice(result) else { return false }
            switch scope {
            case .all: return true
            case .favorites: return annotations[result.id]?.isFavorite == true
            case .offline: return !result.isReachable
            }
        }
    }
}

/// Text and symbols for one device row. Pure, so the table and the modal show the same words.
enum NetToysDeviceText {
    static func name(_ result: NetToysScanResult) -> String? {
        [result.hostname, result.netBIOSName].compactMap { $0 }.first { !$0.isEmpty }
    }

    static func ping(_ result: NetToysScanResult) -> String {
        guard result.isReachable, let value = result.responseMilliseconds else { return "None" }
        return "\(max(Int(value.rounded()), 0)) ms"
    }

    static func lastSeen(_ result: NetToysScanResult, date: Date?, now: Date = Date()) -> String {
        if result.isReachable { return "Now" }
        guard let date else { return "Never" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "Now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 24 * 60 { return minutes < 120 ? "1 hour ago" : "\(minutes / 60) hours ago" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func service(_ port: UInt16) -> String {
        switch port {
        case 21: "FTP"
        case 22: "SSH"
        case 23: "Telnet"
        case 53: "DNS"
        case 80, 8080, 8000: "HTTP"
        case 443, 8443, 5001: "HTTPS"
        case 445: "SMB"
        case 554: "RTSP"
        case 631: "IPP"
        case 3389: "Remote Desktop"
        case 5900: "Screen Sharing"
        case 9100: "Raw print"
        case 62078: "Device sync"
        default: "Port \(port)"
        }
    }

    /// A best guess of the device type from its name, vendor, and open ports.
    static func symbol(_ result: NetToysScanResult) -> String {
        let text = [result.hostname, result.netBIOSName, result.vendor].compactMap { $0 }.joined(separator: " ").lowercased()
        let ports = Set(result.openPorts)
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("iphone") { return "iphone" }
        if has("ipad") { return "ipad" }
        if has("macbook", "laptop") { return "laptopcomputer" }
        if has("appletv", "apple-tv") || ports.contains(7000) { return "appletv" }
        if has("router", "gateway", "ubiquiti", "netgear", "eero") { return "wifi.router" }
        if has("printer", "brother", "epson", "canon") || ports.contains(631) || ports.contains(9100) { return "printer" }
        if has("sonos", "speaker", "homepod") || ports.contains(1400) { return "hifispeaker" }
        if has("cam", "hikvision", "reolink") || ports.contains(554) { return "video" }
        if has("tv", "roku", "chromecast") { return "tv" }
        if has("nas", "synology", "qnap") { return "externaldrive.connected.to.line.below" }
        if has("playstation", "ps5", "xbox", "nintendo", "steamdeck", "valve") { return "gamecontroller" }
        if has("espressif", "esp32", "shelly", "tuya") { return "cpu" }
        if ports.contains(62078) { return "iphone" }
        if ports.contains(3389) || has("windows", "desktop") { return "pc" }
        if has("raspberry", "proxmox", "server") || ports.contains(22) { return "server.rack" }
        return "desktopcomputer"
    }
}

/// All Devices, Favorites, and Offline: the scanner table merged with the device list.
struct NetToysDevicesView: View {
    @Bindable var model: NetToysScannerViewModel
    let scope: NetToysDeviceScope
    let paused: Bool
    let openDevice: (String) -> Void
    let openSettings: () -> Void
    @AppStorage("nettoys.devices.inspector") private var showInspector = false
    @State private var searchFocus = 0
    @State private var networkName: String?
    @State private var activeNetworkCIDR: String?
    @State private var tableWidth: CGFloat = 1000
    @State private var pendingRemoval = Set<String>()
    @State private var showRandomTargets = false
    @State private var openerPreview: NetToysOpenerPreview?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [NetToysScanResult] { model.devices(in: scope, from: model.visibleResults) }
    private var known: [NetToysScanResult] { model.devices(in: .all, from: model.results) }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            toolbar
            progressLine
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    NetToysDeviceTable(model: model, rows: rows, width: tableWidth, openDevice: openDevice,
                                       contextMenu: { contextMenu(for: $0) })
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: rows.map(\.id))
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
                        .overlay { emptyState(rows) }
                    statusBar
                }
                if showInspector {
                    NetToysScanInspector(model: model, activeNetworkCIDR: activeNetworkCIDR,
                                         showRandomTargets: $showRandomTargets, openSettings: openSettings)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Dense.content)
        .sheet(isPresented: $showRandomTargets) { NetToysRandomTargetsView(model: model) }
        .sheet(item: $openerPreview) { NetToysOpenerPreviewSheet(preview: $0) }
        .confirmationDialog("Forget these devices?", isPresented: Binding(
            get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval.removeAll() } }
        ), titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                model.removeResults(ids: pendingRemoval)
                model.selection.subtract(pendingRemoval)
                pendingRemoval.removeAll()
            }
        }
        .alert("Scan", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .background { Button("Find") { searchFocus += 1 }.keyboardShortcut("f").hidden() }
        .onReceive(NotificationCenter.default.publisher(for: .netToysStartScan)) { notification in
            guard let run = notification.object as? NetToysScanRun else { return }
            model.targetInput = run.target
            model.portInput = run.ports.map(String.init).joined(separator: ", ")
            model.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNetworkContext() }
        }
        .task { await refreshNetworkContext() }
    }

    // MARK: Toolbar, light to heavy: inspector, filter, search, Scan.

    private var toolbar: some View {
        let offline = known.filter { !$0.isReachable }.count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(scope.rawValue).font(.system(size: 15, weight: .semibold)).foregroundStyle(Dense.label)
                Text("\(known.count) on \(networkName ?? "this network"), \(offline) offline")
                    .font(.system(size: 11)).foregroundStyle(Dense.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.trailing").font(.system(size: 13, weight: .regular))
                    .foregroundStyle(showInspector ? Dense.label : Dense.secondary)
                    .frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Show scan settings").accessibilityLabel("Scan settings")
            Menu {
                Picker("Show", selection: $model.filter) {
                    Text("All Devices").tag(NetToysResultFilter.all)
                    Text("Online").tag(NetToysResultFilter.alive)
                    Text("With Open Ports").tag(NetToysResultFilter.openPorts)
                }
                .pickerStyle(.inline)
            } label: {
                Text(filterTitle).font(.system(size: 13))
            }
            .menuStyle(.button).buttonStyle(DenseCapsuleButtonStyle()).fixedSize()
            .accessibilityLabel("Filter")
            DenseSearchField(prompt: "Search", text: $model.searchText, focusTrigger: searchFocus)
            scanButton
        }
        .padding(.leading, 20).padding(.trailing, 14)
        .frame(height: 52) // centerline 26 pt, shared with the traffic lights

    }

    private var filterTitle: String {
        switch model.filter {
        case .all: "All Devices"
        case .alive: "Online"
        case .openPorts: "With Open Ports"
        }
    }

    @ViewBuilder private var scanButton: some View {
        if model.isScanning {
            Button { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(DenseCapsuleButtonStyle())
        } else {
            Button { model.start() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                .buttonStyle(DenseCapsuleButtonStyle(prominent: true))
                .keyboardShortcut("r")
                .disabled(model.isLoading || model.isImporting || paused)
        }
    }

    /// One point progress line under the toolbar while a scan runs.
    private var progressLine: some View {
        GeometryReader { proxy in
            Rectangle().fill(Dense.accent)
                .frame(width: proxy.size.width * CGFloat(model.completed) / CGFloat(max(model.total, 1)))
                .animation(reduceMotion ? nil : .linear(duration: 0.15), value: model.completed)
        }
        .frame(height: 1)
        .opacity(model.isScanning ? 1 : 0)
        .background(Dense.hair)
    }

    private var statusBar: some View {
        let offline = known.filter { !$0.isReachable }.count
        return HStack {
            if model.isScanning {
                Text("Scanning \(model.completed) of \(model.total)")
            } else {
                Text("\(known.count) devices, \(offline) offline")
            }
            Spacer()
            if let notice = model.scanResultNotice {
                Text(notice).lineLimit(1).truncationMode(.middle)
            } else if let date = model.lastScanDate, let duration = model.lastDuration {
                Text("Scanned \(date.formatted(date: .omitted, time: .shortened)) in \(duration.formatted(.number.precision(.fractionLength(1)))) s")
            }
        }
        .font(.system(size: 11)).foregroundStyle(Dense.tertiary).monospacedDigit()
        .padding(.horizontal, 16).frame(height: 26)
        .overlay(alignment: .top) { DenseHairline() }
    }

    @ViewBuilder private func emptyState(_ rows: [NetToysScanResult]) -> some View {
        if rows.isEmpty && !model.isScanning && !model.isLoading {
            VStack(spacing: 6) {
                Image(systemName: scope == .favorites ? "star" : "network").font(.system(size: 28, weight: .light))
                    .foregroundStyle(Dense.tertiary)
                Text(emptyTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Dense.secondary)
                Text(emptyTip).font(.system(size: 12)).foregroundStyle(Dense.tertiary)
            }
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty || model.filter != .all { return "No matching devices" }
        return switch scope {
        case .all: "No devices yet"
        case .favorites: "No favorites"
        case .offline: "Every device is online"
        }
    }

    private var emptyTip: String {
        if !model.searchText.isEmpty || model.filter != .all { return "Change the filter or the search." }
        return switch scope {
        case .all: "Click Scan to find the devices on this network."
        case .favorites: "Click the star on a device to keep it here."
        case .offline: "Devices that stop answering show here."
        }
    }

    // MARK: Row menu

    @ViewBuilder private func contextMenu(for result: NetToysScanResult) -> some View {
        Button("Show Details") { openDevice(result.id) }
        Button(model.annotation(for: result.id).isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            NetToysDeviceActions.toggleFavorite(result.id, model: model)
        }
        Button("Add to SSH Anchor") { NetToysDeviceActions.addToAnchor(result) }
        let openers = model.openers.filter { $0.applies(to: result) }
        if !openers.isEmpty {
            Menu("Open With") {
                ForEach(openers) { opener in
                    Button(opener.name) {
                        do {
                            openerPreview = NetToysOpenerPreview(
                                name: opener.name, url: try opener.resolvedURL(address: result.address, hostname: result.hostname))
                        } catch { model.errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        Divider()
        Button("Copy IP Address") { NetToysDeviceActions.copy(result.address.description) }
        Button("Rescan Device") { model.start(targets: [result.address]) }.disabled(model.isScanning || paused)
        Divider()
        Button("Forget Device…", role: .destructive) { pendingRemoval = [result.id] }
    }

    private func refreshNetworkContext() async {
        let snapshot = await Task.detached(priority: .utility) {
            (LocalIPv4Network.active(), NetToysConfigurationStore.status())
        }.value
        guard !Task.isCancelled, let network = snapshot.0 else { return }
        let status = snapshot.1
        let identity = status?.network.map { NetworkIdentity(networkID: $0.networkID, ssid: $0.ssid) }
        let ssid = status?.ssidAccess == .allowed && identity?.interfaceName == network.interfaceName ? identity?.ssid : nil
        activeNetworkCIDR = network.cidr
        model.updateActiveNetwork(network)
        networkName = ssid ?? network.cidr
    }
}

/// Device actions shared by the table menu and the device modal.
@MainActor
enum NetToysDeviceActions {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func toggleFavorite(_ id: String, model: NetToysScannerViewModel) {
        var annotation = model.annotation(for: id)
        annotation.isFavorite.toggle()
        model.saveAnnotation(annotation, for: id)
    }

    static func addToAnchor(_ result: NetToysScanResult) {
        NotificationCenter.default.post(name: .netToysOpenAnchor, object: NetToysAnchorPrefill(
            address: result.address.description, macAddress: result.macAddress, hostname: result.hostname))
    }

    static func openSSH(_ result: NetToysScanResult) {
        guard let url = URL(string: "ssh://\(result.address.description)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Table

private struct NetToysColumn {
    let title: String
    let width: CGFloat?
    var right = false
    var sort: KeyPathComparator<NetToysScanResult>?
}

/// Dense pro table: 26 pt rows, soft zebra, no column lines, tabular figures.
struct NetToysDeviceTable<RowMenu: View>: View {
    @Bindable var model: NetToysScannerViewModel
    let rows: [NetToysScanResult]
    let width: CGFloat
    let openDevice: (String) -> Void
    @ViewBuilder let contextMenu: (NetToysScanResult) -> RowMenu
    @FocusState private var focused: Bool

    /// Narrow tables drop Comment first, then MAC Address, Vendor, and Last Seen.
    private var showComment: Bool { width >= 1000 }
    private var showMAC: Bool { width >= 860 }
    private var showVendor: Bool { width >= 756 }
    private var showLastSeen: Bool { width >= 640 }

    private var columns: [NetToysColumn] {
        var list = [
            NetToysColumn(title: "Name", width: 190, sort: .init(\NetToysScanResult.hostnameTitle)),
            NetToysColumn(title: "IP Address", width: 120, sort: .init(\NetToysScanResult.sortAddress)),
        ]
        if showMAC { list.append(NetToysColumn(title: "MAC Address", width: 140, sort: .init(\NetToysScanResult.macTitle))) }
        if showVendor { list.append(NetToysColumn(title: "Vendor", width: 124, sort: .init(\NetToysScanResult.vendorTitle))) }
        list += [
            NetToysColumn(title: "Ping", width: 58, right: true, sort: .init(\NetToysScanResult.responseMilliseconds)),
            NetToysColumn(title: "Open Ports", width: 120, sort: .init(\NetToysScanResult.portsTitle)),
        ]
        if showLastSeen { list.append(NetToysColumn(title: "Last Seen", width: 96)) }
        if showComment { list.append(NetToysColumn(title: "Comment", width: nil, sort: .init(\NetToysScanResult.commentTitle))) }
        else { list.append(NetToysColumn(title: "", width: nil)) }
        list.append(NetToysColumn(title: "", width: 30))
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DenseHairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                            NetToysDeviceRow(
                                result: result, stripe: index % 2 == 1,
                                selected: model.selection.contains(result.id),
                                favorite: model.annotations[result.id]?.isFavorite == true,
                                comment: model.annotations[result.id]?.comment ?? result.commentTitle,
                                lastSeen: model.lastSeen[result.id],
                                showMAC: showMAC, showVendor: showVendor, showLastSeen: showLastSeen,
                                showComment: showComment,
                                select: { model.selection = [result.id]; focused = true },
                                open: { openDevice(result.id) },
                                toggleFavorite: { NetToysDeviceActions.toggleFavorite(result.id, model: model) }
                            )
                            .id(result.id)
                            .contextMenu { contextMenu(result) }
                            .transition(.opacity.animation(.easeOut(duration: 0.08)))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1, proxy); return .handled }
                .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
                .onKeyPress(.return) {
                    if let id = model.selection.first { openDevice(id) }
                    return .handled
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                headerCell(columns[index])
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
    }

    @ViewBuilder private func headerCell(_ column: NetToysColumn) -> some View {
        let active = column.sort.map { sort in model.sortOrder.first?.keyPath == sort.keyPath } ?? false
        let ascending = model.sortOrder.first?.order != .reverse
        Button {
            guard var sort = column.sort else { return }
            if active { sort.order = ascending ? .reverse : .forward }
            model.sortOrder = [sort]
        } label: {
            HStack(spacing: 4) {
                if column.right { Spacer(minLength: 0) }
                Text(column.title).font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Dense.label : Dense.secondary).lineLimit(1)
                if active { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Dense.secondary) }
                if !column.right { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).allowsHitTesting(column.sort != nil)
        .frame(width: column.width).frame(maxWidth: column.width == nil ? .infinity : nil)
    }

    private func move(_ offset: Int, _ proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let current = model.selection.first.flatMap { id in rows.firstIndex { $0.id == id } }
        let index = current.map { min(max($0 + offset, 0), rows.count - 1) } ?? (offset < 0 ? rows.count - 1 : 0)
        model.selection = [rows[index].id]
        proxy.scrollTo(rows[index].id)
    }
}

private struct NetToysDeviceRow: View {
    let result: NetToysScanResult
    let stripe: Bool
    let selected: Bool
    let favorite: Bool
    let comment: String
    let lastSeen: Date?
    let showMAC: Bool
    let showVendor: Bool
    let showLastSeen: Bool
    let showComment: Bool
    let select: () -> Void
    let open: () -> Void
    let toggleFavorite: () -> Void
    @State private var hovered = false

    var body: some View {
        let offline = !result.isReachable
        let ink: Color = selected ? Dense.rowSelectionInk : (offline ? Dense.tertiary : Dense.label)
        let dim: Color = selected ? Dense.rowSelectionInk.opacity(0.8) : (offline ? Dense.tertiary : Dense.secondary)
        let name = NetToysDeviceText.name(result)
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: NetToysDeviceText.symbol(result)).font(.system(size: 12))
                    .foregroundStyle(selected ? Dense.rowSelectionInk : Dense.secondary).frame(width: 18)
                Text(name ?? "Unknown device").foregroundStyle(name == nil ? dim : ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(width: 190)
            HStack(spacing: 6) {
                Text(result.address.description).foregroundStyle(ink)
                if offline {
                    Circle().strokeBorder(selected ? Dense.rowSelectionInk : Dense.tertiary, lineWidth: 1.2)
                        .frame(width: 7, height: 7).accessibilityLabel("Offline")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(width: 120)
            if showMAC {
                cell(result.macAddress ?? "Unknown", width: 140, color: dim, mono: true)
            }
            if showVendor { cell(result.vendor ?? "Unknown", width: 124, color: result.vendor == nil ? dim : ink) }
            Text(NetToysDeviceText.ping(result))
                .foregroundStyle(selected ? Dense.rowSelectionInk
                    : offline ? Dense.tertiary
                    : (result.responseMilliseconds ?? 0) > 40 ? Dense.amber : Dense.secondary)
                .lineLimit(1).padding(.horizontal, 6).frame(width: 58, alignment: .trailing)
            cell(result.openPorts.isEmpty ? "None" : result.portsTitle, width: 120,
                 color: result.openPorts.isEmpty ? dim : ink)
            if showLastSeen { cell(NetToysDeviceText.lastSeen(result, date: lastSeen), width: 96, color: dim) }
            cell(showComment ? comment : "", width: nil, color: dim)
            Button(action: toggleFavorite) {
                Image(systemName: favorite ? "star.fill" : "star").font(.system(size: 11))
                    .foregroundStyle(selected ? Dense.rowSelectionInk : favorite ? Dense.yellow : Dense.tertiary)
                    .opacity(favorite || hovered || selected ? 1 : 0)
                    .frame(width: 30, height: Dense.rowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .font(.system(size: 13)).monospacedDigit()
        .frame(height: Dense.rowHeight)
        .background {
            ZStack {
                if stripe { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Dense.zebra) }
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Dense.hover)
                    .opacity(hovered && !selected ? 1 : 0)
                    .animation(Dense.fast, value: hovered)
                if selected { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Dense.rowSelection) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded(open))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Show Details", open)
    }

    private func cell(_ text: String, width: CGFloat?, color: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 13))
            .foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, alignment: .leading).frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

// MARK: - Scan inspector

/// The trailing inspector holds what to scan: targets, ports, presets, and export.
private struct NetToysScanInspector: View {
    @Bindable var model: NetToysScannerViewModel
    let activeNetworkCIDR: String?
    @Binding var showRandomTargets: Bool
    let openSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Scan").font(.system(size: 15, weight: .semibold)).foregroundStyle(Dense.label)
                DenseSection(title: "Targets") {
                    field("Address, range, or CIDR", text: $model.targetInput)
                    DenseHairline().padding(.horizontal, 10)
                    field("Ports", text: $model.portInput)
                }
                .disabled(model.isScanning)
                VStack(alignment: .leading, spacing: 8) {
                    Menu("Presets") {
                        Button(activeNetworkCIDR.map { "Local Subnet · \($0)" } ?? "Local Subnet") {
                            if let activeNetworkCIDR { model.useActiveNetwork(activeNetworkCIDR) }
                        }
                        .disabled(activeNetworkCIDR == nil)
                        Button("Random Addresses…") { showRandomTargets = true }
                        Button("Import Target List…") { model.importTargets() }
                        Button("Load Saved Results…") { model.loadResults() }
                        Divider()
                        Button(model.favoriteTargets.contains(model.targetInput) ? "Remove Saved Target" : "Save Target") {
                            model.toggleFavoriteTarget()
                        }
                        ForEach(model.favoriteTargets, id: \.self) { target in
                            Button(target) { model.targetInput = target }
                        }
                    }
                    Menu("Export") {
                        ForEach([NetToysExportFormat.csv, .savedResults]) { format in
                            Button(format.rawValue) { model.export(format, rows: model.visibleResults) }
                        }
                    }
                    .disabled(model.visibleResults.isEmpty || model.isExporting)
                }
                .menuStyle(.button).buttonStyle(DenseCapsuleButtonStyle()).fixedSize()
                .disabled(model.isScanning || model.isImporting)
                Button("Scanner Settings…", action: openSettings)
                    .buttonStyle(.link).font(.system(size: 12))
            }
            .padding(16)
        }
        .frame(width: 280)
        .background(Dense.content)
        .overlay(alignment: .leading) { Rectangle().fill(Dense.hair).frame(width: 1) }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).font(.system(size: 13)).monospacedDigit()
            .padding(.horizontal, 10).frame(height: 30)
            .accessibilityLabel(prompt)
    }
}
