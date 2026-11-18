import AppKit
import SwiftUI

/// Mail-style sidebar (round 12 option 8, tools only): search, Pinned, then the four tool groups.
struct NetToysSidebar<Footer: View>: View {
    @Bindable var shell: NetToysShell
    /// All Devices shows this count.
    var deviceCount: Int?
    /// Below Settings: the pause row.
    @ViewBuilder var footer: Footer
    @State private var query = ""
    @AppStorage("nettoys.sidebar.collapsed") private var collapsedRaw = ""
    @State private var hoveredHeader: String?
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private var pinnedTools: [NetToysTool] { shell.pinned.compactMap(NetToysTool.tool).filter { $0.matches(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights sit in this band, centered 26 pt from the top.
            Color.clear.frame(height: 46)
            search.padding(.horizontal, 10).padding(.bottom, 2)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if !pinnedTools.isEmpty {
                        header("Pinned", collapsible: false)
                        ForEach(pinnedTools) { tool in
                            row(tool)
                                .draggable(tool.id)
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let id = ids.first else { return false }
                                    withAnimation(Dense.spring(reduceMotion)) { shell.movePin(id, to: tool.id) }
                                    return true
                                }
                        }
                    }
                    ForEach(NetToysTool.Group.allCases, id: \.self) { group in
                        let tools = NetToysTool.all.filter { $0.group == group && !shell.isPinned($0.id) && $0.matches(query) }
                        if !tools.isEmpty {
                            let open = !query.isEmpty || !collapsed.contains(group.rawValue)
                            header(group.rawValue, collapsible: query.isEmpty, open: open)
                            if open { ForEach(tools) { row($0) } }
                        }
                    }
                    if query.isEmpty == false && pinnedTools.isEmpty
                        && !NetToysTool.all.contains(where: { $0.matches(query) }) {
                        Text("No tools match").font(.system(size: 12)).foregroundStyle(Dense.tertiary)
                            .padding(.horizontal, 18).padding(.top, 12)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            // Rows fade out under Settings instead of meeting a hard edge.
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
            })
            row(id: "settings", title: "Settings", symbol: "gearshape").padding(.top, 4)
            DenseHairline().padding(.horizontal, 12).padding(.vertical, 8)
            footer.padding(.horizontal, 10).padding(.bottom, 12)
        }
        .animation(Dense.spring(reduceMotion), value: shell.selection)
        .animation(Dense.spring(reduceMotion), value: shell.pinned)
        .animation(Dense.spring(reduceMotion), value: collapsedRaw)
        .animation(Dense.spring(reduceMotion), value: query)
        .frame(width: 240).frame(maxHeight: .infinity, alignment: .top)
        .background(NetToysSidebarGlass())
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                .accessibilityLabel("Search tools")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Dense.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Dense.sidebarField))
    }

    private func header(_ title: String, collapsible: Bool, open: Bool = true) -> some View {
        Button {
            guard collapsible else { return }
            var set = collapsed
            if set.contains(title) { set.remove(title) } else { set.insert(title) }
            collapsedRaw = set.sorted().joined(separator: ",")
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Dense.sidebarHeader)
                Spacer(minLength: 0)
                // Quiet headers: the chevron shows on hover or while the group is collapsed, as in Mail.
                if collapsible {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Dense.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(!open || hoveredHeader == title ? 1 : 0)
                }
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .padding(.top, 12).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredHeader = $0 ? title : (hoveredHeader == title ? nil : hoveredHeader) }
        .animation(Dense.fast, value: hoveredHeader)
        .accessibilityLabel(collapsible ? "\(title), \(open ? "expanded" : "collapsed")" : title)
    }

    private func row(_ tool: NetToysTool) -> some View {
        row(id: tool.id, title: tool.name, symbol: tool.symbol, count: tool.id == "all-devices" ? deviceCount : nil)
            .contextMenu {
                Button(shell.isPinned(tool.id) ? "Unpin" : "Pin") {
                    withAnimation(Dense.spring(reduceMotion)) { shell.togglePin(tool.id) }
                }
            }
            .help(tool.line)
    }

    private func row(id: String, title: String, symbol: String, count: Int? = nil) -> some View {
        let selected = shell.selection == id
        return Button { shell.selection = id } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                    .foregroundStyle(selected ? Dense.label : Dense.sidebarSymbol)
                    .frame(width: 18, height: 18)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Dense.label).lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Dense.tertiary)
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Dense.sidebarSelection)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("nettoys.tool.\(id)")
    }
}

/// The sidebar's behind-window glass, as in Mail and Finder.
struct NetToysSidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
