import Darwin
import Foundation
import Security

public nonisolated enum NetToysHostID: String, Codable, CaseIterable, Sendable {
    case macPowerToys = "com.surajmandal.macpowertoys"
    case standalone = "com.surajmandal.nettoys"

    public var helperIdentifier: String {
        self == .macPowerToys ? "com.surajmandal.macpowertoys.nettoys-helper" : "com.surajmandal.nettoys.helper"
    }
}

public nonisolated enum NetToysBuild {
    public static let packageVersion = "1.0.0"
    public static let statusSchemaVersion = 2

    public static func verifyBundledResources() throws {
        for (name, extensionName) in [("ieee-mac-vendors", "tsv"), ("IEEE-MAC-VENDORS-NOTICE", "txt")] {
            guard let url = Bundle.module.url(forResource: name, withExtension: extensionName),
                  !(try Data(contentsOf: url)).isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        }
    }
}

/// A stable inode holds the lock. Replacing or removing it permits two owners.
public nonisolated final class NetToysProcessLock: @unchecked Sendable {
    private let descriptor: Int32

    public init(directory: URL = NetToysPaths.directory, name: String = "helper.lock", nonblocking: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.EPERM)
        }
        guard chmod(directory.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
        let descriptor = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0, fileInfo.st_uid == geteuid(),
              fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            throw POSIXError(.EPERM)
        }
        let deadline = Date().addingTimeInterval(3)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard !nonblocking, code == EWOULDBLOCK, Date() < deadline else {
                close(descriptor)
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            usleep(10_000)
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    public static func isHeld(directory: URL = NetToysPaths.directory) -> Bool {
        do { _ = try NetToysProcessLock(directory: directory); return false }
        catch { return true }
    }
}

package nonisolated enum NetToysStoreTransaction {
    package static func withLock<Value>(at directory: URL, _ body: () throws -> Value) throws -> Value {
        let lock = try NetToysProcessLock(directory: directory, name: "store.lock", nonblocking: false)
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }
}

public nonisolated enum NetToysHelperIdentity {
    public static func hasFreshHeartbeat(_ status: NetToysHelperStatus?, now: Date = Date(),
                                        expectedSourceCommit: String? = nil) -> Bool {
        guard let status, (0...7).contains(now.timeIntervalSince(status.heartbeat)) else { return false }
        guard let expectedSourceCommit, !expectedSourceCommit.isEmpty,
              !expectedSourceCommit.hasPrefix("$(") else { return true }
        return status.sourceCommit == expectedSourceCommit
    }

    public static func isCompatible(_ status: NetToysHelperStatus?, now: Date = Date(),
                                    verifyOwner: (NetToysHostID, Int32) -> Bool = isSignedOwner) -> Bool {
        guard let status, hasFreshHeartbeat(status, now: now),
              status.version == NetToysBuild.statusSchemaVersion,
              status.packageVersion == NetToysBuild.packageVersion,
              let owner = status.ownerBundleID.flatMap(NetToysHostID.init(rawValue:)),
              let pid = status.ownerPID, pid > 0 else { return false }
        return verifyOwner(owner, pid)
    }

    public static func isSignedOwner(_ owner: NetToysHostID, _ pid: Int32) -> Bool {
        isSignedProcess(identifier: owner.helperIdentifier, pid: pid)
    }

    package static func isSignedProcess(identifier: String, pid: Int32) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"GF57JXJF5A\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    public static func isLockAwareHost(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "NetToysPackageVersion") as? String == NetToysBuild.packageVersion
        else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(NetToysHostID.macPowerToys.rawValue)\" and anchor apple generic and certificate leaf[subject.OU] = \"GF57JXJF5A\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode),
                                          requirement) == errSecSuccess
    }
}

package nonisolated struct NetToysHandoff: Codable, Equatable, Sendable {
    package let nonce: UUID
    package let requester: NetToysHostID
    package let requesterPID: Int32
    package let owner: NetToysHostID
    package let expires: Date
    package var releasedByPID: Int32?
    package static var url: URL { NetToysPaths.directory.appendingPathComponent("handoff.json") }

    package init(requester: NetToysHostID, owner: NetToysHostID) {
        nonce = UUID()
        self.requester = requester
        requesterPID = getpid()
        self.owner = owner
        expires = Date().addingTimeInterval(8)
    }

    package func isValidRequest(for host: NetToysHostID, now: Date = Date(),
                                verifyParent: (String, Int32) -> Bool = NetToysHelperIdentity.isSignedProcess) -> Bool {
        owner == host && requester != host && requesterPID > 0 && releasedByPID == nil
            && (0...8).contains(expires.timeIntervalSince(now)) && expires > now
            && verifyParent(requester.rawValue, requesterPID)
    }

    package func isValidResponse(to request: Self, now: Date = Date(),
                                 verifyParent: (String, Int32) -> Bool = NetToysHelperIdentity.isSignedProcess) -> Bool {
        guard nonce == request.nonce, requester == request.requester, requesterPID == request.requesterPID,
              owner == request.owner, expires == request.expires, expires > now,
              let pid = releasedByPID, pid > 0 else { return false }
        return verifyParent(owner.rawValue, pid)
    }

    package func save(to url: URL = Self.url) throws {
        try NetToysStoreTransaction.withLock(at: url.deletingLastPathComponent()) {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    package static func load(from url: URL = Self.url) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
