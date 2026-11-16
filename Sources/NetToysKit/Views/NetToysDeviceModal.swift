import NetToysCore
import SwiftUI

/// Device details: a tall single column centered over the dimmed, blurred window.
struct NetToysDeviceModal: View {
    @Bindable var model: NetToysScannerViewModel
    let id: String
    let paused: Bool
    let close: () -> Void
    @State private var comment = ""
    @State private var confirmForget = false
    @State var watch = NetToysDeviceWatch()
    /// The device's last 24 hours, oldest first.
    @State var samples: [NetToysLatencySample] = []
    @State private var wakeNote: String?

    var body: some View {
        if let result = model.results.first(where: { $0.id == id }) {
            ViewThatFits(in: .vertical) {
                content(result)
                ScrollView { content(result) }.scrollIndicators(.automatic)
            }
            // 480 pt fits the three labeled buttons and "..." with 8 pt gaps inside the 20 pt insets.
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Dense.modal))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Dense.stroke, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
            .padding(.vertical, 28)
            .background { Button("Close", action: close).keyboardShortcut(.cancelAction).hidden() }
            .onAppear { comment = model.annotation(for: id).comment }
            .onDisappear(perform: saveComment)
            .task(id: id) {
                let id = id
                let loaded = await Task.detached(priority: .utility) {
                    (NetToysDeviceWatchStore.load()[id], NetToysLatencyStore.load().series[id])
                }.value
                if let watch = loaded.0 { self.watch = watch }
                if let samples = loaded.1 { self.samples = samples }
            }
            .confirmationDialog("Forget \(NetToysDeviceText.name(result) ?? result.address.description)?",
                                isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget Device", role: .destructive) {
                    model.removeResults(ids: [id])
                    close()
                }
            } message: {
                Text("It comes back if it answers the next scan.")
            }
        }
    }

    private func content(_ result: NetToysScanResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(result)
            actions(result)
            details(result)
            ports(result)
            latency(result)
            alerts
            commentSection
        }
        .padding(20)
    }

    private func header(_ result: NetToysScanResult) -> some View {
        let favorite = model.annotations[id]?.isFavorite == true
        let status = [result.address.description, result.vendor].compactMap { $0 }.joined(separator: "  ·  ")
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: NetToysDeviceText.symbol(result)).font(.system(size: 19)).foregroundStyle(Dense.secondary)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Dense.groupStroke, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(NetToysDeviceText.name(result) ?? "Unknown device")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(Dense.label).lineLimit(1)
                    Button { NetToysDeviceActions.toggleFavorite(id, model: model) } label: {
                        Image(systemName: favorite ? "star.fill" : "star").font(.system(size: 11))
                            .foregroundStyle(favorite ? Dense.yellow : Dense.tertiary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(favorite ? "Remove from Favorites" : "Add to Favorites")
                }
                HStack(spacing: 0) {
                    Group {
                        if result.isReachable { Circle().fill(Dense.green) }
                        else { Circle().strokeBorder(Dense.tertiary, lineWidth: 1.2) }
                    }
                    .frame(width: 7, height: 7).padding(.trailing, 5)
                    Text(result.isReachable ? "Online" : "Offline").font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.label)
                    Text("  ·  " + status).font(.system(size: 12)).foregroundStyle(Dense.secondary).monospacedDigit().lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Dense.secondary)
                    .frame(width: 22, height: 22).background(Circle().fill(Dense.group))
            }
            .buttonStyle(.plain).accessibilityLabel("Close")
        }
    }

    private func actions(_ result: NetToysScanResult) -> some View {
        HStack(spacing: 8) {
            Button { wake(result) } label: { Label(wakeNote ?? "Wake Device", systemImage: "power") }
                .disabled(paused || result.macAddress == nil)
                .help(result.macAddress == nil ? "Wake needs the device's MAC address from a scan on this network." : "")
            Button { NetToysDeviceActions.openSSH(result) } label: { Label("Open SSH", systemImage: "terminal") }
                .disabled(paused || !result.openPorts.contains(22))
            Button { NetToysDeviceActions.copy(result.address.description) } label: {
                Label("Copy IP Address", systemImage: "doc.on.doc")
            }
            Spacer(minLength: 8)
            Menu {
                Button("Add to SSH Anchor") {
                    NetToysDeviceActions.addToAnchor(result)
                    close()
                }
                .disabled(paused)
                Button("Copy MAC Address") { NetToysDeviceActions.copy(result.macAddress ?? "") }
                    .disabled(result.macAddress == nil)
                Divider()
                Button("Forget Device…", role: .destructive) { confirmForget = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
        .buttonStyle(DenseCapsuleButtonStyle())
    }

    private func details(_ result: NetToysScanResult) -> some View {
        var rows: [(String, String, Bool)] = [("MAC address", result.macAddress ?? "Unknown", true)]
        if let hostname = result.hostname { rows.append(("Hostname", hostname, false)) }
        if let netBIOS = result.netBIOSName { rows.append(("NetBIOS name", netBIOS, false)) }
        rows.append(("Ping", NetToysDeviceText.ping(result), false))
        if let ttl = result.ttl { rows.append(("TTL", "\(ttl)", false)) }
        if let server = result.httpServer { rows.append(("HTTP server", server, false)) }
        rows.append(("Last seen", NetToysDeviceText.lastSeen(result, date: model.lastSeen[id]), false))
        return DenseSection(title: "Details") {
            ForEach(rows.indices, id: \.self) { index in
                DenseValueRow(label: rows[index].0, value: rows[index].1, mono: rows[index].2, last: index == rows.count - 1)
            }
        }
    }

    private func ports(_ result: NetToysScanResult) -> some View {
        DenseSection(title: "Open ports", note: "Watch") {
            if result.openPorts.isEmpty {
                Text("No open ports in the last scan.").font(.system(size: 13)).foregroundStyle(Dense.secondary)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            ForEach(result.openPorts, id: \.self) { port in
                DenseSwitchRow(label: NetToysDeviceText.service(port), detail: "Port \(port)",
                               isOn: watchBinding({ $0.ports.contains(port) }, set: { watch, on in
                                   if on { watch.ports.append(port) } else { watch.ports.removeAll { $0 == port } }
                               }),
                               last: port == result.openPorts.last)
            }
        }
    }

    /// A switch that saves the device watch at once and asks for notification permission the first time one turns on.
    private func watchBinding(_ get: @escaping (NetToysDeviceWatch) -> Bool,
                              set: @escaping (inout NetToysDeviceWatch, Bool) -> Void) -> Binding<Bool> {
        Binding {
            get(watch)
        } set: { on in
            set(&watch, on)
            let id = id
            let change = watch
            Task.detached(priority: .userInitiated) {
                _ = try? NetToysDeviceWatchStore.update(id) { $0 = change }
                if on { _ = await NetToysNotifier.requestPermission() }
            }
        }
    }

    private func wake(_ result: NetToysScanResult) {
        guard let mac = result.macAddress else { return }
        let name = NetToysDeviceText.name(result) ?? result.address.description
        Task {
            let note: String = await Task.detached(priority: .userInitiated) {
                do { return try NetToysWakeOnLAN.wake(mac: mac, deviceName: name) ? "Wake Sent" : "Dry Run Logged" }
                catch { return "Wake Failed" }
            }.value
            wakeNote = note
            try? await Task.sleep(for: .seconds(2))
            wakeNote = nil
        }
    }

    private func latency(_ result: NetToysScanResult) -> some View {
        let day = Date().addingTimeInterval(-86_400)
        let values = samples.filter { $0.date > day }.map(\.milliseconds)
        let answered = values.compactMap { $0 }
        let average = answered.isEmpty ? nil : answered.reduce(0, +) / Double(answered.count)
        return DenseSection(title: "Latency", note: "Last 24 hours") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(average.map { "\(Int($0.rounded()))" } ?? "None")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Dense.label)
                    if average != nil {
                        Text("ms average").font(.system(size: 11)).foregroundStyle(Dense.secondary)
                    }
                    Spacer(minLength: 8)
                    if let low = answered.min(), let high = answered.max() {
                        Text("Min \(Int(low.rounded())) · Max \(Int(high.rounded())) ms")
                            .font(.system(size: 11)).foregroundStyle(Dense.secondary)
                    }
                }
                .monospacedDigit()
                if answered.count > 1 {
                    NetToysLatencyChart(values: Self.buckets(values))
                        .frame(height: 40)
                } else {
                    Text("Samples come from scans, and every 30 sec once an alert or port watch is on.")
                        .font(.system(size: 11)).foregroundStyle(Dense.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Dense.group))
                }
            }
            .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 9)
        }
    }

    /// At most 96 points (15 min each over a full day): the average of each run of samples, 0 for a run with no answer.
    static func buckets(_ values: [Double?]) -> [Double] {
        let size = max(1, (values.count + 95) / 96)
        return stride(from: 0, to: values.count, by: size).map { start in
            let answered = values[start..<min(start + size, values.count)].compactMap { $0 }
            return answered.isEmpty ? 0 : answered.reduce(0, +) / Double(answered.count)
        }
    }

    private var alerts: some View {
        DenseSection(title: "Alerts") {
            DenseSwitchRow(label: "Notify when offline",
                           isOn: watchBinding(\.notifyOffline, set: { $0.notifyOffline = $1 }))
            DenseSwitchRow(label: "Notify when back online",
                           isOn: watchBinding(\.notifyOnline, set: { $0.notifyOnline = $1 }), last: true)
        }
    }

    private var commentSection: some View {
        DenseSection(title: "Comment") {
            TextField("Add a comment", text: $comment, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .onSubmit(saveComment)
                .accessibilityLabel("Comment")
        }
    }

    private func saveComment() {
        var annotation = model.annotation(for: id)
        guard annotation.comment != comment else { return }
        annotation.comment = comment
        model.saveAnnotation(annotation, for: id)
    }
}

/// Modal entry: scale from 0.96 and sharpen from a blur.
struct NetToysModalEntry: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(active ? 0.96 : 1).blur(radius: active ? 8 : 0).opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static func netToysModal(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.12)) }
        return .asymmetric(
            insertion: .modifier(active: NetToysModalEntry(active: true), identity: NetToysModalEntry(active: false))
                .animation(.easeOut(duration: 0.18)),
            removal: .opacity.combined(with: .scale(scale: 0.98)).animation(.easeIn(duration: 0.1))
        )
    }
}
