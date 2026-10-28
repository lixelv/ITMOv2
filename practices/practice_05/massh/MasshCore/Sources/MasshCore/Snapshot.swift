import Foundation

/// Full state of a Server at one moment: overview, ports, Process and Container together.
/// Mirrors `agent/snapshot`; reference JSON lives in `contract/fixtures`.
public struct Snapshot: Sendable, Hashable, Decodable {
    /// Newest format version this build of MasshCore understands.
    public static let supportedFormatVersions = 1...2

    public var formatVersion: Int
    public var agentVersion: String
    public var time: Date
    public var overview: Overview
    public var ports: [Port]
    public var processes: [Process]
    public var docker: Docker

    public init(
        formatVersion: Int = 2,
        agentVersion: String,
        time: Date,
        overview: Overview,
        ports: [Port],
        processes: [Process],
        docker: Docker
    ) {
        self.formatVersion = formatVersion
        self.agentVersion = agentVersion
        self.time = time
        self.overview = overview
        self.ports = ports
        self.processes = processes
        self.docker = docker
    }

    public struct Overview: Sendable, Hashable, Decodable {
        public var os: String
        public var kernel: String
        public var uptimeSeconds: Int
        public var loadAverage: [Double]
        public var cpu: CPU
        public var memory: Usage
        /// Absent in format version 1.
        public var swap: Usage?
        public var disks: [Disk]
        public var network: Network

        public init(
            os: String, kernel: String, uptimeSeconds: Int, loadAverage: [Double],
            cpu: CPU, memory: Usage, swap: Usage?, disks: [Disk], network: Network
        ) {
            self.os = os
            self.kernel = kernel
            self.uptimeSeconds = uptimeSeconds
            self.loadAverage = loadAverage
            self.cpu = cpu
            self.memory = memory
            self.swap = swap
            self.disks = disks
            self.network = network
        }
    }

    public struct CPU: Sendable, Hashable, Decodable {
        public var model: String
        public var cores: Int
        public var usagePercent: Double
        /// Empty in format version 1.
        public var perCorePercent: [Double]

        public init(model: String, cores: Int, usagePercent: Double, perCorePercent: [Double]) {
            self.model = model
            self.cores = cores
            self.usagePercent = usagePercent
            self.perCorePercent = perCorePercent
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decode(String.self, forKey: .model)
            cores = try c.decode(Int.self, forKey: .cores)
            usagePercent = try c.decode(Double.self, forKey: .usagePercent)
            perCorePercent = try c.decodeIfPresent([Double].self, forKey: .perCorePercent) ?? []
        }

        private enum CodingKeys: String, CodingKey { case model, cores, usagePercent, perCorePercent }
    }

    public struct Usage: Sendable, Hashable, Decodable {
        public var totalBytes: UInt64
        public var usedBytes: UInt64

        public init(totalBytes: UInt64, usedBytes: UInt64) {
            self.totalBytes = totalBytes
            self.usedBytes = usedBytes
        }

        public var fraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
    }

    public struct Disk: Sendable, Hashable, Decodable {
        public var mountPoint: String
        public var totalBytes: UInt64
        public var usedBytes: UInt64

        public init(mountPoint: String, totalBytes: UInt64, usedBytes: UInt64) {
            self.mountPoint = mountPoint
            self.totalBytes = totalBytes
            self.usedBytes = usedBytes
        }

        public var usage: Usage { Usage(totalBytes: totalBytes, usedBytes: usedBytes) }
    }

    public struct Network: Sendable, Hashable, Decodable {
        public var rxBytesPerSecond: UInt64
        public var txBytesPerSecond: UInt64

        public init(rxBytesPerSecond: UInt64, txBytesPerSecond: UInt64) {
            self.rxBytesPerSecond = rxBytesPerSecond
            self.txBytesPerSecond = txBytesPerSecond
        }
    }

    public struct Port: Sendable, Hashable, Decodable {
        public var `protocol`: String
        public var address: String
        public var port: Int
        public var owner: PortOwner?

        public init(protocol: String, address: String, port: Int, owner: PortOwner?) {
            self.protocol = `protocol`
            self.address = address
            self.port = port
            self.owner = owner
        }
    }

    /// Process or Container holding a port.
    public enum PortOwner: Sendable, Hashable, Decodable {
        case process(pid: Int, name: String)
        case container(name: String)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decode(String.self, forKey: .name)
            switch try c.decode(String.self, forKey: .kind) {
            case "container": self = .container(name: name)
            default: self = .process(pid: try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0, name: name)
            }
        }

        public var name: String {
            switch self {
            case .process(_, let name), .container(let name): name
            }
        }

        private enum CodingKeys: String, CodingKey { case kind, pid, name }
    }

    /// A program running on the Server outside containers; kernel threads are excluded by the Agent.
    public struct Process: Sendable, Hashable, Decodable, Identifiable {
        public var pid: Int
        public var name: String
        public var user: String
        public var cpuPercent: Double
        public var memoryBytes: UInt64
        public var command: String

        public var id: Int { pid }

        public init(pid: Int, name: String, user: String, cpuPercent: Double, memoryBytes: UInt64, command: String) {
            self.pid = pid
            self.name = name
            self.user = user
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
            self.command = command
        }
    }

    public enum Docker: Sendable, Hashable, Decodable {
        case available([Container])
        case notInstalled

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if try c.decode(Bool.self, forKey: .available) {
                self = .available(try c.decode([Container].self, forKey: .containers))
            } else {
                self = .notInstalled
            }
        }

        public var containers: [Container] {
            if case .available(let containers) = self { containers } else { [] }
        }

        private enum CodingKeys: String, CodingKey { case available, containers }
    }

    public struct Container: Sendable, Hashable, Decodable, Identifiable {
        public var id: String
        public var name: String
        public var image: String
        public var status: String
        public var cpuPercent: Double
        public var memoryBytes: UInt64
        /// Absent in format version 1.
        public var memoryLimitBytes: UInt64?
        public var ports: [String]

        public init(
            id: String, name: String, image: String, status: String, cpuPercent: Double,
            memoryBytes: UInt64, memoryLimitBytes: UInt64?, ports: [String]
        ) {
            self.id = id
            self.name = name
            self.image = image
            self.status = status
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
            self.memoryLimitBytes = memoryLimitBytes
            self.ports = ports
        }
    }
}

/// One message from the Agent's WebSocket: a Snapshot this build understands, or a newer format it does not.
public enum SnapshotMessage: Sendable, Hashable {
    case snapshot(Snapshot)
    case unsupportedFormat(version: Int, agentVersion: String?)

    public var snapshot: Snapshot? {
        if case .snapshot(let snapshot) = self { snapshot } else { nil }
    }

    public static func decode(_ data: Data) throws -> SnapshotMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard Snapshot.supportedFormatVersions.contains(header.formatVersion) else {
            return .unsupportedFormat(version: header.formatVersion, agentVersion: header.agentVersion)
        }
        return .snapshot(try decoder.decode(Snapshot.self, from: data))
    }

    private struct Header: Decodable {
        var formatVersion: Int
        var agentVersion: String?
    }
}
