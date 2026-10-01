import NetToysCore
import SwiftUI

public enum NetToysMenuLayout {
    public static let disclosureHorizontalPadding: CGFloat = 6
    public static let disclosureVerticalPadding: CGFloat = 6

    public nonisolated static func recentAnchors(_ anchors: [SSHAnchorConfiguration], statuses: [SSHAnchorStatus],
                                                limit: Int = 5) -> [SSHAnchorConfiguration] {
        let checkedAt = Dictionary(statuses.map { ($0.anchorID, $0.lastCheck) }, uniquingKeysWith: { max($0, $1) })
        return Array(anchors.enumerated().sorted {
            let left = checkedAt[$0.element.id] ?? .distantPast
            let right = checkedAt[$1.element.id] ?? .distantPast
            return left == right ? $0.offset < $1.offset : left > right
        }.prefix(limit).map(\.element))
    }

    public nonisolated static func recentNetworkIssues(_ events: [NetworkTransitionEvent],
                                                       limit: Int = 5) -> [NetworkTransitionEvent] {
        Array(events.reversed().filter { event in
            event.changes.contains { change in
                switch change {
                case .network(_, let to): to == "disconnected"
                case .gateway(_, let to), .internet(_, let to): to == .unreachable
                }
            }
        }.prefix(limit))
    }
}
