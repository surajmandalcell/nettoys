import AppKit
import NetToysCore
import Observation
import OnePlusUI
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum NetToysResultFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case alive = "Alive"
    case openPorts = "Open Ports"

    var id: String { rawValue }
}

nonisolated enum NetToysExportFormat: String, CaseIterable, Identifiable, Sendable {
    case savedResults = "Sam's NetToys Results"
    case csv = "CSV"
    case text = "Text"
    case xml = "XML"
    case ipPorts = "IP and Port"
    case sql = "SQL"

    var id: String { rawValue }

    var canAppend: Bool {
        switch self {
        case .csv, .text, .ipPorts, .sql: true
        case .savedResults, .xml: false
        }
    }

    var fileExtension: String {
        switch self {
        case .savedResults: "nettoys"
        case .csv: "csv"
        case .text, .ipPorts: "txt"
        case .xml: "xml"
        case .sql: "sql"
        }
    }
}

extension NetToysScanResult {
    nonisolated var sortAddress: UInt32 { address.rawValue }
    nonisolated var statusTitle: String { isReachable ? "Up" : "Down" }
    nonisolated var responseTitle: String { responseMilliseconds.map { String(format: "%.1f", $0) } ?? "" }
    nonisolated var hostnameTitle: String { hostname ?? "" }
    nonisolated var macTitle: String { macAddress ?? (isReachable ? "macOS restricted" : "") }
    nonisolated var vendorTitle: String { vendor ?? "" }
    nonisolated var portsTitle: String { openPorts.map(String.init).joined(separator: ", ") }
    nonisolated var filteredPortsTitle: String { filteredPorts?.map(String.init).joined(separator: ", ") ?? "" }
    nonisolated var ttlTitle: String { ttl.map(String.init) ?? "" }
    nonisolated var packetLossTitle: String {
        packetLossPercent.map { String(format: "%.1f", $0) } ?? ""
    }
    nonisolated var httpServerTitle: String { httpServer ?? "" }
    nonisolated var httpProxyTitle: String { httpProxy ?? "" }
    nonisolated var netBIOSTitle: String { netBIOSName ?? "" }
    nonisolated var customTextTitle: String { customText ?? "" }
    nonisolated var commentTitle: String { comment ?? "" }
}

@Observable
@MainActor
final class NetToysScannerViewModel {
    private static let preferencesKey = "nettoys.scanner.preferences"
    private static let livenessPreferencesKey = "nettoys.scanner.liveness-preferences"
    private static let openersKey = "nettoys.scanner.openers"
    private static let targetKey = "nettoys.scanner.target"
    private static let portKey = "nettoys.scanner.ports"
    private static let filterKey = "nettoys.scanner.filter"
    private static let searchKey = "nettoys.scanner.search"
    private static let sortKey = "nettoys.scanner.sort"
    private static let followsActiveNetworkKey = "nettoys.scanner.follows-active-network"

    private enum SortField: String, Codable {
        case address, status, response, ttl, loss, hostname, mac, vendor
        case netBIOS, openPorts, filteredPorts, httpServer, httpProxy, customText, comment
    }

    private struct SavedSort: Codable {
        let field: SortField
        let order: SortOrder
    }

    var targetInput: String {
        didSet {
            defaults.set(targetInput, forKey: Self.targetKey)
            guard !isApplyingActiveNetwork else { return }
            targetFollowsActiveNetwork = false
            defaults.set(false, forKey: Self.followsActiveNetworkKey)
        }
    }
    var portInput = "22, 80, 443" {
        didSet { defaults.set(portInput, forKey: Self.portKey) }
    }
    private(set) var results: [NetToysScanResult] = []
    private(set) var visibleResults: [NetToysScanResult] = []
    private(set) var aliveResultCount = 0
    private(set) var openPortResultCount = 0
    var filter = NetToysResultFilter.all {
        didSet {
            defaults.set(filter.rawValue, forKey: Self.filterKey)
            refreshVisibleResults()
        }
    }
    var searchText = "" {
        didSet {
            defaults.set(searchText, forKey: Self.searchKey)
            refreshVisibleResults()
        }
    }
    var completed = 0
    var total = 0
    var lastDuration: TimeInterval?
    var lastScanTarget: String?
    var errorMessage: String?
    var isScanning = false
    private(set) var isLoading: Bool
    var isImporting = false
    var isExporting = false
    var timeoutMilliseconds = 750
    /// A ceiling: the scan starts lower and adapts to timeouts.
    var concurrency = 256
    var launchDelayMilliseconds = 0
    var collectPingDetails = false
    var pingProbeCount = 2
    var livenessMethod = NetToysLivenessMethod.tcp
    var pingTimeoutMilliseconds = 750
    var adaptiveTCPTimeout = false
    var scanUnresponsiveHosts = true
    var detectHTTPServer = false
    var detectHTTPProxy = false
    var detectNetBIOS = false
    var customTextEnabled = false
    var customTextPort = 22
    var customTextRequest = ""
    var customTextPattern = ""
    var favoriteTargets: [String] = []
    var annotations: [String: NetToysHostAnnotation] = [:]
    var openers = NetToysOpener.defaults
    var selection = Set<String>()
    /// The last time each address answered, from the saved scan runs and the live scan.
    private(set) var lastSeen: [String: Date] = [:]
    private(set) var lastScanDate: Date?
    var sortOrder = [KeyPathComparator(\NetToysScanResult.sortAddress)] {
        didSet {
            defaults.set(try? JSONEncoder().encode(sortOrder.compactMap(Self.savedSort)), forKey: Self.sortKey)
            refreshVisibleResults()
        }
    }

    private let defaults: UserDefaults
    let host: NetToysHost
    private let scanner: NetToysScanner
    private var scanTask: Task<Void, Never>?
    private var scanIdentifier: UUID?
    private var resultIndices: [String: Int] = [:]
    private var targetFollowsActiveNetwork: Bool
    private var isApplyingActiveNetwork = false
    private var savedAnnotations: [String: NetToysHostAnnotation] = [:]
    private var savedFavoriteTargets: [String] = []

    init(
        archive: NetToysScanArchive? = nil,
        defaults: UserDefaults? = nil,
        host: NetToysHost
    ) {
        self.host = host
        scanner = NetToysScanner()
        let defaults = defaults ?? host.scannerDefaults
        self.defaults = defaults
        isLoading = archive == nil
        let latestRun = archive?.runs.last
        let restoredTarget = defaults.string(forKey: Self.targetKey) ?? latestRun?.target
        targetInput = restoredTarget ?? "192.168.1.0/24"
        targetFollowsActiveNetwork = defaults.object(forKey: Self.followsActiveNetworkKey) as? Bool
            ?? restoredTarget.map(Self.isSingleCIDR) ?? true
        results = latestRun?.results ?? []
        lastDuration = latestRun?.duration
        lastScanDate = latestRun?.date
        lastScanTarget = latestRun?.target
        completed = results.count
        total = results.count
        filter = defaults.string(forKey: Self.filterKey).flatMap(NetToysResultFilter.init(rawValue:)) ?? .all
        searchText = defaults.string(forKey: Self.searchKey) ?? ""
        if let data = defaults.data(forKey: Self.preferencesKey),
           let preferences = try? JSONDecoder().decode(NetToysScannerPreferences.self, from: data) {
            portInput = preferences.portInput
            timeoutMilliseconds = min(max(preferences.timeoutMilliseconds, 100), 5_000)
            concurrency = min(max(preferences.concurrency, 1), 256)
            launchDelayMilliseconds = min(max(preferences.launchDelayMilliseconds, 0), 100)
            collectPingDetails = preferences.collectPingDetails
            pingProbeCount = min(max(preferences.pingProbeCount, 1), 5)
            detectHTTPServer = preferences.detectHTTPServer
            detectHTTPProxy = preferences.detectHTTPProxy
            detectNetBIOS = preferences.detectNetBIOS
            customTextEnabled = preferences.customTextEnabled
            customTextPort = min(max(preferences.customTextPort, 1), 65_535)
            customTextRequest = preferences.customTextRequest
            customTextPattern = preferences.customTextPattern
        }
        portInput = defaults.string(forKey: Self.portKey) ?? portInput
        if let data = defaults.data(forKey: Self.livenessPreferencesKey),
           let preferences = try? JSONDecoder().decode(NetToysLivenessPreferences.self, from: data) {
            livenessMethod = preferences.method
            pingTimeoutMilliseconds = min(max(preferences.pingTimeoutMilliseconds, 100), 5_000)
            adaptiveTCPTimeout = preferences.adaptiveTCPTimeout
            scanUnresponsiveHosts = preferences.scanUnresponsiveHosts
        }
        if let data = defaults.data(forKey: Self.openersKey),
           let saved = try? JSONDecoder().decode([NetToysOpener].self, from: data),
           saved.count <= 20,
           Set(saved.map(\.id)).count == saved.count,
           Set(saved.map {
               $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
           }).count == saved.count,
           saved.allSatisfy({ (try? $0.validate()) != nil }) {
            openers = saved
        }
        if let data = defaults.data(forKey: Self.sortKey),
           let saved = try? JSONDecoder().decode([SavedSort].self, from: data) {
            let restored = saved.map(Self.comparator)
            if !restored.isEmpty { sortOrder = restored }
        }
        if let archive { recordLastSeen(archive) }
        replaceResults(results)
        completed = results.count
        total = results.count
    }

    private func recordLastSeen(_ archive: NetToysScanArchive) {
        for run in archive.runs {
            for result in run.results where result.isReachable { lastSeen[result.id] = run.date }
        }
    }

    /// A device is an address that answered once or that the owner marked. Never-seen range addresses stay out.
    func isKnownDevice(_ result: NetToysScanResult) -> Bool {
        result.isReachable || lastSeen[result.id] != nil || annotations[result.id] != nil
    }

    func applyPrefill(_ prefill: NetToysScanPrefill?) {
        guard let prefill else { return }
        targetInput = prefill.targets
        if let ports = prefill.ports { portInput = ports }
    }

    func loadStoredState() async {
        guard isLoading else { return }
        let (archive, annotations, favorites) = await Task.detached(priority: .utility) {
            (NetToysScannerStore.archive(), NetToysScannerStore.annotations(), NetToysScannerStore.favoriteTargets())
        }.value
        guard !Task.isCancelled, isLoading else { return }
        self.annotations = annotations
        savedAnnotations = annotations
        favoriteTargets = favorites
        savedFavoriteTargets = favorites
        recordLastSeen(archive)
        if let run = archive.runs.last {
            if defaults.string(forKey: Self.targetKey) == nil {
                isApplyingActiveNetwork = true
                targetInput = run.target
                isApplyingActiveNetwork = false
                targetFollowsActiveNetwork = Self.isSingleCIDR(run.target)
            }
            replaceResults(run.results)
            lastDuration = run.duration
            lastScanTarget = run.target
            lastScanDate = run.date
            completed = results.count
            total = results.count
        }
        isLoading = false
    }

    func clearRestoredResults() {
        cancel()
        isLoading = false
        replaceResults([])
        selection.removeAll()
        completed = 0
        total = 0
        lastDuration = nil
        lastScanTarget = nil
    }

    var hasNoResponsiveHosts: Bool {
        !isScanning && !results.isEmpty && aliveResultCount == 0
    }

    var scanResultNotice: String? {
        guard !isScanning, !results.isEmpty, let lastScanTarget else { return nil }
        if lastScanTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            != targetInput.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "Results are from \(lastScanTarget). Scan to refresh."
        }
        return hasNoResponsiveHosts ? "No hosts responded. Check the target and scan again." : nil
    }

    func useActiveNetwork(_ cidr: String) {
        isApplyingActiveNetwork = true
        targetInput = cidr
        isApplyingActiveNetwork = false
        targetFollowsActiveNetwork = true
        defaults.set(true, forKey: Self.followsActiveNetworkKey)
    }

    func updateActiveNetwork(_ network: LocalIPv4Network) {
        guard targetFollowsActiveNetwork else { return }
        useActiveNetwork(network.cidr)
    }

    func targetInputForScan(activeNetwork: LocalIPv4Network?) -> String {
        guard targetFollowsActiveNetwork, let activeNetwork else { return targetInput }
        useActiveNetwork(activeNetwork.cidr)
        return activeNetwork.cidr
    }

    private static func isSingleCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2
            && IPv4Address(String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && UInt8(parts[1]).map { $0 <= 32 } == true
    }

    private static func savedSort(
        _ comparator: KeyPathComparator<NetToysScanResult>
    ) -> SavedSort? {
        let keyPath = comparator.keyPath
        let field: SortField?
        if keyPath == \NetToysScanResult.sortAddress { field = .address }
        else if keyPath == \NetToysScanResult.statusTitle { field = .status }
        else if keyPath == \NetToysScanResult.responseMilliseconds { field = .response }
        else if keyPath == \NetToysScanResult.ttl { field = .ttl }
        else if keyPath == \NetToysScanResult.packetLossPercent { field = .loss }
        else if keyPath == \NetToysScanResult.hostnameTitle { field = .hostname }
        else if keyPath == \NetToysScanResult.macTitle { field = .mac }
        else if keyPath == \NetToysScanResult.vendorTitle { field = .vendor }
        else if keyPath == \NetToysScanResult.netBIOSTitle { field = .netBIOS }
        else if keyPath == \NetToysScanResult.portsTitle { field = .openPorts }
        else if keyPath == \NetToysScanResult.filteredPortsTitle { field = .filteredPorts }
        else if keyPath == \NetToysScanResult.httpServerTitle { field = .httpServer }
        else if keyPath == \NetToysScanResult.httpProxyTitle { field = .httpProxy }
        else if keyPath == \NetToysScanResult.customTextTitle { field = .customText }
        else if keyPath == \NetToysScanResult.commentTitle { field = .comment }
        else { field = nil }
        return field.map { SavedSort(field: $0, order: comparator.order) }
    }

    private static func comparator(
        _ saved: SavedSort
    ) -> KeyPathComparator<NetToysScanResult> {
        switch saved.field {
        case .address: KeyPathComparator(\NetToysScanResult.sortAddress, order: saved.order)
        case .status: KeyPathComparator(\NetToysScanResult.statusTitle, order: saved.order)
        case .response: KeyPathComparator(\NetToysScanResult.responseMilliseconds, order: saved.order)
        case .ttl: KeyPathComparator(\NetToysScanResult.ttl, order: saved.order)
        case .loss: KeyPathComparator(\NetToysScanResult.packetLossPercent, order: saved.order)
        case .hostname: KeyPathComparator(\NetToysScanResult.hostnameTitle, order: saved.order)
        case .mac: KeyPathComparator(\NetToysScanResult.macTitle, order: saved.order)
        case .vendor: KeyPathComparator(\NetToysScanResult.vendorTitle, order: saved.order)
        case .netBIOS: KeyPathComparator(\NetToysScanResult.netBIOSTitle, order: saved.order)
        case .openPorts: KeyPathComparator(\NetToysScanResult.portsTitle, order: saved.order)
        case .filteredPorts: KeyPathComparator(\NetToysScanResult.filteredPortsTitle, order: saved.order)
        case .httpServer: KeyPathComparator(\NetToysScanResult.httpServerTitle, order: saved.order)
        case .httpProxy: KeyPathComparator(\NetToysScanResult.httpProxyTitle, order: saved.order)
        case .customText: KeyPathComparator(\NetToysScanResult.customTextTitle, order: saved.order)
        case .comment: KeyPathComparator(\NetToysScanResult.commentTitle, order: saved.order)
        }
    }

    func savePreferences() {
        let value = NetToysScannerPreferences(
            portInput: portInput,
            timeoutMilliseconds: timeoutMilliseconds,
            concurrency: concurrency,
            launchDelayMilliseconds: launchDelayMilliseconds,
            collectPingDetails: collectPingDetails,
            pingProbeCount: pingProbeCount,
            detectHTTPServer: detectHTTPServer,
            detectHTTPProxy: detectHTTPProxy,
            detectNetBIOS: detectNetBIOS,
            customTextEnabled: customTextEnabled,
            customTextPort: customTextPort,
            customTextRequest: customTextRequest,
            customTextPattern: customTextPattern
        )
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.preferencesKey)
        }
        let liveness = NetToysLivenessPreferences(
            method: livenessMethod,
            pingTimeoutMilliseconds: pingTimeoutMilliseconds,
            adaptiveTCPTimeout: adaptiveTCPTimeout,
            scanUnresponsiveHosts: scanUnresponsiveHosts
        )
        if let data = try? JSONEncoder().encode(liveness) {
            defaults.set(data, forKey: Self.livenessPreferencesKey)
        }
    }

    func saveOpeners(_ proposed: [NetToysOpener]) throws {
        guard proposed.count <= 20 else { throw NetToysOpener.ValidationError.tooManyOpeners }
        try proposed.forEach { try $0.validate() }
        let names = proposed.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count else { throw NetToysOpener.ValidationError.duplicateName }
        var normalized = proposed
        for index in normalized.indices {
            normalized[index].name = normalized[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        openers = normalized
        defaults.set(try JSONEncoder().encode(openers), forKey: Self.openersKey)
    }

    private func refreshVisibleResults() {
        aliveResultCount = results.lazy.filter(\.isReachable).count
        openPortResultCount = results.lazy.filter { !$0.openPorts.isEmpty }.count
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleResults = results.filter { result in
            let includes: Bool
            switch filter {
            case .all: includes = true
            case .alive: includes = result.isReachable
            case .openPorts: includes = !result.openPorts.isEmpty
            }
            guard includes else { return false }
            guard !query.isEmpty else { return true }
            return ([
                result.address.description, result.hostnameTitle, result.macTitle, result.vendorTitle,
                result.portsTitle, result.httpServerTitle, result.httpProxyTitle,
                result.netBIOSTitle, result.customTextTitle, result.commentTitle
            ])
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted(using: sortOrder)
    }

    func start(targets override: [IPv4Address]? = nil) {
        guard !isLoading, !isScanning, !isImporting else { return }
        do {
            var defaultPorts = try PortList.parse(portInput)
            if customTextEnabled {
                let probe = NetToysCustomTextProbe(
                    port: UInt16(customTextPort),
                    request: customTextRequest,
                    responsePattern: customTextPattern
                )
                try probe.validate()
                defaultPorts = Array(Set(defaultPorts + [probe.port])).sorted()
            }
            let followsActiveNetwork = override == nil && targetFollowsActiveNetwork
            errorMessage = nil
            completed = 0
            total = override?.count ?? 0
            isScanning = true
            let identifier = UUID()
            scanIdentifier = identifier
            let started = Date()
            scanTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let sourceTarget: String
                    if let override {
                        sourceTarget = override.map(\.description).joined(separator: ", ")
                    } else {
                        let activeNetwork = followsActiveNetwork
                            ? await Task.detached(priority: .utility) { LocalIPv4Network.active() }.value
                            : nil
                        guard scanIdentifier == identifier else { return }
                        sourceTarget = targetInputForScan(activeNetwork: activeNetwork)
                    }
                    let targets = if let override {
                        override.map { NetToysScanTarget(address: $0, ports: defaultPorts) }
                    } else {
                        try await NetToysTargetResolver.resolve(sourceTarget, defaultPorts: defaultPorts)
                    }
                    guard !targets.isEmpty else {
                        throw NetToysTargetInput.ParseError.invalid(sourceTarget)
                    }
                    guard scanIdentifier == identifier else { return }
                    if override == nil {
                        replaceResults([])
                        selection.removeAll()
                    }
                    lastDuration = nil
                    lastScanTarget = nil
                    total = targets.count
                    let values = await scanner.scan(
                        targets: targets,
                        timeoutMilliseconds: timeoutMilliseconds,
                        concurrency: concurrency,
                        collectPingDetails: collectPingDetails,
                        pingProbeCount: pingProbeCount,
                        livenessMethod: livenessMethod,
                        pingTimeoutMilliseconds: pingTimeoutMilliseconds,
                        adaptiveTCPTimeout: adaptiveTCPTimeout,
                        scanUnresponsiveHosts: scanUnresponsiveHosts,
                        launchDelayMilliseconds: launchDelayMilliseconds,
                        fetchOptions: fetchOptions,
                        progress: { [weak self] completed, total in
                            Task { @MainActor [weak self] in
                                guard self?.scanIdentifier == identifier else { return }
                                self?.completed = completed
                                self?.total = total
                            }
                        },
                        update: { [weak self] result in
                            Task { @MainActor [weak self] in
                                guard self?.scanIdentifier == identifier else { return }
                                self?.applyScanUpdate(result)
                            }
                        }
                    )
                    guard !Task.isCancelled, scanIdentifier == identifier else { return }
                    values.forEach(applyScanUpdate)
                    let duration = Date().timeIntervalSince(started)
                    lastDuration = duration
                    lastScanTarget = sourceTarget
                    lastScanDate = Date()
                    let run = NetToysScanRun(
                        target: sourceTarget,
                        ports: Set(targets.flatMap(\.ports)).sorted(),
                        duration: duration,
                        results: values.map { value in
                            self.resultIndices[value.id].map { self.results[$0] } ?? value
                        }
                    )
                    try await Task.detached(priority: .utility) {
                        try NetToysScannerStore.record(run)
                    }.value
                    guard !Task.isCancelled, scanIdentifier == identifier else { return }
                    isScanning = false
                    scanIdentifier = nil
                    scanTask = nil
                } catch {
                    guard !Task.isCancelled, scanIdentifier == identifier else { return }
                    errorMessage = error.localizedDescription
                    isScanning = false
                    scanIdentifier = nil
                    scanTask = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var fetchOptions: NetToysFetchOptions {
        NetToysFetchOptions(
            detectHTTPServer: detectHTTPServer,
            detectHTTPProxy: detectHTTPProxy,
            detectNetBIOS: detectNetBIOS,
            customTextProbe: customTextEnabled && !customTextPattern.isEmpty
                ? NetToysCustomTextProbe(
                    port: UInt16(customTextPort),
                    request: customTextRequest,
                    responsePattern: customTextPattern
                )
                : nil
        )
    }

    func cancel() {
        scanIdentifier = nil
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func importTargets() {
        guard !isLoading, !isScanning, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task { [weak self] in
            do {
                let targets = try await Task.detached(priority: .userInitiated) {
                    try NetToysFileImport.targets(from: url)
                }.value
                self?.targetInput = targets
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isImporting = false
        }
    }

    func export(_ format: NetToysExportFormat, rows: [NetToysScanResult]) {
        guard !rows.isEmpty, !isExporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sam's NetToys Scan.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    switch format {
                    case .savedResults:
                        try NetToysScanExport.savedResults(rows).write(to: url, options: .atomic)
                    case .csv:
                        try NetToysScanExport.csv(rows).write(to: url, atomically: true, encoding: .utf8)
                    case .text:
                        try NetToysScanExport.text(rows).write(to: url, atomically: true, encoding: .utf8)
                    case .xml:
                        try NetToysScanExport.xml(rows).write(to: url, atomically: true, encoding: .utf8)
                    case .ipPorts:
                        try NetToysScanExport.ipPorts(rows).write(to: url, atomically: true, encoding: .utf8)
                    case .sql:
                        try NetToysScanExport.sql(rows).write(to: url, atomically: true, encoding: .utf8)
                    }
                }.value
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isExporting = false
        }
    }

    func append(_ format: NetToysExportFormat, rows: [NetToysScanResult]) {
        guard format.canAppend, !rows.isEmpty, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Append"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    let isEmpty = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == 0
                    let value = switch format {
                    case .csv: NetToysScanExport.csv(rows, includeHeader: isEmpty)
                    case .text: NetToysScanExport.text(rows)
                    case .ipPorts: NetToysScanExport.ipPorts(rows)
                    case .sql: NetToysScanExport.sql(rows, includeSchema: isEmpty)
                    case .savedResults, .xml: ""
                    }
                    try NetToysScanExport.append(value, to: url)
                }.value
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isExporting = false
        }
    }

    func loadResults() {
        guard !isLoading, !isScanning, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nettoys") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task { [weak self] in
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    let data = try NetToysFileImport.read(
                        url,
                        maximumBytes: NetToysFileImport.resultsByteLimit
                    )
                    return try NetToysScanImport.savedResults(data)
                }.value
                self?.replaceResults(results)
                self?.lastDuration = nil
                self?.lastScanTarget = nil
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isImporting = false
        }
    }

    func removeResults(ids: Set<String>) {
        results.removeAll { ids.contains($0.id) }
        rebuildResultIndices()
        refreshVisibleResults()
    }

    func toggleFavoriteTarget() {
        let value = targetInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if favoriteTargets.contains(value) {
            favoriteTargets.removeAll { $0 == value }
        } else {
            favoriteTargets.append(value)
        }
        do {
            favoriteTargets = try NetToysScannerStore.saveFavoriteTargets(favoriteTargets, since: savedFavoriteTargets)
            savedFavoriteTargets = favoriteTargets
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateRandomTargets(cidr: String, count: Int) {
        do {
            targetInput = try IPv4Targets.random(in: cidr, count: count)
                .map(\.description)
                .joined(separator: ", ")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func annotation(for address: String) -> NetToysHostAnnotation {
        annotations[address] ?? NetToysHostAnnotation(
            comment: resultIndices[address].flatMap { results[$0].comment } ?? ""
        )
    }

    func saveAnnotation(_ annotation: NetToysHostAnnotation, for address: String) {
        if annotation.comment.isEmpty, !annotation.isFavorite {
            annotations[address] = nil
        } else {
            annotations[address] = annotation
        }
        if let index = resultIndices[address] {
            results[index].comment = annotation.comment.isEmpty ? nil : annotation.comment
        }
        refreshVisibleResults()
        do {
            annotations = try NetToysScannerStore.saveAnnotations(annotations, since: savedAnnotations)
            savedAnnotations = annotations
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyScanUpdate(_ update: NetToysScanResult) {
        var update = update
        if update.isReachable { lastSeen[update.id] = Date() }
        if let comment = annotations[update.id]?.comment, !comment.isEmpty {
            update.comment = comment
        }
        if let index = resultIndices[update.id] {
            if update.comment == nil { update.comment = results[index].comment }
            results[index] = update
        } else {
            resultIndices[update.id] = results.endIndex
            results.append(update)
        }
        refreshVisibleResults()
    }

    private func replaceResults(_ values: [NetToysScanResult]) {
        var seen = Set<String>()
        results = values.filter { seen.insert($0.id).inserted }
        rebuildResultIndices()
        for index in results.indices {
            if let comment = annotations[results[index].id]?.comment, !comment.isEmpty {
                results[index].comment = comment
            }
        }
        refreshVisibleResults()
    }

    private func rebuildResultIndices() {
        resultIndices = Dictionary(uniqueKeysWithValues: results.indices.map { (results[$0].id, $0) })
    }

}

struct NetToysScannerSettingsView: View {
    @Bindable var model: NetToysScannerViewModel
    @State private var errorMessage: String?
    @State private var openers: [NetToysOpener]
    @State private var pendingOpenerRemoval: UUID?
    @State private var confirmRestore = false

    init(model: NetToysScannerViewModel) {
        self.model = model
        _openers = State(initialValue: model.openers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OnePlusMetrics.cardGap) {
                    settingsSection("Scan Engine") {
                        stepper("TCP timeout", value: $model.timeoutMilliseconds, range: 100...5_000, step: 100, unit: "ms")
                        stepper("Max parallel connections", value: $model.concurrency, range: 1...256)
                        stepper("Launch delay", value: $model.launchDelayMilliseconds, range: 0...100, step: 5, unit: "ms")
                    }

                    settingsSection("Host Detection") {
                        OnePlusSettingRow("Liveness", controlWidth: OnePlusMetrics.wideControlColumn) {
                            OnePlusSelect(choices: NetToysLivenessMethod.allCases.map { ($0, $0.rawValue) },
                                          selection: $model.livenessMethod, width: OnePlusMetrics.wideControlColumn,
                                          accessibilityLabel: "Liveness")
                        }
                        settingsToggle("Use response-based TCP timeout", isOn: $model.adaptiveTCPTimeout)
                        if model.livenessMethod == .icmpAndTCP {
                            settingsToggle("Scan hosts that do not answer ICMP", isOn: $model.scanUnresponsiveHosts)
                        }
                        settingsToggle("Collect ICMP TTL and packet loss", isOn: $model.collectPingDetails)
                        if model.collectPingDetails || model.livenessMethod == .icmpAndTCP || model.adaptiveTCPTimeout {
                            stepper("ICMP timeout", value: $model.pingTimeoutMilliseconds, range: 100...5_000, step: 100, unit: "ms")
                            stepper("ICMP probes", value: $model.pingProbeCount, range: 1...5)
                        }
                    }

                    settingsSection("Protocol Fetchers") {
                        settingsToggle("Detect HTTP servers", isOn: $model.detectHTTPServer)
                        settingsToggle("Detect HTTP proxies", isOn: $model.detectHTTPProxy)
                        settingsToggle("Read NetBIOS names", isOn: $model.detectNetBIOS)
                        settingsToggle("Use custom text probe", isOn: $model.customTextEnabled)
                        if model.customTextEnabled {
                            stepper("Custom port", value: $model.customTextPort, range: 1...65_535)
                            HStack(alignment: .top, spacing: OnePlusMetrics.cardGap) {
                                Text("Request").onePlusText(.row).frame(maxWidth: .infinity, alignment: .leading)
                                OnePlusTextEditor("Request", text: $model.customTextRequest)
                                    .frame(width: OnePlusMetrics.controlColumn * 3, height: OnePlusMetrics.controlHeight * 3)
                            }.padding(OnePlusMetrics.cardPadding)
                            OnePlusSettingRow("Response regular expression", controlWidth: OnePlusMetrics.controlColumn * 3) {
                                OnePlusTextField("Response regular expression", text: $model.customTextPattern)
                            }
                        }
                    }

                    settingsSection("Openers") {
                        Grid(alignment: .leading, horizontalSpacing: OnePlusMetrics.actionSpacing,
                             verticalSpacing: OnePlusMetrics.actionSpacing) {
                            GridRow {
                                Text("Name")
                                Text("URL template")
                                Text("Port")
                                Color.clear.frame(width: OnePlusMetrics.controlHeight)
                            }
                            .onePlusText(.tableHeader)

                            ForEach($openers) { $opener in
                                GridRow {
                                    OnePlusTextField("Name", text: $opener.name)
                                        .frame(width: OnePlusMetrics.controlColumn)
                                    OnePlusTextField("URL template", text: $opener.urlTemplate)
                                        .help("Use {ip}, {hostname}, and {port}. Sam's NetToys shows a preview before opening a URL.")
                                    OnePlusStepperField("Port", value: $opener.requiredPort,
                                                        in: 1...65_535).frame(width: OnePlusMetrics.controlColumn)
                                    Button(role: .destructive) {
                                        pendingOpenerRemoval = opener.id
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(OnePlusButtonStyle(.icon))
                                    .help("Delete \(opener.name) opener")
                                    .accessibilityLabel("Delete \(opener.name) opener")
                                }
                            }
                        }
                        .padding(OnePlusMetrics.cardPadding)

                        HStack {
                            Button("Add Opener") {
                                guard openers.count < 20 else { return }
                                openers.append(NetToysOpener(
                                    name: "New Opener",
                                    urlTemplate: "http://{ip}:{port}/",
                                    requiredPort: 80
                                ))
                            }
                            Button("Restore Defaults") { confirmRestore = true }
                        }
                        .padding(.horizontal, OnePlusMetrics.cardPadding)
                    }
            if let errorMessage { OnePlusBanner(errorMessage, tone: .error) }
        }
        .onDisappear { model.savePreferences() }
        .onChange(of: openers) { saveOpeners() }
        .onChange(of: model.livenessMethod) { model.savePreferences() }
        .onChange(of: model.customTextRequest) { model.savePreferences() }
        .onChange(of: model.customTextPattern) { model.savePreferences() }
        .confirmationDialog("Remove this opener?", isPresented: Binding(
            get: { pendingOpenerRemoval != nil }, set: { if !$0 { pendingOpenerRemoval = nil } }
        )) {
            Button("Remove opener", role: .destructive) {
                openers.removeAll { $0.id == pendingOpenerRemoval }
                pendingOpenerRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingOpenerRemoval = nil }
        }
        .confirmationDialog("Restore default openers?", isPresented: $confirmRestore) {
            Button("Restore defaults", role: .destructive) { openers = NetToysOpener.defaults }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This replaces your current opener list.") }
    }

    private func saveOpeners() {
        do {
            try model.saveOpeners(openers)
            model.savePreferences()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        OnePlusCard {
            OnePlusCardHeader(title)
            content()
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        OnePlusSettingRow(title) {
            Toggle(title, isOn: Binding(get: { isOn.wrappedValue }, set: {
                isOn.wrappedValue = $0
                model.savePreferences()
            })).labelsHidden().toggleStyle(OnePlusSwitchStyle())
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                         step: Int = 1, unit: String? = nil) -> some View {
        OnePlusSettingRow(title) {
            OnePlusStepperField(title, value: Binding(get: { value.wrappedValue }, set: {
                value.wrappedValue = $0
                model.savePreferences()
            }), in: range, step: step, unit: unit)
        }
    }
}

struct NetToysOpenerPreview: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
}

struct NetToysOpenerPreviewSheet: View {
    let preview: NetToysOpenerPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OnePlusSheet("Open with \(preview.name)?", close: { dismiss() }) {
            VStack(alignment: .leading, spacing: OnePlusMetrics.cardGap) {
            Text("Review the complete URL before another app opens it.")
                .onePlusText(.row).foregroundStyle(OnePlusColor.secondary)
            OnePlusCard {
            Text(preview.url.absoluteString)
                .onePlusText(.mono)
                .textSelection(.enabled)
                .padding(OnePlusMetrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        } footer: {
                Button("Cancel") { dismiss() }.buttonStyle(OnePlusButtonStyle(.ghost))
                Button("Open") {
                    NSWorkspace.shared.open(preview.url)
                    dismiss()
                }
                .buttonStyle(OnePlusButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct NetToysRandomTargetsView: View {
    @Bindable var model: NetToysScannerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var cidr = LocalIPv4Network.active()?.cidr ?? "192.168.1.0/24"
    @State private var count = 32

    var body: some View {
        OnePlusSheet("Random targets", close: { dismiss() }) {
            VStack(alignment: .leading, spacing: OnePlusMetrics.cardGap) {
            Text("Generate unique usable IPv4 addresses inside one CIDR block.")
                .onePlusText(.row).foregroundStyle(OnePlusColor.secondary)
            OnePlusCard {
                OnePlusSettingRow("CIDR", controlWidth: OnePlusMetrics.wideControlColumn) {
                    OnePlusTextField("CIDR", text: $cidr)
                }
                OnePlusSettingRow("Address count") {
                    OnePlusStepperField("Address count", value: $count, in: 1...1_024)
                }
            }
            }
        } footer: {
                Button("Cancel") { dismiss() }.buttonStyle(OnePlusButtonStyle(.ghost))
                Button("Generate") {
                    model.generateRandomTargets(cidr: cidr, count: count)
                    dismiss()
                }
                .buttonStyle(OnePlusButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
    }
}

