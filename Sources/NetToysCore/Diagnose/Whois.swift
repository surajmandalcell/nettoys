import Foundation
import Network

public nonisolated struct NetToysWhoisResult: Equatable, Sendable {
    public let query: String
    /// whois.iana.org, then the registry or RIR it referred to.
    public let servers: [String]
    /// The registry answer when the referral worked, else the IANA answer.
    public let raw: String
    public let registrar: String?
    public let created: String?
    public let expires: String?
    public let nameServers: [String]
}

/// Whois over TCP 43: ask whois.iana.org, then follow its referral once (the TLD registry, or the RIR for an IP).
public nonisolated enum NetToysWhois {
    public static func lookup(_ query: String, timeout: TimeInterval = 10) async throws -> NetToysWhoisResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, !query.contains(where: \.isNewline) else {
            throw NetToysDiagnoseError.invalidInput("Enter a domain or an IP address.")
        }
        var servers = ["whois.iana.org"]
        var text = try await ask("whois.iana.org", query, timeout: timeout)
        if let referral = referral(in: text), referral != servers[0] {
            servers.append(referral)
            text = try await ask(referral, query, timeout: timeout)
        }
        let parsed = fields(in: text)
        return NetToysWhoisResult(query: query, servers: servers, raw: text, registrar: parsed.registrar,
                                  created: parsed.created, expires: parsed.expires, nameServers: parsed.nameServers)
    }

    /// The server named by "refer:" (IANA), "whois:", or "ReferralServer: whois://host:port".
    package static func referral(in text: String) -> String? {
        for (key, value) in pairs(text) where ["refer", "whois", "referralserver"].contains(key) {
            var host = value.lowercased()
            if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
            host = String(host.prefix { $0 != ":" && $0 != "/" && !$0.isWhitespace })
            if host.contains("."), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) {
                return host
            }
        }
        return nil
    }

    package static func fields(in text: String) -> (registrar: String?, created: String?, expires: String?,
                                                    nameServers: [String]) {
        let all = pairs(text)
        func first(_ keys: Set<String>) -> String? { all.first { keys.contains($0.0) && !$0.1.isEmpty }?.1 }
        var servers: [String] = []
        for (key, value) in all where ["name server", "nserver", "nameserver", "name servers"].contains(key) {
            let name = value.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
            let host = name.hasSuffix(".") ? String(name.dropLast()) : name
            if !host.isEmpty, !servers.contains(host) { servers.append(host) }
        }
        return (
            first(["registrar", "sponsoring registrar", "registrar name", "orgname", "org-name", "organisation"]),
            first(["creation date", "created", "created on", "registered on", "registration time", "regdate"]),
            first(["registry expiry date", "registrar registration expiration date", "expiration date", "expires",
                   "expires on", "expiry date", "paid-till", "expiration time"]),
            servers
        )
    }

    /// "Key: value" lines with the key lowercased; comment lines (% and #) are skipped.
    private static func pairs(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("%"), !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func ask(_ server: String, _ query: String, timeout: TimeInterval) async throws -> String {
        let data = try await TCPRequest.exchange(host: server, port: 43, request: Data((query + "\r\n").utf8),
                                                 timeout: timeout)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Sends one request over TCP and reads until the server closes, the byte limit, or the timeout.
nonisolated enum TCPRequest {
    static func exchange(host: String, port: UInt16, request: Data, timeout: TimeInterval,
                         limit: Int = 1_048_576) async throws -> Data {
        let exchange = Exchange(connection: NWConnection(host: NWEndpoint.Host(host),
                                                         port: NWEndpoint.Port(rawValue: port) ?? 43, using: .tcp))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(request: request, timeout: timeout, limit: limit, continuation: continuation)
            }
        } onCancel: {
            exchange.cancel()
        }
    }

    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "NetToys.TCPRequest")
        // Confined to `queue`.
        private var received = Data()
        private var continuation: CheckedContinuation<Data, Error>?

        init(connection: NWConnection) { self.connection = connection }

        func start(request: Data, timeout: TimeInterval, limit: Int,
                   continuation: CheckedContinuation<Data, Error>) {
            queue.async { [self] in
                self.continuation = continuation
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { _ in })
                        receive(limit: limit)
                    case .failed(let error), .waiting(let error):
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    finish(received.isEmpty ? .failure(NetToysDiagnoseError.timedOut) : .success(received))
                }
            }
        }

        func cancel() { queue.async { [self] in finish(.failure(CancellationError())) } }

        private func receive(limit: Int) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
                if let data { received.append(data) }
                if complete || received.count >= limit {
                    finish(.success(received.prefix(limit)))
                } else if let error {
                    finish(received.isEmpty ? .failure(error) : .success(received))
                } else {
                    receive(limit: limit)
                }
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
