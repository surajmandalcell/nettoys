import Foundation
import Testing
@testable import NetToysCore
@testable import NetToysKit

@Suite("NetToys SSH key access presentation")
struct NetToysKeyAccessPresentationTests {
    @MainActor
    private func model() -> NetToysAnchorViewModel {
        let defaults = UserDefaults(suiteName: "NetToys.tests.\(UUID())")!
        return NetToysAnchorViewModel(host: NetToysHost(id: .standalone, requestsPermissions: false,
                                                       defaults: defaults, scannerDefaults: defaults))
    }

    @Test("Scanner-selected address overrides the stale SSH address")
    @MainActor
    func scannerAddressWinsDuringEnrollment() {
        let model = model()
        model.entries = [SSHConfigEntry(aliases: ["winbox", "win1"], hostName: "192.168.1.11", port: 22)]
        model.selectedAlias = "winbox"
        model.requestedAddress = "192.168.1.7"
        #expect(model.selectedEntry?.hostName == "192.168.1.7")
    }

    @Test("Dismissing password setup leaves a retry path")
    @MainActor
    func dismissalKeepsRetry() {
        let model = model()
        let anchorID = UUID()
        model.pendingKeyAccessAnchorID = anchorID
        model.cancelKeyAccess()
        #expect(model.keyAccessRetryAnchorID == anchorID)
    }
}
