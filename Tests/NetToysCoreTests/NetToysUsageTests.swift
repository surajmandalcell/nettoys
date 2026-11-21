import Foundation
import XCTest
@testable import NetToysCore

@MainActor
final class NetToysUsageTests: XCTestCase {
    func testNumberPacksUsesFeaturesAndVersion() {
        // The contract's example: 12 uses with slots 0 and 2.
        XCTAssertEqual(NetToysUsageState.number(uses: 12, features: 0b101), 67_113_996)
        XCTAssertEqual(NetToysUsageState.number(uses: 5000, features: 0) & 1023, 1023)
        // A day with no use sends no feature bits; the server rejects them.
        XCTAssertEqual(NetToysUsageState.number(uses: 0, features: 0b11), 67_108_864)
        XCTAssertTrue(NetToysUsageState.json(67_113_996).contains("\"Diagnose tools\""))
    }

    func testDayRolloverReportsOnlyYesterday() {
        var state = NetToysUsageState()
        state.record(.wifi, use: true, today: "2026-11-20")
        state.record(.globalPalette, use: false, today: "2026-11-20")
        state.record(.wifi, use: true, today: "2026-11-20")
        XCTAssertEqual(state.number(yesterday: "2026-11-20"), 1 << 26 | 2 | (1 << 3 | 1 << 5) << 10)
        state.roll(to: "2026-11-21")
        state.record(.diagnose, use: true, today: "2026-11-21")
        XCTAssertEqual(state.number(yesterday: "2026-11-20"), 1 << 26 | 2 | (1 << 3 | 1 << 5) << 10)
        // Two days later the 21st is not yesterday any more: an empty day.
        state.roll(to: "2026-11-23")
        XCTAssertEqual(state.number(yesterday: "2026-11-22"), 1 << 26)
    }

    func testRequestSendsMonthOnlyOnANewMonth() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9)))
        var state = NetToysUsageState()
        state.roll(to: "2026-11-21")
        let first = try XCTUnwrap(NetToysUsage.request(state, date: date, bundle: .main)).url.absoluteString
        XCTAssertTrue(first.hasPrefix("https://apps.mandalsuraj.com/v1/nettoys/latest?platform=macos&version="))
        XCTAssertTrue(first.hasSuffix("&d=1&m=1&u=67108864"))
        state.checkedMonth = "2026-11"
        XCTAssertTrue(try XCTUnwrap(NetToysUsage.request(state, date: date, bundle: .main)).url.absoluteString.hasSuffix("&d=1&u=67108864"))
    }
}
