import Foundation

nonisolated enum SSHAnchorVerifiedUpdate {
    enum UpdateError: LocalizedError, Equatable {
        case candidateProbeFailed
        case postWriteProbeFailed
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .candidateProbeFailed:
                "The recovered address did not pass its confirmation probe."
            case .postWriteProbeFailed:
                "The recovered address stopped responding, so SSH Anchor restored the original address."
            case .rollbackFailed:
                "The recovered address failed verification, and SSH Anchor could not restore the original address."
            }
        }
    }

    static func apply(
        original: SSHAnchorConfiguration,
        recovered: SSHAnchorConfiguration,
        configURL: URL,
        backupDirectory: URL,
        verify: @escaping @Sendable (String, UInt16) async -> Bool,
        commit: @escaping @Sendable () throws -> Void
    ) async throws {
        guard await verify(recovered.hostName, recovered.port) else {
            throw UpdateError.candidateProbeFailed
        }
        _ = try SSHConfigFileUpdater.update(
            configURL: configURL,
            backupDirectory: backupDirectory,
            hostAlias: original.hostAlias,
            expectedHostName: original.hostName,
            newHostName: recovered.hostName
        )
        do {
            guard await verify(recovered.hostName, recovered.port) else {
                throw UpdateError.postWriteProbeFailed
            }
            try commit()
        } catch {
            do {
                _ = try SSHConfigFileUpdater.update(
                    configURL: configURL,
                    backupDirectory: backupDirectory,
                    hostAlias: original.hostAlias,
                    expectedHostName: recovered.hostName,
                    newHostName: original.hostName
                )
            } catch {
                throw UpdateError.rollbackFailed
            }
            throw error
        }
    }
}

public actor NetToysHelperRuntime {
    private let scanner: NetToysScanner
    private let owner: NetToysHostID
    private var recoveryFailures: [UUID: Int] = [:]
    private var nextRecovery: [UUID: Date] = [:]
    private var routeMonitors: [UUID: SSHAnchorRouteMonitor] = [:]
    private var nextTailscaleAttempt: [UUID: Date] = [:]
    private var policyPreparer = SSHPolicyPreparer()
    private var historyRecorder = NetworkTransitionRecorder()
    private var lastNetworkCheck: TimeInterval?
    private var sleepDetector = SleepDetector()
    private var networkSnapshot: NetworkRuntimeSnapshot?
    private var currentStatuses: [SSHAnchorStatus] = []
    private var ssidAccess: NetToysSSIDAccessState?
    private var wifiFailoverMonitor = WiFiFailoverMonitor()
    private var wifiFailoverStatus: WiFiFailoverStatus?
    private var lastWrittenStatus: NetToysHelperStatus?
    private var configurationStamp: Date?
    private var cachedConfiguration = NetToysConfiguration()
    private static let heartbeatRefresh: TimeInterval = 20

    private let paths: NetToysRuntimePaths
    private var nextSnapshotCheck = Date.distantPast
    private var nextLogPrune = Date.distantPast
    private var nextHomeCheck: [UUID: Date] = [:]
    private var gate: NetToysActionGate
    /// Monotonic seconds; wall-clock jumps never shorten a wait.
    private let uptime: @Sendable () -> TimeInterval
    private let notify: @Sendable (NetToysAlert) -> Void
    private var dnsCheck: NetToysDNSCheck?
    private var pendingLatency: [String: [NetToysLatencySample]] = [:]
    private var lastLatencyFlush: TimeInterval?
    private var internetPresence = NetToysPresence()
    private var devicePresence: [String: NetToysPresence] = [:]
    /// Watched port states from the last check, per device, to alert on a change.
    private var portStates: [String: [UInt16: Bool]] = [:]

    public init(owner: NetToysHostID, paths: NetToysRuntimePaths = .standard,
                notify: @escaping @Sendable (NetToysAlert) -> Void = NetToysNotifier.post) {
        self.owner = owner
        self.paths = paths
        self.notify = notify
        scanner = NetToysScanner()
        gate = NetToysActionGate(log: NetToysActionLog(url: paths.actionLog))
        uptime = { ProcessInfo.processInfo.systemUptime }
    }

    /// Runs an automatic change through pause, safe mode, dry run, and the action log.
    /// Throws `ActionHeld` when nothing may change.
    private func perform(_ kind: NetToysActionKind, _ summary: String, undo: NetToysUndo? = nil,
                         _ body: () async throws -> Void) async throws {
        guard gate.allows(kind, summary, undo: undo, settings: cachedConfiguration) else {
            throw ActionHeld(dryRun: cachedConfiguration.dryRun && !NetToysActionGate.isHeld(cachedConfiguration))
        }
        do {
            try await body()
            _ = gate.finish(kind, summary, undo: undo, error: nil, at: uptime())
        } catch {
            if let reason = gate.finish(kind, summary, error: error, at: uptime()) { enterSafeMode(reason) }
            throw error
        }
    }

    struct ActionHeld: LocalizedError {
        let dryRun: Bool
        var errorDescription: String? {
            dryRun ? "Dry run: the change is in the action log and nothing changed." : "Automatic actions are paused."
        }
    }

    nonisolated static func localSwitchCandidate(
        _ candidate: SSHAnchorConfiguration?,
        routeAction: SSHAnchorRouteAction
    ) -> SSHAnchorConfiguration? {
        routeAction == .useLocal ? candidate : nil
    }

    public func setSSIDAccess(_ state: NetToysSSIDAccessState) async {
        ssidAccess = state
        if state == .allowed { await checkNetwork(NetToysConfigurationStore.load()) }
        writeStatus()
    }

    public func run() async {
        let heartbeat = Task { await heartbeatLoop() }
        defer { heartbeat.cancel() }
        SSHConfigFileUpdater.removeStaleTemporaryFiles(configURL: paths.sshConfig)
        saveStatus([])
        while !Task.isCancelled {
            let configuration = currentConfiguration()
            guard !configuration.backgroundRequests.isEmpty else { return }
            await tick(configuration)
            try? await Task.sleep(for: .seconds(configuration.probeInterval))
        }
    }

    /// Decodes the configuration only after its file changes.
    private func currentConfiguration() -> NetToysConfiguration {
        let stamp = NetToysConfigurationStore.modificationDate(NetToysPaths.configuration)
        if stamp == nil || stamp != configurationStamp {
            cachedConfiguration = NetToysConfigurationStore.load()
            configurationStamp = stamp
        }
        return cachedConfiguration
    }

    private func tick(_ configuration: NetToysConfiguration) async {
        let activeAnchorIDs = Set(configuration.anchors.map(\.id))
        recoveryFailures = recoveryFailures.filter { activeAnchorIDs.contains($0.key) }
        nextRecovery = nextRecovery.filter { activeAnchorIDs.contains($0.key) }
        routeMonitors = routeMonitors.filter { activeAnchorIDs.contains($0.key) }
        nextTailscaleAttempt = nextTailscaleAttempt.filter { activeAnchorIDs.contains($0.key) }
        policyPreparer.keep(activeAnchorIDs)
        if !configuration.anchors.isEmpty, Date() >= nextSnapshotCheck {
            nextSnapshotCheck = Date().addingTimeInterval(3_600)
            NetToysSSHBackups.snapshotIfDue(configURL: paths.sshConfig, in: paths.backups)
        }
        if Date() >= nextLogPrune {
            nextLogPrune = Date().addingTimeInterval(86_400)
            try? gate.log.prune()
        }

        var statuses: [SSHAnchorStatus] = []
        for anchor in configuration.anchors {
            statuses.append(
                configuration.sshAnchorEnabled
                    ? await check(anchor)
                    : status(anchor, .idle)
            )
        }
        let now = uptime()
        if sleepDetector.didWake(wall: Date(), uptime: now) {
            wifiFailoverMonitor.didWake(at: now, wait: configuration.wifiPriority.waitAfterWake)
        }
        switch NetToysFailoverRequest.take(from: paths.failoverRequest) {
        case .joinNow:
            wifiFailoverMonitor.requestJoinNow()
            lastNetworkCheck = nil
        case .stay:
            wifiFailoverMonitor.stay()
            lastNetworkCheck = nil
        case nil: break
        }
        if !configuration.wifiPriority.isEnabled {
            wifiFailoverMonitor = WiFiFailoverMonitor()
            wifiFailoverStatus = nil
        }
        // The background network check runs every 30 s, every 60 s on battery.
        let networkInterval: TimeInterval = PowerSource.isOnBattery() ? 60 : 30
        if lastNetworkCheck.map({ now - $0 >= networkInterval }) ?? true {
            lastNetworkCheck = now
            await checkNetwork(configuration)
            await checkDevices(record: configuration.recordsNetworkHistory)
            if lastLatencyFlush.map({ now - $0 >= 120 }) ?? true {
                lastLatencyFlush = now
                if (try? NetToysLatencyStore.append(pendingLatency, to: paths.latency)) != nil { pendingLatency = [:] }
            }
        }
        currentStatuses = statuses
    }

    /// Pings the watched and favorite devices: latency samples, offline and online alerts, and port changes.
    private func checkDevices(record: Bool) async {
        let watches = NetToysDeviceWatchStore.load(from: paths.deviceWatch)
        let favorites = NetToysScannerStore.annotations(at: paths.data.appendingPathComponent("scanner-annotations.json"))
            .filter(\.value.isFavorite).keys
        let ids = Set(watches.keys).union(favorites).sorted().prefix(32).compactMap(IPv4Address.init)
        let kept = Set(ids.map(\.description))
        devicePresence = devicePresence.filter { kept.contains($0.key) }
        portStates = portStates.filter { kept.contains($0.key) }
        let checks = await withTaskGroup(of: (String, Double?, [UInt16: Bool]).self) { group in
            for address in ids {
                let ports = watches[address.description]?.ports ?? []
                group.addTask {
                    async let ping = PingProbe.check(address: address, count: 1, timeoutMilliseconds: 1_000)
                    var states: [UInt16: Bool] = [:]
                    for port in ports {
                        states[port] = await TCPPortProbe.check(host: address.description, port: port,
                                                                timeoutMilliseconds: 900).state == .open
                    }
                    return (address.description, await ping?.averageMilliseconds, states)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let date = Date()
        var alerts: [(String, (String) -> NetToysAlert)] = []
        for (id, milliseconds, ports) in checks {
            let up = milliseconds != nil || ports.values.contains(true)
            if record { pendingLatency[id, default: []].append(NetToysLatencySample(date: date, milliseconds: milliseconds)) }
            let watch = watches[id] ?? NetToysDeviceWatch()
            switch devicePresence[id, default: NetToysPresence()].observe(up: up, at: date) {
            case .down where watch.notifyOffline:
                alerts.append((id, { NetToysAlert(title: "\($0) is offline", body: "It stopped answering at \(id).") }))
            case .back(let after) where watch.notifyOnline:
                alerts.append((id, { NetToysAlert(title: "\($0) is back online",
                                                   body: "It was offline for \(NetToysDuration.text(after)).") }))
            default: break
            }
            // A device that is down closes every port; only compare ports while it answers.
            guard up else { continue }
            let before = portStates[id] ?? [:]
            portStates[id] = ports
            for (port, open) in ports.sorted(by: { $0.key < $1.key }) {
                guard let was = before[port], was != open else { continue }
                alerts.append((id, { NetToysAlert(title: "\($0): port \(port) \(open ? "opened" : "closed")",
                                                   body: "Port \(port) on \(id) is \(open ? "open" : "closed") now.") }))
            }
        }
        guard !alerts.isEmpty else { return }
        // Names come from the scan archive, read only when an alert fires.
        let latest = NetToysScannerStore.archive().runs.last?.results ?? []
        for (id, make) in alerts {
            let name = latest.first { $0.id == id }.map(NetToysAlert.deviceName) ?? id
            notify(make(name))
        }
    }

    private func check(_ configuredAnchor: SSHAnchorConfiguration) async -> SSHAnchorStatus {
        guard configuredAnchor.isEnabled else { return status(configuredAnchor, .idle) }
        if NetToysActionGate.isHeld(cachedConfiguration) {
            let open = await TCPPortProbe.check(host: configuredAnchor.hostName, port: configuredAnchor.port,
                                                timeoutMilliseconds: 900).state == .open
            return status(configuredAnchor, open ? .healthy : .unavailable, open ? nil : "Automatic actions are paused.")
        }
        do {
            try prepareHostKeyPolicy(configuredAnchor)
        } catch {
            return status(configuredAnchor, .error, error.localizedDescription)
        }
        let anchor = synchronizedAnchor(configuredAnchor)
        if anchor.route == .tailscale { return await checkTailscale(anchor) }
        let probe = await TCPPortProbe.check(host: anchor.hostName, port: anchor.port, timeoutMilliseconds: 900)
        var routeMonitor = routeMonitors[anchor.id] ?? SSHAnchorRouteMonitor()
        let routeAction = routeMonitor.observe(
            route: .local,
            localIsOpen: probe.state == .open,
            at: Date()
        )
        routeMonitors[anchor.id] = routeMonitor
        if probe.state == .open {
            recoveryFailures[anchor.id] = nil
            nextRecovery[anchor.id] = nil
            nextTailscaleAttempt[anchor.id] = nil
            await learnHomeNetwork(anchor)
            return status(anchor, .healthy)
        }
        if anchor.tailscaleFallback?.isEnabled == true,
           routeAction == .useTailscale,
           nextTailscaleAttempt[anchor.id].map({ $0 <= Date() }) ?? true {
            return await switchToTailscale(anchor)
        }
        if let next = nextRecovery[anchor.id], next > Date() {
            return status(anchor, .unavailable, "The port is unavailable. The next local scan is scheduled.")
        }
        return await recover(anchor)
    }

    private func checkTailscale(_ anchor: SSHAnchorConfiguration) async -> SSHAnchorStatus {
        let tailscaleProbe = await TCPPortProbe.check(
            host: anchor.hostName,
            port: anchor.port,
            timeoutMilliseconds: 900
        )
        let date = Date()
        var routeMonitor = routeMonitors[anchor.id] ?? SSHAnchorRouteMonitor()
        var recovered: SSHAnchorConfiguration?
        var localIsOpen = false

        if let localHostName = anchor.localHostName,
           let network = LocalIPv4Network.active(),
           network.contains(localHostName) {
            localIsOpen = await TCPPortProbe.check(
                host: localHostName,
                port: anchor.port,
                timeoutMilliseconds: 900
            ).state == .open
        }

        var action = routeMonitor.observe(
            route: .tailscale,
            localIsOpen: localIsOpen,
            at: date
        )
        if localIsOpen,
           action == .useLocal,
           let localHostName = anchor.localHostName {
            recovered = await verifiedLocalCandidate(anchor, hostName: localHostName)
            if recovered == nil {
                _ = routeMonitor.observe(route: .tailscale, localIsOpen: false, at: date)
            }
        }

        if recovered == nil,
           !localIsOpen,
           nextRecovery[anchor.id].map({ $0 <= date }) ?? true {
            recovered = await discoverLocalCandidate(anchor)
            if var discovered = recovered {
                var metadata = anchor
                metadata.localHostName = discovered.hostName
                saveAnchorMetadata(metadata, expectedHostName: anchor.hostName)
                discovered.localHostName = discovered.hostName
                recovered = discovered
                action = routeMonitor.observe(route: .tailscale, localIsOpen: true, at: date)
            }
        }
        routeMonitors[anchor.id] = routeMonitor

        if let recovered = Self.localSwitchCandidate(recovered, routeAction: action) {
            return await switchToLocal(anchor, recovered: recovered)
        }
        if tailscaleProbe.state == .open {
            let message = anchor.tailscaleFallback?.isEnabled == true
                ? "Using Tailscale while the helper confirms the local connection."
                : "Tailscale fallback is off. Waiting for the local connection."
            return status(anchor, .fallback, message)
        }
        if nextTailscaleAttempt[anchor.id].map({ $0 <= date }) ?? true {
            return await switchToTailscale(anchor)
        }
        return status(anchor, .unavailable, "Neither the local nor Tailscale endpoint is reachable.")
    }

    private func switchToTailscale(_ anchor: SSHAnchorConfiguration) async -> SSHAnchorStatus {
        guard let fallback = anchor.tailscaleFallback else {
            return status(anchor, .unavailable)
        }
        do {
            let peers = try await TailscalePeerCatalog.load()
            guard let endpoint = TailscalePeerCatalog.endpoint(
                nodeID: fallback.nodeID,
                peers: peers,
                isEnabled: fallback.isEnabled
            ) else {
                throw TailscalePeerCatalog.CatalogError.peerNotFound
            }
            var recovered = anchor
            recovered.localHostName = anchor.route == .local ? anchor.hostName : anchor.localHostName
            recovered.hostName = endpoint.ipAddress
            recovered.tailscaleFallback = endpoint
            try await applyVerifiedChange(original: anchor, recovered: recovered)
            var routeMonitor = routeMonitors[anchor.id] ?? SSHAnchorRouteMonitor()
            routeMonitor.didSwitch(to: .tailscale, at: Date())
            routeMonitors[anchor.id] = routeMonitor
            recoveryFailures[anchor.id] = nil
            nextRecovery[anchor.id] = nil
            nextTailscaleAttempt[anchor.id] = nil
            return status(recovered, .fallback, "The local endpoint is unavailable. Using Tailscale.")
        } catch {
            nextTailscaleAttempt[anchor.id] = Date().addingTimeInterval(30)
            return status(anchor, .fallbackUnavailable, error.localizedDescription)
        }
    }

    private func switchToLocal(
        _ anchor: SSHAnchorConfiguration,
        recovered: SSHAnchorConfiguration
    ) async -> SSHAnchorStatus {
        var local = recovered
        local.localHostName = local.hostName
        local.tailscaleFallback = anchor.tailscaleFallback
        do {
            try await applyVerifiedChange(original: anchor, recovered: local)
            var routeMonitor = routeMonitors[anchor.id] ?? SSHAnchorRouteMonitor()
            routeMonitor.didSwitch(to: .local, at: Date())
            routeMonitors[anchor.id] = routeMonitor
            recoveryFailures[anchor.id] = nil
            nextRecovery[anchor.id] = nil
            nextTailscaleAttempt[anchor.id] = nil
            return status(local, .recovered, "The local connection is back. Tailscale is on standby.")
        } catch {
            scheduleRetry(for: anchor.id)
            return status(anchor, .error, error.localizedDescription)
        }
    }

    private func recover(_ anchor: SSHAnchorConfiguration) async -> SSHAnchorStatus {
        guard let network = await homeNetwork(for: anchor) else {
            scheduleRetry(for: anchor.id)
            return status(anchor, .unavailable, Self.awayFromHomeMessage(anchor))
        }
        let targets: [IPv4Address]
        do {
            targets = try network.targets(limit: 1_024)
        } catch {
            scheduleRetry(for: anchor.id)
            return status(anchor, .error, error.localizedDescription)
        }
        saveStatus([status(anchor, .scanning, "Searching \(network.cidr) on port \(anchor.port).")])
        let results = await scanner.scan(
            targets: targets,
            ports: [anchor.port],
            timeoutMilliseconds: 600
        )
        let move = SSHAnchorRecovery.resolve(anchor: anchor, scanResults: results)
        guard var recovered = await prove(move, original: anchor) else {
            scheduleRetry(for: anchor.id)
            return status(anchor, .notFound, move == nil
                ? "No unique device matched this anchor."
                : "A device matched by name, but neither its MAC address nor its SSH host key is known. The config is unchanged.")
        }
        recovered.localHostName = recovered.hostName
        if recovered.hostName == anchor.hostName {
            recoveryFailures[anchor.id] = nil
            nextRecovery[anchor.id] = nil
            return status(recovered, .healthy)
        }
        do {
            try await applyVerifiedChange(original: anchor, recovered: recovered)
            recoveryFailures[anchor.id] = nil
            nextRecovery[anchor.id] = nil
            return status(recovered, .recovered, "Updated only HostName in ~/.ssh/config.")
        } catch {
            scheduleRetry(for: anchor.id)
            return status(anchor, .error, error.localizedDescription)
        }
    }

    private func verifiedLocalCandidate(
        _ anchor: SSHAnchorConfiguration,
        hostName: String
    ) async -> SSHAnchorConfiguration? {
        guard let address = IPv4Address(hostName),
              await homeNetwork(for: anchor)?.contains(hostName) == true
        else { return nil }
        let results = await scanner.scan(
            targets: [address],
            ports: [anchor.port],
            timeoutMilliseconds: 600,
            concurrency: 1
        )
        return await prove(SSHAnchorRecovery.resolve(anchor: anchor, scanResults: results), original: anchor)
    }

    private func discoverLocalCandidate(_ anchor: SSHAnchorConfiguration) async -> SSHAnchorConfiguration? {
        guard let network = await homeNetwork(for: anchor),
              let targets = try? network.targets(limit: 1_024)
        else {
            scheduleRetry(for: anchor.id)
            return nil
        }
        let results = await scanner.scan(
            targets: targets,
            ports: [anchor.port],
            timeoutMilliseconds: 600
        )
        guard let recovered = await prove(
            SSHAnchorRecovery.resolve(anchor: anchor, scanResults: results),
            original: anchor
        ) else {
            scheduleRetry(for: anchor.id)
            return nil
        }
        recoveryFailures[anchor.id] = nil
        nextRecovery[anchor.id] = nil
        return recovered
    }

    private func prove(_ move: SSHAnchorMove?, original: SSHAnchorConfiguration) async -> SSHAnchorConfiguration? {
        let knownHosts = paths.knownHosts
        let addresses = [original.hostName] + (original.localHostName.map { [$0] } ?? [])
        // known_hosts stores a host on a port other than 22 as "[address]:port".
        let names = [original.knownHostsAlias] + addresses
            + (original.port == 22 ? [] : addresses.map { "[\($0)]:\(original.port)" })
        return await SSHAnchorRecovery.proven(move) { host, port in
            await SSHHostKeyProof.matches(host: host, port: port, names: names, knownHosts: knownHosts)
        }
    }

    /// The subnet and router MAC of the joined network, so a café with the same 192.168.1.x range never matches.
    private func currentHome() async -> (network: LocalIPv4Network, id: String)? {
        guard let route = await DefaultRoute.load(),
              let network = LocalIPv4Network.active(preferredInterfaceName: route.interfaceName),
              network.contains(route.gateway),
              let gateway = IPv4Address(route.gateway),
              let mac = await ARPTable.load(addresses: [gateway], interfaceName: network.interfaceName)[route.gateway]
        else { return nil }
        return (network, "\(network.cidr)|\(AnchorMatcher.normalizedMAC(mac))")
    }

    /// The joined network when it is this anchor's home network; SSH Anchor never searches anywhere else.
    private func homeNetwork(for anchor: SSHAnchorConfiguration) async -> LocalIPv4Network? {
        guard let expected = anchor.homeNetwork, let home = await currentHome(), home.id == expected else { return nil }
        return home.network
    }

    /// Records the home network the first time the host answers at its saved address on the joined network.
    private func learnHomeNetwork(_ anchor: SSHAnchorConfiguration) async {
        guard anchor.homeNetwork == nil, nextHomeCheck[anchor.id].map({ $0 <= Date() }) ?? true else { return }
        nextHomeCheck[anchor.id] = Date().addingTimeInterval(60)
        guard let home = await currentHome(), home.network.contains(anchor.hostName) else { return }
        var learned = anchor
        learned.homeNetwork = home.id
        saveAnchorMetadata(learned, expectedHostName: anchor.hostName)
    }

    nonisolated static func awayFromHomeMessage(_ anchor: SSHAnchorConfiguration) -> String {
        anchor.homeNetwork == nil
            ? "SSH Anchor learns this host's home network the next time the host answers there."
            : "SSH Anchor searches only this host's home network."
    }

    private func applyVerifiedChange(
        original: SSHAnchorConfiguration,
        recovered: SSHAnchorConfiguration
    ) async throws {
        let latest = NetToysConfigurationStore.load()
        guard let current = latest.anchors.first(where: { $0.id == original.id }),
              current.hostName == original.hostName
        else { throw NetToysConfiguration.ConfigurationError.anchorNotFound }
        let updated = try latest.replacingAnchor(recovered)
        let summary = "Changed \(original.hostAlias) HostName from \(original.hostName) to \(recovered.hostName)"
        let undo = NetToysUndo.sshHostName(anchorID: original.id, hostAlias: original.hostAlias,
                                           from: original.hostName, to: recovered.hostName)
        let configURL = paths.sshConfig
        let backups = paths.backups
        try await perform(.sshHostName, summary, undo: undo) {
            try await SSHAnchorVerifiedUpdate.apply(
                original: original,
                recovered: recovered,
                configURL: configURL,
                backupDirectory: backups,
                verify: { host, port in
                    await TCPPortProbe.check(host: host, port: port, timeoutMilliseconds: 900).state == .open
                },
                commit: { _ = try NetToysConfigurationStore.saveChanges(updated, since: latest) }
            )
        }
    }

    private func saveAnchorMetadata(
        _ anchor: SSHAnchorConfiguration,
        expectedHostName: String
    ) {
        let latest = NetToysConfigurationStore.load()
        guard let current = latest.anchors.first(where: { $0.id == anchor.id }),
              current.hostName == expectedHostName,
              let updated = try? latest.replacingAnchor(anchor)
        else { return }
        _ = try? NetToysConfigurationStore.saveChanges(updated, since: latest)
    }

    private func synchronizedAnchor(_ anchor: SSHAnchorConfiguration) -> SSHAnchorConfiguration {
        let configURL = paths.sshConfig
        guard let data = try? Data(contentsOf: configURL),
              let entry = SSHConfigEditor.entries(in: data).first(where: {
                  $0.aliases.contains { $0.caseInsensitiveCompare(anchor.hostAlias) == .orderedSame }
              }), entry.hostName != anchor.hostName
        else { return anchor }
        var copy = anchor
        copy.hostName = entry.hostName
        if copy.route == .local { copy.localHostName = entry.hostName }
        let configuration = NetToysConfigurationStore.load()
        if let updated = try? configuration.replacingAnchor(copy) {
            _ = try? NetToysConfigurationStore.saveChanges(updated, since: configuration)
        }
        return copy
    }

    private func prepareHostKeyPolicy(_ anchor: SSHAnchorConfiguration) throws {
        var reason: String?
        defer { if let reason { enterSafeMode(reason) } }
        try policyPreparer.prepare(anchor, configURL: paths.sshConfig, backupDirectory: paths.backups, gate: &gate,
                                   settings: cachedConfiguration, at: uptime(), safeModeReason: &reason)
    }

    private func enterSafeMode(_ reason: String) {
        if let saved = try? NetToysConfigurationStore.update({ $0.safeModeReason = reason }) {
            cachedConfiguration = saved
        }
    }

    private func scheduleRetry(for id: UUID) {
        let failures = min((recoveryFailures[id] ?? 0) + 1, 5)
        recoveryFailures[id] = failures
        let seconds = min(30 * (1 << (failures - 1)), 300)
        nextRecovery[id] = Date().addingTimeInterval(TimeInterval(seconds))
    }

    private func checkNetwork(_ configuration: NetToysConfiguration) async {
        guard let route = await DefaultRoute.load() else {
            dnsCheck = nil
            recordNetwork(
                networkID: "disconnected",
                ssid: nil,
                gateway: .unknown,
                internet: .unknown,
                shouldRecordHistory: configuration.recordsNetworkHistory
            )
            // No route means Wi-Fi is off or not joined: leaving a network is not an outage.
            await updateWiFiFailover(
                configuration.wifiPriority,
                currentSSID: nil,
                isFailure: false,
                left: true,
                hasActiveRoute: false
            )
            return
        }
        async let gateway = NetworkProbe.gateway(route.gateway)
        async let internet = NetworkProbe.internet()
        async let dns = DNSProbe.check()
        let ssid = NetworkSSID.current(interfaceName: route.interfaceName)
        let internetState = await internet
        let (gatewayState, gatewayMilliseconds) = await gateway
        dnsCheck = await dns
        let date = Date()
        if configuration.recordsNetworkHistory, gatewayState != .unknown {
            pendingLatency[NetToysLatencyHistory.gateway, default: []]
                .append(NetToysLatencySample(date: date, milliseconds: gatewayMilliseconds))
        }
        if internetState != .unknown {
            switch internetPresence.observe(up: internetState == .reachable, at: date) {
            case .down: notify(NetToysAlert(title: "Internet is down",
                                            body: "\(ssid ?? "This network") stopped reaching the Internet."))
            case .back(let after): notify(NetToysAlert(title: "Internet is back",
                                                       body: "The outage lasted \(NetToysDuration.text(after))."))
            case nil: break
            }
        }
        await announceNewNeighbors(interfaceName: route.interfaceName)
        recordNetwork(
            networkID: route.networkID,
            ssid: ssid,
            usesSSIDIdentity: NetworkSSID.isWiFi(interfaceName: route.interfaceName),
            gateway: gatewayState,
            internet: internetState,
            shouldRecordHistory: configuration.recordsNetworkHistory
        )
        await updateWiFiFailover(
            configuration.wifiPriority,
            currentSSID: ssid,
            isFailure: WiFiFailoverMonitor.isOutage(internet: internetState, gateway: gatewayState),
            left: NetworkSSID.isWiFiOff(),
            hasActiveRoute: true
        )
    }

    /// The neighbor table holds every device that talked on the subnet lately, so a new MAC shows up without a scan.
    private func announceNewNeighbors(interfaceName: String) async {
        guard let network = LocalIPv4Network.active(preferredInterfaceName: interfaceName) else { return }
        let neighbors = await ARPTable.all(interfaceName: interfaceName).compactMap { address, mac -> NetToysScanResult? in
            guard network.contains(address), let address = IPv4Address(address) else { return nil }
            return NetToysScanResult(address: address, isReachable: true, responseMilliseconds: nil, hostname: nil,
                                     macAddress: mac, vendor: MACVendorDatabase.bundled.vendor(for: mac), openPorts: [])
        }
        let found = (try? NetToysKnownDevices.newDevices(neighbors.sorted { $0.address < $1.address },
                                                          at: paths.knownDevices)) ?? []
        NetToysKnownDevices.alert(for: found).map(notify)
    }

    private func updateWiFiFailover(
        _ configuration: WiFiPriorityConfiguration,
        currentSSID: String?,
        isFailure: Bool,
        left: Bool,
        hasActiveRoute: Bool
    ) async {
        guard configuration.isEnabled else { return }
        let date = Date()
        guard !NetToysActionGate.isHeld(cachedConfiguration) else {
            wifiFailoverStatus = WiFiFailoverStatus(state: .monitoring, message: "Automatic actions are paused.",
                                                    updatedAt: date)
            return
        }
        guard !left else {
            _ = wifiFailoverMonitor.shouldAttempt(isFailure: false, left: true, threshold: configuration.outageThreshold,
                                                  at: uptime())
            wifiFailoverStatus = WiFiFailoverStatus(state: .monitoring,
                                                    message: "Wi-Fi is off or not joined. This is not an outage.",
                                                    updatedAt: date)
            return
        }
        guard !(hasActiveRoute && currentSSID == nil) else {
            wifiFailoverStatus = WiFiFailoverStatus(
                state: .failed,
                message: "The helper needs the Wi-Fi network name before it can switch networks.",
                updatedAt: date
            )
            return
        }
        let now = uptime()
        guard wifiFailoverMonitor.shouldAttempt(
            isFailure: isFailure,
            ssid: currentSSID,
            threshold: configuration.outageThreshold,
            maximumAttempts: configuration.ssids.count,
            at: now
        ) else {
            let attempts = wifiFailoverMonitor.attempts
            let exhausted = isFailure && attempts > 0 && attempts >= configuration.ssids.count
            let resting = isFailure && now < wifiFailoverMonitor.holdUntil
            let staying = isFailure && wifiFailoverMonitor.staying
            wifiFailoverStatus = WiFiFailoverStatus(
                state: exhausted ? .failed : isFailure ? .waiting : .monitoring,
                message: exhausted
                    ? "Every saved Wi-Fi network was tried. Waiting for the connection to return."
                    : staying
                    ? "Staying on \(currentSSID ?? "this network") until the connection returns."
                    : resting
                    ? "Internet is unavailable. Waiting after wake or a recent switch."
                    : isFailure
                    ? "Internet is unavailable. Waiting before failover."
                    : "Internet is reachable.",
                updatedAt: date
            )
            // The panel counts down to the next attempt; it assumes the next saved network is nearby.
            if isFailure, !exhausted, let at = wifiFailoverMonitor.nextAttempt(threshold: configuration.outageThreshold) {
                wifiFailoverStatus?.next = WiFiFailoverMonitor.nextSSID(after: currentSSID, priorities: configuration.ssids,
                                                                       availableSSIDs: Set(configuration.ssids))
                wifiFailoverStatus?.joinAt = date.addingTimeInterval(max(0, at - now))
            }
            return
        }
        wifiFailoverMonitor.didAttempt(at: now)
        wifiFailoverStatus = WiFiFailoverStatus(
            state: .switching,
            message: "Looking for the next saved Wi-Fi network.",
            updatedAt: date
        )
        writeStatus()
        let availableSSIDs = await WiFiNetworkController.availableSSIDs()
        guard let target = WiFiFailoverMonitor.nextSSID(
            after: currentSSID,
            priorities: configuration.ssids,
            availableSSIDs: availableSSIDs
        ) else {
            wifiFailoverStatus = WiFiFailoverStatus(
                state: .failed,
                message: "No configured backup Wi-Fi network is nearby. macOS can try Instant Hotspot next.",
                updatedAt: Date()
            )
            return
        }
        do {
            try await perform(.wifiJoin, "Switched Wi-Fi from \(currentSSID ?? "no network") to \(target)",
                              undo: currentSSID.map { .wifi(previousSSID: $0) }) {
                try await WiFiNetworkController.join(target)
            }
            wifiFailoverMonitor.didSwitch(to: target, at: uptime(), cooldown: configuration.cooldownAfterSwitch)
            wifiFailoverStatus = WiFiFailoverStatus(
                state: .switching,
                message: "Joined \(target). Checking Internet access.",
                updatedAt: Date()
            )
        } catch {
            // A held join (dry run) changed nothing, so it must not use up a network in the rotation.
            if error is ActionHeld { wifiFailoverMonitor.didSkipAttempt() }
            wifiFailoverStatus = WiFiFailoverStatus(
                state: error is ActionHeld ? .monitoring : .failed,
                message: error.localizedDescription,
                updatedAt: Date()
            )
        }
    }

    private func recordNetwork(
        networkID: String,
        ssid: String?,
        usesSSIDIdentity: Bool = false,
        gateway: NetworkReachability,
        internet: NetworkReachability,
        shouldRecordHistory: Bool = true
    ) {
        let date = Date()
        networkSnapshot = NetworkRuntimeSnapshot(
            networkID: networkID,
            ssid: ssid,
            gateway: gateway,
            internet: internet,
            checkedAt: date
        )
        guard shouldRecordHistory,
              let event = historyRecorder.observe(
            networkID: networkID,
            ssid: ssid,
            usesSSIDIdentity: usesSSIDIdentity,
            gateway: gateway,
            internet: internet,
            at: date
        ) else { return }
        try? NetToysConfigurationStore.appendHistory(event)
    }

    private func status(
        _ anchor: SSHAnchorConfiguration,
        _ state: SSHAnchorRuntimeState,
        _ message: String? = nil
    ) -> SSHAnchorStatus {
        SSHAnchorStatus(
            anchorID: anchor.id,
            state: state,
            currentHostName: anchor.hostName,
            lastCheck: Date(),
            message: message
        )
    }

    private func saveStatus(_ anchors: [SSHAnchorStatus]) {
        currentStatuses = anchors
        writeStatus()
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            writeStatus()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Rewrites the file only when its content changed, or to refresh the heartbeat.
    private func writeStatus() {
        let now = Date()
        if let last = lastWrittenStatus,
           now.timeIntervalSince(last.heartbeat) < Self.heartbeatRefresh,
           makeStatus(heartbeat: last.heartbeat) == last { return }
        let status = makeStatus(heartbeat: now)
        guard (try? NetToysConfigurationStore.saveStatus(status)) != nil else { return }
        lastWrittenStatus = status
    }

    private func makeStatus(heartbeat: Date) -> NetToysHelperStatus {
        NetToysHelperStatus(
            version: NetToysBuild.statusSchemaVersion,
            heartbeat: heartbeat,
            anchors: currentStatuses,
            network: networkSnapshot,
            sourceCommit: (Bundle.main.object(forInfoDictionaryKey: "NetToysSourceCommit")
                ?? Bundle.main.object(forInfoDictionaryKey: "MPTSourceCommit")) as? String,
            ssidAccess: ssidAccess,
            wifiFailover: wifiFailoverStatus,
            ownerBundleID: owner.rawValue,
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            packageVersion: NetToysBuild.packageVersion,
            system: .make(settings: cachedConfiguration, warnings: gate.warningCount(at: uptime())),
            dns: dnsCheck
        )
    }
}

nonisolated enum NetworkProbe {
    /// Reachability and the round trip in ms.
    static func gateway(_ host: String) async -> (NetworkReachability, Double?) {
        do {
            let result = try await SSHProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/sbin/ping"),
                arguments: ["-n", "-c", "1", "-W", "1000", "-t", "2", host],
                environment: ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new },
                maximumOutputBytes: 65_536,
                timeout: 4
            )
            guard result.status == 0 else { return (.unreachable, nil) }
            return (.reachable, PingProbe.parse(result.standardOutput)?.averageMilliseconds)
        } catch SSHKeyAccessError.timeout {
            return (.unreachable, nil)
        } catch {
            return (.unknown, nil)
        }
    }

    static func internet() async -> NetworkReachability {
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else { return .unknown }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .unknown }
            return (200..<400).contains(response.statusCode) ? .reachable : .unreachable
        } catch {
            return .unreachable
        }
    }
}
