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

    private struct Failure: LocalizedError {
        var errorDescription: String? { "join failed" }
    }

    func testSafeModeStartsAfterThreeFailuresInTenMinutes() throws {
        var gate = NetToysActionGate(log: NetToysActionLog(url: paths.actionLog))
        let settings = NetToysConfiguration()
        XCTAssertTrue(gate.allows(.wifiJoin, "Switched Wi-Fi", settings: settings))

        // Spread over more than ten minutes: no safe mode.
        XCTAssertNil(gate.finish(.wifiJoin, "a", error: Failure(), at: 0))
        XCTAssertNil(gate.finish(.wifiJoin, "b", error: Failure(), at: 400))
        XCTAssertNil(gate.finish(.wifiJoin, "c", error: Failure(), at: 700))
        XCTAssertEqual(gate.warningCount(at: 700), 2)
        XCTAssertEqual(NetToysSystemHealth.make(settings: settings, warnings: 2), .warning(count: 2))

        // The third failure inside ten minutes starts safe mode, and safe mode holds every action.
        let reason = try XCTUnwrap(gate.finish(.wifiJoin, "d", error: Failure(), at: 800))
        XCTAssertTrue(reason.contains("join failed"))
        var held = settings
        held.safeModeReason = reason
        XCTAssertFalse(gate.allows(.sshHostName, "Changed jetson", settings: held))
        XCTAssertEqual(NetToysSystemHealth.make(settings: held, warnings: 0), .failed(reason: reason))
        held.safeModeReason = nil
        held.actionsPaused = true
        XCTAssertEqual(NetToysSystemHealth.make(settings: held, warnings: 0), .paused)

        let log = NetToysActionLog(url: paths.actionLog).entries()
        XCTAssertEqual(log.first?.kind, .safeMode)
        XCTAssertEqual(log.filter { $0.outcome == .failed }.count, 4)
    }

    func testDryRunLogsTheActionAndChangesNothing() throws {
        let config = paths.sshConfig
        let original = Data("Host jetson\n  HostName 192.168.1.8\n".utf8)
        try original.write(to: config)
        let gate = NetToysActionGate(log: NetToysActionLog(url: paths.actionLog))
        var settings = NetToysConfiguration()
        settings.dryRun = true
        let undo = NetToysUndo.sshHostName(anchorID: UUID(), hostAlias: "jetson", from: "192.168.1.8", to: "192.168.1.44")

        var wrote = false
        if gate.allows(.sshHostName, "Changed jetson HostName", undo: undo, settings: settings) {
            _ = try SSHConfigFileUpdater.update(configURL: config, backupDirectory: paths.backups, hostAlias: "jetson",
                                                expectedHostName: "192.168.1.8", newHostName: "192.168.1.44")
            wrote = true
        }

        XCTAssertFalse(wrote)
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backups.path))
        let entries = NetToysActionLog(url: paths.actionLog).entries()
        XCTAssertEqual(entries.map(\.outcome), [.dryRun])
        XCTAssertNil(NetToysActionLog(url: paths.actionLog).lastUndoable(), "A dry run has nothing to undo.")
    }
}
