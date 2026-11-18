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

/// `nettoys://open[/<page>][?targets=…&ports=…]`, the routes MacPowerToys served as `open/nettoys…`,
/// and `nettoys://tool/<id>[?host=…]`, which opens a tool with its input filled.
public struct NetToysRoute: Equatable, Sendable {
    /// Nil keeps the current page.
    public let page: NetToysPage?
    public let prefill: NetToysScanPrefill?
    public let toolID: String?
    /// The tool input, only host, address, URL, or CIDR characters, at most 253 of them.
    public let input: String?

    public init?(_ url: URL) {
        guard url.scheme == "nettoys" else { return nil }
        if url.host == "tool" {
            guard let id = url.pathComponents.first(where: { $0 != "/" }), NetToysTool.tool(id) != nil else { return nil }
            toolID = id
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "host" }?.value?.trimmingCharacters(in: .whitespaces) ?? ""
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:/[]%?=&"))
            input = !raw.isEmpty && raw.count <= 253 && raw.unicodeScalars.allSatisfy(allowed.contains) ? raw : nil
            page = nil
            prefill = nil
            return
        }
        guard url.host == "open" else { return nil }
        toolID = nil
        input = nil
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
