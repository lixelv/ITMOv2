import MasshCore
import SwiftUI

// MARK: Containers

struct ContainersGrid: View {
    var docker: Snapshot.Docker

    var body: some View {
        switch docker {
        case .notInstalled:
            SectionNote(part: .containers, text: String(localized: "This Server has no Docker, or the Agent cannot reach it."))
        case .available(let containers) where containers.isEmpty:
            SectionNote(part: .containers, text: String(localized: "No Running Containers"))
        case .available:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.md, alignment: .top)], spacing: Space.md) {
                ForEach(docker.containersByName) { container in
                    ContainerCard(container: container)
                }
            }
        }
    }
}

struct ContainerCard: View {
    var container: Snapshot.Container

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(container.name).font(.headline).lineLimit(1)
                MachineLine(container.image).foregroundStyle(.secondary)
            }
            StatusBadge(state: ContainerState(dockerStatus: container.status), text: container.status)
            Meter(title: "CPU", value: Format.percent(container.cpuPercent), fraction: container.cpuPercent / 100)
            if let limit = container.memoryLimitBytes, limit > 0 {
                Meter(title: "RAM", value: String(localized: "\(Format.bytes(container.memoryBytes)) of \(Format.bytes(limit))"),
                      fraction: Double(container.memoryBytes) / Double(limit))
            } else {
                LabeledContent("RAM") {
                    Text(Format.bytes(container.memoryBytes)).monospacedDigit().contentTransition(.numericText())
                }
                .font(.caption)
            }
            if !container.ports.isEmpty {
                FlowLayout(spacing: Space.xs) {
                    ForEach(container.ports, id: \.self) { Chip(text: $0) }
                }
            }
        }
        .card()
    }
}

// MARK: Processes

struct ProcessList: View {
    var processes: [Snapshot.Process]
    @Binding var query: ProcessQuery

    var body: some View {
        let result = query.apply(to: processes)
        let peakMemory = Double(processes.map(\.memoryBytes).max() ?? 1)
        // Not lazy: a LazyVStack nested in the page's LazyVStack overlaps the next section. The top-50 cap keeps it cheap.
        VStack(spacing: 0) {
            if result.shown.isEmpty {
                SectionNote(part: .processes,
                            text: query.search.isEmpty ? String(localized: "No Processes") : String(localized: "Nothing matches “\(query.search)”"))
            }
            ForEach(result.shown) { process in
                ProcessRow(process: process, peakMemory: peakMemory)
                Divider()
            }
            Group {
                if result.shown.count < result.matching {
                    Button(String(localized: "Show All \(result.matching)")) { query.limit = nil }
                } else if query.limit == nil, result.matching > ProcessQuery.defaultLimit {
                    Button(String(localized: "Show Top \(ProcessQuery.defaultLimit)")) { query.limit = ProcessQuery.defaultLimit }
                }
            }
            .buttonStyle(.link)
            .padding(.top, Space.sm)
        }
    }
}

/// Search field and order menu shown in the Processes header.
struct ProcessControls: View {
    @Binding var query: ProcessQuery

    var body: some View {
        HStack(spacing: Space.sm) {
            TextField("Filter", text: $query.search, prompt: Text("Name or command"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Picker("Sort by", selection: $query.order) {
                ForEach(ProcessQuery.Order.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .controlSize(.small)
    }
}

extension ProcessQuery.Order {
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .name: String(localized: "Name")
        case .pid: "PID"
        }
    }
}

struct ProcessRow: View {
    var process: Snapshot.Process
    /// Largest RSS among all Processes, so RAM bars compare Processes with each other.
    var peakMemory: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(process.name).lineLimit(1)
                    Text("\(process.user) · \(String(process.pid))").font(.caption).monospaced().foregroundStyle(.secondary)
                }
                MachineLine(process.command).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Meter(title: "CPU", value: Format.percent(process.cpuPercent), fraction: process.cpuPercent / 100)
                .frame(width: 110)
            Meter(title: "RAM", value: Format.bytes(process.memoryBytes), fraction: Double(process.memoryBytes) / max(peakMemory, 1), warns: false)
                .frame(width: 130)
        }
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Ports

struct PortsView: View {
    var ports: [Snapshot.Port]

    var body: some View {
        let sections = PortSections(ports)
        VStack(alignment: .leading, spacing: Space.lg) {
            if ports.isEmpty {
                SectionNote(part: .ports, text: String(localized: "No Listening Ports"))
            }
            if !sections.external.isEmpty {
                PortGroupList(title: String(localized: "Open to the network"), symbol: "globe", groups: sections.external, tone: .accent)
            }
            if !sections.local.isEmpty {
                PortGroupList(title: String(localized: "Localhost only"), symbol: "lock", groups: sections.local, tone: .neutral)
            }
        }
    }
}

private struct PortGroupList: View {
    var title: String
    var symbol: String
    var groups: [PortSections.Group]
    var tone: Chip.Tone

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(groups) { group in
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    OwnerLabel(owner: group.owner)
                        .frame(width: 180, alignment: .leading)
                    FlowLayout(spacing: Space.xs) {
                        ForEach(group.ports, id: \.self) { port in
                            Chip(text: PortSections.endpoint(port), tone: tone)
                        }
                    }
                }
                .padding(.vertical, Space.xxs)
            }
        }
    }
}

struct OwnerLabel: View {
    var owner: Snapshot.PortOwner?

    var body: some View {
        switch owner {
        case .process(let pid, let name):
            Label { Text("\(name) (\(Text(String(pid)).monospaced()))").lineLimit(1) } icon: { Image(systemName: "gearshape") }
                .help("Process \(name), PID \(pid)")
        case .container(let name):
            Label { Text(name).lineLimit(1) } icon: { Image(systemName: "shippingbox") }
                .help("Container \(name)")
        case nil:
            Label { Text("Unknown owner").foregroundStyle(.secondary) } icon: { Image(systemName: "questionmark.circle") }
                .help("Owner unknown: the Agent cannot see the process")
        }
    }
}

// MARK: Shared

/// One-line empty state inside a section; a full ContentUnavailableView would dwarf the page.
struct SectionNote: View {
    var part: InspectorPart
    var text: String

    var body: some View {
        Label(text, systemImage: part.symbol)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.sm)
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
