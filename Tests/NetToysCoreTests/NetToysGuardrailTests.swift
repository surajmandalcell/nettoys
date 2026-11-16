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
}
