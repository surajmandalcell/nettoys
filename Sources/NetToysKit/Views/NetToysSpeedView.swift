import Charts
import NetToysCore
import OnePlusUI
import SwiftUI

/// Speed Test: the last run on top, the history chart, the schedule, and the ISP report; every run below.
struct NetToysSpeedView: View {
    let tool: NetToysTool
    let speedTest: NetToysSpeedTest
    private let live: Bool
    @State private var schedule: NetToysSpeedSchedule
    @State private var reportDays = 7
    @State private var input = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Offscreen renders pass a test with synthetic history and a schedule; nothing then reads disk.
    init(tool: NetToysTool, speedTest: NetToysSpeedTest = .shared, schedule: NetToysSpeedSchedule? = nil) {
        self.tool = tool
        self.speedTest = speedTest
        live = schedule == nil
        _schedule = State(initialValue: schedule ?? .off)
    }

    private var history: [NetToysSpeedRecord] { speedTest.history }

    var body: some View {
        NetToysToolPage(tool: tool, input: $input, subtitle: subtitle, running: speedTest.isRunning,
                        run: { speedTest.isRunning ? speedTest.stop() : speedTest.start() }) {
            VStack(alignment: .leading, spacing: 12) {
                cards
                if case .failed(let message) = speedTest.phase {
                    UtilityNote(symbol: "exclamationmark.triangle.fill", text: message, tone: Dense.amber)
                }
                HStack(alignment: .top, spacing: 12) {
                    chart.frame(maxWidth: .infinity)
                    VStack(spacing: 12) {
                        scheduleBox
                        report
                    }
                    .frame(width: 320)
                }
            }
        } results: {
            UtilityTable(columns: columns, rows: history.reversed(), empty: "No runs yet. Click Run to test the speed.") { run in
                Text(run.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())).cell(columns[0])
                Text(run.networkName ?? "Unknown").foregroundStyle(Dense.secondary).cell(columns[1])
                Text(UtilityFormat.mbps(run.downloadMbps)).fontWeight(.medium).cell(columns[2])
                Text(UtilityFormat.mbps(run.uploadMbps)).cell(columns[3])
                Text(run.responsivenessRPM.map { String(Int($0)) } ?? "None").foregroundStyle(Dense.secondary).cell(columns[4])
                Text(UtilityFormat.ms(run.idleLatencyMilliseconds)).foregroundStyle(Dense.secondary).cell(columns[5])
                Text(run.isp ?? "Unknown").foregroundStyle(Dense.secondary).cell(columns[6])
            }
        }
        .task {
            guard live else { return }
            schedule = await Task.detached(priority: .utility) { NetToysSpeedSchedule.load() }.value
            await speedTest.reload()
        }
    }

    private let columns = [
        UtilityColumn(title: "Date", width: 150), UtilityColumn(title: "Network", width: 150),
        UtilityColumn(title: "Download Mbps", width: 100, trailing: true), UtilityColumn(title: "Upload Mbps", width: 90, trailing: true),
        UtilityColumn(title: "Responsiveness", width: 104, trailing: true), UtilityColumn(title: "Latency ms", width: 80, trailing: true),
        UtilityColumn(title: "ISP"),
    ]

    private var subtitle: String {
        if speedTest.isRunning { return "Testing download and upload, up to \(Int(NetToysSpeedTest.maximumSeconds)) sec" }
        guard let last = history.last else { return tool.line }
        return "Last run \(UtilityFormat.ago(last.date)) on \(last.networkName ?? "this network"), \(history.count) runs saved"
    }

    private var cards: some View {
        let last = history.last
        return HStack(spacing: 10) {
            NetToysSummaryCard(title: "Download", value: UtilityFormat.mbps(last?.downloadMbps), unit: "Mbps")
            NetToysSummaryCard(title: "Upload", value: UtilityFormat.mbps(last?.uploadMbps), unit: "Mbps")
            NetToysSummaryCard(title: "Responsiveness", value: last?.responsivenessRPM.map { String(Int($0)) } ?? "None",
                               unit: "round trips a minute")
            NetToysSummaryCard(title: "Idle latency", value: UtilityFormat.ms(last?.idleLatencyMilliseconds), unit: "ms")
        }
    }

    // MARK: History chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.system(size: 12, weight: .semibold)).foregroundStyle(Dense.secondary)
                Spacer()
                legend("Download", Dense.accent)
                legend("Upload", Dense.green)
            }
            Chart {
                ForEach(history) { run in
                    LineMark(x: .value("Date", run.date), y: .value("Mbps", run.downloadMbps), series: .value("Kind", "Download"))
                        .foregroundStyle(Dense.accent)
                    PointMark(x: .value("Date", run.date), y: .value("Mbps", run.downloadMbps))
                        .foregroundStyle(Dense.accent).symbolSize(14)
                    if let upload = run.uploadMbps {
                        LineMark(x: .value("Date", run.date), y: .value("Mbps", upload), series: .value("Kind", "Upload"))
                            .foregroundStyle(Dense.green)
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Dense.hair); AxisValueLabel() } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { AxisGridLine().foregroundStyle(Dense.hair); AxisValueLabel() } }
            .overlay { if history.isEmpty { Text("Runs show here").font(.system(size: 12)).foregroundStyle(Dense.tertiary) } }
            .animation(Dense.spring(reduceMotion), value: history.count)
            .frame(height: 196)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dense.group))
    }

    private func legend(_ title: String, _ tone: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(tone).frame(width: 10, height: 3)
            Text(title).font(.system(size: 11)).foregroundStyle(Dense.secondary)
        }
    }

    // MARK: Schedule

    private enum Repeat: Hashable { case off, sixHours, daily }

    private var scheduleBox: some View {
        let mode = Binding<Repeat>(get: {
            switch schedule { case .off: .off; case .everySixHours: .sixHours; case .daily: .daily }
        }, set: { value in
            switch value {
            case .off: save(.off)
            case .sixHours: save(.everySixHours)
            case .daily: save(.daily(hour: 9, minute: 0))
            }
        })
        let time = Binding<Date>(get: {
            guard case .daily(let hour, let minute) = schedule else { return Date() }
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            save(.daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0))
        })
        return DenseSection(title: "Schedule") {
            HStack {
                Text("Run").font(.system(size: 13)).foregroundStyle(Dense.label)
                Spacer()
                if mode.wrappedValue == .daily {
                    OnePlusLinearDateField("Time", selection: time, showsDate: false)
                }
                OnePlusLinearSelect(choices: [(Repeat.off, "Off"), (.sixHours, "Every 6 hours"), (.daily, "Daily")],
                                    selection: mode, accessibilityLabel: "Run", width: 136)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .overlay(alignment: .bottom) { DenseHairline().padding(.horizontal, 10) }
            Text(NetToysSpeedSchedule.dataNote).font(.system(size: 11)).foregroundStyle(Dense.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }

    private func save(_ value: NetToysSpeedSchedule) {
        schedule = value
        try? value.save()
    }

    // MARK: ISP report

    private var report: some View {
        let report = NetToysISPReport(records: history, days: reportDays)
        let hours = report.downloadByHour.sorted { $0.value.median < $1.value.median }
        return DenseSection(title: "ISP report") {
            OnePlusLinearSegmented(choices: [(7, "7 days"), (30, "30 days")], selection: $reportDays,
                                   accessibilityLabel: "Period", sizing: .snug)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .overlay(alignment: .bottom) { DenseHairline().padding(.horizontal, 10) }
            DenseValueRow(label: "Download, median", value: stat(report.download?.median))
            DenseValueRow(label: "Download, slowest tenth", value: stat(report.download?.p10))
            DenseValueRow(label: "Upload, median", value: stat(report.upload?.median))
            DenseValueRow(label: "Slowest hour", value: hours.first.map { "\(hourText($0.key)), \(stat($0.value.median))" } ?? "None")
            DenseValueRow(label: "Runs", value: "\(report.download?.count ?? 0)", last: true)
        }
    }

    private func stat(_ value: Double?) -> String { value.map { "\(UtilityFormat.mbps($0)) Mbps" } ?? "None" }

    private func hourText(_ hour: Int) -> String {
        (Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date())
            .formatted(date: .omitted, time: .shortened)
    }
}
