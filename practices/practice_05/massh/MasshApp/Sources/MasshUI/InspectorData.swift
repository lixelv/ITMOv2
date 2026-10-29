import Foundation
import MasshCore

/// Listening ports for the Inspector: open to the network first, then localhost-only, each grouped by owner.
struct PortSections {
    struct Group: Identifiable {
        /// Process or Container name; nil when the Agent cannot see who holds the port.
        var owner: Snapshot.PortOwner?
        var ports: [Snapshot.Port]

        var title: String? { owner?.name }
        var id: String {
            switch owner {
            case .process(let pid, _): "process-\(pid)"
            case .container(let name): "container-\(name)"
            case nil: "unknown"
            }
        }
    }

    var external: [Group]
    var local: [Group]

    init(_ ports: [Snapshot.Port]) {
        external = Self.grouped(ports.filter { !Self.isLoopback($0.address) })
        local = Self.grouped(ports.filter { Self.isLoopback($0.address) })
    }

    /// "tcp 0.0.0.0:443", with IPv6 addresses in brackets: "tcp [::]:80".
    static func endpoint(_ port: Snapshot.Port) -> String {
        let host = port.address.contains(":") ? "[\(port.address)]" : port.address
        return "\(port.protocol) \(host):\(port.port)"
    }

    static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address == "localhost"
    }

    /// Owners by name, ports without an owner last; ports by number inside a group.
    private static func grouped(_ ports: [Snapshot.Port]) -> [Group] {
        Dictionary(grouping: ports, by: \.owner)
            .map { Group(owner: $0.key, ports: $0.value.sorted { ($0.port, $0.protocol) < ($1.port, $1.protocol) }) }
            .sorted { a, b in
                switch (a.title, b.title) {
                case let (x?, y?): x.localizedStandardCompare(y) == .orderedAscending
                case (_?, nil): true
                default: false
                }
            }
    }
}

/// What the Processes section shows: a search over name and command, an order, and a cap so 400+ Processes stay cheap.
struct ProcessQuery: Equatable {
    enum Order: CaseIterable {
        case cpu, memory, name, pid
    }

    static let defaultLimit = 50

    var search = ""
    var order = Order.cpu
    var limit: Int? = defaultLimit

    /// `matching` counts every Process that passes the search, before the cap.
    func apply(to processes: [Snapshot.Process]) -> (shown: [Snapshot.Process], matching: Int) {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let found = needle.isEmpty ? processes : processes.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.command.localizedCaseInsensitiveContains(needle)
        }
        let sorted = found.sorted { a, b in
            switch order {
            case .cpu: (b.cpuPercent, a.pid) < (a.cpuPercent, b.pid)
            case .memory: (b.memoryBytes, a.pid) < (a.memoryBytes, b.pid)
            case .name: (a.name.lowercased(), a.pid) < (b.name.lowercased(), b.pid)
            case .pid: a.pid < b.pid
            }
        }
        return (limit.map { Array(sorted.prefix($0)) } ?? sorted, found.count)
    }
}

/// A Container's state read from Docker's human status line ("Up 3 hours (Paused)", "Restarting (1) …").
enum ContainerState: Hashable, Sendable {
    case running, paused, failing, stopped, unknown

    init(dockerStatus status: String) {
        let s = status.lowercased()
        if s.hasPrefix("restarting") || s.contains("(unhealthy)") {
            self = .failing
        } else if s.contains("(paused)") {
            self = .paused
        } else if s.hasPrefix("up") {
            self = .running
        } else if s.hasPrefix("exited") || s.hasPrefix("dead") {
            self = .stopped
        } else {
            self = .unknown
        }
    }
}

extension Snapshot.Docker {
    /// Running Containers for the section header; nil when there is no Docker to count.
    var count: Int? {
        if case .available(let containers) = self { containers.count } else { nil }
    }

    var containersByName: [Snapshot.Container] {
        containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
