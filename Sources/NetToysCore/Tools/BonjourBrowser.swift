import dnssd
import Foundation

public nonisolated struct NetToysBonjourService: Equatable, Identifiable, Sendable {
    public var id: String { "\(name)|\(type)|\(domain)" }
    public let name: String
    /// Such as "_http._tcp".
    public let type: String
    public let domain: String
    /// Nil until resolved.
    public var host: String?
    public var port: UInt16?
    public var txt: [String: String] = [:]
}

/// Finds the service types on the network with the `_services._dns-sd._udp` meta query, browses each type,
/// and resolves each service to host, port, and TXT. It uses dns_sd for all three steps, because NWBrowser
/// cannot resolve a service to host and port without opening a connection to it.
public nonisolated enum NetToysBonjourBrowser {
    /// Yields the full service list after every change, until the caller stops reading.
    public static func browse(domain: String = "local.") -> AsyncStream<[NetToysBonjourService]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let session = BonjourSession(domain: domain, continuation: continuation)
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }

    /// TXT data is a list of length-prefixed "key=value" strings.
    static func parseTXT(_ bytes: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard length > 0, index + length <= bytes.count else { break }
            let entry = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
            index += length
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            result[String(key)] = parts.count > 1 ? String(parts[1]) : ""
        }
        return result
    }
}

/// All dns_sd references live on one serial queue; callbacks arrive there too.
private nonisolated final class BonjourSession: @unchecked Sendable {
    static let maximumServices = 2_048

    private let queue = DispatchQueue(label: "nettoys.bonjour")
    private let domain: String
    private let continuation: AsyncStream<[NetToysBonjourService]>.Continuation
    private var meta: DNSServiceRef?
    private var browsers: [String: DNSServiceRef] = [:]
    private var resolvers: [String: (DNSServiceRef, Unmanaged<ResolveContext>)] = [:]
    private var services: [String: NetToysBonjourService] = [:]
    private var stopped = false

    final class ResolveContext {
        unowned let session: BonjourSession
        let key: String
        init(session: BonjourSession, key: String) { self.session = session; self.key = key }
    }

    init(domain: String, continuation: AsyncStream<[NetToysBonjourService]>.Continuation) {
        self.domain = domain
        self.continuation = continuation
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func start() {
        queue.async { [self] in
            var ref: DNSServiceRef?
            guard DNSServiceBrowse(&ref, 0, 0, "_services._dns-sd._udp", domain, metaReply, context) == kDNSServiceErr_NoError,
                  let ref else { continuation.finish(); return }
            DNSServiceSetDispatchQueue(ref, queue)
            meta = ref
        }
    }

    /// The stream's end keeps the session alive until every reference is gone.
    func stop() {
        queue.async { [self] in
            stopped = true
            meta.map(DNSServiceRefDeallocate)
            browsers.values.forEach(DNSServiceRefDeallocate)
            for (ref, context) in resolvers.values { DNSServiceRefDeallocate(ref); context.release() }
            meta = nil
            browsers = [:]
            resolvers = [:]
        }
    }

    fileprivate func foundType(name: String, regtype: String, add: Bool) {
        // The meta reply names "_http" with regtype "_tcp.local."
        guard !stopped, add, let proto = regtype.split(separator: ".").first else { return }
        let type = "\(name).\(proto)"
        guard browsers[type] == nil else { return }
        var ref: DNSServiceRef?
        guard DNSServiceBrowse(&ref, 0, 0, type, domain, serviceReply, context) == kDNSServiceErr_NoError,
              let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        browsers[type] = ref
    }

    fileprivate func foundService(name: String, regtype: String, domain: String, interface: UInt32, add: Bool) {
        guard !stopped else { return }
        let type = regtype.split(separator: ".").prefix(2).joined(separator: ".")
        let service = NetToysBonjourService(name: name, type: type, domain: domain)
        if !add {
            services[service.id] = nil
            if let (ref, context) = resolvers.removeValue(forKey: service.id) { DNSServiceRefDeallocate(ref); context.release() }
            continuation.yield(sorted)
            return
        }
        guard services[service.id] == nil, services.count < Self.maximumServices else { return }
        services[service.id] = service
        continuation.yield(sorted)
        let resolveContext = Unmanaged.passRetained(ResolveContext(session: self, key: service.id))
        var ref: DNSServiceRef?
        guard DNSServiceResolve(&ref, 0, interface, name, regtype, domain, resolveReply,
                                resolveContext.toOpaque()) == kDNSServiceErr_NoError, let ref else {
            resolveContext.release()
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        resolvers[service.id] = (ref, resolveContext)
    }

    fileprivate func resolved(key: String, host: String, port: UInt16, txt: [UInt8]) {
        guard !stopped, var service = services[key] else { return }
        service.host = host
        service.port = port
        service.txt = NetToysBonjourBrowser.parseTXT(txt)
        services[key] = service
        // One answer is enough; stop asking.
        if let (ref, context) = resolvers.removeValue(forKey: key) { DNSServiceRefDeallocate(ref); context.release() }
        continuation.yield(sorted)
    }

    private var sorted: [NetToysBonjourService] {
        services.values.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
    }
}

private nonisolated func metaReply(_: DNSServiceRef?, flags: DNSServiceFlags, _: UInt32, error: DNSServiceErrorType,
                                   name: UnsafePointer<CChar>?, regtype: UnsafePointer<CChar>?,
                                   _: UnsafePointer<CChar>?, context: UnsafeMutableRawPointer?) {
    guard error == kDNSServiceErr_NoError, let name, let regtype, let context else { return }
    Unmanaged<BonjourSession>.fromOpaque(context).takeUnretainedValue()
        .foundType(name: String(cString: name), regtype: String(cString: regtype), add: flags & kDNSServiceFlagsAdd != 0)
}

private nonisolated func serviceReply(_: DNSServiceRef?, flags: DNSServiceFlags, interface: UInt32, error: DNSServiceErrorType,
                                      name: UnsafePointer<CChar>?, regtype: UnsafePointer<CChar>?,
                                      domain: UnsafePointer<CChar>?, context: UnsafeMutableRawPointer?) {
    guard error == kDNSServiceErr_NoError, let name, let regtype, let domain, let context else { return }
    Unmanaged<BonjourSession>.fromOpaque(context).takeUnretainedValue()
        .foundService(name: String(cString: name), regtype: String(cString: regtype), domain: String(cString: domain),
                      interface: interface, add: flags & kDNSServiceFlagsAdd != 0)
}

private nonisolated func resolveReply(_: DNSServiceRef?, _: DNSServiceFlags, _: UInt32, error: DNSServiceErrorType,
                                      _: UnsafePointer<CChar>?, host: UnsafePointer<CChar>?, port: UInt16,
                                      txtLength: UInt16, txt: UnsafePointer<UInt8>?, context: UnsafeMutableRawPointer?) {
    guard error == kDNSServiceErr_NoError, let host, let context else { return }
    let resolve = Unmanaged<BonjourSession.ResolveContext>.fromOpaque(context).takeUnretainedValue()
    let bytes = txt.map { Array(UnsafeBufferPointer(start: $0, count: Int(txtLength))) } ?? []
    resolve.session.resolved(key: resolve.key, host: String(cString: host), port: UInt16(bigEndian: port), txt: bytes)
}
