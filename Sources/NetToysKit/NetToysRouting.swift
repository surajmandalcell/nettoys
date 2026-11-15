import AppKit
import NetToysCore
import OnePlusUI

public extension Notification.Name {
    static let netToysPrefill = Notification.Name("netToysPrefill")
    static let netToysRescanRun = Notification.Name("netToysRescanRun")
    static let netToysStartScan = Notification.Name("netToysStartScan")
    static let netToysOpenAnchor = Notification.Name("netToysOpenAnchor")
    static let netToysApplyAnchorPrefill = Notification.Name("netToysApplyAnchorPrefill")
    static let netToysOpenPage = Notification.Name("netToysOpenPage")
    static let netToysHistoryCleared = Notification.Name("netToysHistoryCleared")
}

/// `nettoys://open[/<page>][?targets=…&ports=…]`, the routes MacPowerToys served as `open/nettoys…`.
public struct NetToysRoute: Equatable, Sendable {
    /// Nil keeps the current page.
    public let page: NetToysPage?
    public let prefill: NetToysScanPrefill?

    public init?(_ url: URL) {
        guard url.scheme == "nettoys", url.host == "open" else { return nil }
        let pageID = url.pathComponents.first(where: { $0 != "/" })
        let page = pageID.flatMap { id in NetToysPage.allCases.first(where: { $0.pageID == id }) }
        guard pageID == nil || page != nil else { return nil }
        prefill = NetToysScanPrefill.parse(url, schemes: ["nettoys"], toolPath: nil)
        self.page = page ?? (prefill == nil ? nil : .scanner)
    }
}

public enum NetToysGlyph {
    /// The socket-module template glyph MacPowerToys showed for NetToys, sized for the menu bar.
    @MainActor public static let menuBarImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "NetToysGlyph", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: OnePlusMenuMetrics.statusIconSize, height: OnePlusMenuMetrics.statusIconSize)
        image.isTemplate = true
        return image
    }()
}
