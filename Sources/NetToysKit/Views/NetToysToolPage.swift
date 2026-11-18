import SwiftUI

/// The shared tool page: toolbar (title, input field, Run), a summary or diagram on top, the result table below.
/// A tool whose view has not landed passes no summary and no results and shows "Coming in this build".
struct NetToysToolPage<Summary: View, Results: View>: View {
    let tool: NetToysTool
    @Binding var input: String
    var subtitle: String?
    var running = false
    var run: (() -> Void)?
    /// False for a tool that works as you type (Subnet Calculator): the toolbar has no Run button.
    var showsRun = true
    @ViewBuilder var summary: Summary
    @ViewBuilder var results: Results
    @Environment(NetToysShell.self) private var shell: NetToysShell?

    private var hasInput: Bool { tool.input == nil || !input.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Run is the normal prominent button whenever it can act: a valid input, or Stop while running.
    private var canRun: Bool { run != nil && (running || hasInput) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if run == nil {
                emptyState
            } else {
                summary.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
                results.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Palette actions fill the input and run once; nettoys:// routes only fill it (NetToysShell.open).
        .onChange(of: shell?.pendingRun, initial: true) { _, id in
            guard id == tool.id, let shell, let run, hasInput else { return }
            shell.pendingRun = nil
            if running { run() } // stop the old host first
            run()
        }
    }

    // Light to heavy: title, input field, Run.
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: tool.symbol).font(.system(size: 15)).foregroundStyle(Dense.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(tool.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Dense.label)
                Text(subtitle ?? tool.line).font(.system(size: 11)).foregroundStyle(Dense.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 12)
            if let prompt = tool.input {
                HStack(spacing: 6) {
                    Image(systemName: "scope").font(.system(size: 12, weight: .medium)).foregroundStyle(Dense.secondary)
                    TextField(prompt, text: $input).textFieldStyle(.plain).font(.system(size: 13))
                        .onSubmit { if !running && hasInput { run?() } }
                        .accessibilityLabel(prompt)
                }
                .padding(.horizontal, 10).frame(width: 300, height: 28)
                .background(Capsule().fill(Dense.field))
            }
            if showsRun {
                Button {
                    run?()
                } label: {
                    Label(running ? "Stop" : "Run", systemImage: running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(DenseCapsuleButtonStyle(prominent: true))
                .disabled(!canRun)
                .help(run == nil ? "Coming in this build" : hasInput ? "" : "Enter \(tool.input?.lowercased() ?? "an input")")
            }
        }
        .padding(.leading, 20).padding(.trailing, 14)
        .frame(height: 52) // centerline 26 pt, shared with the traffic lights
        .overlay(alignment: .bottom) { DenseHairline() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: tool.symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Dense.tertiary)
            Text("Coming in this build").font(.system(size: 15, weight: .semibold)).foregroundStyle(Dense.label)
            Text(tool.line).font(.system(size: 12)).foregroundStyle(Dense.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension NetToysToolPage where Summary == EmptyView, Results == EmptyView {
    /// The honest placeholder for a tool whose view has not landed.
    init(placeholder tool: NetToysTool, input: Binding<String>) {
        self.init(tool: tool, input: input, summary: { EmptyView() }, results: { EmptyView() })
    }
}

/// One summary number, as in the approved tool screen ("Hops 8", "Round trip 18.9 ms").
struct NetToysSummaryCard: View {
    let title: String
    let value: String
    var unit = ""
    var tone: Color = Dense.label

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Dense.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(tone).monospacedDigit()
                Text(unit).font(.system(size: 12)).foregroundStyle(Dense.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
    }
}
