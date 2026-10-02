import Darwin
import Foundation
import dnssd

package nonisolated enum PortList {
    enum ParseError: LocalizedError {
        case invalid(String)
        case tooMany(Int)

        var errorDescription: String? {
            switch self {
            case .invalid(let value): "Invalid TCP port: \(value)"
            case .tooMany(let limit): "Select no more than \(limit) TCP ports."
            }
        }
    }

    package static func parse(_ input: String, limit: Int = 4_096) throws -> [UInt16] {
        var seen = Set<UInt16>()
        var result: [UInt16] = []
        for part in input.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let text = String(part)
            if text.contains("-") {
                let bounds = text.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2,
                      let start = UInt16(bounds[0]), start > 0,
                      let end = UInt16(bounds[1]), end >= start
                else { throw ParseError.invalid(text) }
                for port in start...end where seen.insert(port).inserted {
                    result.append(port)
                    guard result.count <= limit else { throw ParseError.tooMany(limit) }
                }
            } else {
                guard let port = UInt16(text), port > 0 else { throw ParseError.invalid(text) }
                if seen.insert(port).inserted { result.append(port) }
                guard result.count <= limit else { throw ParseError.tooMany(limit) }
            }
        }
        guard !result.isEmpty else { throw ParseError.invalid(input) }
        return result
    }
}

package nonisolated enum NetToysTargetInput: Equatable, Sendable {
    case addresses([IPv4Address], port: UInt16?)
    case hostname(String, port: UInt16?)

    package enum ParseError: LocalizedError, Equatable {
        case invalid(String)
        case unsupportedIPv6(String)
        case tooMany(Int)

        package var errorDescription: String? {
            switch self {
            case .invalid(let value): "Invalid scan target: \(value)"
            case .unsupportedIPv6(let value): "IPv6 scanning is not supported for this target: \(value)"
            case .tooMany(let limit): "The scan exceeds the \(limit)-target limit."
            }
        }
    }

    package static func parse(_ input: String, limit: Int = 65_536) throws -> [Self] {
        let parts = input.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        guard !parts.isEmpty else { throw ParseError.invalid(input) }
        var result: [Self] = []
        var addressCount = 0
        for part in parts {
            guard result.count < limit else { throw ParseError.tooMany(limit) }
            let token = String(part)
            let (target, port) = try splitPort(token)
            if target.contains(":") { throw ParseError.unsupportedIPv6(token) }
            let addresses: [IPv4Address]
            do {
                addresses = try IPv4Targets.parse(target, limit: max(1, limit - addressCount))
            } catch IPv4Targets.ParseError.tooMany {
                throw ParseError.tooMany(limit)
            } catch {
                guard isHostname(target) else { throw ParseError.invalid(token) }
                result.append(.hostname(target, port: port))
                continue
            }
            if !addresses.isEmpty {
                addressCount += addresses.count
                guard addressCount <= limit else { throw ParseError.tooMany(limit) }
                result.append(.addresses(addresses, port: port))
            } else {
                throw ParseError.invalid(token)
            }
        }
        return result
    }

    private static func splitPort(_ token: String) throws -> (String, UInt16?) {
        let colons = token.indices.filter { token[$0] == ":" }
        guard colons.count <= 1 else { throw ParseError.unsupportedIPv6(token) }
        guard let separator = colons.first else { return (token, nil) }
        let target = String(token[..<separator])
        let value = String(token[token.index(after: separator)...])
        guard !target.isEmpty, let port = UInt16(value), port > 0 else {
            throw ParseError.invalid(token)
        }
        return (target, port)
    }

    private static func isHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253,
              !value.contains("/"), !value.contains("-") || value.contains(where: \.isLetter)
        else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: true)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard label.utf8.count <= 63,
                  label.first != "-", label.last != "-"
            else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}

package nonisolated struct NetToysScanTarget: Equatable, Hashable, Sendable {
    package let address: IPv4Address
    package let ports: [UInt16]

    package init(address: IPv4Address, ports: [UInt16]) {
        self.address = address
        self.ports = ports
    }
}

package nonisolated enum NetToysTargetResolver {
    package static func resolve(
        _ input: String,
        defaultPorts: [UInt16],
        limit: Int = 65_536
    ) async throws -> [NetToysScanTarget] {
        let inputs = try NetToysTargetInput.parse(input, limit: limit)
        var order: [IPv4Address] = []
        var portsByAddress: [IPv4Address: Set<UInt16>] = [:]
        for item in inputs {
            let addresses: [IPv4Address]
            let port: UInt16?
            switch item {
            case .addresses(let values, let value):
                addresses = values
                port = value
            case .hostname(let hostname, let value):
                addresses = await HostResolver.forward(hostname)
                port = value
                guard !addresses.isEmpty else { throw NetToysTargetInput.ParseError.invalid(hostname) }
            }
            let selectedPorts = port.map { [$0] } ?? defaultPorts
            for address in addresses {
                if portsByAddress[address] == nil { order.append(address) }
                portsByAddress[address, default: []].formUnion(selectedPorts)
                guard order.count <= limit else { throw NetToysTargetInput.ParseError.tooMany(limit) }
            }
        }
        return order.map { address in
            NetToysScanTarget(address: address, ports: portsByAddress[address, default: []].sorted())
        }
    }
}

nonisolated enum TCPPortState: String, Codable, Sendable {
    case open
    case closed
    case unreachable
}

nonisolated struct TCPPortProbeResult: Equatable, Sendable {
    let state: TCPPortState
    let latencyMilliseconds: Double
}

nonisolated enum TCPPortProbe {
    static func check(host: String, port: UInt16, timeoutMilliseconds: Int) async -> TCPPortProbeResult {
        await Task.detached(priority: .userInitiated) {
            checkSynchronously(host: host, port: port, timeoutMilliseconds: timeoutMilliseconds)
        }.value
    }

    private static func checkSynchronously(
        host: String,
        port: UInt16,
        timeoutMilliseconds: Int
    ) -> TCPPortProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return result(.unreachable, started: started) }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return result(.unreachable, started: started)
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return result(.unreachable, started: started)
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return result(.open, started: started) }
        if errno == ECONNREFUSED { return result(.closed, started: started) }
        guard errno == EINPROGRESS else { return result(.unreachable, started: started) }

        var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let pollResult = Darwin.poll(&item, 1, Int32(max(1, timeoutMilliseconds)))
        guard pollResult > 0 else { return result(.unreachable, started: started) }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return result(.unreachable, started: started)
        }
        switch socketError {
        case 0: return result(.open, started: started)
        case ECONNREFUSED: return result(.closed, started: started)
        default: return result(.unreachable, started: started)
        }
    }

    private static func result(_ state: TCPPortState, started: UInt64) -> TCPPortProbeResult {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return TCPPortProbeResult(state: state, latencyMilliseconds: elapsed)
    }
}

package nonisolated struct PingProbeResult: Equatable, Sendable {
    let ttl: Int?
    let packetLossPercent: Double?
    package let averageMilliseconds: Double?
}

public nonisolated enum NetToysLivenessMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case tcp = "TCP ports"
    case icmpAndTCP = "ICMP and TCP ports"

    public var id: String { rawValue }
}

package nonisolated enum PingProbe {
    static func check(
        address: IPv4Address,
        count: Int,
        timeoutMilliseconds: Int
    ) async -> PingProbeResult? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = [
                "-n", "-c", String(min(max(count, 1), 5)),
                "-W", String(min(max(timeoutMilliseconds, 100), 5_000)),
                address.description
            ]
            process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return parse(String(decoding: data, as: UTF8.self))
            } catch {
                return nil
            }
        }.value
    }

    package static func parse(_ output: String) -> PingProbeResult? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let ttl = lines.compactMap { line -> Int? in
            guard let range = line.range(of: "ttl=") else { return nil }
            return Int(line[range.upperBound...].prefix(while: \.isNumber))
        }.first
        let loss = lines.compactMap { line -> Double? in
            guard line.contains("packet loss"), let percent = line.firstIndex(of: "%") else { return nil }
            let prefix = line[..<percent]
            let value = prefix.split(whereSeparator: { $0 == " " || $0 == "," }).last
            return value.flatMap { Double($0) }
        }.first
        let average = lines.compactMap { line -> Double? in
            guard line.contains("min/avg/max"), let equals = line.firstIndex(of: "=") else { return nil }
            let values = line[line.index(after: equals)...].split(separator: "/")
            guard values.count >= 2 else { return nil }
            return Double(values[1].trimmingCharacters(in: .whitespaces))
        }.first
        guard ttl != nil || loss != nil || average != nil else { return nil }
        return PingProbeResult(ttl: ttl, packetLossPercent: loss, averageMilliseconds: average)
    }
}

package nonisolated struct NetToysCustomTextProbe: Codable, Equatable, Sendable {
    package let port: UInt16
    package let request: String
    package let responsePattern: String

    package init(port: UInt16, request: String, responsePattern: String) {
        self.port = port
        self.request = request
        self.responsePattern = responsePattern
    }

    enum ValidationError: LocalizedError {
        case invalidPort
        case requestTooLarge
        case patternRequired
        case patternTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidPort: "The custom text probe port must be between 1 and 65535."
            case .requestTooLarge: "The custom text request must be 16 KB or smaller."
            case .patternRequired: "Enter a response regular expression for the custom text probe."
            case .patternTooLarge: "The response regular expression must be 1 KB or smaller."
            }
        }
    }

    package func validate() throws {
        guard port > 0 else { throw ValidationError.invalidPort }
        guard request.utf8.count <= 16_384 else { throw ValidationError.requestTooLarge }
        guard !responsePattern.isEmpty else { throw ValidationError.patternRequired }
        guard responsePattern.utf8.count <= 1_024 else { throw ValidationError.patternTooLarge }
        _ = try NSRegularExpression(pattern: responsePattern)
    }

    func match(in response: Data) throws -> String? {
        try validate()
        let text = String(decoding: response, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: responsePattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range, in: text)
        else { return nil }
        return String(text[valueRange])
    }
}

package nonisolated struct NetToysFetchOptions: Equatable, Sendable {
    var detectHTTPServer = false
    var detectHTTPProxy = false
    var detectNetBIOS = false
    var customTextProbe: NetToysCustomTextProbe?

    package init(detectHTTPServer: Bool = false, detectHTTPProxy: Bool = false,
                 detectNetBIOS: Bool = false, customTextProbe: NetToysCustomTextProbe? = nil) {
        self.detectHTTPServer = detectHTTPServer
        self.detectHTTPProxy = detectHTTPProxy
        self.detectNetBIOS = detectNetBIOS
        self.customTextProbe = customTextProbe
    }
}

nonisolated struct NetToysProtocolMetadata: Sendable {
    let httpServer: String?
    let httpProxy: String?
    let netBIOSName: String?
    let customText: String?
}

nonisolated enum TCPTextProbe {
    static func exchange(
        address: IPv4Address,
        port: UInt16,
        request: Data,
        timeoutMilliseconds: Int,
        responseLimit: Int = 16_384
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            exchangeSynchronously(
                address: address,
                port: port,
                request: request,
                timeoutMilliseconds: timeoutMilliseconds,
                responseLimit: responseLimit
            )
        }.value
    }

    private static func exchangeSynchronously(
        address: IPv4Address,
        port: UInt16,
        request: Data,
        timeoutMilliseconds: Int,
        responseLimit: Int
    ) -> Data? {
        guard request.count <= 16_384 else { return nil }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address.description, &socketAddress.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS,
                  poll(descriptor, events: Int16(POLLOUT), timeoutMilliseconds: timeoutMilliseconds)
            else { return nil }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0
            else { return nil }
        }

        if !request.isEmpty {
            let sent = request.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return true }
                var offset = 0
                while offset < bytes.count {
                    guard poll(descriptor, events: Int16(POLLOUT), timeoutMilliseconds: timeoutMilliseconds) else {
                        return false
                    }
                    let count = Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                    if count > 0 { offset += count; continue }
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                return true
            }
            guard sent else { return nil }
        }

        let limit = min(max(responseLimit, 1), 65_536)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: min(4_096, limit))
        var wait = min(max(timeoutMilliseconds, 50), 5_000)
        while response.count < limit,
              poll(descriptor, events: Int16(POLLIN), timeoutMilliseconds: wait) {
            let capacity = min(buffer.count, limit - response.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(descriptor, bytes.baseAddress, capacity, 0)
            }
            guard count > 0 else { break }
            response.append(buffer, count: count)
            wait = 10
        }
        return response.isEmpty ? nil : response
    }

    private static func poll(_ descriptor: Int32, events: Int16, timeoutMilliseconds: Int) -> Bool {
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&item, 1, Int32(min(max(timeoutMilliseconds, 1), 5_000)))
        return result > 0 && item.revents & (events | Int16(POLLHUP)) != 0
    }
}

nonisolated enum NetToysProtocolFetchers {
    static func httpServer(from response: Data) -> String? {
        guard let headers = HTTPHeaders(response), headers.statusLine.hasPrefix("HTTP/") else { return nil }
        return headers["server"] ?? headers.statusLine
    }

    static func proxy(from response: Data) -> String? {
        guard let headers = HTTPHeaders(response), headers.statusLine.hasPrefix("HTTP/") else { return nil }
        if headers.statusLine.localizedCaseInsensitiveContains("connection established")
            || headers["proxy-agent"] != nil || headers["via"] != nil {
            return headers["proxy-agent"] ?? "HTTP proxy"
        }
        return nil
    }

    static func collect(
        address: IPv4Address,
        openPorts: [UInt16],
        timeoutMilliseconds: Int,
        options: NetToysFetchOptions
    ) async -> NetToysProtocolMetadata {
        async let httpServer = options.detectHTTPServer
            ? detectHTTPServer(address: address, ports: openPorts, timeoutMilliseconds: timeoutMilliseconds)
            : nil
        async let httpProxy = options.detectHTTPProxy
            ? detectProxy(address: address, ports: openPorts, timeoutMilliseconds: timeoutMilliseconds)
            : nil
        async let netBIOSName = options.detectNetBIOS
            ? NetBIOSProbe.check(address: address, timeoutMilliseconds: timeoutMilliseconds)
            : nil
        async let customText = detectCustomText(
            address: address,
            probe: options.customTextProbe,
            timeoutMilliseconds: timeoutMilliseconds
        )
        return await NetToysProtocolMetadata(
            httpServer: httpServer,
            httpProxy: httpProxy,
            netBIOSName: netBIOSName,
            customText: customText
        )
    }

    private static func detectHTTPServer(
        address: IPv4Address,
        ports: [UInt16],
        timeoutMilliseconds: Int
    ) async -> String? {
        for port in ports where port != 443 {
            let request = Data("HEAD / HTTP/1.0\r\nHost: \(address)\r\nConnection: close\r\n\r\n".utf8)
            if let response = await TCPTextProbe.exchange(
                address: address,
                port: port,
                request: request,
                timeoutMilliseconds: timeoutMilliseconds
            ), let value = httpServer(from: response) { return "\(port): \(value)" }
        }
        return nil
    }

    private static func detectProxy(
        address: IPv4Address,
        ports: [UInt16],
        timeoutMilliseconds: Int
    ) async -> String? {
        let request = Data("CONNECT 127.0.0.1:1 HTTP/1.0\r\nConnection: close\r\n\r\n".utf8)
        for port in ports {
            if let response = await TCPTextProbe.exchange(
                address: address,
                port: port,
                request: request,
                timeoutMilliseconds: timeoutMilliseconds
            ), let value = proxy(from: response) { return "\(port): \(value)" }
        }
        return nil
    }

    private static func detectCustomText(
        address: IPv4Address,
        probe: NetToysCustomTextProbe?,
        timeoutMilliseconds: Int
    ) async -> String? {
        guard let probe else { return nil }
        guard let response = await TCPTextProbe.exchange(
            address: address,
            port: probe.port,
            request: Data(probe.request.utf8),
            timeoutMilliseconds: timeoutMilliseconds
        ) else { return nil }
        return try? probe.match(in: response)
    }

    private struct HTTPHeaders {
        private let values: [String: String]
        let statusLine: String

        init?(_ data: Data) {
            let text = String(decoding: data.prefix(16_384), as: UTF8.self)
            let lines = text.components(separatedBy: .newlines)
            guard let status = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty
            else { return nil }
            statusLine = status
            values = lines.dropFirst().reduce(into: [:]) { result, line in
                guard let separator = line.firstIndex(of: ":") else { return }
                let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !value.isEmpty { result[key] = value }
            }
        }

        subscript(_ name: String) -> String? { values[name.lowercased()] }
    }
}

nonisolated enum NetBIOSProbe {
    static func check(address: IPv4Address, timeoutMilliseconds: Int) async -> String? {
        await Task.detached(priority: .utility) {
            checkSynchronously(address: address, timeoutMilliseconds: timeoutMilliseconds)
        }.value
    }

    static func parse(_ response: Data) -> String? {
        let bytes = [UInt8](response)
        guard bytes.count >= 12 else { return nil }
        let questionCount = Int(readUInt16(bytes, at: 4) ?? 0)
        let answerCount = Int(readUInt16(bytes, at: 6) ?? 0)
        var offset = 12
        for _ in 0..<questionCount {
            guard let next = skipName(bytes, at: offset), next + 4 <= bytes.count else { return nil }
            offset = next + 4
        }
        for _ in 0..<answerCount {
            guard let nameEnd = skipName(bytes, at: offset), nameEnd + 10 <= bytes.count,
                  let type = readUInt16(bytes, at: nameEnd),
                  let length = readUInt16(bytes, at: nameEnd + 8)
            else { return nil }
            let dataStart = nameEnd + 10
            let dataEnd = dataStart + Int(length)
            guard dataEnd <= bytes.count else { return nil }
            defer { offset = dataEnd }
            guard type == 0x21, dataStart < dataEnd else { continue }
            let count = Int(bytes[dataStart])
            let namesEnd = dataStart + 1 + count * 18
            guard namesEnd <= dataEnd else { return nil }
            var computer: String?
            var fallbackComputer: String?
            var workgroup: String?
            var user: String?
            for index in 0..<count {
                let entry = dataStart + 1 + index * 18
                let suffix = bytes[entry + 15]
                let flags = readUInt16(bytes, at: entry + 16) ?? 0
                let name = String(decoding: bytes[entry..<(entry + 15)], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if flags & 0x8000 != 0 {
                    if workgroup == nil, suffix == 0 || suffix == 0x1E { workgroup = name }
                } else {
                    if computer == nil, suffix == 0 { computer = name }
                    if fallbackComputer == nil, suffix == 0x20 { fallbackComputer = name }
                    if user == nil, suffix == 3 { user = name }
                }
            }
            computer = computer ?? fallbackComputer
            let macBytes = namesEnd + 6 <= dataEnd ? Array(bytes[namesEnd..<(namesEnd + 6)]) : []
            let mac = macBytes.count == 6 && macBytes.contains(where: { $0 != 0 })
                ? macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                : nil
            let identity: String?
            if let computer, let user, let workgroup {
                identity = "\(workgroup)\\\(user)@\(computer)"
            } else if let computer, let user {
                identity = "\(user)@\(computer)"
            } else if let computer, let workgroup {
                identity = "\(workgroup)\\\(computer)"
            } else {
                identity = computer ?? user ?? workgroup
            }
            if let identity { return mac.map { "\(identity) [\($0)]" } ?? identity }
            if let mac { return "[\(mac)]" }
        }
        return nil
    }

    private static func checkSynchronously(address: IPv4Address, timeoutMilliseconds: Int) -> String? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = UInt16(137).bigEndian
        guard inet_pton(AF_INET, address.description, &socketAddress.sin_addr) == 1 else { return nil }
        let query = statusQuery()
        let sent = query.withUnsafeBytes { bytes in
            withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return nil }
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&item, 1, Int32(min(max(timeoutMilliseconds, 50), 5_000))) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = buffer.withUnsafeMutableBytes { bytes in
            recv(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard count > 0 else { return nil }
        return parse(Data(buffer.prefix(count)))
    }

    static func statusQuery() -> Data {
        var bytes = Data([0x4D, 0x50, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x20])
        let name = [UInt8(ascii: "*")] + Array(repeating: UInt8(0), count: 15)
        for byte in name {
            bytes.append(UInt8(ascii: "A") + (byte >> 4))
            bytes.append(UInt8(ascii: "A") + (byte & 0x0F))
        }
        bytes.append(contentsOf: [0, 0, 0x21, 0, 1])
        return bytes
    }

    private static func skipName(_ bytes: [UInt8], at start: Int) -> Int? {
        var offset = start
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length & 0xC0 == 0xC0 { return offset + 2 <= bytes.count ? offset + 2 : nil }
            offset += 1
            if length == 0 { return offset }
            guard length <= 63, offset + length <= bytes.count else { return nil }
            offset += length
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset + 1 < bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}

public nonisolated struct NetToysScanResult: Codable, Identifiable, Equatable, Sendable {
    public var id: String { address.description }
    public let address: IPv4Address
    public var isReachable: Bool
    public var responseMilliseconds: Double?
    public var hostname: String?
    public var macAddress: String?
    public var vendor: String?
    public var openPorts: [UInt16]
    public var filteredPorts: [UInt16]?
    public var ttl: Int?
    public var packetLossPercent: Double?
    public var httpServer: String?
    public var httpProxy: String?
    public var netBIOSName: String?
    public var customText: String?
    public var comment: String?

    public init(
        address: IPv4Address,
        isReachable: Bool,
        responseMilliseconds: Double?,
        hostname: String?,
        macAddress: String?,
        vendor: String?,
        openPorts: [UInt16],
        filteredPorts: [UInt16]? = nil,
        ttl: Int? = nil,
        packetLossPercent: Double? = nil,
        httpServer: String? = nil,
        httpProxy: String? = nil,
        netBIOSName: String? = nil,
        customText: String? = nil,
        comment: String? = nil
    ) {
        self.address = address
        self.isReachable = isReachable
        self.responseMilliseconds = responseMilliseconds
        self.hostname = hostname
        self.macAddress = macAddress
        self.vendor = vendor
        self.openPorts = openPorts
        self.filteredPorts = filteredPorts
        self.ttl = ttl
        self.packetLossPercent = packetLossPercent
        self.httpServer = httpServer
        self.httpProxy = httpProxy
        self.netBIOSName = netBIOSName
        self.customText = customText
        self.comment = comment
    }
}

package nonisolated struct NetToysScanStatistics: Equatable, Sendable {
    package let addressCount: Int
    package let reachableCount: Int
    package let openPortHostCount: Int
    package let openPortCount: Int
    package let averageResponseMilliseconds: Double?
    package let fastestResponseMilliseconds: Double?
    package let slowestResponseMilliseconds: Double?
    package let duration: TimeInterval?

    package init(results: [NetToysScanResult], duration: TimeInterval?) {
        let responses = results.compactMap(\.responseMilliseconds)
        addressCount = results.count
        reachableCount = results.filter(\.isReachable).count
        openPortHostCount = results.filter { !$0.openPorts.isEmpty }.count
        openPortCount = results.reduce(0) { $0 + $1.openPorts.count }
        averageResponseMilliseconds = responses.isEmpty ? nil : responses.reduce(0, +) / Double(responses.count)
        fastestResponseMilliseconds = responses.min()
        slowestResponseMilliseconds = responses.max()
        self.duration = duration
    }

    package var downCount: Int { addressCount - reachableCount }
    package var addressesPerSecond: Double? {
        guard let duration, duration > 0 else { return nil }
        return Double(addressCount) / duration
    }
}

public nonisolated struct NetToysOpener: Codable, Identifiable, Equatable, Sendable {
    package enum ValidationError: LocalizedError {
        case nameRequired
        case nameTooLong
        case invalidPort
        case invalidTemplate
        case unsupportedScheme
        case credentialsNotAllowed
        case tooManyOpeners
        case duplicateName

        package var errorDescription: String? {
            switch self {
            case .nameRequired: "Enter an opener name."
            case .nameTooLong: "Opener names must be 64 characters or shorter."
            case .invalidPort: "Opener ports must be between 1 and 65535."
            case .invalidTemplate: "Enter an absolute URL with a supported placeholder."
            case .unsupportedScheme: "Use HTTP, HTTPS, SSH, FTP, SFTP, Telnet, SMB, or VNC."
            case .credentialsNotAllowed: "Opener URLs cannot contain a user name or password."
            case .tooManyOpeners: "Use no more than 20 openers."
            case .duplicateName: "Give each opener a different name."
            }
        }
    }

    public static let defaults = [
        Self(name: "Web", urlTemplate: "http://{ip}:{port}/", requiredPort: 80),
        Self(name: "Secure Web", urlTemplate: "https://{ip}:{port}/", requiredPort: 443),
        Self(name: "SSH", urlTemplate: "ssh://{ip}:{port}", requiredPort: 22),
        Self(name: "FTP", urlTemplate: "ftp://{ip}:{port}/", requiredPort: 21),
        Self(name: "Screen Sharing", urlTemplate: "vnc://{ip}:{port}", requiredPort: 5900)
    ]

    private static let allowedSchemes = Set(["http", "https", "ssh", "ftp", "sftp", "telnet", "smb", "vnc"])
    private static let placeholders = ["{ip}", "{hostname}", "{port}"]

    public var id = UUID()
    public var name: String
    public var urlTemplate: String
    public var requiredPort: Int

    public init(id: UUID = UUID(), name: String, urlTemplate: String, requiredPort: Int) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.requiredPort = requiredPort
    }

    package func validate() throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw ValidationError.nameRequired }
        guard cleanName.count <= 64 else { throw ValidationError.nameTooLong }
        guard (1...65_535).contains(requiredPort) else { throw ValidationError.invalidPort }
        guard !urlTemplate.isEmpty, urlTemplate.utf8.count <= 2_048 else {
            throw ValidationError.invalidTemplate
        }
        guard urlTemplate.contains("{ip}") || urlTemplate.contains("{hostname}") else {
            throw ValidationError.invalidTemplate
        }
        var remainder = urlTemplate
        for placeholder in Self.placeholders {
            remainder = remainder.replacingOccurrences(of: placeholder, with: "")
        }
        guard !remainder.contains("{") && !remainder.contains("}") else {
            throw ValidationError.invalidTemplate
        }
        _ = try resolvedURL(
            address: IPv4Address(rawValue: 0xC000_0201),
            hostname: "host.example"
        )
    }

    package func applies(to result: NetToysScanResult) -> Bool {
        guard let port = UInt16(exactly: requiredPort) else { return false }
        return result.openPorts.contains(port)
    }

    package func resolvedURL(address: IPv4Address, hostname: String?) throws -> URL {
        let safeHostname = hostname.flatMap(Self.safeHostname) ?? address.description
        let expanded = urlTemplate
            .replacingOccurrences(of: "{ip}", with: address.description)
            .replacingOccurrences(of: "{hostname}", with: safeHostname)
            .replacingOccurrences(of: "{port}", with: String(requiredPort))
        guard let components = URLComponents(string: expanded),
              let scheme = components.scheme?.lowercased(),
              components.host != nil,
              let url = components.url,
              url.absoluteString.utf8.count <= 4_096
        else { throw ValidationError.invalidTemplate }
        guard Self.allowedSchemes.contains(scheme) else { throw ValidationError.unsupportedScheme }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentialsNotAllowed
        }
        return url
    }

    private static func safeHostname(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 253,
              clean.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
              })
        else { return nil }
        return clean
    }
}

public nonisolated struct NetToysScanRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public let date: Date
    public let target: String
    public let ports: [UInt16]
    public let duration: TimeInterval
    public let results: [NetToysScanResult]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        target: String,
        ports: [UInt16],
        duration: TimeInterval,
        results: [NetToysScanResult]
    ) {
        self.id = id
        self.date = date
        self.target = target
        self.ports = ports
        self.duration = duration
        self.results = results
    }
}

package nonisolated struct NetToysScanArchive: Codable, Equatable, Sendable {
    package var runs: [NetToysScanRun]

    package init(runs: [NetToysScanRun] = [], limit: Int = 50) {
        self.runs = Array(runs.suffix(max(1, limit)))
    }

    mutating func append(_ run: NetToysScanRun, limit: Int = 50) {
        runs.append(run)
        if runs.count > limit { runs.removeFirst(runs.count - limit) }
    }
}

package nonisolated struct NetToysHostAnnotation: Codable, Equatable, Sendable {
    package var comment: String = ""
    package var isFavorite = false

    package init(comment: String = "", isFavorite: Bool = false) {
        self.comment = comment
        self.isFavorite = isFavorite
    }
}

package nonisolated enum NetToysScannerStore {
    package static func archive() -> NetToysScanArchive {
        load(NetToysScanArchive.self, from: NetToysPaths.scanHistory) ?? NetToysScanArchive()
    }

    package static func record(_ run: NetToysScanRun) throws {
        try NetToysStoreTransaction.withLock(at: NetToysPaths.directory) {
            var value = archive()
            value.append(run)
            try save(value, to: NetToysPaths.scanHistory)
        }
    }

    package static func clearArchive() throws {
        try NetToysStoreTransaction.withLock(at: NetToysPaths.directory) {
            try save(NetToysScanArchive(), to: NetToysPaths.scanHistory)
        }
    }

    package static func annotations(at url: URL = NetToysPaths.scannerAnnotations) -> [String: NetToysHostAnnotation] {
        load([String: NetToysHostAnnotation].self, from: url) ?? [:]
    }

    package static func saveAnnotations(_ value: [String: NetToysHostAnnotation],
                                        since original: [String: NetToysHostAnnotation],
                                        to url: URL = NetToysPaths.scannerAnnotations) throws -> [String: NetToysHostAnnotation] {
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            var latest = annotations(at: url)
            for key in Set(value.keys).union(original.keys) {
                let edited = value[key] ?? NetToysHostAnnotation()
                let baseline = original[key] ?? NetToysHostAnnotation()
                var entry = latest[key] ?? NetToysHostAnnotation()
                if edited.comment != baseline.comment { entry.comment = edited.comment }
                if edited.isFavorite != baseline.isFavorite { entry.isFavorite = edited.isFavorite }
                latest[key] = entry.comment.isEmpty && !entry.isFavorite ? nil : entry
            }
            try save(latest, to: url)
            return latest
        }
    }

    package static func favoriteTargets(at url: URL = NetToysPaths.favoriteTargets) -> [String] {
        load([String].self, from: url) ?? []
    }

    package static func saveFavoriteTargets(_ value: [String], since original: [String],
                                            to url: URL = NetToysPaths.favoriteTargets) throws -> [String] {
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            let removed = Set(original).subtracting(value)
            var latest = favoriteTargets(at: url).filter { !removed.contains($0) }
            for target in value where !original.contains(target) && !latest.contains(target) { latest.append(target) }
            latest = Array(latest.prefix(50))
            try save(latest, to: url)
            return latest
        }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

package actor NetToysScanner {
    private let neighborContract: NetToysNeighborServiceContract?

    package init(neighborContract: NetToysNeighborServiceContract? = nil) {
        self.neighborContract = neighborContract
    }

    package func scan(
        targets: [IPv4Address],
        ports: [UInt16],
        timeoutMilliseconds: Int = 750,
        concurrency: Int = 64,
        collectPingDetails: Bool = false,
        pingProbeCount: Int = 2,
        livenessMethod: NetToysLivenessMethod = .tcp,
        pingTimeoutMilliseconds: Int = 750,
        adaptiveTCPTimeout: Bool = false,
        scanUnresponsiveHosts: Bool = true,
        launchDelayMilliseconds: Int = 0,
        fetchOptions: NetToysFetchOptions = NetToysFetchOptions(),
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        update: (@Sendable (NetToysScanResult) -> Void)? = nil
    ) async -> [NetToysScanResult] {
        await scan(
            targets: targets.map { NetToysScanTarget(address: $0, ports: ports) },
            timeoutMilliseconds: timeoutMilliseconds,
            concurrency: concurrency,
            collectPingDetails: collectPingDetails,
            pingProbeCount: pingProbeCount,
            livenessMethod: livenessMethod,
            pingTimeoutMilliseconds: pingTimeoutMilliseconds,
            adaptiveTCPTimeout: adaptiveTCPTimeout,
            scanUnresponsiveHosts: scanUnresponsiveHosts,
            launchDelayMilliseconds: launchDelayMilliseconds,
            fetchOptions: fetchOptions,
            progress: progress,
            update: update
        )
    }

    package func scan(
        targets: [NetToysScanTarget],
        timeoutMilliseconds: Int = 750,
        concurrency: Int = 64,
        collectPingDetails: Bool = false,
        pingProbeCount: Int = 2,
        livenessMethod: NetToysLivenessMethod = .tcp,
        pingTimeoutMilliseconds: Int = 750,
        adaptiveTCPTimeout: Bool = false,
        scanUnresponsiveHosts: Bool = true,
        launchDelayMilliseconds: Int = 0,
        fetchOptions: NetToysFetchOptions = NetToysFetchOptions(),
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        update: (@Sendable (NetToysScanResult) -> Void)? = nil
    ) async -> [NetToysScanResult] {
        let maximum = min(max(concurrency, 1), 256)
        let activeNetwork = LocalIPv4Network.active()
        let localDNSServer = await Self.localDNSServer(in: activeNetwork)
        var scanned: [NetToysScanResult] = []
        scanned.reserveCapacity(targets.count)
        var completed = 0
        for offset in stride(from: 0, to: targets.count, by: maximum) {
            if Task.isCancelled { break }
            let batch = targets[offset..<min(offset + maximum, targets.count)]
            let results = await withTaskGroup(of: NetToysScanResult?.self) { group in
                for (index, target) in batch.enumerated() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        if launchDelayMilliseconds > 0, index > 0 {
                            try? await Task.sleep(for: .milliseconds(
                                min(1_000, launchDelayMilliseconds) * index
                            ))
                        }
                        return await Self.scanHost(
                            target.address,
                            ports: target.ports,
                            timeoutMilliseconds: timeoutMilliseconds,
                            collectPingDetails: collectPingDetails,
                            pingProbeCount: pingProbeCount,
                            livenessMethod: livenessMethod,
                            pingTimeoutMilliseconds: pingTimeoutMilliseconds,
                            adaptiveTCPTimeout: adaptiveTCPTimeout,
                            scanUnresponsiveHosts: scanUnresponsiveHosts,
                            fetchOptions: fetchOptions,
                            nameServer: Self.nameServer(localDNSServer, for: target.address, in: activeNetwork),
                            update: update
                        )
                    }
                }
                var values: [NetToysScanResult] = []
                for await value in group {
                    if let value { values.append(value) }
                    completed += 1
                    progress?(completed, targets.count)
                }
                return values
            }
            scanned.append(contentsOf: results)
        }
        let interfaceIndex = activeNetwork.map { if_nametoindex($0.interfaceName) } ?? 0
        // A local host that answered ARP is alive even when every probed port is closed.
        let neighborCandidates = scanned.filter {
            $0.isReachable || activeNetwork?.contains($0.address.description) == true
        }.map(\.address)
        let arp = Task.isCancelled ? [:] : await ARPTable.load(
            addresses: neighborCandidates,
            interfaceIndex: interfaceIndex,
            contract: neighborContract
        )
        var macAddresses = arp
        // The neighbor table has no usable entry for this Mac's own address; read the interface.
        if let activeNetwork, let ownMAC = ARPTable.interfaceMAC(named: activeNetwork.interfaceName) {
            macAddresses[activeNetwork.address.description] = ownMAC
        }
        let (enriched, newlyAlive) = Self.applyNeighbors(scanned, macAddresses: macAddresses)
        let names = await Self.reverseNames(newlyAlive, server: localDNSServer)
        return enriched.map { result in
            var result = result
            if let name = names[result.address] { result.hostname = name }
            if result.macAddress != nil { update?(result) }
            return result
        }.sorted { $0.address < $1.address }
    }

    nonisolated static func applyNeighbors(
        _ results: [NetToysScanResult],
        macAddresses: [String: String]
    ) -> (results: [NetToysScanResult], newlyAlive: [IPv4Address]) {
        var newlyAlive: [IPv4Address] = []
        let updated = results.map { result in
            guard let macAddress = macAddresses[result.address.description] else { return result }
            var enriched = result
            enriched.macAddress = macAddress
            enriched.vendor = MACVendorDatabase.bundled.vendor(for: macAddress)
            if !enriched.isReachable {
                enriched.isReachable = true
                newlyAlive.append(result.address)
            }
            return enriched
        }
        return (updated, newlyAlive)
    }

    private nonisolated static func reverseNames(
        _ addresses: [IPv4Address],
        server: IPv4Address?
    ) async -> [IPv4Address: String] {
        guard !addresses.isEmpty, !Task.isCancelled else { return [:] }
        return await withTaskGroup(of: (IPv4Address, String?).self) { group in
            for address in addresses {
                group.addTask { (address, await HostResolver.reverse(address, localServer: server)) }
            }
            var names: [IPv4Address: String] = [:]
            for await (address, name) in group { if let name { names[address] = name } }
            return names
        }
    }

    /// Home routers answer PTR queries for their DHCP clients; public resolvers such as 1.1.1.1 cannot.
    private nonisolated static func localDNSServer(in network: LocalIPv4Network?) async -> IPv4Address? {
        guard let network, let route = await DefaultRoute.load(),
              route.interfaceName == network.interfaceName, network.contains(route.gateway) else { return nil }
        return IPv4Address(route.gateway)
    }

    nonisolated static func nameServer(
        _ server: IPv4Address?,
        for address: IPv4Address,
        in network: LocalIPv4Network?
    ) -> IPv4Address? {
        network?.contains(address.description) == true ? server : nil
    }

    private nonisolated static func scanHost(
        _ address: IPv4Address,
        ports: [UInt16],
        timeoutMilliseconds: Int,
        collectPingDetails: Bool,
        pingProbeCount: Int,
        livenessMethod: NetToysLivenessMethod,
        pingTimeoutMilliseconds: Int,
        adaptiveTCPTimeout: Bool,
        scanUnresponsiveHosts: Bool,
        fetchOptions: NetToysFetchOptions,
        nameServer: IPv4Address?,
        update: (@Sendable (NetToysScanResult) -> Void)?
    ) async -> NetToysScanResult {
        let needsPing = collectPingDetails || livenessMethod == .icmpAndTCP || adaptiveTCPTimeout
        let ping = needsPing
            ? await PingProbe.check(
                address: address,
                count: pingProbeCount,
                timeoutMilliseconds: pingTimeoutMilliseconds
            )
            : nil
        var reachable = pingResponded(ping) && (collectPingDetails || livenessMethod == .icmpAndTCP)
        var openPorts: [UInt16] = []
        var filteredPorts: [UInt16] = []
        var fastest = reachable ? ping?.averageMilliseconds : nil
        let tcpTimeout = effectiveTCPTimeout(
            configuredMilliseconds: timeoutMilliseconds,
            pingAverageMilliseconds: ping?.averageMilliseconds,
            adaptive: adaptiveTCPTimeout
        )
        if shouldScanPorts(
            ping: ping,
            livenessMethod: livenessMethod,
            scanUnresponsiveHosts: scanUnresponsiveHosts
        ) {
            for port in ports {
                if Task.isCancelled { break }
                let probe = await TCPPortProbe.check(
                    host: address.description,
                    port: port,
                    timeoutMilliseconds: tcpTimeout
                )
                if probe.state != .unreachable {
                    reachable = true
                    fastest = min(fastest ?? probe.latencyMilliseconds, probe.latencyMilliseconds)
                }
                if probe.state == .open { openPorts.append(port) }
                if probe.state == .unreachable { filteredPorts.append(port) }
            }
        }
        var result = NetToysScanResult(
            address: address,
            isReachable: reachable,
            responseMilliseconds: fastest,
            hostname: nil,
            macAddress: nil,
            vendor: nil,
            openPorts: openPorts,
            filteredPorts: reportedFilteredPorts(filteredPorts, reachable: reachable),
            ttl: ping?.ttl,
            packetLossPercent: ping?.packetLossPercent
        )
        update?(result)
        guard reachable, !Task.isCancelled else { return result }

        async let hostname = HostResolver.reverse(address, localServer: nameServer)
        let metadata = await NetToysProtocolFetchers.collect(
            address: address,
            openPorts: openPorts,
            timeoutMilliseconds: tcpTimeout,
            options: fetchOptions
        )
        result.httpServer = metadata.httpServer
        result.httpProxy = metadata.httpProxy
        result.netBIOSName = metadata.netBIOSName
        result.customText = metadata.customText
        if metadata.httpServer != nil || metadata.httpProxy != nil
            || metadata.netBIOSName != nil || metadata.customText != nil {
            update?(result)
        }
        result.hostname = await hostname
        if result.hostname != nil { update?(result) }
        return result
    }

    nonisolated static func reportedFilteredPorts(_ ports: [UInt16], reachable: Bool) -> [UInt16] {
        reachable ? ports : []
    }

    nonisolated static func effectiveTCPTimeout(
        configuredMilliseconds: Int,
        pingAverageMilliseconds: Double?,
        adaptive: Bool
    ) -> Int {
        let configured = min(max(configuredMilliseconds, 100), 5_000)
        guard adaptive,
              let average = pingAverageMilliseconds,
              average.isFinite,
              average >= 0
        else { return configured }
        return min(configured, max(100, Int(ceil(average * 4))))
    }

    nonisolated static func shouldScanPorts(
        ping: PingProbeResult?,
        livenessMethod: NetToysLivenessMethod,
        scanUnresponsiveHosts: Bool
    ) -> Bool {
        guard livenessMethod == .icmpAndTCP,
              !scanUnresponsiveHosts,
              let loss = ping?.packetLossPercent
        else { return true }
        return loss < 100
    }

    private nonisolated static func pingResponded(_ ping: PingProbeResult?) -> Bool {
        guard let loss = ping?.packetLossPercent else { return false }
        return loss < 100
    }
}

nonisolated enum HostResolver {
    static func forward(_ hostname: String) async -> [IPv4Address] {
        await Task.detached(priority: .utility) { forwardSynchronously(hostname) }.value
    }

    static func reverse(_ address: IPv4Address, localServer: IPv4Address? = nil) async -> String? {
        await Task.detached(priority: .utility) {
            reverseSynchronously(address, flags: 0)
                ?? localServer.flatMap { unicastPTR(address, server: $0) }
                ?? reverseSynchronously(address, flags: DNSServiceFlags(kDNSServiceFlagsForceMulticast))
        }.value
    }

    private static func reverseName(_ address: IPv4Address) -> String {
        address.description.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
    }

    static func unicastPTR(_ address: IPv4Address, server: IPv4Address, timeoutMilliseconds: Int32 = 800) -> String? {
        let id = UInt16.random(in: 1...UInt16.max)
        let query = ptrQuery(for: address, id: id)
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(53).bigEndian
        destination.sin_addr.s_addr = server.rawValue.bigEndian
        let sent = query.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return nil }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&event, 1, timeoutMilliseconds) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        return ptrAnswer(in: Array(buffer.prefix(received)), id: id)
    }

    static func ptrQuery(for address: IPv4Address, id: UInt16) -> [UInt8] {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in reverseName(address).split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: label.utf8)
        }
        packet.append(contentsOf: [0, 0, 12, 0, 1])
        return packet
    }

    /// Returns the first PTR answer of a reply to `id`. Rejects truncated, failed, and looping messages.
    static func ptrAnswer(in message: [UInt8], id: UInt16) -> String? {
        guard message.count >= 12,
              UInt16(message[0]) << 8 | UInt16(message[1]) == id,
              message[2] & 0x80 != 0, message[3] & 0x0F == 0 else { return nil }
        let questions = Int(message[4]) << 8 | Int(message[5])
        let answers = Int(message[6]) << 8 | Int(message[7])
        var offset = 12
        for _ in 0..<questions {
            guard let end = nameEnd(in: message, from: offset), end + 4 <= message.count else { return nil }
            offset = end + 4
        }
        for _ in 0..<answers {
            guard let end = nameEnd(in: message, from: offset), end + 10 <= message.count else { return nil }
            let type = Int(message[end]) << 8 | Int(message[end + 1])
            let length = Int(message[end + 8]) << 8 | Int(message[end + 9])
            let data = end + 10
            guard data + length <= message.count else { return nil }
            if type == 12 { return name(in: message, at: data) }
            offset = data + length
        }
        return nil
    }

    private static func nameEnd(in message: [UInt8], from start: Int) -> Int? {
        var offset = start
        while offset < message.count {
            let length = Int(message[offset])
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 { return offset + 2 <= message.count ? offset + 2 : nil }
            guard length <= 63 else { return nil }
            offset += 1 + length
        }
        return nil
    }

    private static func name(in message: [UInt8], at start: Int) -> String? {
        var labels: [String] = []
        var offset = start
        var jumps = 0
        var total = 0
        while offset < message.count {
            let length = Int(message[offset])
            if length == 0 {
                let joined = labels.joined(separator: ".")
                return labels.isEmpty || total > 255 ? nil : joined
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < message.count, jumps < 16 else { return nil }
                jumps += 1
                offset = (length & 0x3F) << 8 | Int(message[offset + 1])
                continue
            }
            guard length <= 63, offset + 1 + length <= message.count,
                  let label = String(bytes: message[(offset + 1)...(offset + length)], encoding: .utf8),
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else { return nil }
            labels.append(label)
            total += length + 1
            offset += 1 + length
        }
        return nil
    }

    private static func forwardSynchronously(_ hostname: String) -> [IPv4Address] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &head) == 0, let head else { return [] }
        defer { freeaddrinfo(head) }
        var result: [IPv4Address] = []
        var seen = Set<IPv4Address>()
        var current: UnsafeMutablePointer<addrinfo>? = head
        while let item = current {
            if item.pointee.ai_family == AF_INET, let socketAddress = item.pointee.ai_addr {
                let value = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    IPv4Address(rawValue: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                }
                if seen.insert(value).inserted { result.append(value) }
            }
            current = item.pointee.ai_next
        }
        return result.sorted()
    }

    private static func reverseSynchronously(_ address: IPv4Address, flags: DNSServiceFlags) -> String? {
        let queryName = reverseName(address) + "."
        var answer: String?
        return withUnsafeMutablePointer(to: &answer) { answerPointer in
            var query: DNSServiceRef?
            let status = DNSServiceQueryRecord(
                &query, flags, 0, queryName,
                UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                { _, flags, _, error, _, _, _, length, data, _, context in
                    guard error == kDNSServiceErr_NoError,
                          flags & kDNSServiceFlagsAdd != 0,
                          let data, let context, length <= 255 else { return }
                    context.assumingMemoryBound(to: String?.self).pointee =
                        HostResolver.ptrHostname(from: Data(bytes: data, count: Int(length)))
                },
                answerPointer
            )
            guard status == kDNSServiceErr_NoError, let query else { return nil }
            defer { DNSServiceRefDeallocate(query) }
            let socket = DNSServiceRefSockFD(query)
            guard socket >= 0 else { return nil }
            var event = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&event, 1, 1_500) > 0,
                  event.revents & Int16(POLLIN) != 0,
                  DNSServiceProcessResult(query) == kDNSServiceErr_NoError else { return nil }
            return answerPointer.pointee
        }
    }

    static func ptrHostname(from data: Data) -> String? {
        var labels: [String] = []
        var offset = 0
        while offset < data.count {
            let length = Int(data[offset])
            offset += 1
            if length == 0 {
                return offset == data.count && !labels.isEmpty ? labels.joined(separator: ".") : nil
            }
            guard length <= 63, offset + length <= data.count,
                  let label = String(bytes: data[offset..<(offset + length)], encoding: .utf8),
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else { return nil }
            labels.append(label)
            offset += length
        }
        return nil
    }
}

public nonisolated enum ARPTable {
    static func load(
        addresses: [IPv4Address],
        interfaceIndex: UInt32,
        contract: NetToysNeighborServiceContract? = nil
    ) async -> [String: String] {
        await Task.detached(priority: .utility) {
            var result = loadSynchronously(addresses: addresses, interfaceIndex: interfaceIndex)
            guard result.count < Set(addresses).count else { return result }
            result.merge(loadNeighborCache(addresses: addresses, interfaceIndex: interfaceIndex)) {
                current, _ in current
            }
            let missing = addresses.filter { result[$0.description] == nil }
            if !missing.isEmpty, let contract {
                result.merge(await NetToysNeighborXPCClient.load(
                    addresses: missing,
                    interfaceIndex: interfaceIndex,
                    contract: contract
                )) { current, _ in current }
            }
            return result
        }.value
    }

    static func loadNeighborCache(
        addresses: [IPv4Address],
        interfaceIndex: UInt32
    ) -> [String: String] {
        guard interfaceIndex > 0, interfaceIndex <= UInt16.max else { return [:] }
        guard let data = neighborCacheData() else { return [:] }
        let requested = Set(addresses.map(\.description))
        return parseRoutingMessages(data, interfaceIndex: interfaceIndex)
            .filter { requested.contains($0.key) }
    }

    static func interfaceMAC(named name: String) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == name,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK)
            else { continue }
            let raw = UnsafeRawPointer(address)
            let link = raw.loadUnaligned(as: sockaddr_dl.self)
            let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8
            let start = dataOffset + Int(link.sdl_nlen)
            guard link.sdl_alen == 6, start + 6 <= Int(link.sdl_len) else { return nil }
            let octets = (0..<6).map { raw.load(fromByteOffset: start + $0, as: UInt8.self) }
            guard octets.contains(where: { $0 != 0 }) else { return nil }
            return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return nil
    }

    public static func neighborCacheData() -> Data? {
        var mib = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        if size < data.count { data.removeSubrange(size..<data.count) }
        return data
    }

    static func queryMessage(
        for address: IPv4Address,
        interfaceIndex: UInt32,
        sequence: Int32,
        processID: pid_t
    ) -> Data {
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + MemoryLayout<sockaddr_in>.size)
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_index = UInt16(interfaceIndex)
        header.rtm_flags = RTF_IFSCOPE
        header.rtm_addrs = RTA_DST
        header.rtm_pid = processID
        header.rtm_seq = sequence
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_addr.s_addr = address.rawValue.bigEndian
        var message = withUnsafeBytes(of: &header) { Data($0) }
        message.append(withUnsafeBytes(of: &destination) { Data($0) })
        return message
    }

    private static func loadSynchronously(
        addresses: [IPv4Address],
        interfaceIndex: UInt32
    ) -> [String: String] {
        guard interfaceIndex > 0, interfaceIndex <= UInt16.max else { return [:] }
        let descriptor = socket(PF_ROUTE, SOCK_RAW, 0)
        guard descriptor >= 0 else { return [:] }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        let processID = getpid()
        var result: [String: String] = [:]
        for (offset, address) in Array(Set(addresses)).sorted().enumerated() {
            let sequence = Int32(truncatingIfNeeded: offset + 1)
            let query = queryMessage(
                for: address,
                interfaceIndex: interfaceIndex,
                sequence: sequence,
                processID: processID
            )
            let sent = query.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            guard sent == query.count else { continue }
            for _ in 0..<8 {
                var reply = Data(count: 2_048)
                let byteCount = reply.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                guard byteCount >= MemoryLayout<rt_msghdr>.size else { break }
                let header = reply.withUnsafeBytes {
                    $0.loadUnaligned(as: rt_msghdr.self)
                }
                guard header.rtm_pid == processID, header.rtm_seq == sequence else { continue }
                guard header.rtm_errno == 0 else { break }
                if let macAddress = neighborMAC(
                    in: reply.prefix(byteCount),
                    expectedAddress: address,
                    interfaceIndex: interfaceIndex
                ) {
                    result[address.description] = macAddress
                }
                break
            }
        }
        return result
    }

    static func neighborMAC(
        in data: Data,
        expectedAddress: IPv4Address,
        interfaceIndex: UInt32
    ) -> String? {
        guard data.count >= MemoryLayout<rt_msghdr>.size else { return nil }
        let header = data.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        guard header.rtm_index == UInt16(interfaceIndex),
              header.rtm_flags & RTF_LLINFO != 0,
              header.rtm_flags & RTF_GATEWAY == 0
        else { return nil }
        return parseRoutingMessages(data, interfaceIndex: interfaceIndex)[expectedAddress.description]
    }

    static func parseRoutingMessages(
        _ data: Data,
        interfaceIndex: UInt32? = nil
    ) -> [String: String] {
        data.withUnsafeBytes { bytes in
            var result: [String: String] = [:]
            var messageOffset = 0
            let headerSize = MemoryLayout<rt_msghdr>.size
            while messageOffset + headerSize <= bytes.count {
                let header = bytes.loadUnaligned(
                    fromByteOffset: messageOffset,
                    as: rt_msghdr.self
                )
                let messageLength = Int(header.rtm_msglen)
                guard messageLength >= headerSize,
                      messageOffset + messageLength <= bytes.count
                else { break }
                if let interfaceIndex, header.rtm_index != UInt16(interfaceIndex) {
                    messageOffset += messageLength
                    continue
                }
                var addressOffset = messageOffset + headerSize
                var ipAddress: String?
                var macAddress: String?
                for index in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << index) != 0 {
                    guard addressOffset + 2 <= messageOffset + messageLength else { break }
                    let addressLength = Int(bytes[addressOffset])
                    let family = Int32(bytes[addressOffset + 1])
                    let alignedLength = addressLength > 0
                        ? (addressLength + MemoryLayout<UInt32>.size - 1)
                            & ~(MemoryLayout<UInt32>.size - 1)
                        : MemoryLayout<UInt32>.size
                    guard addressOffset + alignedLength <= messageOffset + messageLength else { break }
                    if index == Int(RTAX_DST), family == AF_INET, addressLength >= 8 {
                        ipAddress = (4..<8)
                            .map { String(bytes[addressOffset + $0]) }
                            .joined(separator: ".")
                    } else if index == Int(RTAX_GATEWAY), family == AF_LINK, addressLength >= 8 {
                        let nameLength = Int(bytes[addressOffset + 5])
                        let macLength = Int(bytes[addressOffset + 6])
                        let macOffset = addressOffset + 8 + nameLength
                        if macLength == 6, macOffset + macLength <= addressOffset + addressLength {
                            let octets = (0..<macLength).map { bytes[macOffset + $0] }
                            if octets != [2, 0, 0, 0, 0, 0], octets.contains(where: { $0 != 0 }) {
                                macAddress = octets
                                    .map { String(format: "%02x", $0) }
                                    .joined(separator: ":")
                            }
                        }
                    }
                    addressOffset += alignedLength
                }
                if let ipAddress, let macAddress { result[ipAddress] = macAddress }
                messageOffset += messageLength
            }
            return result
        }
    }
}

nonisolated struct MACVendorDatabase: Sendable {
    static let bundled: Self = {
        guard let url = Bundle.module.url(forResource: "ieee-mac-vendors", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return Self(text: "") }
        return Self(text: text)
    }()

    private let vendors: [String: String]

    init(text: String) {
        vendors = text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            guard !line.hasPrefix("#") else { return }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let bits = Int(fields[0]), [24, 28, 36].contains(bits),
                  fields[1].count == bits / 4,
                  !fields[2].isEmpty
            else { return }
            result["\(bits):\(fields[1].uppercased())"] = String(fields[2])
        }
    }

    func vendor(for macAddress: String?) -> String? {
        guard let macAddress else { return nil }
        let normalized = AnchorMatcher.normalizedMAC(macAddress)
        guard normalized.count == 12,
              let firstOctet = UInt8(normalized.prefix(2), radix: 16)
        else { return nil }
        // Phones and Macs use randomized, locally administered addresses on Wi-Fi.
        guard firstOctet & 0x02 == 0 else { return "Private address" }
        let hexadecimal = normalized.uppercased()
        return vendors["36:\(hexadecimal.prefix(9))"]
            ?? vendors["28:\(hexadecimal.prefix(7))"]
            ?? vendors["24:\(hexadecimal.prefix(6))"]
    }
}

package nonisolated enum NetToysScanExport {
    enum ExportError: LocalizedError {
        case tooLarge

        var errorDescription: String? {
            "The saved scan exceeds the 32 MiB import limit. Export fewer results."
        }
    }

    private struct SavedResults: Codable {
        let version: Int
        let results: [NetToysScanResult]
    }

    package static func savedResults(_ results: [NetToysScanResult]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SavedResults(version: 1, results: results))
        guard data.count <= NetToysFileImport.resultsByteLimit else { throw ExportError.tooLarge }
        return data
    }

    package static func csv(_ results: [NetToysScanResult], includeHeader: Bool = true) -> String {
        let rows = results.map { result in
            [
                result.address.description,
                result.isReachable ? "Up" : "Down",
                result.responseMilliseconds.map { String(format: "%.1f", $0) } ?? "",
                result.ttl.map(String.init) ?? "",
                result.packetLossPercent.map { String(format: "%.1f", $0) } ?? "",
                result.filteredPorts?.map(String.init).joined(separator: " ") ?? "",
                result.hostname ?? "",
                result.macAddress ?? "",
                result.vendor ?? "",
                result.openPorts.map(String.init).joined(separator: " "),
                result.httpServer ?? "",
                result.httpProxy ?? "",
                result.netBIOSName ?? "",
                result.customText ?? "",
                result.comment ?? ""
            ].map(quote).joined(separator: ",")
        }
        let header = "IP Address,Status,Response ms,TTL,Packet Loss %,Filtered Ports,Hostname,MAC Address,Vendor,Open Ports,HTTP Server,HTTP Proxy,NetBIOS,Custom Text,Comments"
        return ((includeHeader ? [header] : []) + rows).joined(separator: "\n")
    }

    package static func text(_ results: [NetToysScanResult]) -> String {
        results.map { result in
            [
                result.address.description,
                result.isReachable ? "Up" : "Down",
                result.ttl.map(String.init) ?? "-",
                result.packetLossPercent.map { String(format: "%.1f%%", $0) } ?? "-",
                result.hostname ?? "-",
                result.macAddress ?? "-",
                result.vendor ?? "-",
                result.openPorts.map(String.init).joined(separator: ","),
                result.filteredPorts?.map(String.init).joined(separator: ",") ?? "",
                result.httpServer ?? "-",
                result.httpProxy ?? "-",
                result.netBIOSName ?? "-",
                result.customText ?? "-",
                result.comment ?? "-"
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    package static func ipPorts(_ results: [NetToysScanResult]) -> String {
        results.flatMap { result in
            result.openPorts.map { "\(result.address):\($0)" }
        }.joined(separator: "\n")
    }

    package static func xml(_ results: [NetToysScanResult]) -> String {
        let hosts = results.map { result in
            """
              <host ip="\(xmlEscape(result.address.description))" status="\(result.isReachable ? "up" : "down")">
                <hostname>\(xmlEscape(result.hostname ?? ""))</hostname>
                <mac>\(xmlEscape(result.macAddress ?? ""))</mac>
                <mac-vendor>\(xmlEscape(result.vendor ?? ""))</mac-vendor>
                <ttl>\(result.ttl.map(String.init) ?? "")</ttl>
                <packet-loss>\(result.packetLossPercent.map { String(format: "%.1f", $0) } ?? "")</packet-loss>
                <ports>\(xmlEscape(result.openPorts.map(String.init).joined(separator: " ")))</ports>
                <filtered-ports>\(xmlEscape(result.filteredPorts?.map(String.init).joined(separator: " ") ?? ""))</filtered-ports>
                <http-server>\(xmlEscape(result.httpServer ?? ""))</http-server>
                <http-proxy>\(xmlEscape(result.httpProxy ?? ""))</http-proxy>
                <netbios>\(xmlEscape(result.netBIOSName ?? ""))</netbios>
                <custom-text>\(xmlEscape(result.customText ?? ""))</custom-text>
                <comment>\(xmlEscape(result.comment ?? ""))</comment>
              </host>
            """
        }.joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<scan>\n\(hosts)\n</scan>"
    }

    package static func sql(_ results: [NetToysScanResult], includeSchema: Bool = true) -> String {
        let rows = results.map { result in
            let values = [
                result.address.description,
                result.isReachable ? "up" : "down",
                result.ttl.map(String.init) ?? "",
                result.packetLossPercent.map { String(format: "%.1f", $0) } ?? "",
                result.hostname ?? "",
                result.macAddress ?? "",
                result.vendor ?? "",
                result.openPorts.map(String.init).joined(separator: " "),
                result.filteredPorts?.map(String.init).joined(separator: " ") ?? "",
                result.httpServer ?? "",
                result.httpProxy ?? "",
                result.netBIOSName ?? "",
                result.customText ?? "",
                result.comment ?? ""
            ].map(sqlQuote).joined(separator: ", ")
            return "INSERT INTO nettoys_scan (ip_address, status, ttl, packet_loss, hostname, mac_address, mac_vendor, open_ports, filtered_ports, http_server, http_proxy, netbios, custom_text, comment) VALUES (\(values));"
        }
        let schema = "CREATE TABLE IF NOT EXISTS nettoys_scan (ip_address TEXT, status TEXT, ttl TEXT, packet_loss TEXT, hostname TEXT, mac_address TEXT, mac_vendor TEXT, open_ports TEXT, filtered_ports TEXT, http_server TEXT, http_proxy TEXT, netbios TEXT, custom_text TEXT, comment TEXT);"
        return ((includeSchema ? [schema] : []) + rows).joined(separator: "\n")
    }

    package static func append(_ value: String, to url: URL) throws {
        guard !value.isEmpty else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var prefix = ""
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            prefix = try handle.read(upToCount: 1) == Data([0x0A]) ? "" : "\n"
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: Data((prefix + value).utf8))
        try handle.synchronize()
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sqlQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

package nonisolated enum NetToysFileImport {
    package static let targetByteLimit = 2 * 1_024 * 1_024
    package static let resultsByteLimit = 32 * 1_024 * 1_024

    enum ImportError: LocalizedError, Equatable {
        case tooLarge(Int)
        case invalidTextEncoding

        var errorDescription: String? {
            switch self {
            case .tooLarge(let limit):
                "The selected file exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit."
            case .invalidTextEncoding:
                "The target list must be UTF-8 text."
            }
        }
    }

    package static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw ImportError.tooLarge(maximumBytes) }
        }
        return data
    }

    package static func targets(from url: URL) throws -> String {
        let data = try read(url, maximumBytes: targetByteLimit)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidTextEncoding
        }
        let targets = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = line.prefix(while: { $0 != "#" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.joined(separator: ", ")
        _ = try NetToysTargetInput.parse(targets)
        return targets
    }
}

package nonisolated enum NetToysScanImport {
    enum ImportError: LocalizedError {
        case unsupportedVersion(Int)
        case empty
        case duplicateAddress

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "Unsupported NetToys results version: \(version)"
            case .empty: "The NetToys results file is empty."
            case .duplicateAddress: "The NetToys results file contains duplicate IP addresses."
            }
        }
    }

    private struct SavedResults: Codable {
        let version: Int
        let results: [NetToysScanResult]
    }

    package static func savedResults(_ data: Data) throws -> [NetToysScanResult] {
        let value = try JSONDecoder().decode(SavedResults.self, from: data)
        guard value.version == 1 else { throw ImportError.unsupportedVersion(value.version) }
        guard !value.results.isEmpty else { throw ImportError.empty }
        guard Set(value.results.map(\.id)).count == value.results.count else {
            throw ImportError.duplicateAddress
        }
        return value.results
    }
}
