import CoreLocation
import Foundation
import SwiftUI
import XCTest
@testable import NetToysCore
@testable import NetToysKit

final class NetToysPresentationTests: XCTestCase {
    func testLocationFailureRoutesToSettingsWithoutRetrying() {
        XCTAssertEqual(
            NetToysLocationAction(status: .notDetermined, requestFailed: false),
            .request
        )
        XCTAssertEqual(
            NetToysLocationAction(status: .notDetermined, requestFailed: true),
            .openSettings
        )
    }

    func testLocationAccessPromptsOnlyFromExplicitUserAction() throws {
        XCTAssertEqual(NetToysLocationAction(status: .authorized, requestFailed: false), .none)
        XCTAssertEqual(NetToysLocationAction(status: .authorizedAlways, requestFailed: false), .none)
        XCTAssertEqual(NetToysLocationAction(status: .denied, requestFailed: false), .openSettings)
        XCTAssertEqual(NetToysLocationAction(status: .restricted, requestFailed: false), .openSettings)

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NetToysKit/Views/NetToysHistoryView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("requestSSIDAccessIfNeeded"))
        XCTAssertEqual(source.components(separatedBy: "requestWhenInUseAuthorization()").count - 1, 1)
    }

    func testLocalNetworkPolicyDenialNeedsSettings() {
        XCTAssertEqual(
            NetToysLocalNetworkAccessState(dnsErrorCode: -65_570),
            .denied
        )
        XCTAssertEqual(
            NetToysLocalNetworkAccessState(posixError: .EPERM),
            .denied
        )
        XCTAssertEqual(
            NetToysLocalNetworkAccessState(posixError: .ENETDOWN),
            .unavailable
        )
    }

    func testNetworkAvailabilitySummarizesOutagesBySSID() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)
        let events = [
            NetworkTransitionEvent(
                networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                date: start.addingTimeInterval(-10),
                changes: [.internet(from: .unknown, to: .reachable)]
            ),
            NetworkTransitionEvent(
                networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                date: start.addingTimeInterval(10),
                changes: [.internet(from: .reachable, to: .unreachable)]
            ),
            NetworkTransitionEvent(
                networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                date: start.addingTimeInterval(25),
                changes: [.internet(from: .unreachable, to: .reachable)]
            ),
            NetworkTransitionEvent(
                networkID: "en0|192.168.31.1", ssid: "Guest Wi-Fi",
                date: start.addingTimeInterval(40),
                changes: [.network(from: "Home Wi-Fi", to: "Guest Wi-Fi")]
            ),
            NetworkTransitionEvent(
                networkID: "en0|192.168.31.1", ssid: "Guest Wi-Fi",
                date: start.addingTimeInterval(80),
                changes: [.internet(from: .reachable, to: .unreachable)]
            )
        ]

        let summaries = networkAvailabilitySummaries(events: events, from: start, to: end)
        let home = try XCTUnwrap(summaries.first { $0.network == "Home Wi-Fi" })
        let guest = try XCTUnwrap(summaries.first { $0.network == "Guest Wi-Fi" })

        XCTAssertEqual(home.knownDuration, 40)
        XCTAssertEqual(home.unavailableDuration, 15)
        XCTAssertEqual(home.outages.count, 1)
        XCTAssertEqual(home.uptime, 0.625)
        XCTAssertEqual(guest.knownDuration, 60)
        XCTAssertEqual(guest.unavailableDuration, 20)
        XCTAssertEqual(guest.outages.count, 1)

        let repaired = networkAvailabilitySummaries(
            events: [
                NetworkTransitionEvent(
                    networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                    date: start.addingTimeInterval(40),
                    changes: [.internet(from: .reachable, to: .unreachable)]
                ),
                NetworkTransitionEvent(
                    networkID: "en0|192.168.31.1", ssid: "Guest Wi-Fi",
                    date: start.addingTimeInterval(80),
                    changes: [.network(from: "Home Wi-Fi", to: "Guest Wi-Fi")]
                )
            ],
            from: start,
            to: end,
            currentGateway: .reachable,
            currentInternet: .reachable,
            currentNetwork: "Guest Wi-Fi"
        )
        XCTAssertEqual(repaired.first { $0.network == "Home Wi-Fi" }?.unavailableDuration, 40)
        XCTAssertEqual(repaired.first { $0.network == "Guest Wi-Fi" }?.unavailableDuration, 0)
    }

    func testNetworkAvailabilityCountsGatewayOutagesShownInTransitions() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)
        let events = [
            NetworkTransitionEvent(
                networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                date: start.addingTimeInterval(-10),
                changes: [
                    .gateway(from: .unknown, to: .reachable),
                    .internet(from: .unknown, to: .reachable)
                ]
            ),
            NetworkTransitionEvent(
                networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                date: start.addingTimeInterval(20),
                changes: [.gateway(from: .reachable, to: .unreachable)]
            ),
            NetworkTransitionEvent(
                networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                date: start.addingTimeInterval(50),
                changes: [.gateway(from: .unreachable, to: .reachable)]
            )
        ]

        let summary = try XCTUnwrap(
            networkAvailabilitySummaries(events: events, from: start, to: end).first
        )

        XCTAssertEqual(summary.knownDuration, 100)
        XCTAssertEqual(summary.unavailableDuration, 30)
        XCTAssertEqual(summary.outages.count, 1)
        XCTAssertEqual(summary.uptime, 0.7)
    }

    func testHistoryPresentationFiltersAndFormatsRowsBeforeRendering() {
        let now = Date()
        let presentation = netToysHistoryPresentation(
            events: [
                NetworkTransitionEvent(
                    networkID: "en0|192.168.1.1", ssid: "Office Wi-Fi",
                    date: now.addingTimeInterval(-60),
                    changes: [.internet(from: .reachable, to: .unreachable)]
                ),
                NetworkTransitionEvent(
                    networkID: "en0|192.168.1.2", ssid: "Guest Wi-Fi",
                    date: now.addingTimeInterval(-120),
                    changes: [.internet(from: .unreachable, to: .reachable)]
                )
            ],
            runs: [],
            range: .day,
            query: "office",
            currentGateway: .reachable,
            currentInternet: .unreachable,
            currentNetwork: "Office Wi-Fi"
        )

        XCTAssertEqual(presentation.events.map(\.network), ["Office Wi-Fi"])
        XCTAssertEqual(presentation.events.first?.isOutage, true)
        XCTAssertFalse(presentation.events.first?.time.isEmpty ?? true)
        XCTAssertFalse(presentation.availability.startLabel.isEmpty)
        XCTAssertTrue(presentation.availability.summaries.contains {
            $0.summary.network == "Office Wi-Fi" && !$0.label.isEmpty
        })
    }

    @MainActor
    func testHistoryDistinguishesEmptyPeriodFromEmptyArchive() async {
        let model = NetToysHistoryViewModel(host: testHost())
        await model.rebuildPresentation()
        XCTAssertTrue(model.recentScanRows.isEmpty)
        XCTAssertEqual(model.recentScansEmptyTitle, "No saved scans")

        let run = NetToysScanRun(
            date: Date().addingTimeInterval(-2 * NetToysHistoryRange.day.rawValue),
            target: "192.168.1.0/24", ports: [22], duration: 1, results: []
        )
        model.scanArchive = NetToysScanArchive(runs: [run])
        await model.rebuildPresentation()
        XCTAssertTrue(model.recentScanRows.isEmpty)
        XCTAssertEqual(model.recentScansEmptyTitle, "No scans in this period")

        model.range = .week
        await model.rebuildPresentation()
        XCTAssertEqual(model.recentScanRows.map(\.run.id), [run.id])

        model.scanArchive = NetToysScanArchive()
        await model.rebuildPresentation()
        XCTAssertTrue(model.recentScanRows.isEmpty)
        XCTAssertEqual(model.recentScansEmptyTitle, "No saved scans")
    }

    func testHistoryPresentationLeavesUnsampledRangeHollow() throws {
        let now = Date(timeIntervalSince1970: 200_000)
        let outage = now.addingTimeInterval(-3_600)
        let presentation = netToysHistoryPresentation(
            events: [
                NetworkTransitionEvent(
                    networkID: "en0|192.168.1.1", ssid: "Home Wi-Fi",
                    date: outage,
                    changes: [.gateway(from: .reachable, to: .unreachable)]
                )
            ],
            runs: [],
            range: .day,
            query: "",
            currentGateway: .unreachable,
            currentInternet: .reachable,
            currentNetwork: "Home Wi-Fi",
            now: now
        )

        XCTAssertEqual(presentation.availability.start, now.addingTimeInterval(-86_400))
        XCTAssertNotEqual(
            presentation.availability.startLabel,
            presentation.availability.start.formatted(date: .omitted, time: .shortened)
        )
        let summary = try XCTUnwrap(presentation.availability.summaries.first?.summary)
        XCTAssertEqual(summary.segments.first?.state, .unknown)
        XCTAssertEqual(summary.segments.first?.start, presentation.availability.start)
        XCTAssertEqual(summary.segments.first?.end, outage)
        XCTAssertEqual(summary.unavailableDuration, 3_600)
        XCTAssertEqual(summary.outages.count, 1)
    }

    func testTailscalePeerChooserUsesCompactShortAndScrollingListGeometry() {
        XCTAssertEqual(NetToysAnchorSheetLayout.peerPickerWidth, 420)
        XCTAssertEqual(NetToysAnchorSheetLayout.titleRowHeight, 40)
        XCTAssertEqual(NetToysAnchorSheetLayout.peerRowHeight, 44)
        XCTAssertEqual(NetToysAnchorSheetLayout.peerPickerHeight(peerCount: -1), 80)
        XCTAssertEqual(NetToysAnchorSheetLayout.peerPickerHeight(peerCount: 1), 124)
        XCTAssertEqual(NetToysAnchorSheetLayout.peerPickerHeight(peerCount: 5), 300)
        XCTAssertEqual(NetToysAnchorSheetLayout.peerPickerHeight(peerCount: 6), 300)
        XCTAssertFalse(NetToysAnchorSheetLayout.peerPickerNeedsScrolling(peerCount: 5))
        XCTAssertTrue(NetToysAnchorSheetLayout.peerPickerNeedsScrolling(peerCount: 6))
    }

    func testSSHAnchorSheetsUseSharedCloseAndPeerInteractionControls() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NetToysKit/Views/NetToysAnchorView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let peerPickerStart = try XCTUnwrap(source.range(of: "private var tailscalePeerPicker"))
        let peerPickerEnd = try XCTUnwrap(source.range(
            of: "private func identityDescription",
            range: peerPickerStart.upperBound..<source.endIndex
        ))
        let peerPicker = source[peerPickerStart.lowerBound..<peerPickerEnd.lowerBound]
        let keyAccessStart = try XCTUnwrap(source.range(of: "private struct SSHKeyAccessSheet"))
        let keyAccessSheet = source[keyAccessStart.lowerBound..<source.endIndex]

        XCTAssertTrue(peerPicker.contains("OnePlusSheet(\"Choose Tailscale device\", width: .small, close: model.cancelTailscaleSelection)"))
        XCTAssertTrue(keyAccessSheet.contains("OnePlusSheet(\"Set up key access\", width: .small, close: onCancel)"))
        XCTAssertTrue(peerPicker.contains("OnePlusInteractionStyle()"))
        XCTAssertTrue(keyAccessSheet.contains("OnePlusSecureField.focusedOnOpen(\"Password\", text: $password)"))
        XCTAssertTrue(keyAccessSheet.contains("password = \"\"\n        onContinue(submittedPassword)"))
    }

    @MainActor
    func testNetToysPageIDsCoverEverySidebarDestination() {
        XCTAssertEqual(NetToysPage.allCases.map(\.pageID), [
            "scanner", "ssh-anchor", "wifi", "history", "settings", "how-to-use"
        ])
    }

    @MainActor
    func testScannerViewModelRestoresLatestRunWhenRecreated() throws {
        let older = NetToysScanRun(
            target: "10.0.0.0/24",
            ports: [22],
            duration: 4,
            results: []
        )
        let result = NetToysScanResult(
            address: try XCTUnwrap(IPv4Address("192.168.1.18")),
            isReachable: true,
            responseMilliseconds: 1.5,
            hostname: "jetson.local",
            macAddress: "aa:bb:cc:dd:ee:ff",
            vendor: "Example",
            openPorts: [22]
        )
        let latest = NetToysScanRun(
            target: "192.168.1.0/24",
            ports: [22, 80, 443],
            duration: 12,
            results: [result]
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let model = NetToysScannerViewModel(
            archive: NetToysScanArchive(runs: [older, latest]),
            defaults: defaults, host: testHost(defaults)
        )

        XCTAssertEqual(model.targetInput, latest.target)
        XCTAssertEqual(model.results, latest.results)
        XCTAssertEqual(model.lastDuration, latest.duration)
        XCTAssertEqual(model.lastScanTarget, latest.target)
        XCTAssertEqual(model.completed, 1)
        XCTAssertEqual(model.total, 1)
        let newNetwork = try XCTUnwrap(LocalIPv4Network(
            interfaceName: "en0", address: "192.168.2.10", netmask: "255.255.255.0"
        ))
        model.updateActiveNetwork(newNetwork)
        XCTAssertEqual(model.targetInput, "192.168.2.0/24")
        XCTAssertEqual(model.lastScanTarget, latest.target)
        XCTAssertEqual(model.results, latest.results)
        model.targetInput = "192.168.1.18"
        model.portInput = "22"
        model.filter = .alive
        model.searchText = "jetson"
        model.sortOrder = [KeyPathComparator(\NetToysScanResult.hostnameTitle, order: .reverse)]

        let recreated = NetToysScannerViewModel(
            archive: NetToysScanArchive(runs: [older, latest]),
            defaults: defaults, host: testHost(defaults)
        )
        XCTAssertEqual(recreated.targetInput, "192.168.1.18")
        XCTAssertEqual(recreated.portInput, "22")
        XCTAssertEqual(recreated.filter, .alive)
        XCTAssertEqual(recreated.searchText, "jetson")
        XCTAssertEqual(recreated.sortOrder.first?.keyPath, \NetToysScanResult.hostnameTitle)
        XCTAssertEqual(recreated.sortOrder.first?.order, .reverse)
        XCTAssertEqual(recreated.results, latest.results)
        XCTAssertEqual(recreated.lastScanTarget, latest.target)
        defaults.removePersistentDomain(forName: #function)
    }

    @MainActor
    func testScannerPrefillUpdatesWindowModelBeforeScannerPageExists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let model = NetToysScannerViewModel(archive: NetToysScanArchive(runs: []), host: testHost(defaults))

        model.applyPrefill(NetToysScanPrefill(targets: "10.0.0.8", ports: "8080"))
        let network = try XCTUnwrap(LocalIPv4Network(
            interfaceName: "en0", address: "192.168.2.10", netmask: "255.255.255.0"
        ))
        model.updateActiveNetwork(network)
        XCTAssertEqual(model.targetInput, "10.0.0.8")
        XCTAssertEqual(model.portInput, "8080")
        XCTAssertFalse(model.isScanning)

        model.applyPrefill(NetToysScanPrefill(targets: "10.0.0.9", ports: nil))
        model.applyPrefill(nil)
        XCTAssertEqual(model.targetInput, "10.0.0.9")
        XCTAssertEqual(model.portInput, "8080")
    }

    @MainActor
    func testScannerViewModelMergesLiveRescanWithoutDroppingOtherHosts() throws {
        let first = NetToysScanResult(
            address: try XCTUnwrap(IPv4Address("192.168.1.10")),
            isReachable: false,
            responseMilliseconds: nil,
            hostname: nil,
            macAddress: nil,
            vendor: nil,
            openPorts: []
        )
        let second = NetToysScanResult(
            address: try XCTUnwrap(IPv4Address("192.168.1.11")),
            isReachable: true,
            responseMilliseconds: 2,
            hostname: "printer.local",
            macAddress: nil,
            vendor: nil,
            openPorts: [80]
        )
        let updatedFirst = NetToysScanResult(
            address: first.address,
            isReachable: true,
            responseMilliseconds: 1,
            hostname: "server.local",
            macAddress: nil,
            vendor: nil,
            openPorts: [22]
        )
        let run = NetToysScanRun(target: "192.168.1.0/24", ports: [22, 80], duration: 1, results: [first, second])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let model = NetToysScannerViewModel(
            archive: NetToysScanArchive(runs: [run]),
            defaults: defaults, host: testHost(defaults)
        )

        model.applyScanUpdate(updatedFirst)

        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.results.first(where: { $0.id == first.id }), updatedFirst)
        XCTAssertEqual(model.results.first(where: { $0.id == second.id }), second)
        defaults.removePersistentDomain(forName: #function)
    }

    func testTableColumnCustomizationPersistsVisibility() throws {
        var customization = TableColumnCustomization<NetToysScanResult>()
        customization[visibility: "nettoys.ttl"] = .hidden

        let decoded = try JSONDecoder().decode(
            TableColumnCustomization<NetToysScanResult>.self,
            from: JSONEncoder().encode(customization)
        )

        XCTAssertEqual(decoded, customization)
        XCTAssertEqual(decoded[visibility: "nettoys.ttl"], .hidden)
    }
    @MainActor
    private func testHost(_ defaults: UserDefaults? = nil) -> NetToysHost {
        let defaults = defaults ?? UserDefaults(suiteName: "NetToys.tests.\(UUID())")!
        return NetToysHost(id: .standalone, requestsPermissions: false, defaults: defaults, scannerDefaults: defaults)
    }
}
