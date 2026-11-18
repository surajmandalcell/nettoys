import XCTest
@testable import NetToysCore

/// Risky pure logic of the Monitor, Local Network, and Wi-Fi tools. Fixtures and a fake clock; no network.
final class ToolsTests: XCTestCase {
    // MARK: SNTP

    func testSNTPParseGivesOffsetAndDelay() throws {
        let t1 = 1_700_000_000.0
        let request = NetToysClock.request(transmit: t1)
        var reply = [UInt8](repeating: 0, count: 48)
        reply[0] = 0x24 // version 4, server mode
        reply[1] = 1
        reply.replaceSubrange(24..<32, with: request[40..<48])
        reply.replaceSubrange(32..<40, with: NetToysClock.stamp(t1 + 0.6))
        reply.replaceSubrange(40..<48, with: NetToysClock.stamp(t1 + 0.61))
        let parsed = try XCTUnwrap(NetToysClock.parse(reply, request: request, sentAt: t1, receivedAt: t1 + 0.2))
        XCTAssertEqual(parsed.offset, 0.505, accuracy: 0.001)
        XCTAssertEqual(parsed.delay, 0.19, accuracy: 0.001)
        XCTAssertEqual(parsed.stratum, 1)

        var spoofed = reply
        spoofed[30] ^= 0xFF
        XCTAssertNil(NetToysClock.parse(spoofed, request: request, sentAt: t1, receivedAt: t1 + 0.2))
        var unsynced = reply
        unsynced[0] = 0xE4 // leap indicator 3
        XCTAssertNil(NetToysClock.parse(unsynced, request: request, sentAt: t1, receivedAt: t1 + 0.2))
    }

    // MARK: Wi-Fi channels

    private func network(_ channel: Int, _ band: NetToysWiFiBand, width: Int = 20) -> NetToysWiFiNetwork {
        NetToysWiFiNetwork(ssid: "n\(channel)", bssid: nil, rssi: -60, noise: -92, channel: channel, band: band, widthMHz: width)
    }

    func testChannelAdvicePicksLeastCrowded() {
        let networks = [network(1, .ghz2), network(1, .ghz2), network(3, .ghz2), network(11, .ghz2),
                        network(36, .ghz5, width: 80), network(149, .ghz5)]
        let advice = NetToysWiFiAnalyzer.advice(networks)
        let twoFour = try? XCTUnwrap(advice.first { $0.band == .ghz2 })
        // Channel 3 spills onto 1 and 6; channel 11 is alone.
        XCTAssertEqual(twoFour?.channel, 6)
        XCTAssertEqual(twoFour?.overlapping, 1)
        XCTAssertTrue(twoFour?.reason.contains("Channel 6") == true)
        // An 80 MHz network on 36 covers 36-48, so 153 (next to the 20 MHz 149) wins without DFS.
        let five = advice.first { $0.band == .ghz5 }
        XCTAssertEqual(five?.channel, 153)
        XCTAssertEqual(five?.overlapping, 0)
        XCTAssertEqual(network(44, .ghz5, width: 80).covered, 36...48)
        XCTAssertEqual(network(116, .ghz5, width: 160).covered, 100...128)
        XCTAssertEqual(network(157, .ghz5, width: 80).covered, 149...161)

        let usage = NetToysWiFiAnalyzer.usage(networks).first { $0.band == .ghz2 && $0.channel == 1 }
        XCTAssertEqual(usage?.networks, 2)
        XCTAssertEqual(usage?.overlapping, 3)
    }

    // MARK: ISP report

    private func record(_ hoursAgo: Double, _ download: Double, upload: Double? = nil, network: String = "Home",
                        now: Date) -> NetToysSpeedRecord {
        NetToysSpeedRecord(date: now.addingTimeInterval(-hoursAgo * 3_600), downloadMbps: download, uploadMbps: upload,
                           responsivenessRPM: nil, idleLatencyMilliseconds: nil, interfaceName: "en0",
                           networkName: network, publicIP: nil, isp: nil, server: nil)
    }

    func testISPReportMedianP10AndGroups() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let records = (1...10).map { record(Double($0), Double($0 * 10), upload: 5, now: now) }
            + [record(2, 500, network: "Cafe", now: now), record(24 * 20, 1, now: now)]
        let report = NetToysISPReport(records: records, days: 7, now: now, calendar: calendar)
        let download = try XCTUnwrap(report.download)
        XCTAssertEqual(download.count, 11)
        XCTAssertEqual(download.median, 60)
        XCTAssertEqual(download.p10, 20) // nearest rank: ceil(1.1) = 2nd slowest
        XCTAssertEqual(report.upload?.median, 5)
        XCTAssertEqual(report.downloadByNetwork["Home"]?.median, 55)
        XCTAssertEqual(report.downloadByNetwork["Cafe"]?.count, 1)
        let hour = calendar.component(.hour, from: now.addingTimeInterval(-2 * 3_600))
        XCTAssertEqual(report.downloadByHour[hour]?.median, 260)
        XCTAssertEqual(NetToysISPReport(records: records, days: 30, now: now, calendar: calendar).download?.count, 12)
    }

    // MARK: Store caps

    func testUptimeResultsDropOldAndRemovedThenFitTheCap() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = (0..<5_000).map {
            NetToysUptimeSample(date: now.addingTimeInterval(-Double($0)), milliseconds: 12.3, failure: $0 % 7 == 0 ? "Timed out" : nil)
        }.reversed()
        var series: [String: [NetToysUptimeSample]] = [
            "old": [NetToysUptimeSample(date: now.addingTimeInterval(-31 * 86_400), milliseconds: 1, failure: nil)],
            "gone": [NetToysUptimeSample(date: now, milliseconds: 1, failure: nil)],
        ]
        let data = try NetToysUptimeResults.merge(&series, ["a": Array(fresh), "old": []], keeping: ["a", "old"],
                                                  now: now, maximumBytes: 32_768)
        XCTAssertLessThanOrEqual(data.count, 32_768)
        XCTAssertEqual(Set(series.keys), ["a"])
        XCTAssertEqual(series["a"]?.last?.date, now, "the newest samples stay")
        let decoded = try JSONDecoder().decode([String: [NetToysUptimeSample]].self, from: data)
        XCTAssertEqual(decoded["a"]?.count, series["a"]?.count)
        XCTAssertEqual(decoded["a"]?.first { !$0.isUp }?.failure, "Timed out")
    }

    func testSpeedHistoryCapKeepsNewest() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<2_000).map { record(Double($0), 100, now: now) } + [record(24 * 400, 1, now: now)]
        let result = try NetToysSpeedHistory.capped(records, now: now, maximumBytes: 16_384)
        XCTAssertLessThanOrEqual(result.data.count, 16_384)
        XCTAssertEqual(result.items.last?.date, now)
        XCTAssertFalse(result.items.contains { $0.downloadMbps == 1 }, "runs older than a year go")
    }

    func testDailyScheduleRunsMissedSlotOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let nine = Date(timeIntervalSince1970: 1_700_038_800) // 2023-11-15 09:00 UTC
        let schedule = NetToysSpeedSchedule.daily(hour: 9, minute: 0)
        let next = schedule.nextRun(lastRun: nine.addingTimeInterval(-86_400), now: nine.addingTimeInterval(7_200), calendar: calendar)
        XCTAssertEqual(next, nine)
        XCTAssertEqual(schedule.nextRun(lastRun: nine, now: nine.addingTimeInterval(60), calendar: calendar),
                       nine.addingTimeInterval(86_400))
        XCTAssertNil(NetToysSpeedSchedule.off.nextRun(lastRun: nil, now: nine))
    }

    func testSpeedParseReadsNetworkQualityJSON() {
        let json = #"{"base_rtt":21.5,"dl_throughput":312500000,"ul_throughput":41000000,"responsiveness":812.3,"interface_name":"en0"}"#
        let parsed = NetToysSpeedTestRunner.parse(json)
        XCTAssertEqual(parsed?.download, 312.5)
        XCTAssertEqual(parsed?.upload, 41)
        XCTAssertEqual(parsed?.rpm, 812.3)
        XCTAssertEqual(parsed?.interfaceName, "en0")
        XCTAssertNil(NetToysSpeedTestRunner.parse(#"{"error_code":-1009,"dl_throughput":0}"#))
    }

    // MARK: Uptime state

    func testUptimeDownAfterNFailuresThenBackUpSlowAndCertificate() {
        let check = NetToysUptimeCheck(name: "NAS", kind: .tcp(host: "nas", port: 22), latencyThresholdMilliseconds: 100,
                                       downAfterFailures: 3, sslWarningDays: 14)
        var status = NetToysUptimeStatus()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }

        XCTAssertTrue(status.observe(.init(date: at(0), milliseconds: 10, failure: nil), check: check).isEmpty)
        XCTAssertTrue(status.observe(.init(date: at(1), milliseconds: nil, failure: "Timed out"), check: check).isEmpty)
        XCTAssertTrue(status.observe(.init(date: at(2), milliseconds: nil, failure: "Timed out"), check: check).isEmpty)
        let down = status.observe(.init(date: at(3), milliseconds: nil, failure: "Timed out"), check: check)
        XCTAssertEqual(down.map(\.title), ["NAS is down"])
        XCTAssertTrue(status.isDown)
        XCTAssertEqual(status.downSince, at(1))
        XCTAssertTrue(status.observe(.init(date: at(4), milliseconds: nil, failure: "Timed out"), check: check).isEmpty)

        let back = status.observe(.init(date: at(11), milliseconds: 20, failure: nil), check: check)
        XCTAssertEqual(back.map(\.body), ["It was down for 10 min."])
        XCTAssertFalse(status.isDown)

        XCTAssertEqual(status.observe(.init(date: at(12), milliseconds: 250, failure: nil), check: check).map(\.title), ["NAS is slow"])
        XCTAssertTrue(status.observe(.init(date: at(13), milliseconds: 260, failure: nil), check: check).isEmpty)
        XCTAssertTrue(status.observe(.init(date: at(14), milliseconds: 30, failure: nil), check: check).isEmpty)
        XCTAssertEqual(status.observe(.init(date: at(15), milliseconds: 300, failure: nil), check: check).count, 1)

        let expiry = at(15).addingTimeInterval(10 * 86_400 + 60)
        let warn = status.observe(.init(date: at(16), milliseconds: 20, failure: nil, certificateExpiry: expiry), check: check)
        XCTAssertEqual(warn.first?.title, "NAS certificate expires soon")
        XCTAssertTrue(warn.first?.body.contains("10 days") == true)
        XCTAssertTrue(status.observe(.init(date: at(17), milliseconds: 20, failure: nil, certificateExpiry: expiry), check: check).isEmpty)

        // A check that fails from the start also goes down, after N.
        var fresh = NetToysUptimeStatus()
        let single = NetToysUptimeCheck(name: "Web", kind: .http(url: "https://example.com", expectedStatus: nil), downAfterFailures: 1)
        XCTAssertEqual(fresh.observe(.init(date: at(0), milliseconds: nil, failure: "HTTP 503"), check: single).first?.body,
                       "HTTP 503.")
    }

    func testMonitorTickRunsDueChecksAndNotifies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NetToysRuntimePaths(home: root, data: root)
        let monitor = NetToysUptimeMonitor { _ in NetToysUptimeSample(date: Date(), milliseconds: nil, failure: "No reply") }
        let check = NetToysUptimeCheck(name: "Router", kind: .ping(host: "192.0.2.1"), intervalSeconds: 30, downAfterFailures: 2)
        let alerts = AlertBox()
        let start = Date()
        for second in [0.0, 10, 30, 60] {
            await monitor.tick(checks: [check], now: start.addingTimeInterval(second), paths: paths, notify: alerts.add)
        }
        // Due at 0, 30, 60 only; down after the second failure.
        XCTAssertEqual(alerts.titles, ["Router is down"])
        XCTAssertEqual(NetToysUptimeResults.load(paths: paths)[check.id.uuidString]?.count, 3)
    }
}

private final class AlertBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var titles: [String] { lock.withLock { stored } }
    func add(_ alert: NetToysAlert) { lock.withLock { stored.append(alert.title) } }
}
