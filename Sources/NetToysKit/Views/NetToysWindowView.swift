import AppKit
import NetToysCore
import Network
import Observation
import OnePlusUI
import SwiftUI

nonisolated enum NetToysLocalNetworkAccessState: Equatable {
    case checking
    case allowed
    case denied
    case unavailable

    init(dnsErrorCode: Int32) {
        self = dnsErrorCode == -65_570 ? .denied : .unavailable
    }

    init(posixError: POSIXErrorCode) {
        self = posixError == .EPERM ? .denied : .unavailable
    }
}

@Observable
@MainActor
final class NetToysLocalNetworkAccess {
    private let requestsPermissions: Bool

    init(requestsPermissions: Bool) { self.requestsPermissions = requestsPermissions }

    private(set) var state = NetToysLocalNetworkAccessState.checking
    @ObservationIgnored private var browser: NWBrowser?

    func request() {
        guard requestsPermissions else { return }
        browser?.cancel()
        state = .checking
        let browser = NWBrowser(
            for: .bonjour(type: "_macpowertoys-permission._tcp", domain: nil),
            using: .tcp
        )
        let observer = self
        browser.stateUpdateHandler = { browserState in
            Task { @MainActor in observer.update(browserState) }
        }
        self.browser = browser
        browser.start(queue: DispatchQueue(label: "com.surajmandal.macpowertoys.local-network"))
    }

    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func update(_ browserState: NWBrowser.State) {
        switch browserState {
        case .ready:
            finish(.allowed)
        case .waiting(let error), .failed(let error):
            switch error {
            case .dns(let code): finish(.init(dnsErrorCode: code))
            case .posix(let code): finish(.init(posixError: code))
            case .tls, .wifiAware: finish(.unavailable)
            @unknown default: finish(.unavailable)
            }
        case .cancelled:
            break
        case .setup:
            state = .checking
        @unknown default:
            finish(.unavailable)
        }
    }

    private func finish(_ state: NetToysLocalNetworkAccessState) {
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        self.state = state
    }
}

public enum NetToysPage: String, CaseIterable, Identifiable, Sendable {
    case scanner = "IP Scanner"
    case anchor = "SSH Anchor"
    case wifiPriority = "Wi-Fi Priority"
    case history = "Network History"
    case settings = "Settings"
    case howToUse = "How to use"

    public var id: String { rawValue }

    public var pageID: String {
        switch self {
        case .scanner: "scanner"
        case .anchor: "ssh-anchor"
        case .wifiPriority: "wifi"
        case .history: "history"
        case .settings: "settings"
        case .howToUse: "how-to-use"
        }
    }

    var icon: String {
        switch self {
        case .scanner: "dot.radiowaves.left.and.right"
        case .anchor: "link"
        case .history: "clock.arrow.circlepath"
        case .wifiPriority: "wifi"
        case .settings: "gearshape"
        case .howToUse: "questionmark.circle"
        }
    }
}

public struct NetToysWindowView: View {
    private let host: NetToysHost
    @Bindable private var shell: NetToysShell
    @Binding private var enabled: Bool
    private let isTransitioning: Bool
    private let consumePrefill: () -> NetToysScanPrefill?
    @State private var settingsSection = "permissions"
    @State private var scannerModel: NetToysScannerViewModel
    @State private var localNetworkAccess: NetToysLocalNetworkAccess
    @State private var openDevice: String?
    @State private var configuration: NetToysConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pause or safe mode: every automatic action is held.
    private var pausedAll: Bool { configuration.actionsPaused || configuration.safeModeReason != nil }

    public init(host: NetToysHost, shell: NetToysShell, enabled: Binding<Bool>,
                isTransitioning: Bool = false, consumePrefill: @escaping () -> NetToysScanPrefill? = { nil }) {
        self.init(host: host, shell: shell, enabled: enabled, isTransitioning: isTransitioning,
                  consumePrefill: consumePrefill, scannerModel: NetToysScannerViewModel(host: host))
    }

    /// Takes a prepared scanner model, so offscreen renders can use synthetic devices.
    init(host: NetToysHost, shell: NetToysShell, enabled: Binding<Bool>, isTransitioning: Bool = false,
         consumePrefill: @escaping () -> NetToysScanPrefill? = { nil }, scannerModel: NetToysScannerViewModel,
         openDevice: String? = nil, configuration: NetToysConfiguration = NetToysConfiguration()) {
        _configuration = State(initialValue: configuration)
        self.host = host
        self.shell = shell
        _enabled = enabled
        self.isTransitioning = isTransitioning
        self.consumePrefill = consumePrefill
        _scannerModel = State(initialValue: scannerModel)
        _localNetworkAccess = State(initialValue: host.localNetworkAccess)
        _openDevice = State(initialValue: openDevice)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                NetToysSidebar(shell: shell, deviceCount: knownDevices.count) { pauseRow }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                    .background(Dense.content)
                    .environment(shell)
            }
            .background(NetToysTrafficLights())
            .blur(radius: openDevice == nil || reduceMotion ? 0 : 6)
            if let openDevice {
                modalDim.transition(.opacity).onTapGesture { self.openDevice = nil }
                NetToysDeviceModal(model: scannerModel, id: openDevice, paused: pausedAll) { self.openDevice = nil }
                    .transition(.netToysModal(reduceMotion: reduceMotion))
            }
            if shell.paletteVisible {
                Color.clear.contentShape(Rectangle()).onTapGesture { shell.paletteVisible = false }
                NetToysPaletteView(shell: shell) { _ in shell.paletteVisible = false }
                    .shadow(color: .black.opacity(0.22), radius: 30, y: 16)
                    .padding(.top, 90)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: openDevice == nil ? 0.1 : 0.18), value: openDevice)
        .animation(Dense.spring(reduceMotion), value: shell.paletteVisible)
        .ignoresSafeArea()
        .frame(minWidth: 1100, idealWidth: 1280, maxWidth: .infinity, minHeight: 620, idealHeight: 820, maxHeight: .infinity)
        .onePlusDensity(.regular)
        .onePlusLiveUpdates()
        .onePlusFocusPolicy()
        .onePlusAppAppearance()
        .background {
            Group {
                Button("") { shell.selection = "settings" }.keyboardShortcut(",")
                Button("") { shell.paletteVisible.toggle() }.keyboardShortcut("k")
                Button("") { shell.selection = "all-devices" }.keyboardShortcut("1")
                Button("") { shell.selection = "ssh-anchor" }.keyboardShortcut("2")
                Button("") { shell.selection = "wifi-priority" }.keyboardShortcut("3")
                Button("") { shell.selection = "history" }.keyboardShortcut("4")
            }
            .hidden()
        }
        .onChange(of: scannerModel.results.count, initial: true) { shell.devices = knownDevices }
        .onChange(of: shell.deviceRequest) { _, id in
            guard let id else { return }
            shell.deviceRequest = nil
            openDevice = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .netToysRescanRun)) { notification in
            guard let run = notification.object as? NetToysScanRun else { return }
            shell.selection = "all-devices"
            Task { @MainActor in
                await Task.yield()
                NotificationCenter.default.post(name: .netToysStartScan, object: run)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .netToysPrefill)) { notification in
            scannerModel.applyPrefill(consumePrefill() ?? (notification.object as? NetToysScanPrefill))
            shell.selection = "all-devices"
        }
        .onReceive(NotificationCenter.default.publisher(for: .netToysOpenAnchor)) { notification in
            guard let prefill = notification.object as? NetToysAnchorPrefill else { return }
            shell.selection = "ssh-anchor"
            Task { @MainActor in
                await Task.yield()
                NotificationCenter.default.post(name: .netToysApplyAnchorPrefill, object: prefill)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .netToysOpenPage)) { notification in
            guard let requestedPage = notification.object as? NetToysPage else { return }
            shell.selection = requestedPage.selectionID
        }
        .task {
            scannerModel.applyPrefill(consumePrefill())
            localNetworkAccess.request()
            await scannerModel.loadStoredState()
        }
        .task {
            // The menu panel and safe mode change the pause too, so keep reading the saved state.
            while !Task.isCancelled {
                configuration = await Task.detached(priority: .utility) { NetToysConfigurationStore.load() }.value
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .netToysHistoryCleared)) { _ in
            scannerModel.clearRestoredResults()
        }
        .onDisappear { scannerModel.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            localNetworkAccess.request()
        }
    }

    private var modalDim: some View {
        Color(light: .init(white: 0, alpha: 0.16), dark: .init(white: 0, alpha: 0.4))
    }

    private var knownDevices: [NetToysScanResult] { scannerModel.devices(in: .all, from: scannerModel.results) }

    /// Pause and Resume write the saved configuration; Resume also ends safe mode.
    private var pauseRow: some View {
        let safeMode = configuration.safeModeReason != nil
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(safeMode ? "Safe mode is on" : pausedAll ? "All actions paused" : "Pause all actions")
                    .font(.system(size: 12, weight: pausedAll ? .medium : .regular))
                    .foregroundStyle(pausedAll ? Dense.amber : Dense.label)
                Text(pausedAll ? "Click play to resume" : configuration.dryRun ? "Dry run: nothing changes" : "Actions run normally")
                    .font(.system(size: 11)).foregroundStyle(Dense.tertiary)
            }
            .help(configuration.safeModeReason ?? "")
            Spacer(minLength: 0)
            Button {
                if let saved = try? NetToysConfigurationStore.setActionsPaused(!pausedAll) { configuration = saved }
            } label: {
                Image(systemName: pausedAll ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pausedAll ? Color.white : Dense.label)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(pausedAll ? Dense.accent : Dense.field))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pausedAll ? "Resume all actions" : "Pause all actions")
        }
        .padding(.horizontal, 8)
    }

    /// The OnePlus pages reload from disk on each visit, so they rebuild instead of staying mounted.
    static func keepsAlive(_ id: String) -> Bool { NetToysTool.tool(id) != nil && !["ssh-anchor", "history", "wifi-priority"].contains(id) }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .topLeading) {
            NetToysKeptPages(selection: shell.selection, keeps: Self.keepsAlive) { id in
                if let tool = NetToysTool.tool(id) { toolView(tool) }
            }
            if !Self.keepsAlive(shell.selection) {
                if let tool = NetToysTool.tool(shell.selection) {
                    toolView(tool)
                } else {
                    legacyPage.buttonStyle(OnePlusButtonStyle()).onePlusNeutralControls()
                }
            }
        }
    }

    /// One `case` per tool whose view has landed; every other tool shows the shared placeholder page.
    @ViewBuilder
    private func toolView(_ tool: NetToysTool) -> some View {
        switch tool.id {
        case "all-devices":
            NetToysDevicesView(model: scannerModel, scope: .all, paused: pausedAll, openDevice: { openDevice = $0 }) {
                settingsSection = "scanner"
                shell.selection = "settings"
            }
        // Older pages keep their OnePlus layout inside the new shell.
        case "ssh-anchor": NetToysAnchorView(host: host).buttonStyle(OnePlusButtonStyle()).onePlusNeutralControls()
        case "history": NetToysHistoryView(host: host).buttonStyle(OnePlusButtonStyle()).onePlusNeutralControls()
        case "wifi-priority": NetToysWiFiPriorityView().buttonStyle(OnePlusButtonStyle()).onePlusNeutralControls()
        case "ping": NetToysPingView(tool: tool, input: Binding(get: { shell.inputs[tool.id] ?? "" }, set: { shell.inputs[tool.id] = $0 }))
        case "traceroute": NetToysTraceView(tool: tool, input: Binding(get: { shell.inputs[tool.id] ?? "" }, set: { shell.inputs[tool.id] = $0 }))
        case "dns-lookup": NetToysDNSLookupView(tool: tool, input: shell.diagnoseField(tool))
        case "dns-propagation": NetToysDNSPropagationView(tool: tool, input: shell.diagnoseField(tool))
        case "whois": NetToysWhoisView(tool: tool, input: shell.diagnoseField(tool))
        case "port-scan": NetToysPortScanView(tool: tool, input: shell.diagnoseField(tool))
        case "ssl-certificate": NetToysSSLView(tool: tool, input: shell.diagnoseField(tool))
        case "http-check": NetToysHTTPCheckView(tool: tool, input: shell.diagnoseField(tool))
        case "geoip": NetToysGeoIPView(tool: tool, input: shell.diagnoseField(tool))
        case "path-mtu": NetToysPathMTUView(tool: tool, input: shell.diagnoseField(tool))
        case "internet-check": NetToysInternetCheckView(tool: tool, input: shell.diagnoseField(tool))
        case "subnet-calculator": NetToysSubnetView(tool: tool, input: shell.diagnoseField(tool))
        case "uptime-monitor": NetToysUptimeView(tool: tool)
        case "speed-test": NetToysSpeedView(tool: tool)
        case "network-monitor": NetToysTrafficView(tool: tool)
        case "bonjour-browser": NetToysBonjourView(tool: tool)
        case "arp-table": NetToysARPView(tool: tool)
        case "mac-vendor": NetToysMACVendorView(tool: tool, input: toolInput(tool))
        case "my-connection": NetToysMyConnectionView(tool: tool)
        case "ipv6-check": NetToysIPv6View(tool: tool)
        case "clock-check": NetToysClockView(tool: tool, input: toolInput(tool))
        case "wifi-analyzer": NetToysWiFiAnalyzerView(tool: tool)
        case "wifi-signal": NetToysWiFiSignalView(tool: tool)
        default:
            NetToysToolPage(placeholder: tool, input: Binding(get: { shell.inputs[tool.id] ?? "" },
                                                              set: { shell.inputs[tool.id] = $0 }))
                .id(tool.id)
        }
    }

    private func toolInput(_ tool: NetToysTool) -> Binding<String> {
        Binding(get: { shell.inputs[tool.id] ?? "" }, set: { shell.inputs[tool.id] = $0 })
    }

    @ViewBuilder
    private var legacyPage: some View {
        if shell.selection == "how-to-use" {
            howToUsePage
        } else {
            OnePlusPage {
                OnePlusPageHeader(title: "Settings", subtitle: "Permissions, scanner, and safety")
            } tabs: {
                OnePlusTabStrip(tabs: [OnePlusTab("permissions", "Permissions"), OnePlusTab("scanner", "Scanner"),
                                       OnePlusTab("safety", "Safety")],
                                selection: $settingsSection)
            } content: {
                if settingsSection == "scanner" { NetToysScannerSettingsView(model: scannerModel) }
                else if settingsSection == "safety" { NetToysSafetySettingsView() }
                else { NetToysSettingsView(host: host, enabled: $enabled, isTransitioning: isTransitioning) }
            }
        }
    }

    private var howToUsePage: some View {
            OnePlusPage {
                OnePlusPageHeader(title: "How to use", subtitle: "Discover devices and keep your network available")
            } content: {
                ForEach(NetToysManual.sections, id: \.title) { section in
                    howToSection(section.title, section.points.joined(separator: "\n\n"))
                }
                howToSection("Wi-Fi Priority", "Add at least two saved Wi-Fi networks, set their order, and enable failover. macOS manages the final Personal Hotspot fallback.")
                HStack(spacing: OnePlusMetrics.actionSpacing) {
                    Text("Wi-Fi names need Location access. IP scanning needs Local Network access. Settings shows each permission and its recovery action.")
                        .onePlusText(.row, color: OnePlusColor.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Open Settings") {
                        settingsSection = "permissions"
                        shell.selection = "settings"
                    }
                    .buttonStyle(OnePlusButtonStyle(.link))
                }
                .frame(height: OnePlusMetrics.settingRow)
            }
    }

    private func howToSection(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: OnePlusMetrics.actionSpacing) {
            Text(title).onePlusText(.cardTitle)
            ForEach(Array(message.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).onePlusText(.row).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Moves the traffic lights into the sidebar's top row: close button 20 pt from the left edge,
/// centered 26 pt from the top, on the same line as the toolbar title and controls.
private struct NetToysTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> LightsView { LightsView() }
    func updateNSView(_ view: LightsView, context: Context) { view.place() }

    final class LightsView: NSView {
        private static let leading: CGFloat = 20
        private static let centerFromTop: CGFloat = 26
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            place()
        }

        /// Runs after AppKit's own titlebar layout, which resets the buttons.
        func place() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, !window.styleMask.contains(.fullScreen),
                      let close = window.standardWindowButton(.closeButton),
                      let container = close.superview?.superview ?? close.superview, let ancestor = container.superview
                else { return }
                let frame = close.convert(close.bounds, to: nil)
                let dx = Self.leading - frame.minX
                let dy = window.frame.height - Self.centerFromTop - frame.midY
                guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
                container.setFrameOrigin(NSPoint(x: container.frame.minX + dx,
                                                 y: container.frame.minY + (ancestor.isFlipped ? -dy : dy)))
            }
        }
    }
}
