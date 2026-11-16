import XCTest
@testable import NetToysCore

/// Risky guardrail logic only, with a temp home, fake clock, and fake network. Never the real ~/.ssh.
final class NetToysGuardrailTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var paths: NetToysRuntimePaths { NetToysRuntimePaths(home: root, data: root.appendingPathComponent("data")) }

    func testSSHWriteIsAtomicCleansTempFilesAndCapsBackups() throws {
        let config = paths.sshConfig
        let original = Data("Host jetson\n  HostName 192.168.1.8\n".utf8)
        try original.write(to: config)
        let stale = root.appendingPathComponent(".ssh/.config.macpowertoys.dead.tmp")
        try Data("half".utf8).write(to: stale)
        XCTAssertEqual(SSHConfigFileUpdater.removeStaleTemporaryFiles(configURL: config), 1)

        // A rejected edit leaves the file and the folder exactly as they were.
        XCTAssertThrowsError(try SSHConfigFileUpdater.update(
            configURL: config, backupDirectory: paths.backups,
            hostAlias: "jetson", expectedHostName: "10.0.0.1", newHostName: "192.168.1.44"))
        XCTAssertEqual(try Data(contentsOf: config), original)

        _ = try SSHConfigFileUpdater.update(
            configURL: config, backupDirectory: paths.backups,
            hostAlias: "jetson", expectedHostName: "192.168.1.8", newHostName: "192.168.1.44")
        XCTAssertEqual(try Data(contentsOf: config), Data("Host jetson\n  HostName 192.168.1.44\n".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".ssh").path), ["config"])
        let backup = try XCTUnwrap(NetToysSSHBackups.list(in: paths.backups).first)
        XCTAssertEqual(backup.hostAlias, "jetson")
        XCTAssertEqual(try Data(contentsOf: backup.url), original)

        try NetToysSSHBackups.restore(backup, configURL: config, backupDirectory: paths.backups)
        XCTAssertEqual(try Data(contentsOf: config), original)

        // 1 MB total, oldest first, across every host.
        let big = Data(repeating: 0x41, count: 400_000)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for (index, host) in ["a", "b", "a", "c"].enumerated() {
            try NetToysSSHBackups.write(big, hostAlias: host, in: paths.backups, date: start + Double(index))
        }
        NetToysSSHBackups.enforceCap(in: paths.backups)
        let kept = NetToysSSHBackups.list(in: paths.backups)
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.size }, NetToysSSHBackups.totalCap)
        XCTAssertTrue(kept.contains { $0.hostAlias == "jetson" }, "The newest small backups stay.")
        XCTAssertEqual(kept.filter { $0.size == big.count }.map(\.hostAlias), ["c", "a"])
    }

    func testHostMoveNeedsMACOrHostKeyProofNeverAnOpenPortAlone() async throws {
        let anchor = SSHAnchorConfiguration(hostAlias: "jetson", hostName: "192.168.1.8", port: 22,
                                            identity: .randomizedMAC(hostname: "jetson", learnedMACs: ["aabbccddeeff"]))
        func result(_ ip: String, mac: String?, name: String?) throws -> NetToysScanResult {
            NetToysScanResult(address: try XCTUnwrap(IPv4Address(ip)), isReachable: true, responseMilliseconds: 1,
                              hostname: name, macAddress: mac, vendor: nil, openPorts: [22])
        }
        let noKey: @Sendable (String, UInt16) async -> Bool = { _, _ in false }
        let sameKey: @Sendable (String, UInt16) async -> Bool = { _, _ in true }

        // A stranger named "jetson" with port 22 open and an unknown MAC: rejected without the host key.
        let stranger = SSHAnchorRecovery.resolve(anchor: anchor, scanResults: [try result("192.168.1.50", mac: "00:11:22:33:44:55", name: "jetson.local")])
        XCTAssertEqual(stranger?.provenByMAC, false)
        let rejected = await SSHAnchorRecovery.proven(stranger, hostKeyMatches: noKey)
        XCTAssertNil(rejected)
        let byKey = await SSHAnchorRecovery.proven(stranger, hostKeyMatches: sameKey)
        XCTAssertEqual(byKey?.hostName, "192.168.1.50")

        // A known MAC proves the device on its own.
        let known = SSHAnchorRecovery.resolve(anchor: anchor, scanResults: [try result("192.168.1.44", mac: "AA:BB:CC:DD:EE:FF", name: nil)])
        let byMAC = await SSHAnchorRecovery.proven(known, hostKeyMatches: noKey)
        XCTAssertEqual(byMAC?.hostName, "192.168.1.44")

        // Host key comparison: same key in known_hosts and in the scan, revoked keys never count.
        let stored = "|1|salt|hash ssh-ed25519 AAAAkeyA\n@cert-authority * ssh-rsa AAAAca\n"
        XCTAssertTrue(SSHHostKeyProof.keysMatch(stored: stored, scanned: "192.168.1.50 ssh-ed25519 AAAAkeyA\n"))
        XCTAssertFalse(SSHHostKeyProof.keysMatch(stored: stored, scanned: "192.168.1.50 ssh-ed25519 AAAAother\n"))
        XCTAssertFalse(SSHHostKeyProof.keysMatch(stored: "@revoked * ssh-ed25519 AAAAkeyA", scanned: "h ssh-ed25519 AAAAkeyA"))
        XCTAssertFalse(SSHHostKeyProof.keysMatch(stored: "", scanned: ""))
    }
}
