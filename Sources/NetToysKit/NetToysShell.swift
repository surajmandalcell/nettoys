import Foundation
import NetToysCore
import Observation

/// Window navigation shared by the sidebar, the command palettes, routes, and the menu panel.
@Observable
@MainActor
public final class NetToysShell {
    static let pinsKey = "nettoys.pinned"
    static let selectionKey = "nettoys.selection"

    /// A tool id, `settings`, or `how-to-use`.
    public var selection: String { didSet { defaults.set(selection, forKey: Self.selectionKey) } }
    /// Toolbar input per tool id, filled by routes and palette actions.
    public var inputs: [String: String] = [:]
    /// A tool that routes or the palette opened with an input; its page runs once and clears this.
    public var pendingRun: String?
    public private(set) var pinned: [String]
    public var paletteVisible = false
    /// Known devices for the palette; the window keeps it current.
    public var devices: [NetToysScanResult] = []
    /// A device the palette asked the window to open.
    public var deviceRequest: String?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.selectionKey) ?? ""
        selection = NetToysTool.tool(saved) != nil || saved == "settings" ? saved : "all-devices"
        pinned = (defaults.stringArray(forKey: Self.pinsKey) ?? []).filter { NetToysTool.tool($0) != nil }
    }

    public func open(_ id: String, input: String? = nil) {
        if let input { inputs[id] = input }
        pendingRun = input == nil ? nil : id
        selection = id
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    public func togglePin(_ id: String) {
        guard NetToysTool.tool(id) != nil else { return }
        if let index = pinned.firstIndex(of: id) { pinned.remove(at: index) } else { pinned.append(id) }
        savePins()
    }

    /// Drag and drop: puts `id` where `target` is.
    public func movePin(_ id: String, to target: String) {
        guard id != target, let from = pinned.firstIndex(of: id), let to = pinned.firstIndex(of: target) else { return }
        pinned.remove(at: from)
        pinned.insert(id, at: to)
        savePins()
    }

    private func savePins() { defaults.set(pinned, forKey: Self.pinsKey) }

    /// Loads the last scan's devices when no window has filled the list yet (the global palette).
    func loadDevicesIfNeeded() async {
        guard devices.isEmpty else { return }
        let results = await Task.detached(priority: .userInitiated) { NetToysScannerStore.archive().runs.last?.results ?? [] }.value
        if devices.isEmpty { devices = results.filter(\.isReachable) }
    }
}
