import Foundation

public nonisolated struct NetToysNeighborServiceContract: Sendable {
    public let daemonPlistName: String
    public let machServiceName: String
    public let mainAppRequirement: String
    public let helperRequirement: String

    public init(host: NetToysHostID) {
        let service = host == .macPowerToys ? "com.surajmandal.macpowertoys.nettoys-neighbor" : "com.surajmandal.nettoys.neighbor"
        daemonPlistName = service + ".plist"
        machServiceName = service
        mainAppRequirement = "identifier \"\(host.rawValue)\" and anchor apple generic and certificate leaf[subject.OU] = \"GF57JXJF5A\""
        helperRequirement = "identifier \"\(host.helperIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"GF57JXJF5A\""
    }
}

@objc public nonisolated protocol NetToysNeighborXPCProtocol {
    func neighborSnapshot(reply: @escaping (Data?, String) -> Void)
}

/// Ends an on-demand daemon after it has served no connection for `delay` seconds.
/// launchd starts it again from the installed binary on the next request, so an app
/// update can never leave an old, no longer valid daemon process running.
public final nonisolated class NetToysDaemonIdleExit: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let exitProcess: @Sendable () -> Void
    private var connections = 0
    private var generation = 0

    public init(delay: TimeInterval = 30, exitProcess: @escaping @Sendable () -> Void = { exit(0) }) {
        self.delay = delay
        self.exitProcess = exitProcess
        schedule()
    }

    public func track(_ connection: NSXPCConnection) {
        connectionStarted()
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
    }

    func connectionStarted() {
        lock.withLock { connections += 1; generation += 1 }
    }

    func connectionEnded() {
        lock.withLock { connections -= 1; generation += 1 }
        schedule()
    }

    private func schedule() {
        let scheduled = lock.withLock { generation }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            if lock.withLock({ connections == 0 && generation == scheduled }) { exitProcess() }
        }
    }
}

public nonisolated enum NetToysNeighborProbe: Equatable, Sendable {
    case ready, stale, unavailable
}

public nonisolated enum NetToysNeighborXPCClient {
    /// A daemon whose binary changed after launch fails its code-signing requirement.
    public static func probe(contract: NetToysNeighborServiceContract) async -> NetToysNeighborProbe {
        await withCheckedContinuation { continuation in
            let reply = ProbeReply(continuation)
            let connection = NSXPCConnection(machServiceName: contract.machServiceName, options: .privileged)
            reply.attach(connection)
            connection.remoteObjectInterface = NSXPCInterface(with: NetToysNeighborXPCProtocol.self)
            connection.setCodeSigningRequirement(contract.helperRequirement)
            connection.invalidationHandler = { reply.finish(.unavailable) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                let code = (error as NSError).code
                reply.finish(code == NSXPCConnectionCodeSigningRequirementFailure ? .stale : .unavailable)
            } as? NetToysNeighborXPCProtocol
            proxy?.neighborSnapshot { data, _ in reply.finish(data == nil ? .unavailable : .ready) }
            if proxy == nil { reply.finish(.unavailable) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { reply.finish(.unavailable) }
        }
    }

    private final class ProbeReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NetToysNeighborProbe, Never>?
        private var connection: NSXPCConnection?

        init(_ continuation: CheckedContinuation<NetToysNeighborProbe, Never>) {
            self.continuation = continuation
        }

        func attach(_ connection: NSXPCConnection) {
            lock.withLock { self.connection = connection }
        }

        func finish(_ value: NetToysNeighborProbe) {
            let (continuation, connection) = lock.withLock { () -> (CheckedContinuation<NetToysNeighborProbe, Never>?, NSXPCConnection?) in
                defer { self.continuation = nil; self.connection = nil }
                return (self.continuation, self.connection)
            }
            guard let continuation else { return }
            connection?.invalidate()
            continuation.resume(returning: value)
        }
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String: String], Never>?
        private var connection: NSXPCConnection?

        init(_ continuation: CheckedContinuation<[String: String], Never>) {
            self.continuation = continuation
        }

        func attach(_ connection: NSXPCConnection) {
            lock.lock()
            self.connection = connection
            lock.unlock()
        }

        func finish(_ value: [String: String]) {
            lock.lock()
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            let connection = self.connection
            self.connection = nil
            lock.unlock()
            connection?.invalidate()
            continuation.resume(returning: value)
        }
    }

    static func load(addresses: [IPv4Address], interfaceIndex: UInt32,
                     contract: NetToysNeighborServiceContract) async -> [String: String] {
        guard !addresses.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            let connection = NSXPCConnection(machServiceName: contract.machServiceName, options: .privileged)
            reply.attach(connection)
            connection.remoteObjectInterface = NSXPCInterface(with: NetToysNeighborXPCProtocol.self)
            connection.setCodeSigningRequirement(contract.helperRequirement)
            connection.interruptionHandler = { reply.finish([:]) }
            connection.invalidationHandler = { reply.finish([:]) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish([:]) }
                as? NetToysNeighborXPCProtocol
            proxy?.neighborSnapshot { data, _ in
                guard let data else { reply.finish([:]); return }
                let requested = Set(addresses.map(\.description))
                reply.finish(ARPTable.parseRoutingMessages(data, interfaceIndex: interfaceIndex)
                    .filter { requested.contains($0.key) })
            }
            if proxy == nil { reply.finish([:]) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { reply.finish([:]) }
        }
    }
}
