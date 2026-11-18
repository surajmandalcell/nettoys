import Foundation
import Synchronization

public nonisolated struct NetToysHTTPRedirect: Equatable, Sendable {
    public let url: String
    public let status: Int
    public let location: String
}

/// Phases of the final request in milliseconds; nil when the phase did not happen (a reused connection).
public nonisolated struct NetToysHTTPTiming: Equatable, Sendable {
    public let dns: Double?
    public let connect: Double?
    public let tls: Double?
    /// Request sent to first response byte.
    public let firstByte: Double?
    /// Whole task, redirects included.
    public let total: Double
}

public nonisolated struct NetToysHTTPResult: Equatable, Sendable {
    public let url: String
    public let status: Int
    /// Sorted by name; URLSession does not keep the server's order.
    public let headers: [(name: String, value: String)]
    public let redirects: [NetToysHTTPRedirect]
    public let timing: NetToysHTTPTiming
    /// "h2", "http/1.1", "h3".
    public let httpVersion: String?
    public let remoteAddress: String?
    public let bodyBytes: Int

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.status == rhs.status && lhs.redirects == rhs.redirects && lhs.timing == rhs.timing
            && lhs.headers.map { [$0.name, $0.value] } == rhs.headers.map { [$0.name, $0.value] }
            && lhs.httpVersion == rhs.httpVersion && lhs.remoteAddress == rhs.remoteAddress
            && lhs.bodyBytes == rhs.bodyBytes
    }
}

public nonisolated enum NetToysHTTPCheck {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// A URL without a scheme gets https://. Follows redirects and records each one.
    // shortcut: GET downloads the whole body, add a byte cap with bytes(for:) if large pages get checked.
    public static func check(_ text: String, method: String = "GET", timeout: TimeInterval = 15) async throws
        -> NetToysHTTPResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw NetToysDiagnoseError.invalidInput("Enter an http or https address.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        let recorder = Recorder()
        let (data, response) = try await session.data(for: request, delegate: recorder)
        guard let response = response as? HTTPURLResponse else {
            throw NetToysDiagnoseError.server("The server did not answer with HTTP.")
        }
        let metrics = recorder.metrics
        let final = metrics?.transactionMetrics.last
        func span(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start) * 1_000
        }
        let tls = span(final?.secureConnectionStartDate, final?.secureConnectionEndDate)
        let timing = NetToysHTTPTiming(
            dns: span(final?.domainLookupStartDate, final?.domainLookupEndDate),
            // URLSession's connect phase includes TLS; report TCP alone.
            connect: span(final?.connectStartDate, final?.connectEndDate).map { $0 - (tls ?? 0) },
            tls: tls,
            firstByte: span(final?.requestStartDate, final?.responseStartDate),
            total: (metrics?.taskInterval.duration ?? 0) * 1_000
        )
        return NetToysHTTPResult(
            url: response.url?.absoluteString ?? url.absoluteString,
            status: response.statusCode,
            headers: response.allHeaderFields.map { ("\($0.key)", "\($0.value)") }
                .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending },
            redirects: recorder.redirects,
            timing: timing,
            httpVersion: final?.networkProtocolName,
            remoteAddress: final?.remoteAddress,
            bodyBytes: data.count
        )
    }

    private final class Recorder: NSObject, URLSessionTaskDelegate, Sendable {
        private let state = Mutex<(redirects: [NetToysHTTPRedirect], metrics: URLSessionTaskMetrics?)>(([], nil))

        var redirects: [NetToysHTTPRedirect] { state.withLock { $0.redirects } }
        var metrics: URLSessionTaskMetrics? { state.withLock { $0.metrics } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            let hop = NetToysHTTPRedirect(url: response.url?.absoluteString ?? "", status: response.statusCode,
                                          location: request.url?.absoluteString ?? "")
            state.withLock { $0.redirects.append(hop) }
            return request
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            state.withLock { $0.metrics = metrics }
        }
    }
}
