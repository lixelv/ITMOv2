import Foundation
import Synchronization

// In-memory implementations of the public API, used by MasshApp previews and while it runs without a Server.

public final class FakeServerStore: ServerStore {
    private let list: Mutex<[Server]>
    private let broadcast: Broadcast<[Server]>

    public static let sampleServers: [Server] = {
        let config = URL(filePath: NSHomeDirectory()).appending(path: ".ssh/config")
        let work = URL(filePath: NSHomeDirectory()).appending(path: ".ssh/config.d/work")
        return [
            Server(fields: ServerFields(name: "web-1", hostName: "203.0.113.10", user: "deploy"), source: config),
            Server(fields: ServerFields(name: "db-1", hostName: "10.0.1.5", user: "deploy", proxyJump: "bastion"), source: config),
            Server(fields: ServerFields(name: "bastion", hostName: "bastion.example.com", user: "ops", port: 2222,
                                        identityFile: "~/.ssh/id_ed25519"), source: config),
            Server(fields: ServerFields(name: "ci-runner", hostName: "198.51.100.7", user: "ci"), source: work, isReadOnly: true),
            Server(fields: ServerFields(name: "pi", hostName: "raspberrypi.local", user: "pi"), source: config),
        ]
    }()

    public init(servers: [Server] = FakeServerStore.sampleServers) {
        list = Mutex(servers)
        broadcast = Broadcast(servers)
    }

    public func servers() async throws -> [Server] { list.withLock { $0 } }

    public func add(_ fields: ServerFields) async throws {
        try commit { servers in
            guard !servers.contains(where: { $0.name == fields.name }) else { throw ServerStoreError.nameTaken(fields.name) }
            servers.append(Server(fields: fields, source: FakeServerStore.sampleServers[0].source))
        }
    }

    public func update(_ name: String, to fields: ServerFields) async throws {
        try commit { servers in
            let index = try editableIndex(of: name, in: servers)
            if fields.name != name, servers.contains(where: { $0.name == fields.name }) {
                throw ServerStoreError.nameTaken(fields.name)
            }
            servers[index].fields = fields
        }
    }

    public func remove(_ name: String) async throws {
        try commit { servers in servers.remove(at: try editableIndex(of: name, in: servers)) }
    }

    public func serverListUpdates() -> AsyncStream<[Server]> { broadcast.stream() }

    private func commit(_ change: (inout [Server]) throws -> Void) throws {
        let updated = try list.withLock { servers in
            try change(&servers)
            return servers
        }
        broadcast.send(updated)
    }

    private func editableIndex(of name: String, in servers: [Server]) throws -> Int {
        guard let index = servers.firstIndex(where: { $0.name == name }) else { throw ServerStoreError.notFound(name) }
        guard !servers[index].isReadOnly else { throw ServerStoreError.readOnly(name) }
        return index
    }
}

public struct FakeReachabilityMonitor: ReachabilityMonitor {
    private let status: @Sendable (Server) -> Reachability

    /// By default Servers behind a Bastion are Unknown, a Server named "pi" is Offline, the rest Online.
    public init(status: @escaping @Sendable (Server) -> Reachability = { server in
        if server.proxyJump != nil { return .unknown }
        return server.name == "pi" ? .offline : .online
    }) {
        self.status = status
    }

    public func statuses(of servers: [Server]) -> AsyncStream<[String: Reachability]> {
        let map = Dictionary(servers.map { ($0.name, status($0)) }, uniquingKeysWith: { a, _ in a })
        return AsyncStream { continuation in
            continuation.yield(map)
        }
    }
}

public struct FakeObservationService: ObservationService {
    public enum Scenario: Sendable {
        case live
        case noAgent
        case outdatedAgent
        /// Lose the connection after this many Snapshots, then reconnect.
        case dropsConnection(after: Int)
        case dockerMissing
    }

    public var scenario: Scenario
    public var interval: Duration
    public var processCount: Int

    public init(scenario: Scenario = .live, interval: Duration = .seconds(1), processCount: Int = 40) {
        self.scenario = scenario
        self.interval = interval
        self.processCount = processCount
    }

    public func observe(_ server: Server) -> AsyncStream<ObservationEvent> {
        let scenario = scenario, interval = interval, processCount = processCount
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.connecting)
                try await Task.sleep(for: interval)
                switch scenario {
                case .noAgent:
                    continuation.yield(.noAgent)
                    continuation.finish()
                    return
                case .outdatedAgent:
                    continuation.yield(.agentOutdated(installed: "0.0.9", bundled: AgentRelease.bundledVersion))
                default:
                    break
                }
                var tick = 0
                while !Task.isCancelled {
                    if case .dropsConnection(let after) = scenario, tick > 0, tick % after == 0 {
                        continuation.yield(.connectionLost(reason: "Connection reset by peer"))
                        try await Task.sleep(for: interval)
                        continuation.yield(.reconnecting(attempt: 1))
                        try await Task.sleep(for: interval)
                    }
                    var snapshot = FakeSnapshots.make(tick: tick, processCount: processCount, seed: server.name)
                    if case .dockerMissing = scenario { snapshot.docker = .notInstalled }
                    if case .outdatedAgent = scenario { snapshot.agentVersion = "0.0.9" }
                    continuation.yield(.snapshot(snapshot))
                    tick += 1
                    try await Task.sleep(for: interval)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct FakeAgentOperations: AgentOperations {
    public init() {}

    public func install(on server: Server) async throws -> TerminalCommand { script(String(localized: "Installing Agent", bundle: .module), server) }
    public func update(on server: Server) async throws -> TerminalCommand { script(String(localized: "Updating Agent", bundle: .module), server) }
    public func uninstall(from server: Server) async throws -> TerminalCommand { script(String(localized: "Removing Agent", bundle: .module), server) }

    private func script(_ title: String, _ server: Server) -> TerminalCommand {
        TerminalCommand(
            title: "\(title) — \(server.name)",
            executable: "/bin/sh",
            arguments: ["-c", "echo '\(title) on \(server.name) (fake)'; sleep 1; echo done"]
        )
    }
}

/// Plausible Snapshots that drift smoothly over time.
public enum FakeSnapshots {
    public static func make(tick: Int, processCount: Int = 40, seed: String = "web-1") -> Snapshot {
        var rng = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed.hashValueStable &+ tick))
        let t = Double(tick)
        func wave(_ period: Double, _ phase: Double = 0) -> Double { (sin(t / period + phase) + 1) / 2 }

        let cores = 4
        let perCore = (0..<cores).map { i in min(100, 8 + 60 * wave(7 + Double(i), Double(i)) + Double.random(in: 0...6, using: &rng)) }
        let gib: UInt64 = 1 << 30
        let memTotal = 8 * gib
        let memUsed = UInt64(Double(memTotal) * (0.35 + 0.2 * wave(20)))

        let names = ["nginx", "postgres", "redis-server", "node", "python3", "sshd", "systemd-journald", "dockerd",
                     "containerd", "cron", "rsyslogd", "bash", "htop", "gunicorn", "celery"]
        let users = ["root", "www-data", "postgres", "deploy", "redis"]
        var processes = [Snapshot.Process(pid: 1, name: "systemd", user: "root", cpuPercent: 0, memoryBytes: 12 << 20, command: "/sbin/init")]
        for i in 1..<max(processCount, 1) {
            let name = names[i % names.count]
            processes.append(Snapshot.Process(
                pid: 300 + i * 17,
                name: name,
                user: users[i % users.count],
                cpuPercent: (i % 7 == 0 ? 25 * wave(5, Double(i)) : 0) + Double.random(in: 0...0.8, using: &rng),
                memoryBytes: UInt64(4 + (i * 37) % 300) << 20,
                command: "/usr/bin/\(name) --worker \(i)"
            ))
        }

        let containers = [
            Snapshot.Container(id: "4f2a9c1b7e3d", name: "web", image: "nginx:1.27", status: "Up 3 hours",
                               cpuPercent: 2 + 10 * wave(6), memoryBytes: 48 << 20, memoryLimitBytes: 512 << 20,
                               ports: ["0.0.0.0:8080->80/tcp"]),
            Snapshot.Container(id: "9b1e22aa0c41", name: "cache", image: "redis:7", status: "Up 2 days",
                               cpuPercent: 0.4, memoryBytes: 12 << 20, memoryLimitBytes: nil, ports: ["127.0.0.1:6379->6379/tcp"]),
        ]

        return Snapshot(
            agentVersion: AgentRelease.bundledVersion,
            time: Date(timeIntervalSince1970: 1_793_188_800 + t),
            overview: .init(
                os: "Ubuntu 24.04.1 LTS",
                kernel: "6.8.0-45-generic",
                uptimeSeconds: 864_210 + tick,
                loadAverage: [0.4 + wave(9), 0.35 + wave(30) / 2, 0.3],
                cpu: .init(model: "AMD EPYC 7763 64-Core Processor", cores: cores,
                           usagePercent: perCore.reduce(0, +) / Double(cores), perCorePercent: perCore),
                memory: .init(totalBytes: memTotal, usedBytes: memUsed),
                swap: .init(totalBytes: 2 * gib, usedBytes: 64 << 20),
                disks: [
                    .init(mountPoint: "/", totalBytes: 80 * gib, usedBytes: 31 * gib),
                    .init(mountPoint: "/boot", totalBytes: gib, usedBytes: 180 << 20),
                    .init(mountPoint: "/var/lib/docker", totalBytes: 200 * gib, usedBytes: 182 * gib),
                ],
                network: .init(rxBytesPerSecond: UInt64(20_000 + 400_000 * wave(8)),
                               txBytesPerSecond: UInt64(5_000 + 90_000 * wave(11, 1)))
            ),
            ports: [
                .init(protocol: "tcp", address: "0.0.0.0", port: 22, owner: .process(pid: 317, name: "sshd")),
                .init(protocol: "tcp", address: "0.0.0.0", port: 8080, owner: .container(name: "web")),
                .init(protocol: "tcp", address: "127.0.0.1", port: 5432, owner: .process(pid: 334, name: "postgres")),
                .init(protocol: "tcp", address: "127.0.0.1", port: 6379, owner: .container(name: "cache")),
                .init(protocol: "udp", address: "127.0.0.53", port: 53, owner: nil),
                .init(protocol: "tcp", address: "::", port: 22, owner: .process(pid: 317, name: "sshd")),
            ],
            processes: processes,
            docker: .available(containers)
        )
    }
}

private extension String {
    /// Hash that is stable across launches, unlike `hashValue`.
    var hashValueStable: Int { unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) } }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
