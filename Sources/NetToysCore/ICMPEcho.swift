import Darwin
import Dispatch

/// In-process ICMP echo over one shared unprivileged datagram socket, so checks spawn no `ping` processes.
package nonisolated enum ICMPEcho {
    package struct Reply: Equatable, Sendable {
        package let ttl: Int?
        package let milliseconds: Double
    }

    package struct Packet: Equatable, Sendable {
        package let source: UInt32?
        package let ttl: Int?
        package let type: UInt8
        package let identifier: UInt16
        package let sequence: UInt16
    }

    package static var isAvailable: Bool { EchoSocket.shared != nil }

    /// One echo request; nil on timeout, send failure, or when the socket cannot open.
    package static func send(to address: IPv4Address, timeoutMilliseconds: Int) async -> Reply? {
        await EchoSocket.shared?.echo(to: address.rawValue, timeout: timeoutMilliseconds)
    }

    /// Echo request: type 8, code 0, checksum, identifier, sequence, then an 8-byte payload.
    package static func encodeRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xff),
                              UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        bytes += Array("NetToys!".utf8)
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

    /// Darwin datagram ICMP sockets deliver the IPv4 header before the ICMP message.
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
        guard bytes.count >= offset + 8, checksum(Array(bytes[offset...])) == 0 else { return nil }
        return Packet(
            source: source,
            ttl: ttl,
            type: bytes[offset],
            identifier: UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5]),
            sequence: UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
        )
    }

    /// A reply matches only an echo reply (type 0) with our identifier and sequence from the address we asked.
    package static func matches(_ packet: Packet, identifier: UInt16, sequence: UInt16, address: UInt32) -> Bool {
        packet.type == 0 && packet.identifier == identifier && packet.sequence == sequence
            && (packet.source == nil || packet.source == address)
    }
}

private nonisolated final class EchoSocket: @unchecked Sendable {
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

    private init?() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [unowned self] in drain() }
        source.resume()
    }

    func echo(to address: UInt32, timeout: Int) async -> ICMPEcho.Reply? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard pending.count < Int(UInt16.max) else { return continuation.resume(returning: nil) }
                repeat { sequence &+= 1 } while pending[sequence] != nil
                let sequence = sequence
                let packet = ICMPEcho.encodeRequest(identifier: identifier, sequence: sequence)
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

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 2_048)
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
                ttl: packet.ttl, milliseconds: Double(received - entry.sent) / 1_000_000
            ))
        }
    }
}
