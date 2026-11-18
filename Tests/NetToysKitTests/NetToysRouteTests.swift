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

    func testToolRoutesFillTheInput() {
        XCTAssertEqual(route("nettoys://tool/ping?host=192.168.50.1")?.toolID, "ping")
        XCTAssertEqual(route("nettoys://tool/ping?host=192.168.50.1")?.input, "192.168.50.1")
        XCTAssertNil(route("nettoys://tool/ping?host=192.168.50.1")?.page)
        XCTAssertEqual(route("nettoys://tool/http-check?host=https%3A%2F%2Ffiles.example.com%2Fa")?.input, "https://files.example.com/a")
        XCTAssertNil(route("nettoys://tool/ping")?.input)
        XCTAssertNil(route("nettoys://tool/ping?host=a%20b%3Bc")?.input)
        XCTAssertNil(route("nettoys://tool/unknown?host=x"))
        XCTAssertNil(route("nettoys://tool"))
        XCTAssertEqual(NetToysTool.all.count, 29)
        XCTAssertEqual(Set(NetToysTool.all.map(\.id)).count, 29)
    }

    func testPinsPersistAndReorder() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nettoys.tests.pins"))
        defaults.removePersistentDomain(forName: "nettoys.tests.pins")
        let shell = NetToysShell(defaults: defaults)
        shell.togglePin("speed-test")
        shell.togglePin("wake-on-lan")
        shell.togglePin("ssl-certificate")
        shell.togglePin("not-a-tool")
        shell.movePin("ssl-certificate", to: "speed-test")
        shell.togglePin("wake-on-lan")
        XCTAssertEqual(NetToysShell(defaults: defaults).pinned, ["ssl-certificate", "speed-test"])
        defaults.removePersistentDomain(forName: "nettoys.tests.pins")
    }

    func testMenuBarGlyphLoadsAsTemplate() throws {
        let image = try XCTUnwrap(NetToysGlyph.menuBarImage)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 14)
    }
}
