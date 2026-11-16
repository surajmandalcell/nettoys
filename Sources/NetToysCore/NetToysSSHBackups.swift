import Foundation

/// Where the runtime reads and writes. Tests pass a temporary folder for both roots.
public nonisolated struct NetToysRuntimePaths: Sendable {
    public var home: URL
    public var data: URL

    public init(home: URL, data: URL) {
        self.home = home
        self.data = data
    }

    public static var standard: Self {
        Self(home: FileManager.default.homeDirectoryForCurrentUser, data: NetToysPaths.directory)
    }

    public var sshConfig: URL { home.appendingPathComponent(".ssh/config") }
    public var knownHosts: URL { home.appendingPathComponent(".ssh/known_hosts") }
    public var backups: URL { data.appendingPathComponent("SSH Backups", isDirectory: true) }
    public var actionLog: URL { data.appendingPathComponent("actions.log") }
    public var latency: URL { data.appendingPathComponent("latency.json") }
    public var deviceWatch: URL { data.appendingPathComponent("device-watch.json") }
    public var knownDevices: URL { data.appendingPathComponent("known-devices.json") }
    public var failoverRequest: URL { data.appendingPathComponent("failover-request.json") }
}

/// One saved copy of ~/.ssh/config, taken before a change (per host) or once a day (periodic).
public nonisolated struct NetToysSSHBackup: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// The SSH host whose change made this copy; nil for a periodic snapshot.
    public let hostAlias: String?
    public let date: Date
    public let size: Int
}

public nonisolated enum NetToysSSHBackups {
    public static let totalCap = 1_048_576
    static let hostsFolder = "Hosts"
    static let periodicFolder = "Periodic"

    /// Every backup, newest first. Files from older builds sit loose in the folder and list as periodic.
    public static func list(in directory: URL) -> [NetToysSSHBackup] {
        let fileManager = FileManager.default
        var folders: [(URL, String?)] = [(directory, nil), (directory.appendingPathComponent(periodicFolder), nil)]
        let hosts = directory.appendingPathComponent(hostsFolder)
        for folder in (try? fileManager.contentsOfDirectory(at: hosts, includingPropertiesForKeys: nil)) ?? [] {
            folders.append((folder, folder.lastPathComponent))
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        return folders.flatMap { folder, alias in
            ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [])
                .filter { $0.pathExtension == "backup" }
                .compactMap { url -> NetToysSSHBackup? in
                    guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                    return NetToysSSHBackup(url: url, hostAlias: alias,
                                            date: values.contentModificationDate ?? .distantPast,
                                            size: values.fileSize ?? 0)
                }
        }.sorted { $0.date > $1.date }
    }

    @discardableResult
    static func write(_ data: Data, hostAlias: String?, in directory: URL, date: Date = Date()) throws -> URL {
        let folder = hostAlias.map {
            directory.appendingPathComponent(hostsFolder).appendingPathComponent(folderName($0))
        } ?? directory.appendingPathComponent(periodicFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stamp = Int(date.timeIntervalSince1970 * 1_000)
        let url = folder.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8)).backup")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    /// Deletes the oldest backups, across every host, until all of them fit in `maxBytes`.
    static func enforceCap(in directory: URL, maxBytes: Int = totalCap) {
        var backups = list(in: directory)
        var total = backups.reduce(0) { $0 + $1.size }
        while total > maxBytes, backups.count > 1, let oldest = backups.popLast() {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    /// Saves a periodic copy when the newest one is older than `interval` and the file changed since.
    @discardableResult
    static func snapshotIfDue(configURL: URL, in directory: URL, now: Date = Date(),
                              interval: TimeInterval = 86_400) -> Bool {
        guard let data = try? Data(contentsOf: configURL.resolvingSymlinksInPath()) else { return false }
        let newest = list(in: directory).first { $0.hostAlias == nil }
        if let newest {
            guard now.timeIntervalSince(newest.date) >= interval,
                  (try? Data(contentsOf: newest.url)) != data else { return false }
        }
        guard (try? write(data, hostAlias: nil, in: directory, date: now)) != nil else { return false }
        enforceCap(in: directory)
        return true
    }

    /// Puts a backup back in place. The current file is backed up first, so a restore can be undone.
    public static func restore(_ backup: NetToysSSHBackup, configURL: URL, backupDirectory: URL) throws {
        let data = try Data(contentsOf: backup.url)
        try SSHConfigFileUpdater.replaceContents(configURL: configURL, backupDirectory: backupDirectory,
                                                 hostAlias: backup.hostAlias, with: data)
    }

    private static func folderName(_ alias: String) -> String {
        String(alias.map { $0 == "/" || $0 == ":" ? "_" : $0 })
    }
}
