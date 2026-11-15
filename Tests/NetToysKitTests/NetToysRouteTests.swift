import NetToysCore
import XCTest
@testable import NetToysKit

@MainActor
final class NetToysRouteTests: XCTestCase {
    private func route(_ string: String) -> NetToysRoute? { NetToysRoute(URL(string: string)!) }

    func testPageRoutesAndBareOpen() {
        XCTAssertEqual(route("nettoys://open/ssh-anchor")?.page, .anchor)
        XCTAssertEqual(route("nettoys://open/scanner")?.page, .scanner)
        XCTAssertNotNil(route("nettoys://open"))
        XCTAssertNil(route("nettoys://open")?.page)
        XCTAssertNil(route("nettoys://open/unknown"))
        XCTAssertNil(route("macpowertoys://open/nettoys"))
    }

    func testPrefillWithoutPageOpensScanner() {
        let route = route("nettoys://open?targets=jetson.local%2C192.168.1.0%2F24&ports=22%2C80-81")
        XCTAssertEqual(route?.page, .scanner)
        XCTAssertEqual(route?.prefill, NetToysScanPrefill(targets: "jetson.local,192.168.1.0/24", ports: "22,80-81"))
        XCTAssertNil(self.route("nettoys://open?targets=192.168.1.1&ports=0")?.prefill)
    }

    func testMenuBarGlyphLoadsAsTemplate() throws {
        let image = try XCTUnwrap(NetToysGlyph.menuBarImage)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 14)
    }
}
