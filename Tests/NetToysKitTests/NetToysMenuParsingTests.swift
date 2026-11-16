import XCTest
@testable import NetToysCore
@testable import NetToysKit

final class NetToysMenuParsingTests: XCTestCase {
    func testSpeedTestReadsDownloadFromNetworkQualityJSON() {
        let fixture = Data(#"{"dl_throughput":412345678,"ul_throughput":40123456,"responsiveness":1234.5,"interface_name":"en0"}"#.utf8)
        XCTAssertEqual(NetToysSpeedTest.downloadMbps(fixture) ?? 0, 412.345678, accuracy: 0.0001)
        XCTAssertNil(NetToysSpeedTest.downloadMbps(Data(#"{"error_code":-1}"#.utf8)))
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
