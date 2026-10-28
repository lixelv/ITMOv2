import MasshCore
import SwiftUI

/// Sorting lives in view state, so 1 Hz Snapshot updates keep both the sort and the selection.
struct PortsTable: View {
    var ports: [Snapshot.Port]
    @State private var sortOrder = [KeyPathComparator(\PortRow.portNumber)]
    @State private var selection: PortRow.ID?

    struct PortRow: Identifiable {
        var port: Snapshot.Port
        var id: String { "\(port.protocol) \(port.address) \(port.port)" }
        var proto: String { port.protocol.uppercased() }
        var address: String { port.address }
        var portNumber: Int { port.port }
        var ownerName: String { port.owner?.name ?? "" }
        var ownerPID: Int {
            if case .process(let pid, _) = port.owner { pid } else { 0 }
        }
    }

    var body: some View {
        Table(ports.map { PortRow(port: $0) }.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Прот.", value: \.proto).width(min: 36, ideal: 40)
            TableColumn("Адрес", value: \.address) { Text($0.address).monospaced() }
            TableColumn("Порт", value: \.portNumber) { Text("\($0.portNumber)").monospacedDigit() }.width(min: 40, ideal: 50)
            TableColumn("Владелец", value: \.ownerName) { row in OwnerLabel(owner: row.port.owner) }
        }
        .overlay { if ports.isEmpty { ContentUnavailableView("Нет слушающих портов", systemImage: "point.3.connected.trianglepath.dotted") } }
    }
}

struct OwnerLabel: View {
    var owner: Snapshot.PortOwner?

    var body: some View {
        switch owner {
        case .process(let pid, let name):
            Label { Text("\(name) (\(pid))").lineLimit(1) } icon: { Image(systemName: "gearshape") }
                .help("Process \(name), PID \(pid)")
        case .container(let name):
            Label { Text(name).lineLimit(1) } icon: { Image(systemName: "shippingbox") }
                .help("Container \(name)")
        case nil:
            Text("—").foregroundStyle(.tertiary).help("Владелец неизвестен: Agent не видит процесс")
        }
    }
}

struct ProcessesTable: View {
    var processes: [Snapshot.Process]
    @State private var sortOrder = [KeyPathComparator(\Snapshot.Process.cpuPercent, order: .reverse)]
    @State private var selection: Snapshot.Process.ID?

    var body: some View {
        Table(processes.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit() }.width(min: 44, ideal: 52)
            TableColumn("Имя", value: \.name) { Text($0.name).lineLimit(1) }
            TableColumn("Польз.", value: \.user) { Text($0.user).lineLimit(1) }.width(min: 48, ideal: 64)
            TableColumn("CPU", value: \.cpuPercent) { Text(Format.percent($0.cpuPercent)).monospacedDigit() }.width(min: 44, ideal: 50)
            TableColumn("RAM", value: \.memoryBytes) { Text(Format.bytes($0.memoryBytes)).monospacedDigit() }.width(min: 56, ideal: 64)
            TableColumn("Команда", value: \.command) { p in
                Text(p.command).lineLimit(1).truncationMode(.middle).help(p.command).foregroundStyle(.secondary)
            }
        }
        .overlay { if processes.isEmpty { ContentUnavailableView("Нет процессов", systemImage: "list.bullet.rectangle") } }
    }
}

struct ContainersTable: View {
    var docker: Snapshot.Docker
    @State private var sortOrder = [KeyPathComparator(\ContainerRow.name)]
    @State private var selection: ContainerRow.ID?

    struct ContainerRow: Identifiable {
        var container: Snapshot.Container
        var id: String { container.id }
        var name: String { container.name }
        var image: String { container.image }
        var status: String { container.status }
        var cpu: Double { container.cpuPercent }
        var memory: UInt64 { container.memoryBytes }
        var ports: String { container.ports.joined(separator: ", ") }
    }

    var body: some View {
        switch docker {
        case .notInstalled:
            ContentUnavailableView("Docker не установлен", systemImage: "shippingbox",
                                   description: Text("На этом Server нет Docker, или Agent не может к нему обратиться."))
        case .available(let containers):
            Table(containers.map { ContainerRow(container: $0) }.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Имя", value: \.name) { Text($0.name).lineLimit(1) }
                TableColumn("Образ", value: \.image) { Text($0.image).lineLimit(1).foregroundStyle(.secondary) }
                TableColumn("Статус", value: \.status) { Text($0.status).lineLimit(1) }
                TableColumn("CPU", value: \.cpu) { Text(Format.percent($0.cpu)).monospacedDigit() }.width(min: 44, ideal: 50)
                TableColumn("RAM", value: \.memory) { row in
                    Text(row.container.memoryLimitBytes.map { "\(Format.bytes(row.memory)) / \(Format.bytes($0))" } ?? Format.bytes(row.memory))
                        .monospacedDigit().lineLimit(1)
                }
                TableColumn("Порты", value: \.ports) { Text($0.ports).lineLimit(1).truncationMode(.middle).help($0.ports) }
            }
            .overlay { if containers.isEmpty { ContentUnavailableView("Нет запущенных контейнеров", systemImage: "shippingbox") } }
        }
    }
}

#Preview("Processes — 400") {
    ProcessesTable(processes: FakeSnapshots.make(tick: 3, processCount: 400).processes).frame(width: 480, height: 600)
}

#Preview("Ports") {
    PortsTable(ports: FakeSnapshots.make(tick: 0).ports).frame(width: 420, height: 300)
}

#Preview("Containers") {
    ContainersTable(docker: FakeSnapshots.make(tick: 0).docker).frame(width: 520, height: 300)
}

#Preview("No Docker") {
    ContainersTable(docker: .notInstalled).frame(width: 420, height: 300)
}
