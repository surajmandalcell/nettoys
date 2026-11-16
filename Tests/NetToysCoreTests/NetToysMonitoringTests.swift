import XCTest
@testable import NetToysCore

/// Risky monitoring logic only, with a temp folder and a fake clock. No real network, no real notifications.
final class NetToysMonitoringTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMagicPacketIsSixFFThenTheMACSixteenTimes() throws {
        let packet = try XCTUnwrap(NetToysWakeOnLAN.magicPacket(mac: "3C:22:FB:01:A2:FF"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        for copy in 0..<16 {
            XCTAssertEqual(Array(packet[(6 + copy * 6)..<(12 + copy * 6)]), [0x3c, 0x22, 0xfb, 0x01, 0xa2, 0xff])
        }
        XCTAssertNil(NetToysWakeOnLAN.magicPacket(mac: "3c:22:fb"))
    }

    func testLatencyHistoryKeeps24HoursAndStaysUnderItsSizeCap() throws {
        let url = root.appendingPathComponent("latency.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Two days of 10 s samples for 20 devices is far over the cap.
        let samples = (0..<17_280).map { NetToysLatencySample(date: now - Double($0) * 10, milliseconds: $0 % 7 == 0 ? nil : 12.34) }
        var batch = [String: [NetToysLatencySample]]()
        for device in 0..<20 { batch["192.0.2.\(device)"] = samples.reversed() }
        try NetToysLatencyStore.append(batch, to: url, now: now)
        try NetToysLatencyStore.append([NetToysLatencyHistory.gateway: [.init(date: now, milliseconds: 3)]], to: url, now: now)

        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, NetToysLatencyHistory.maximumBytes)
        let history = NetToysLatencyStore.load(from: url)
        let all = history.series.values.flatMap { $0 }
        XCTAssertTrue(all.allSatisfy { now.timeIntervalSince($0.date) < 86_400 }, "Nothing older than 24 hours.")
        XCTAssertEqual(history.series[NetToysLatencyHistory.gateway]?.last?.milliseconds, 3, "The newest sample stays.")
        XCTAssertEqual(history.series["192.0.2.5"]?.last?.date, now, "Trimming drops the oldest samples first.")
        XCTAssertTrue(all.contains { $0.milliseconds == nil }, "A lost ping is kept as a lost ping.")
    }

    func testNewDeviceIsAnnouncedOnceAndAFreshInstallAnnouncesNothing() throws {
        let url = root.appendingPathComponent("known-devices.json")
        func device(_ last: Int, _ mac: String?) -> NetToysScanResult {
            NetToysScanResult(address: IPv4Address(rawValue: 0xC000_0200 + UInt32(last)), isReachable: true,
                              responseMilliseconds: 2, hostname: nil, macAddress: mac, vendor: nil, openPorts: [])
        }
        let home = [device(1, "aa:bb:cc:00:00:01"), device(2, "aa:bb:cc:00:00:02"), device(3, nil)]
        XCTAssertEqual(try NetToysKnownDevices.newDevices(home, at: url), [], "The first look only learns the network.")
        XCTAssertEqual(try NetToysKnownDevices.newDevices(home, at: url), [])

        // Same MAC at a new address is not new; a new MAC is announced once, in either MAC spelling.
        let moved = [device(9, "AA-BB-CC-00-00-01"), device(4, "aa:bb:cc:00:00:04")]
        XCTAssertEqual(try NetToysKnownDevices.newDevices(moved, at: url).map(\.id), ["192.0.2.4"])
        XCTAssertEqual(try NetToysKnownDevices.newDevices(moved, at: url), [])
        XCTAssertEqual(NetToysKnownDevices.alert(for: [device(4, "aa:bb:cc:00:00:04")])?.title, "New device on your network")
    }

    func testJoinNowAndStayRespectPauseAndCooldown() throws {
        var monitor = WiFiFailoverMonitor()
        XCTAssertFalse(monitor.shouldAttempt(isFailure: true, ssid: "Home", threshold: 60, at: 100))
        XCTAssertEqual(monitor.nextAttempt(threshold: 60), 160, "The panel counts down to the end of the outage wait.")
        // Join Now skips the outage wait.
        monitor.requestJoinNow()
        XCTAssertTrue(monitor.shouldAttempt(isFailure: true, ssid: "Home", threshold: 60, at: 105))
        monitor.didAttempt(at: 105)
        monitor.didSwitch(to: "Backup", at: 105, cooldown: 600)
        // It never skips the rest after a switch: it waits for the cooldown, then runs.
        monitor.requestJoinNow()
        XCTAssertFalse(monitor.shouldAttempt(isFailure: true, ssid: "Backup", threshold: 60, at: 200))
        XCTAssertTrue(monitor.shouldAttempt(isFailure: true, ssid: "Backup", threshold: 60, at: 705))

        // Stay holds every switch until this outage ends, then the next outage counts again.
        var stay = WiFiFailoverMonitor()
        XCTAssertFalse(stay.shouldAttempt(isFailure: true, ssid: "Home", threshold: 30, at: 0))
        stay.stay()
        XCTAssertNil(stay.nextAttempt(threshold: 30), "No countdown while staying.")
        XCTAssertFalse(stay.shouldAttempt(isFailure: true, ssid: "Home", threshold: 30, at: 500))
        XCTAssertFalse(stay.shouldAttempt(isFailure: false, ssid: "Home", threshold: 30, at: 510))
        XCTAssertFalse(stay.shouldAttempt(isFailure: true, ssid: "Home", threshold: 30, at: 520))
        XCTAssertTrue(stay.shouldAttempt(isFailure: true, ssid: "Home", threshold: 30, at: 550))

        // Pause and safe mode hold the join in the gate; nothing is logged as done.
        let log = NetToysActionLog(url: root.appendingPathComponent("actions.log"))
        let gate = NetToysActionGate(log: log)
        XCTAssertFalse(gate.allows(.wifiJoin, "Switched", settings: NetToysConfiguration(actionsPaused: true)))
        XCTAssertFalse(gate.allows(.wifiJoin, "Switched", settings: NetToysConfiguration(safeModeReason: "3 failed")))
        XCTAssertTrue(log.entries().isEmpty)
        // The panel's request reaches the runtime once, and a stale one is ignored.
        let request = root.appendingPathComponent("failover-request.json")
        try NetToysFailoverRequest.joinNow.send(to: request)
        XCTAssertEqual(NetToysFailoverRequest.take(from: request), .joinNow)
        XCTAssertNil(NetToysFailoverRequest.take(from: request))
        try NetToysFailoverRequest.stay.send(to: request)
        XCTAssertNil(NetToysFailoverRequest.take(from: request, now: Date() + 120))
    }
}
