import CryptoKit
import Foundation
import Network
import Security

public nonisolated struct NetToysCertificate: Equatable, Sendable {
    public let subject: String
    public let issuer: String
    public let subjectAlternativeNames: [String]
    public let notBefore: Date?
    public let notAfter: Date?
    /// Whole days from now to `notAfter`; negative once expired.
    public let daysToExpiry: Int?
    /// "RSA 2048", "EC 256".
    public let key: String?
    public let signatureAlgorithm: String?
    public let sha256: String
}

public nonisolated struct NetToysSSLResult: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    /// "TLS 1.3", "TLS 1.2".
    public let tlsVersion: String
    public let trusted: Bool
    /// Why macOS does not trust the chain, such as an expired or self-signed certificate.
    public let trustError: String?
    /// Leaf first.
    public let chain: [NetToysCertificate]
    public let milliseconds: Double
}

/// TLS handshake to host:port that records the chain and the macOS trust verdict, then closes. It accepts an
/// untrusted chain only to show it; no application data is sent.
public nonisolated enum NetToysSSLCheck {
    public static func check(host: String, port: UInt16 = 443, timeout: TimeInterval = 10) async throws
        -> NetToysSSLResult {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NetToysDiagnoseError.invalidInput("Enter a host name and a port.")
        }
        let handshake = Handshake(host: host)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            handshake.evaluate(sec_trust_copy_ref(trust).takeRetainedValue())
            complete(true)
        }, handshake.queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                      using: NWParameters(tls: tls, tcp: .init()))
        let started = ContinuousClock.now
        let version = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handshake.start(connection, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            connection.cancel()
        }
        let elapsed = DiagnoseHost.milliseconds(since: started)
        let verdict = handshake.verdict
        return NetToysSSLResult(host: host, port: port, tlsVersion: version, trusted: verdict.trusted,
                                trustError: verdict.error, chain: verdict.chain, milliseconds: elapsed)
    }

    package static func certificate(_ certificate: SecCertificate, now: Date = Date()) -> NetToysCertificate {
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter,
                    kSecOIDSubjectAltName, kSecOIDX509V1SignatureAlgorithm] as CFArray
        let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] ?? [:]
        func value(_ oid: CFString) -> Any? { values[oid as String]?[kSecPropertyKeyValue as String] }
        func date(_ oid: CFString) -> Date? {
            (value(oid) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        func labeled(_ oid: CFString) -> [(String, String)] {
            (value(oid) as? [[String: Any]] ?? []).compactMap { entry in
                guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                      let text = entry[kSecPropertyKeyValue as String] as? String else { return nil }
                return (label, text)
            }
        }
        let issuer = labeled(kSecOIDX509V1IssuerName)
        let notAfter = date(kSecOIDX509V1ValidityNotAfter)
        let algorithm = labeled(kSecOIDX509V1SignatureAlgorithm).first { $0.0 == "Algorithm" }?.1
        var key: String?
        if let publicKey = SecCertificateCopyKey(certificate),
           let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any] {
            let type = attributes[kSecAttrKeyType as String] as? String
            let kind = type == (kSecAttrKeyTypeRSA as String) ? "RSA"
                : type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "EC" : "Key"
            key = (attributes[kSecAttrKeySizeInBits as String] as? Int).map { "\(kind) \($0)" } ?? kind
        }
        let der = SecCertificateCopyData(certificate) as Data
        return NetToysCertificate(
            subject: SecCertificateCopySubjectSummary(certificate) as String? ?? "",
            issuer: issuer.first { $0.0 == "2.5.4.3" }?.1 ?? issuer.first { $0.0 == "2.5.4.10" }?.1 ?? "",
            subjectAlternativeNames: labeled(kSecOIDSubjectAltName).filter { $0.0 == "DNS Name" || $0.0 == "IP Address" }
                .map(\.1),
            notBefore: date(kSecOIDX509V1ValidityNotBefore),
            notAfter: notAfter,
            daysToExpiry: notAfter.map { Int(floor($0.timeIntervalSince(now) / 86_400)) },
            key: key,
            signatureAlgorithm: algorithm.map { signatureNames[$0] ?? $0 },
            sha256: SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        )
    }

    private static let signatureNames = [
        "1.2.840.113549.1.1.5": "SHA-1 with RSA",
        "1.2.840.113549.1.1.11": "SHA-256 with RSA",
        "1.2.840.113549.1.1.12": "SHA-384 with RSA",
        "1.2.840.113549.1.1.13": "SHA-512 with RSA",
        "1.2.840.113549.1.1.10": "RSA-PSS",
        "1.2.840.10045.4.3.2": "ECDSA with SHA-256",
        "1.2.840.10045.4.3.3": "ECDSA with SHA-384",
        "1.2.840.10045.4.3.4": "ECDSA with SHA-512",
        "1.3.101.112": "Ed25519",
    ]

    fileprivate static func versionName(_ version: tls_protocol_version_t) -> String {
        switch version {
        case .TLSv13: "TLS 1.3"
        case .TLSv12: "TLS 1.2"
        case .TLSv11: "TLS 1.1"
        case .TLSv10: "TLS 1.0"
        default: "TLS (\(version.rawValue))"
        }
    }
}

private nonisolated final class Handshake: @unchecked Sendable {
    let queue = DispatchQueue(label: "NetToys.SSLCheck")
    private let host: String
    // Confined to `queue`.
    private(set) var verdict: (trusted: Bool, error: String?, chain: [NetToysCertificate]) = (false, nil, [])
    private var continuation: CheckedContinuation<String, Error>?
    private var connection: NWConnection?

    init(host: String) { self.host = host }

    /// Runs on `queue` inside the TLS verify block.
    func evaluate(_ trust: SecTrust) {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).map {
            NetToysSSLCheck.certificate($0)
        }
        verdict = (trusted, error.map { CFErrorCopyDescription($0) as String }, chain)
    }

    func start(_ connection: NWConnection, timeout: TimeInterval, continuation: CheckedContinuation<String, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            self.connection = connection
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    let version = metadata.map {
                        NetToysSSLCheck.versionName(
                            sec_protocol_metadata_get_negotiated_tls_protocol_version($0.securityProtocolMetadata))
                    }
                    finish(.success(version ?? "TLS"))
                case .failed(let error), .waiting(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.failure(NetToysDiagnoseError.timedOut)) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection?.cancel()
        connection = nil
        continuation.resume(with: result)
    }
}
