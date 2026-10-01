import Darwin
import Foundation
import Synchronization
import NetToysLockFixture
import XCTest
@testable import NetToysCore

final class NetToysOwnershipTests: XCTestCase {
    func testBundledResourcesLoadFromThePackage() throws {
        try NetToysBuild.verifyBundledResources()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NetToys-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLifetimeLockHasOneOwnerAndKeepsItsInodeAfterRelease() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: NetToysProcessLock? = try NetToysProcessLock(directory: directory)
        XCTAssertNotNil(owner)
        XCTAssertTrue(NetToysProcessLock.isHeld(directory: directory))
        XCTAssertThrowsError(try NetToysProcessLock(directory: directory))
        let url = directory.appendingPathComponent("helper.lock")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        owner = nil
        XCTAssertFalse(NetToysProcessLock.isHeld(directory: directory))
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.systemFileNumber] as? UInt64, after[.systemFileNumber] as? UInt64)
    }

    func testKernelReleasesCrashedChildAndOnlyOneRacingChildWins() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("helper.lock").path
        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }
        var children: [Int32] = []
        defer {
            for child in children where child > 0 { kill(child, SIGKILL); var status: Int32 = 0; waitpid(child, &status, 0) }
        }
        try path.withCString { pointer in
            for _ in 0..<2 {
                let child = nettoys_start_lock_holder(pointer, pipeFDs[1])
                guard child >= 0 else { throw POSIXError(.EAGAIN) }
                children.append(child)
            }
        }
        var answers: [UInt8] = []
        for _ in 0..<2 {
            var item = pollfd(fd: pipeFDs[0], events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, 2_000) > 0 else { return XCTFail("Child did not report within two seconds") }
            var answer: UInt8 = 0
            XCTAssertEqual(read(pipeFDs[0], &answer, 1), 1)
            answers.append(answer)
        }
        XCTAssertEqual(answers.sorted(), [0, 1])
        XCTAssertTrue(NetToysProcessLock.isHeld(directory: directory))
        for child in children { kill(child, SIGKILL); var status: Int32 = 0; waitpid(child, &status, 0) }
        children.removeAll()
        XCTAssertFalse(NetToysProcessLock.isHeld(directory: directory))
    }

    func testLockRejectsSymlinksAndHardLinks() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("helper.lock")
        let target = directory.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try NetToysProcessLock(directory: directory))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.linkItem(at: target, to: url)
        XCTAssertThrowsError(try NetToysProcessLock(directory: directory))
    }

    func testConcurrentHostRequestsAndConfigurationEditsDoNotOverwriteEachOther() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("configuration.json")
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                if index % 2 == 0 {
                    try NetToysConfigurationStore.setBackgroundRequest(true, for: .macPowerToys, to: url)
                } else {
                    try NetToysConfigurationStore.setBackgroundRequest(true, for: .standalone, to: url)
                }
            } catch { failures.withLock { $0.append(error.localizedDescription) } }
        }
        XCTAssertTrue(failures.withLock { $0.isEmpty })
        let baseline = try JSONDecoder().decode(NetToysConfiguration.self, from: Data(contentsOf: url))
        XCTAssertEqual(baseline.backgroundRequests, Set(NetToysHostID.allCases))
        try NetToysConfigurationStore.setBackgroundRequest(false, for: .macPowerToys, to: url)
        var edited = baseline
        edited.recordsNetworkHistory = false
        let saved = try NetToysConfigurationStore.saveChanges(edited, since: baseline, to: url)
        XCTAssertEqual(saved.backgroundRequests, [.standalone])
        XCTAssertFalse(saved.recordsNetworkHistory)
        let disabled = try NetToysConfigurationStore.setBackgroundRequest(false, for: .standalone, to: url)
        XCTAssertTrue(disabled.backgroundRequests.isEmpty)
    }

    func testCompatibilityRejectsStaleUntrustedMissingAndWrongVersionOwners() {
        let now = Date()
        var status = NetToysHelperStatus(version: 2, heartbeat: now, anchors: [], sourceCommit: "independent-repo",
                                        ownerBundleID: NetToysHostID.standalone.rawValue, ownerPID: 123,
                                        packageVersion: "1.0.0")
        let signed: (NetToysHostID, Int32) -> Bool = { $0 == .standalone && $1 == 123 }
        XCTAssertTrue(NetToysHelperIdentity.isCompatible(status, now: now, verifyOwner: signed))
        XCTAssertFalse(NetToysHelperIdentity.isCompatible(status, now: now, verifyOwner: { _, _ in false }))
        XCTAssertFalse(NetToysHelperIdentity.isCompatible(status, now: now.addingTimeInterval(8), verifyOwner: signed))
        XCTAssertFalse(NetToysHelperIdentity.isCompatible(status, now: now.addingTimeInterval(-1), verifyOwner: signed))
        status.ownerPID = nil
        XCTAssertFalse(NetToysHelperIdentity.isCompatible(status, now: now, verifyOwner: signed))
        status.ownerPID = 123
        status.packageVersion = "0.1.0"
        XCTAssertFalse(NetToysHelperIdentity.isCompatible(status, now: now, verifyOwner: signed))
        XCTAssertFalse(NetToysHelperIdentity.isCompatible(NetToysHelperStatus(version: 1, heartbeat: now, anchors: []),
                                                         now: now, verifyOwner: signed))
        XCTAssertFalse(NetToysHelperIdentity.isLockAwareHost(at: URL(fileURLWithPath: "/nonexistent/old-host.app")))
    }

    func testMigrationImportsOnlyNineAbsentScannerKeysOnce() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyName = "NetToys.legacy.\(UUID())", sharedName = "NetToys.shared.\(UUID())"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacyName))
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedName))
        defer { legacy.removePersistentDomain(forName: legacyName); shared.removePersistentDomain(forName: sharedName) }
        XCTAssertEqual(NetToysPreferences.scannerKeys.count, 9)
        for key in NetToysPreferences.scannerKeys { legacy.set("old", forKey: key) }
        legacy.set(true, forKey: "tray.nettoys.anchor.expanded")
        shared.set("new", forKey: "nettoys.scanner.target")
        try NetToysPreferences.migrate(legacy: legacy, shared: shared, host: .macPowerToys, directory: directory)
        XCTAssertEqual(shared.string(forKey: "nettoys.scanner.target"), "new")
        XCTAssertNil(shared.object(forKey: "tray.nettoys.anchor.expanded"))
        for key in NetToysPreferences.scannerKeys.dropFirst() { XCTAssertEqual(shared.string(forKey: key), "old") }
        shared.removeObject(forKey: "nettoys.scanner.ports")
        try NetToysPreferences.migrate(legacy: legacy, shared: shared, host: .macPowerToys, directory: directory)
        XCTAssertNil(shared.object(forKey: "nettoys.scanner.ports"))
    }

    func testScannerTransactionsPreserveOtherHostAnnotationsAndFavorites() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let annotations = directory.appendingPathComponent("scanner-annotations.json")
        _ = try NetToysScannerStore.saveAnnotations(["192.0.2.1": .init(comment: "Rack 1")], since: [:], to: annotations)
        let merged = try NetToysScannerStore.saveAnnotations(["192.0.2.1": .init(isFavorite: true)],
                                                            since: [:], to: annotations)
        XCTAssertEqual(merged["192.0.2.1"], .init(comment: "Rack 1", isFavorite: true))
        let favorites = directory.appendingPathComponent("favorite-targets.json")
        _ = try NetToysScannerStore.saveFavoriteTargets(["192.0.2.1"], since: [], to: favorites)
        let added = try NetToysScannerStore.saveFavoriteTargets(["192.0.2.2"], since: [], to: favorites)
        XCTAssertEqual(added, ["192.0.2.1", "192.0.2.2"])
        let removed = try NetToysScannerStore.saveFavoriteTargets([], since: ["192.0.2.1"], to: favorites)
        XCTAssertEqual(removed, ["192.0.2.2"])
    }

    func testHandoffRequiresMatchingLiveSignedParentsAndExpires() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("handoff.json")
        let request = NetToysHandoff(requester: .standalone, owner: .macPowerToys)
        let signed: (String, Int32) -> Bool = { _, pid in pid > 0 }
        XCTAssertTrue(request.isValidRequest(for: .macPowerToys, verifyParent: signed))
        XCTAssertFalse(request.isValidRequest(for: .standalone, verifyParent: signed))
        XCTAssertFalse(request.isValidRequest(for: .macPowerToys, verifyParent: { _, _ in false }))
        XCTAssertFalse(request.isValidRequest(for: .macPowerToys, now: request.expires, verifyParent: signed))
        XCTAssertFalse(request.isValidRequest(for: .macPowerToys, now: request.expires.addingTimeInterval(-60),
                                             verifyParent: signed))
        try request.save(to: url)
        XCTAssertEqual(NetToysHandoff.load(from: url), request)
        var response = request
        response.releasedByPID = 123
        XCTAssertTrue(response.isValidResponse(to: request, verifyParent: signed))
        XCTAssertFalse(response.isValidResponse(to: request, verifyParent: { _, _ in false }))
        XCTAssertFalse(response.isValidResponse(to: request, now: request.expires, verifyParent: signed))
        XCTAssertFalse(response.isValidResponse(to: .init(requester: .standalone, owner: .macPowerToys),
                                               verifyParent: signed))
        XCTAssertFalse(response.isValidRequest(for: .macPowerToys, verifyParent: signed))
    }
}
