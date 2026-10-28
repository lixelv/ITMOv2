import Charts
import MasshCore
import SwiftUI

/// System overview in the style of an Xcode inspector: grouped sections, gauges and charts since connecting.
struct OverviewView: View {
    var snapshot: Snapshot
    var history: [InspectorModel.Sample]

    private var o: Snapshot.Overview { snapshot.overview }

    var body: some View {
        Form {
            Section("System") {
                LabeledContent("OS", value: o.os)
                LabeledContent("Kernel", value: o.kernel)
                LabeledContent("Uptime", value: Format.uptime(o.uptimeSeconds))
                LabeledContent("Load average") {
                    Text(Format.load(o.loadAverage)).monospacedDigit()
                }
            }

            Section("Processor") {
                LabeledContent("Model") { Text(o.cpu.model).lineLimit(2).multilineTextAlignment(.trailing) }
                LabeledContent("Cores", value: "\(o.cpu.cores)")
                UsageGauge(title: String(localized: "Usage"), fraction: o.cpu.usagePercent / 100, value: Format.percent(o.cpu.usagePercent))
                if !o.cpu.perCorePercent.isEmpty {
                    PerCoreBars(values: o.cpu.perCorePercent)
                }
                HistoryChart(history: history, series: [.init(name: "CPU", value: \.cpuPercent)], percent: true)
            }

            Section("Memory") {
                UsageGauge(title: "RAM", usage: o.memory)
                if let swap = o.swap {
                    if swap.totalBytes > 0 {
                        UsageGauge(title: "Swap", usage: swap)
                    } else {
                        LabeledContent("Swap", value: "none")
                    }
                }
                HistoryChart(history: history, series: [.init(name: "RAM", value: \.memoryPercent)], percent: true)
            }

            Section("Disks") {
                if o.disks.isEmpty {
                    Text("No disk data").foregroundStyle(.secondary)
                }
                ForEach(o.disks, id: \.mountPoint) { disk in
                    UsageGauge(title: disk.mountPoint, usage: disk.usage, warnsWhenFull: true)
                }
            }

            Section("Network") {
                LabeledContent {
                    Text(Format.rate(Double(o.network.rxBytesPerSecond))).monospacedDigit()
                } label: {
                    Label("Incoming", systemImage: "arrow.down")
                }
                LabeledContent {
                    Text(Format.rate(Double(o.network.txBytesPerSecond))).monospacedDigit()
                } label: {
                    Label("Outgoing", systemImage: "arrow.up")
                }
                HistoryChart(history: history, series: [
                    .init(name: String(localized: "Incoming"), value: \.rxBytesPerSecond),
                    .init(name: String(localized: "Outgoing"), value: \.txBytesPerSecond),
                ], percent: false)
            }
        }
        .formStyle(.grouped)
    }
}

/// Used/total bar. Disks turn orange past 80 % and red past 90 %.
struct UsageGauge: View {
    var title: String
    var fraction: Double
    var value: String
    var warnsWhenFull = false

    init(title: String, fraction: Double, value: String) {
        self.title = title
        self.fraction = fraction
        self.value = value
    }

    init(title: String, usage: Snapshot.Usage, warnsWhenFull: Bool = false) {
        self.title = title
        fraction = usage.fraction
        value = String(localized: "\(Format.bytes(usage.usedBytes)) of \(Format.bytes(usage.totalBytes))")
        self.warnsWhenFull = warnsWhenFull
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            Gauge(value: min(max(fraction, 0), 1)) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(tint)
                .labelsHidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(Format.percent(fraction * 100))")
    }

    private var tint: Color {
        guard warnsWhenFull else { return .accentColor }
        return fraction > 0.9 ? .red : fraction > 0.8 ? .orange : .accentColor
    }
}

/// One small bar per core.
struct PerCoreBars: View {
    var values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per core").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.tint)
                        .frame(height: max(2, 28 * value / 100))
                        .frame(maxWidth: .infinity, maxHeight: 28, alignment: .bottom)
                        .background(RoundedRectangle(cornerRadius: 2).fill(.quaternary))
                        .help("Core \(index): \(Format.percent(value))")
                }
            }
            .animation(.easeOut(duration: 0.3), value: values)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-core usage")
        .accessibilityValue(values.map(Format.percent).joined(separator: ", "))
    }
}

struct HistoryChart: View {
    struct Series {
        var name: String
        var value: KeyPath<InspectorModel.Sample, Double>
    }

    var history: [InspectorModel.Sample]
    var series: [Series]
    var percent: Bool

    var body: some View {
        Chart {
            ForEach(series, id: \.name) { s in
                ForEach(points) { sample in
                    LineMark(x: .value("Time", sample.time), y: .value(s.name, sample[keyPath: s.value]))
                        .foregroundStyle(by: .value("Series", s.name))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(percent ? Format.percent(v) : Format.rate(v)).font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: percent ? 0...100 : 0...max(1, maxValue * 1.2))
        .frame(height: 56)
        .accessibilityLabel("Chart: \(series.map(\.name).joined(separator: ", ")) since connecting")
    }

    /// At most ~300 points are drawn however long the connection has been open.
    private var points: [InspectorModel.Sample] {
        let step = max(1, history.count / 300)
        guard step > 1 else { return history }
        return stride(from: 0, to: history.count, by: step).map { history[$0] }
    }

    private var maxValue: Double {
        series.flatMap { s in history.map { $0[keyPath: s.value] } }.max() ?? 1
    }
}

#Preview("Overview") {
    let history = (0..<60).map { tick in
        let s = FakeSnapshots.make(tick: tick)
        return InspectorModel.Sample(time: s.time, cpuPercent: s.overview.cpu.usagePercent,
                                     memoryPercent: s.overview.memory.fraction * 100,
                                     rxBytesPerSecond: Double(s.overview.network.rxBytesPerSecond),
                                     txBytesPerSecond: Double(s.overview.network.txBytesPerSecond))
    }
    OverviewView(snapshot: FakeSnapshots.make(tick: 60), history: history)
        .frame(width: 360, height: 900)
}
