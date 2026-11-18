import AppKit
import SwiftUI
import XCTest
@testable import NetToysKit

@MainActor
final class NetToysKeptPagesTests: XCTestCase {
    @Observable final class Pick { var id = "ping" }
    static var events: [String] = []

    private struct Probe: View {
        let id: String
        var body: some View {
            Text(id).onAppear { NetToysKeptPagesTests.events.append("+\(id)") }
                .onDisappear { NetToysKeptPagesTests.events.append("-\(id)") }
        }
    }

    private struct Host: View {
        let pick: Pick
        var body: some View {
            NetToysKeptPages(selection: pick.id, keeps: { $0 != "history" }) { Probe(id: $0) }.frame(width: 200, height: 100)
        }
    }

    /// Switching away and back keeps the page mounted, so its state and results survive; a page that is not kept rebuilds.
    func testSwitchingAwayAndBackKeepsThePage() {
        Self.events = []
        let pick = Pick()
        let hosting = NSHostingView(rootView: Host(pick: pick))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        settle()
        for id in ["speed-test", "ping", "history", "ping"] {
            pick.id = id
            settle()
        }
        XCTAssertEqual(Self.events.filter { $0.hasSuffix("ping") }, ["+ping"], "ping mounts once and never unmounts")
        XCTAssertEqual(Self.events.filter { $0.hasSuffix("speed-test") }, ["+speed-test"])
        XCTAssertFalse(Self.events.contains("+history"), "a page that is not kept is not mounted by the container")
    }
}
