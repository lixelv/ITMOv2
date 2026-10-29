import Charts
import MasshCore
import SwiftUI

/// System overview: a line of facts, then CPU, memory, disk and network tiles with charts since connecting.
struct OverviewView: View {
    var snapshot: Snapshot
    var history: [InspectorModel.Sample]

    private var o: Snapshot.Overview { snapshot.overview }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            FlowLayout(spacing: Space.lg) {
                Fact(title: String(localized: "OS"), value: o.os)
                Fact(title: String(localized: "Kernel"), value: o.kernel, mono: true)
                Fact(title: String(localized: "Uptime"), value: Format.uptime(o.uptimeSeconds))
                Fact(title: String(localized: "Load average"), value: Format.load(o.loadAverage), mono: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Space.md, alignment: .top)], alignment: .leading, spacing: Space.md) {
                Tile(title: String(localized: "Processor"), symbol: "cpu", detail: "\(o.cpu.cores) × \(o.cpu.model)") {
                    Meter(title: String(localized: "Usage"), value: Format.percent(o.cpu.usagePercent), fraction: o.cpu.usagePercent / 100)
                    if !o.cpu.perCorePercent.isEmpty {
                        PerCoreBars(values: o.cpu.perCorePercent)
                    }
                    // Charts are off by default; uncomment to bring them back.
                    // HistoryChart(history: history, series: [.init(name: "CPU", value: \.cpuPercent)], percent: true)
                }
                Tile(title: String(localized: "Memory"), symbol: "memorychip") {
                    Meter(title: "RAM", usage: o.memory)
                    if let swap = o.swap {
                        if swap.totalBytes > 0 {
                            Meter(title: "Swap", usage: swap)
                        } else {
                            LabeledContent("Swap", value: String(localized: "none")).font(.caption)
                        }
                    }
                    // HistoryChart(history: history, series: [.init(name: "RAM", value: \.memoryPercent)], percent: true)
                }
                Tile(title: String(localized: "Disks"), symbol: "internaldrive") {
                    if o.disks.isEmpty {
                        Text("No disk data").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(o.disks, id: \.mountPoint) { disk in
                        Meter(title: disk.mountPoint, usage: disk.usage)
                    }
                }
                Tile(title: String(localized: "Network"), symbol: "network") {
                    HStack(spacing: Space.lg) {
                        Rate(symbol: "arrow.down", label: String(localized: "Incoming"), bytesPerSecond: o.network.rxBytesPerSecond)
                        Rate(symbol: "arrow.up", label: String(localized: "Outgoing"), bytesPerSecond: o.network.txBytesPerSecond)
                    }
                    .font(.caption)
                    // HistoryChart(history: history, series: [
                    //     .init(name: String(localized: "Incoming"), value: \.rxBytesPerSecond),
                    //     .init(name: String(localized: "Outgoing"), value: \.txBytesPerSecond),
                    // ], percent: false)
                }
            }
        }
    }
}

private struct Fact: View {
    var title: String
    var value: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(mono ? .callout.monospaced() : .callout).lineLimit(1).contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Rate: View {
    var symbol: String
    var label: String
    var bytesPerSecond: UInt64

    var body: some View {
        Label { Text(Format.rate(Double(bytesPerSecond))).monospacedDigit().contentTransition(.numericText()) }
            icon: { Image(systemName: symbol) }
            .accessibilityLabel(label)
    }
}

private struct Tile<Content: View>: View {
    var title: String
    var symbol: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label(title, systemImage: symbol).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(detail)
            }
            content
        }
        .card()
    }
}

extension Meter {
    /// Used of total, e.g. "3.1 GB of 8 GB"; disks and memory warn as they fill up.
    init(title: String, usage: Snapshot.Usage) {
        self.init(title: title, value: String(localized: "\(Format.bytes(usage.usedBytes)) of \(Format.bytes(usage.totalBytes))"),
                  fraction: usage.fraction)
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
                        .fill(Geist.blue)
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
        // Vercel charts: one blue series, a second one in gray.
        .chartForegroundStyleScale(domain: series.map(\.name), range: [Geist.blue, Geist.gray900])
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
    ScrollView {
        OverviewView(snapshot: FakeSnapshots.make(tick: 60), history: history).padding(Space.lg)
    }
    .frame(width: 900, height: 600)
}
