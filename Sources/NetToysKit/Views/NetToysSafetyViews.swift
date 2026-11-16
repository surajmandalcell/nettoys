import NetToysCore
import OnePlusUI
import SwiftUI

// MARK: - Action log

/// Every automatic action, newest first, in the Dense pro list style. A click opens a row's detail.
struct NetToysActionLogList: View {
    static let rowHeight: CGFloat = 30
    let entries: [NetToysActionEntry]
    let undoableID: UUID?
    let undo: (NetToysActionEntry) -> Void
    @State private var expanded: UUID?

    /// `focus` opens that entry at first, such as the failure the System row's Details points to.
    init(entries: [NetToysActionEntry], undoableID: UUID?, focus: UUID? = nil,
         undo: @escaping (NetToysActionEntry) -> Void) {
        self.entries = entries
        self.undoableID = undoableID
        self.undo = undo
        _expanded = State(initialValue: focus)
    }

    var body: some View {
        DenseSection(title: "Automatic actions", note: entries.isEmpty ? nil : "\(entries.count) in 30 days") {
            if entries.isEmpty {
                Text("No automatic actions yet. SSH Anchor moves and Wi-Fi switches show here.")
                    .font(.system(size: 12)).foregroundStyle(Dense.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: Self.rowHeight)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, zebra: index.isMultiple(of: 2) == false)
                        }
                    }
                }
                .frame(height: listHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(min(entries.count, 6)) * Self.rowHeight
        return rows + (expanded == nil ? 0 : 58)
    }

    private func row(_ entry: NetToysActionEntry, zebra: Bool) -> some View {
        let open = expanded == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol(entry)).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone(entry)).frame(width: 16)
                Text(entry.summary).font(.system(size: 13)).foregroundStyle(Dense.label)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 440, alignment: .leading)
                Spacer(minLength: 8)
                Text(kindTitle(entry.kind)).font(.system(size: 12)).foregroundStyle(Dense.secondary)
                    .frame(width: 92, alignment: .leading)
                Text(outcomeTitle(entry.outcome)).font(.system(size: 12, weight: .medium)).foregroundStyle(tone(entry))
                    .frame(width: 56, alignment: .leading)
                Text(entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 12)).foregroundStyle(Dense.secondary).monospacedDigit().lineLimit(1)
                    .frame(width: 140, alignment: .trailing)
                Group {
                    if entry.id == undoableID {
                        Button("Undo") { undo(entry) }.buttonStyle(DenseCapsuleButtonStyle())
                            .accessibilityLabel("Undo: \(entry.summary)")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { expanded = open ? nil : entry.id }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(open ? "Hides the detail" : "Shows the detail")
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.summary).font(.system(size: 12)).foregroundStyle(Dense.label)
                    Text(entry.detail ?? "No more detail.").font(.system(size: 12)).foregroundStyle(Dense.secondary)
                    Text(entry.date.formatted(date: .complete, time: .standard))
                        .font(.system(size: 11)).foregroundStyle(Dense.tertiary)
                }
                .lineLimit(2).textSelection(.enabled)
                .padding(.leading, 34).padding(.trailing, 10).padding(.bottom, 8)
                .frame(height: 58, alignment: .topLeading)
            }
        }
        .background(zebra ? Dense.zebra : .clear)
    }

    private func symbol(_ entry: NetToysActionEntry) -> String {
        if entry.kind == .safeMode { return "exclamationmark.shield.fill" }
        return switch entry.outcome {
        case .done: entry.kind == .undo ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .dryRun: "eye.circle.fill"
        }
    }

    private func tone(_ entry: NetToysActionEntry) -> Color {
        if entry.kind == .safeMode { return Dense.amber }
        return switch entry.outcome {
        case .done: Dense.green
        case .failed: Color(light: .systemRed, dark: .systemRed)
        case .dryRun: Dense.secondary
        }
    }

    private func kindTitle(_ kind: NetToysActionKind) -> String {
        switch kind {
        case .sshHostName: "SSH move"
        case .sshPolicy: "SSH policy"
        case .wifiJoin: "Wi-Fi switch"
        case .undo: "Undo"
        case .safeMode: "Safe mode"
        }
    }

    private func outcomeTitle(_ outcome: NetToysActionOutcome) -> String {
        switch outcome {
        case .done: "Done"
        case .failed: "Failed"
        case .dryRun: "Dry run"
        }
    }
}

// MARK: - SSH config backups

/// Backups of ~/.ssh/config: daily snapshots first, then one group per host. Restore asks first.
struct NetToysSSHBackupList: View {
    let backups: [NetToysSSHBackup]
    let restore: (NetToysSSHBackup) -> Void
    @State private var pending: NetToysSSHBackup?

    var body: some View {
        let total = backups.reduce(0) { $0 + $1.size }
        let hosts = Array(Set(backups.compactMap(\.hostAlias))).sorted()
        let periodic = backups.filter { $0.hostAlias == nil }
        return VStack(alignment: .leading, spacing: 16) {
            Text("Every SSH config change keeps a copy of the file from before it. Up to 1 MB in total, oldest first. \(Self.size(total)) used.")
                .font(.system(size: 12)).foregroundStyle(Dense.secondary)
                .padding(.horizontal, 10)
            if backups.isEmpty {
                DenseSection(title: "Backups") {
                    Text("No backups yet. The first SSH config change makes one.")
                        .font(.system(size: 12)).foregroundStyle(Dense.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).frame(height: 30)
                }
            }
            if !periodic.isEmpty { group("Daily snapshots", periodic) }
            ForEach(hosts, id: \.self) { host in
                group(host, backups.filter { $0.hostAlias == host })
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { backup in
            Button("Restore") { restore(backup); pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { backup in
            Text("~/.ssh/config goes back to the copy from \(backup.date.formatted(date: .abbreviated, time: .shortened)). The current file is backed up first.")
        }
    }

    private func group(_ title: String, _ items: [NetToysSSHBackup]) -> some View {
        DenseSection(title: title, note: items.count == 1 ? "1 copy" : "\(items.count) copies") {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, backup in
                HStack(spacing: 8) {
                    Image(systemName: backup.hostAlias == nil ? "calendar" : "doc.on.doc")
                        .font(.system(size: 12)).foregroundStyle(Dense.secondary).frame(width: 16)
                    Text(backup.hostAlias == nil ? "Daily snapshot" : "Before a change to \(backup.hostAlias ?? "")")
                        .font(.system(size: 13)).foregroundStyle(Dense.label).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Self.size(backup.size)).font(.system(size: 12)).foregroundStyle(Dense.secondary)
                        .monospacedDigit().frame(width: 64, alignment: .trailing)
                    Text(backup.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 12)).foregroundStyle(Dense.secondary).monospacedDigit().lineLimit(1)
                        .frame(width: 140, alignment: .trailing)
                    Button("Restore…") { pending = backup }.buttonStyle(DenseCapsuleButtonStyle())
                        .accessibilityLabel("Restore the backup from \(backup.date.formatted())")
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(index.isMultiple(of: 2) ? Color.clear : Dense.zebra)
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Settings: dry run and the Wi-Fi switch timers

struct NetToysSafetySettingsView: View {
    @State private var configuration: NetToysConfiguration
    @State private var errorMessage: String?
    private let loadsStore: Bool

    /// Pass a configuration to show it without reading the store, as offscreen renders do.
    init(configuration: NetToysConfiguration? = nil) {
        _configuration = State(initialValue: configuration ?? NetToysConfiguration())
        loadsStore = configuration == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OnePlusMetrics.cardGap) {
            OnePlusCard {
                OnePlusCardHeader("Automatic actions")
                OnePlusSettingRow("Dry run", help: "Log what each automatic action would do in History, and change nothing.",
                                  separator: false) {
                    Toggle("Dry run", isOn: Binding(get: { configuration.dryRun },
                                                    set: { value in save { $0.dryRun = value } }))
                        .labelsHidden().toggleStyle(OnePlusSwitchStyle())
                }
            }
            OnePlusCard {
                OnePlusCardHeader("Wi-Fi switch")
                OnePlusSettingRow("Wait after wake", help: "After the Mac wakes, wait this long before any Wi-Fi switch.") {
                    OnePlusSelect(choices: Self.choices([0, 30, 60, 120, 300, 600],
                                                          current: configuration.wifiPriority.waitAfterWake, zero: "No wait"),
                                  selection: Binding(get: { configuration.wifiPriority.waitAfterWake },
                                                     set: { value in save { $0.wifiPriority.waitAfterWake = value } }),
                                  accessibilityLabel: "Wait after wake")
                }
                OnePlusSettingRow("Rest after a switch", help: "After a Wi-Fi switch, wait this long before the next one.",
                                  separator: false) {
                    OnePlusSelect(choices: Self.choices([60, 300, 600, 1_800, 3_600],
                                                          current: configuration.wifiPriority.cooldownAfterSwitch),
                                  selection: Binding(get: { configuration.wifiPriority.cooldownAfterSwitch },
                                                     set: { value in save { $0.wifiPriority.cooldownAfterSwitch = value } }),
                                  accessibilityLabel: "Rest after a switch")
                }
            }
        }
        .task {
            guard loadsStore else { return }
            configuration = await Task.detached(priority: .utility) { NetToysConfigurationStore.load() }.value
        }
        .alert("Settings", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    /// Keeps a saved value that is not in the list, so the select never shows a blank.
    private static func choices(_ values: [TimeInterval], current: TimeInterval,
                                zero: String? = nil) -> [(TimeInterval, String)] {
        Set(values + [current]).sorted().map { ($0, $0 == 0 ? zero ?? "0 sec" : NetToysDuration.text($0)) }
    }

    private func save(_ change: (inout NetToysConfiguration) -> Void) {
        do { configuration = try NetToysConfigurationStore.update(change) } catch { errorMessage = error.localizedDescription }
    }
}
