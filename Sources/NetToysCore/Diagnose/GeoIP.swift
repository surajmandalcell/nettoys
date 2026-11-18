import Foundation

public nonisolated struct NetToysGeoIPResult: Equatable, Sendable {
    public let ip: String
    public let country: String?
    public let countryCode: String?
    public let region: String?
    public let city: String?
    public let latitude: Double?
    public let longitude: Double?
    public let timeZone: String?
    public let asn: Int?
    public let organization: String?
    public let isp: String?
}

/// Location of an IP address from ipwho.is (free, no key, HTTPS).
/// Privacy: the address asked about, and this Mac's public IP, go to ipwho.is, a third party.
// shortcut: online API, switch to a local GeoLite file if offline use matters.
public nonisolated enum NetToysGeoIP {
    /// `host` nil or empty looks up this Mac's public address. A host name is resolved to IPv4 first.
    public static func lookup(_ host: String? = nil) async throws -> NetToysGeoIPResult {
        let host = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ip = host.isEmpty || host.contains(":") ? host : try await DiagnoseHost.resolve(host).description
        guard let url = URL(string: "https://ipwho.is/" + (ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))
        else { throw NetToysDiagnoseError.invalidInput("\(host) is not an IP address.") }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        return try parse(data)
    }

    package static func parse(_ data: Data) throws -> NetToysGeoIPResult {
        struct Reply: Decodable {
            struct Connection: Decodable { let asn: Int?; let org: String?; let isp: String? }
            struct Zone: Decodable { let id: String? }
            let success: Bool
            let message: String?
            let ip: String?
            let country: String?
            let country_code: String?
            let region: String?
            let city: String?
            let latitude: Double?
            let longitude: Double?
            let connection: Connection?
            let timezone: Zone?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.success, let ip = reply.ip else {
            throw NetToysDiagnoseError.server(reply.message ?? "The GeoIP service did not find that address.")
        }
        return NetToysGeoIPResult(ip: ip, country: reply.country, countryCode: reply.country_code,
                                  region: reply.region, city: reply.city, latitude: reply.latitude,
                                  longitude: reply.longitude, timeZone: reply.timezone?.id,
                                  asn: reply.connection?.asn, organization: reply.connection?.org,
                                  isp: reply.connection?.isp)
    }
}
