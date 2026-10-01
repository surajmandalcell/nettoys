import Foundation

public nonisolated struct NetToysScannerPreferences: Codable, Equatable, Sendable {
    public let portInput: String
    public let timeoutMilliseconds: Int
    public let concurrency: Int
    public let launchDelayMilliseconds: Int
    public let collectPingDetails: Bool
    public let pingProbeCount: Int
    public let detectHTTPServer: Bool
    public let detectHTTPProxy: Bool
    public let detectNetBIOS: Bool
    public let customTextEnabled: Bool
    public let customTextPort: Int
    public let customTextRequest: String
    public let customTextPattern: String

    public init(portInput: String, timeoutMilliseconds: Int, concurrency: Int, launchDelayMilliseconds: Int,
                collectPingDetails: Bool, pingProbeCount: Int, detectHTTPServer: Bool, detectHTTPProxy: Bool,
                detectNetBIOS: Bool, customTextEnabled: Bool, customTextPort: Int,
                customTextRequest: String, customTextPattern: String) {
        self.portInput = portInput
        self.timeoutMilliseconds = timeoutMilliseconds
        self.concurrency = concurrency
        self.launchDelayMilliseconds = launchDelayMilliseconds
        self.collectPingDetails = collectPingDetails
        self.pingProbeCount = pingProbeCount
        self.detectHTTPServer = detectHTTPServer
        self.detectHTTPProxy = detectHTTPProxy
        self.detectNetBIOS = detectNetBIOS
        self.customTextEnabled = customTextEnabled
        self.customTextPort = customTextPort
        self.customTextRequest = customTextRequest
        self.customTextPattern = customTextPattern
    }
}

public nonisolated struct NetToysLivenessPreferences: Codable, Equatable, Sendable {
    public let method: NetToysLivenessMethod
    public let pingTimeoutMilliseconds: Int
    public let adaptiveTCPTimeout: Bool
    public let scanUnresponsiveHosts: Bool

    public init(method: NetToysLivenessMethod, pingTimeoutMilliseconds: Int,
                adaptiveTCPTimeout: Bool, scanUnresponsiveHosts: Bool) {
        self.method = method
        self.pingTimeoutMilliseconds = pingTimeoutMilliseconds
        self.adaptiveTCPTimeout = adaptiveTCPTimeout
        self.scanUnresponsiveHosts = scanUnresponsiveHosts
    }
}

public nonisolated enum NetToysPreferences {
    public static let suiteName = "com.surajmandal.nettoys.preferences"
    public static let scannerKeys = ["target", "ports", "follows-active-network", "filter", "search",
                                     "sort", "preferences", "liveness-preferences", "openers"]
        .map { "nettoys.scanner." + $0 }

    public static func migrate(legacy: UserDefaults, shared: UserDefaults, host: NetToysHostID,
                               directory: URL = NetToysPaths.directory) throws {
        try NetToysStoreTransaction.withLock(at: directory) {
            let marker = "nettoys.migrated." + host.rawValue
            guard !shared.bool(forKey: marker) else { return }
            for key in scannerKeys where shared.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { shared.set(value, forKey: key) }
            }
            shared.set(true, forKey: marker)
            shared.synchronize()
        }
    }
}
