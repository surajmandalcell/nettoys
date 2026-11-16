import Foundation

public nonisolated enum NetToysActionKind: String, Codable, Sendable {
    case sshHostName
    case sshPolicy
    case wifiJoin
    case undo
    case safeMode
}

public nonisolated enum NetToysActionOutcome: String, Codable, Sendable {
    case done
    case failed
    /// Dry run: logged what the action would do and changed nothing.
    case dryRun
}

/// What it takes to put an automatic change back.
public nonisolated enum NetToysUndo: Codable, Equatable, Sendable {
    case sshHostName(anchorID: UUID, hostAlias: String, from: String, to: String)
    case wifi(previousSSID: String)
}

/// One automatic action, shown in History.
public nonisolated struct NetToysActionEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var kind: NetToysActionKind
    public var outcome: NetToysActionOutcome
    public var summary: String
    public var detail: String?
    public var undo: NetToysUndo?
    /// Set on an `.undo` entry: the action it put back.
    public var undoes: UUID?

    public init(date: Date = Date(), kind: NetToysActionKind, outcome: NetToysActionOutcome, summary: String,
                detail: String? = nil, undo: NetToysUndo? = nil, undoes: UUID? = nil) {
        self.date = date
        self.kind = kind
        self.outcome = outcome
        self.summary = summary
        self.detail = detail
        self.undo = undo
        self.undoes = undoes
    }
}

/// A JSON Lines file of every automatic action. 30 days and 5 MB at most, oldest first.
public nonisolated struct NetToysActionLog: Sendable {
    public static let maximumBytes = 5 * 1_048_576
    public static let maximumAge: TimeInterval = 30 * 86_400
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: Self { Self(url: NetToysRuntimePaths.standard.actionLog) }

    public func append(_ entry: NetToysActionEntry) throws {
        var line = try JSONEncoder().encode(entry)
        line.append(0x0a)
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            if Int(size) + line.count > Self.maximumBytes { try pruneLocked(now: entry.date) }
        }
    }

    /// Every entry, newest first. A damaged line is skipped, never fatal.
    public func entries() -> [NetToysActionEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0a).compactMap { try? decoder.decode(NetToysActionEntry.self, from: $0) }.reversed()
    }

    /// The newest automatic change that can still be put back, for the Undo button.
    public func lastUndoable() -> NetToysActionEntry? {
        let all = entries()
        guard let last = all.first(where: { $0.outcome == .done && $0.undo != nil }),
              !all.contains(where: { $0.undoes == last.id }) else { return nil }
        return last
    }

    func prune(now: Date = Date()) throws {
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) { try pruneLocked(now: now) }
    }

    private func pruneLocked(now: Date) throws {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        var lines = data.split(separator: 0x0a).filter {
            guard let entry = try? decoder.decode(NetToysActionEntry.self, from: $0) else { return false }
            return now.timeIntervalSince(entry.date) < Self.maximumAge
        }
        // Trim to 80% so the next few appends do not rewrite the file again.
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        while total > Self.maximumBytes * 4 / 5, !lines.isEmpty { total -= lines.removeFirst().count + 1 }
        let kept = Data(lines.joined(separator: [0x0a])) + (lines.isEmpty ? Data() : Data([0x0a]))
        guard kept != data else { return }
        try kept.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The one gate every automatic change passes: pause, safe mode, dry run, and the action log.
nonisolated struct NetToysActionGate: Sendable {
    static let failureLimit = 3
    static let failureWindow: TimeInterval = 600
    let log: NetToysActionLog
    /// Monotonic seconds of recent failures.
    private(set) var failures: [TimeInterval] = []

    init(log: NetToysActionLog) {
        self.log = log
    }

    static func isHeld(_ settings: NetToysConfiguration) -> Bool {
        settings.actionsPaused || settings.safeModeReason != nil
    }

    /// True when the action may change something. Paused or safe mode: false. Dry run: logs it, then false.
    func allows(_ kind: NetToysActionKind, _ summary: String, undo: NetToysUndo? = nil,
                settings: NetToysConfiguration) -> Bool {
        if Self.isHeld(settings) { return false }
        if settings.dryRun {
            try? log.append(NetToysActionEntry(kind: kind, outcome: .dryRun, summary: summary, undo: undo))
            return false
        }
        return true
    }

    /// Logs the result. Returns the safe-mode reason when this is the third failure in ten minutes.
    mutating func finish(_ kind: NetToysActionKind, _ summary: String, undo: NetToysUndo? = nil,
                         error: Error?, at now: TimeInterval) -> String? {
        try? log.append(NetToysActionEntry(kind: kind, outcome: error == nil ? .done : .failed, summary: summary,
                                           detail: error?.localizedDescription, undo: error == nil ? undo : nil))
        guard let error else { return nil }
        failures = failures.filter { now - $0 < Self.failureWindow } + [now]
        guard failures.count >= Self.failureLimit else { return nil }
        failures.removeAll()
        let reason = "\(Self.failureLimit) automatic actions failed within 10 minutes. Last error: \(error.localizedDescription)"
        try? log.append(NetToysActionEntry(kind: .safeMode, outcome: .done, summary: "Safe mode started", detail: reason))
        return reason
    }

    func warningCount(at now: TimeInterval) -> Int {
        failures.filter { now - $0 < Self.failureWindow }.count
    }
}

/// Writes each anchor's host key policy block once. An anchor counts as prepared only after the block
/// is really in the file, so a dry run or a pause never leaves it marked done without the write.
nonisolated struct SSHPolicyPreparer: Sendable {
    private(set) var prepared = Set<UUID>()
    private var dryRunLogged = Set<UUID>()
    private var settingsKey: [String?] = []

    mutating func keep(_ ids: Set<UUID>) {
        prepared.formIntersection(ids)
        dryRunLogged.formIntersection(ids)
    }

    /// Throws a failed write. `safeModeReason` is set when that failure starts safe mode.
    mutating func prepare(_ anchor: SSHAnchorConfiguration, configURL: URL, backupDirectory: URL,
                          gate: inout NetToysActionGate, settings: NetToysConfiguration, at now: TimeInterval,
                          safeModeReason: inout String?) throws {
        let key = [String(settings.actionsPaused), String(settings.dryRun), settings.safeModeReason]
        if key != settingsKey {
            settingsKey = key
            prepared.removeAll()
            dryRunLogged.removeAll()
        }
        guard !prepared.contains(anchor.id) else { return }
        let current = try Data(contentsOf: configURL.resolvingSymlinksInPath())
        let wanted = try SSHConfigEditor.preparingAnchor(in: current, hostAlias: anchor.hostAlias,
                                                         knownHostsAlias: anchor.knownHostsAlias)
        guard wanted != current else {
            prepared.insert(anchor.id)
            return
        }
        let summary = "Added the SSH Anchor host key policy for \(anchor.hostAlias)"
        if NetToysActionGate.isHeld(settings) { return }
        if settings.dryRun {
            // Log once per dry run; the anchor stays unprepared so the write happens when dry run ends.
            if dryRunLogged.insert(anchor.id).inserted { _ = gate.allows(.sshPolicy, summary, settings: settings) }
            return
        }
        do {
            _ = try SSHConfigFileUpdater.prepareAnchor(configURL: configURL, backupDirectory: backupDirectory,
                                                       hostAlias: anchor.hostAlias,
                                                       knownHostsAlias: anchor.knownHostsAlias)
            _ = gate.finish(.sshPolicy, summary, error: nil, at: now)
            prepared.insert(anchor.id)
        } catch {
            safeModeReason = gate.finish(.sshPolicy, summary, error: error, at: now)
            throw error
        }
    }
}

/// The System row in the menu bar panel reads this.
public nonisolated enum NetToysSystemHealth: Codable, Equatable, Sendable {
    case running
    case warning(count: Int)
    case paused
    case failed(reason: String)

    static func make(settings: NetToysConfiguration, warnings: Int) -> Self {
        if let reason = settings.safeModeReason { return .failed(reason: reason) }
        if settings.actionsPaused { return .paused }
        return warnings > 0 ? .warning(count: warnings) : .running
    }
}

public nonisolated enum NetToysUndoAction {
    public enum UndoError: LocalizedError {
        case notUndoable

        public var errorDescription: String? { "This action cannot be undone." }
    }

    /// Puts an automatic change back. An undone SSH move also turns its anchor off, so it does not move again.
    public static func undo(_ entry: NetToysActionEntry, paths: NetToysRuntimePaths = .standard,
                            configurationURL: URL = NetToysPaths.configuration) async throws {
        guard entry.outcome == .done, let undo = entry.undo else { throw UndoError.notUndoable }
        let log = NetToysActionLog(url: paths.actionLog)
        do {
            switch undo {
            case .sshHostName(let anchorID, let hostAlias, let from, let to):
                _ = try SSHConfigFileUpdater.update(configURL: paths.sshConfig, backupDirectory: paths.backups,
                                                    hostAlias: hostAlias, expectedHostName: to, newHostName: from)
                try NetToysConfigurationStore.update(at: configurationURL) { configuration in
                    guard let index = configuration.anchors.firstIndex(where: { $0.id == anchorID }) else { return }
                    configuration.anchors[index].hostName = from
                    if configuration.anchors[index].route == .local { configuration.anchors[index].localHostName = from }
                    configuration.anchors[index].isEnabled = false
                }
            case .wifi(let previousSSID):
                try await WiFiNetworkController.join(previousSSID)
            }
            try? log.append(NetToysActionEntry(kind: .undo, outcome: .done, summary: "Undid: \(entry.summary)",
                                               undoes: entry.id))
        } catch {
            try? log.append(NetToysActionEntry(kind: .undo, outcome: .failed, summary: "Undo failed: \(entry.summary)",
                                               detail: error.localizedDescription))
            throw error
        }
    }
}
