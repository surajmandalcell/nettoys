import XCTest
@testable import NetToysCore
@testable import NetToysKit

final class NetToysMenuParsingTests: XCTestCase {
    func testSpeedTestReadsLiveAndFinalDownloadFromNetworkQualityOutput() {
        // Captured from networkQuality under a terminal: live lines end in \r, then the summary.
        let live = "\u{1b}[2K\rDownlink: 286.335 Mbps, 0 RPM - Uplink: 0.000 Mbps, 0 RPM\r\u{1b}[2K\rDownlink: 312.5 Mbps, 52 RPM - Uplink: 0.000 Mbps, 0 RPM\r"
        XCTAssertEqual(NetToysSpeedTest.downloadMbps(live) ?? 0, 312.5, accuracy: 0.001)
        XCTAssertNil(NetToysSpeedTest.downloadMbps(live, final: true), "A stopped test has no summary.")
        let done = live + "\u{1b}[2K==== SUMMARY ====\r\nDownlink capacity: 1.385 Gbps\r\nDownlink Responsiveness: High (7.046 milliseconds | 8514 RPM)\r\n"
        XCTAssertEqual(NetToysSpeedTest.downloadMbps(done, final: true) ?? 0, 1_385, accuracy: 0.001)
        XCTAssertEqual(NetToysSpeedTest.downloadMbps(done) ?? 0, 1_385, accuracy: 0.001)
    }

    func testDurationsUseFullHoursThenMinThenSec() {
        XCTAssertEqual(NetToysDuration.text(4 * 3600 + 52 * 60 + 9), "4 hours 52 min")
        XCTAssertEqual(NetToysDuration.text(3600 + 59), "1 hour")
        XCTAssertEqual(NetToysDuration.text(120), "2 min")
        XCTAssertEqual(NetToysDuration.text(45), "45 sec")
    }

    func testHistoryCountsTodaysOutagesAndTheCurrentStretch() {
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let down = NetworkTransitionEvent(networkID: "n", date: now.addingTimeInterval(-600),
                                          changes: [.internet(from: .reachable, to: .unreachable)])
        let up = NetworkTransitionEvent(networkID: "n", date: now.addingTimeInterval(-480),
                                        changes: [.internet(from: .unreachable, to: .reachable)])
        var snapshot = NetToysTraySnapshot()
        snapshot.applyHistory([up, down], now: now)
        XCTAssertEqual(snapshot.outagesToday, 1)
        XCTAssertEqual(snapshot.outageSecondsToday, 120, accuracy: 0.001)
        XCTAssertEqual(snapshot.stateSince, up.date)
    }
}
