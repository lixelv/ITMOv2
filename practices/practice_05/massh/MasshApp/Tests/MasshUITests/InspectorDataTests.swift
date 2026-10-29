import Testing
import MasshCore
@testable import MasshUI

@Suite("Inspector data: ports, Processes, Containers")
struct InspectorDataTests {
    typealias Port = Snapshot.Port

    @Test func portsSplitIntoExternalAndLocalAndGroupByOwner() {
        let nginx = Snapshot.PortOwner.process(pid: 10, name: "nginx")
        let db = Snapshot.PortOwner.container(name: "db")
        let ports = [
            Port(protocol: "tcp", address: "0.0.0.0", port: 443, owner: nginx),
            Port(protocol: "tcp", address: "::", port: 80, owner: nginx),
            Port(protocol: "tcp", address: "127.0.0.1", port: 5432, owner: db),
            Port(protocol: "tcp", address: "::1", port: 6379, owner: nil),
            Port(protocol: "udp", address: "192.168.0.19", port: 53, owner: nil),
        ]
        let sections = PortSections(ports)

        #expect(sections.external.map(\.title) == ["nginx", nil])
        #expect(sections.external[0].ports.map(\.port) == [80, 443])
        #expect(sections.external[1].ports.map(\.port) == [53])
        #expect(sections.local.map(\.title) == ["db", nil])
        #expect(sections.local[1].ports.map(\.port) == [6379])
    }

    @Test func processesAreSearchedSortedAndCapped() {
        func p(_ pid: Int, _ name: String, cpu: Double, ram: UInt64, _ command: String) -> Snapshot.Process {
            Snapshot.Process(pid: pid, name: name, user: "root", cpuPercent: cpu, memoryBytes: ram, command: command)
        }
        let processes = [
            p(1, "systemd", cpu: 0.1, ram: 9_000, "/sbin/init"),
            p(20, "nginx", cpu: 3, ram: 4_000, "nginx: worker process"),
            p(21, "nginx", cpu: 7, ram: 5_000, "nginx: master process"),
            p(30, "python3", cpu: 50, ram: 1_000, "python3 /srv/NGINX-exporter.py"),
        ]

        let byCPU = ProcessQuery(limit: 2).apply(to: processes)
        #expect(byCPU.shown.map(\.pid) == [30, 21])
        #expect(byCPU.matching == 4)

        let search = ProcessQuery(search: "nginx", order: .memory).apply(to: processes)
        #expect(search.shown.map(\.pid) == [21, 20, 30])

        let byName = ProcessQuery(order: .name).apply(to: processes)
        #expect(byName.shown.map(\.pid) == [20, 21, 30, 1])
    }

    @Test(arguments: [
        ("Up 3 hours", ContainerState.running),
        ("Up 2 minutes (healthy)", .running),
        ("Up 2 minutes (unhealthy)", .failing),
        ("Up 5 days (Paused)", .paused),
        ("Restarting (1) 5 seconds ago", .failing),
        ("Exited (0) 3 hours ago", .stopped),
        ("Created", .unknown),
    ])
    func containerStateComesFromDockerStatus(status: String, state: ContainerState) {
        #expect(ContainerState(dockerStatus: status) == state)
    }

    @Test(arguments: [
        (Snapshot.Port(protocol: "tcp", address: "0.0.0.0", port: 443, owner: nil), "tcp 0.0.0.0:443"),
        (Snapshot.Port(protocol: "tcp", address: "::", port: 80, owner: nil), "tcp [::]:80"),
        (Snapshot.Port(protocol: "udp", address: "::1", port: 53, owner: nil), "udp [::1]:53"),
    ])
    func portEndpointBracketsIPv6(port: Snapshot.Port, text: String) {
        #expect(PortSections.endpoint(port) == text)
    }
}
