import Darwin
import Dispatch

/// In-process ICMP echo over one shared unprivileged datagram socket, so checks spawn no `ping` processes.
/// Darwin delivers "time exceeded" (type 11) and "unreachable" (type 3) on this socket too, so the same
/// socket serves traceroute (TTL per send) and path MTU (don't-fragment per send).
package nonisolated enum ICMPEcho {
    package struct Reply: Equatable, Sendable {
        package let ttl: Int?
        package let milliseconds: Double
        /// Who answered: the target for an echo reply, a router for time exceeded.
        package var source: UInt32? = nil
        /// 0 echo reply, 11 time exceeded, 3 unreachable (code 4 is "fragmentation needed").
        package var type: UInt8 = 0
        package var code: UInt8 = 0
    }

    package struct Packet: Equatable, Sendable {
        package let source: UInt32?
        package let ttl: Int?
        package let type: UInt8
        package let identifier: UInt16
        package let sequence: UInt16
        package var code: UInt8 = 0
        /// For type 11 and 3: the destination of our quoted request.
        package var quotedDestination: UInt32? = nil
    }

    package static var isAvailable: Bool { EchoSocket.shared != nil }

    /// One echo request; nil on timeout, send failure, a router error, or when the socket cannot open.
    package static func send(to address: IPv4Address, timeoutMilliseconds: Int) async -> Reply? {
        await probe(to: address, timeoutMilliseconds: timeoutMilliseconds).flatMap { $0.type == 0 ? $0 : nil }
    }

    /// One echo request that also returns time exceeded and unreachable replies. Nil on timeout, send failure
    /// (EMSGSIZE for an oversized don't-fragment probe), or when the socket cannot open.
    /// `payloadSize` is the ICMP data length after the 8-byte header.
    package static func probe(
        to address: IPv4Address,
        timeoutMilliseconds: Int,
        ttl: Int? = nil,
        payloadSize: Int = 8,
        dontFragment: Bool = false
    ) async -> Reply? {
        await EchoSocket.shared?.echo(
            to: address.rawValue, timeout: timeoutMilliseconds,
            options: EchoSocket.Options(ttl: ttl, payloadSize: payloadSize, dontFragment: dontFragment)
        )
    }

    /// Echo request: type 8, code 0, checksum, identifier, sequence, then the payload ("NetToys!" repeated).
    package static func encodeRequest(identifier: UInt16, sequence: UInt16, payloadSize: Int = 8) -> [UInt8] {
        var bytes: [UInt8] = [8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xff),
                              UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        let filler = Array("NetToys!".utf8)
        bytes += (0..<max(payloadSize, 0)).map { filler[$0 % filler.count] }
        let sum = checksum(bytes)
        bytes[2] = UInt8(sum >> 8)
        bytes[3] = UInt8(sum & 0xff)
        return bytes
    }

    /// RFC 1071 one's-complement sum; a packet with a valid checksum sums to 0.
    package static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// Darwin datagram ICMP sockets deliver the IPv4 header before the ICMP message. For time exceeded and
    /// unreachable, the identifier and sequence come from our request quoted after the 8-byte ICMP header.
    package static func decode(_ bytes: [UInt8]) -> Packet? {
        var offset = 0
        var source: UInt32?
        var ttl: Int?
        if let first = bytes.first, first >> 4 == 4 {
            offset = Int(first & 0x0f) * 4
            guard offset >= 20, bytes.count >= offset else { return nil }
            ttl = Int(bytes[8])
            source = bytes[12..<16].reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard bytes.count >= offset + 8 else { return nil }
        let type = bytes[offset]
        // The kernel checks every ICMP checksum on input, then byte-swaps ip_len in the quoted header of
        // type 3 and 11, so only an echo reply still sums to 0 here.
        guard type == 3 || type == 11 || checksum(Array(bytes[offset...])) == 0 else { return nil }
        var echo = offset
        var quotedDestination: UInt32?
        if type == 11 || type == 3 {
            let inner = offset + 8
            guard bytes.count >= inner + 20, bytes[inner] >> 4 == 4 else { return nil }
            echo = inner + Int(bytes[inner] & 0x0f) * 4
            guard bytes.count >= echo + 8, bytes[echo] == 8 else { return nil }
            quotedDestination = bytes[(inner + 16)..<(inner + 20)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        return Packet(
            source: source,
            ttl: ttl,
            type: type,
            identifier: UInt16(bytes[echo + 4]) << 8 | UInt16(bytes[echo + 5]),
            sequence: UInt16(bytes[echo + 6]) << 8 | UInt16(bytes[echo + 7]),
            code: bytes[offset + 1],
            quotedDestination: quotedDestination
        )
    }

    /// An echo reply (type 0) must come from the address we asked; time exceeded or unreachable must quote it.
    package static func matches(_ packet: Packet, identifier: UInt16, sequence: UInt16, address: UInt32) -> Bool {
        guard packet.identifier == identifier, packet.sequence == sequence else { return false }
        switch packet.type {
        case 0: return packet.source == nil || packet.source == address
        case 3, 11: return packet.quotedDestination == address
        default: return false
        }
    }
}

private nonisolated final class EchoSocket: @unchecked Sendable {
    struct Options: Equatable {
        var ttl: Int?
        var payloadSize: Int
        var dontFragment: Bool
    }

    private struct Pending {
        let address: UInt32
        let sent: UInt64
        let continuation: CheckedContinuation<ICMPEcho.Reply?, Never>
    }

    static let shared = EchoSocket()

    private let descriptor: Int32
    private let identifier = UInt16(truncatingIfNeeded: getpid())
    private let queue = DispatchQueue(label: "NetToys.ICMPEcho", qos: .utility)
    private let source: DispatchSourceRead
    // Confined to `queue`.
    private var sequence: UInt16 = 0
    private var pending: [UInt16: Pending] = [:]
    private var ttl: Int32 = 64
    private var dontFragment: Int32 = 0

    private init?() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [unowned self] in drain() }
        source.resume()
    }

    func echo(to address: UInt32, timeout: Int, options: Options) async -> ICMPEcho.Reply? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard pending.count < Int(UInt16.max) else { return continuation.resume(returning: nil) }
                repeat { sequence &+= 1 } while pending[sequence] != nil
                let sequence = sequence
                let packet = ICMPEcho.encodeRequest(identifier: identifier, sequence: sequence,
                                                    payloadSize: min(max(options.payloadSize, 0), 9_000))
                // Sends run one at a time on `queue`, so a per-send socket option applies to this packet only.
                apply(ttl: Int32(min(max(options.ttl ?? 64, 1), 255)), dontFragment: options.dontFragment ? 1 : 0)
                var target = sockaddr_in()
                target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                target.sin_family = sa_family_t(AF_INET)
                target.sin_addr.s_addr = address.bigEndian
                let sent = DispatchTime.now().uptimeNanoseconds
                let written = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard written == packet.count else { return continuation.resume(returning: nil) }
                pending[sequence] = Pending(address: address, sent: sent, continuation: continuation)
                queue.asyncAfter(deadline: .now() + .milliseconds(max(timeout, 1))) { [self] in
                    pending.removeValue(forKey: sequence)?.continuation.resume(returning: nil)
                }
            }
        }
    }

    private func apply(ttl: Int32, dontFragment: Int32) {
        if ttl != self.ttl {
            var value = ttl
            if setsockopt(descriptor, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                self.ttl = ttl
            }
        }
        if dontFragment != self.dontFragment {
            var value = dontFragment
            if setsockopt(descriptor, IPPROTO_IP, IP_DONTFRAG, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                self.dontFragment = dontFragment
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 9_216)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            let received = DispatchTime.now().uptimeNanoseconds
            guard let packet = ICMPEcho.decode(Array(buffer[..<count])),
                  let entry = pending[packet.sequence],
                  ICMPEcho.matches(packet, identifier: identifier, sequence: packet.sequence, address: entry.address)
            else { continue }
            pending[packet.sequence] = nil
            entry.continuation.resume(returning: ICMPEcho.Reply(
                ttl: packet.ttl, milliseconds: Double(received - entry.sent) / 1_000_000,
                source: packet.source, type: packet.type, code: packet.code
            ))
        }
    }
}
