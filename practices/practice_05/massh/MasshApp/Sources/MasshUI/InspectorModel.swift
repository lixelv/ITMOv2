import Foundation
import MasshCore
import Observation

/// Live view of one Server's observation session, plus chart history since the inspector connected.
@MainActor
@Observable
public final class InspectorModel {
    public enum Connection: Equatable {
        case idle
        case connecting
        case live
        case noAgent
        case unsupportedFormat(version: Int)
        case lost(reason: String)
        case reconnecting(attempt: Int)
    }

    public struct Sample: Identifiable, Equatable {
        public var time: Date
        public var cpuPercent: Double
        public var memoryPercent: Double
        public var rxBytesPerSecond: Double
        public var txBytesPerSecond: Double
        public var id: Date { time }
    }

    /// Samples kept for charts: the whole connection, up to a day at 1 Hz (a few MB at most).
    public static let historyLimit = 86_400

    public private(set) var server: Server?
    public private(set) var connection: Connection = .idle
    public private(set) var snapshot: Snapshot?
    public private(set) var receivedAt: Date?
    public private(set) var history: [Sample] = []
    /// Installed and bundled versions when the Agent is older than this build of massh.
    public private(set) var outdated: (installed: String, bundled: String)?

    private let observation: any ObservationService
    private var task: Task<Void, Never>?

    public init(observation: any ObservationService) {
        self.observation = observation
    }

    public var isLive: Bool { connection == .live }

    /// Switches to another Server; history starts over.
    public func observe(_ server: Server?) {
        task?.cancel()
        self.server = server
        snapshot = nil
        receivedAt = nil
        history = []
        outdated = nil
        connection = server == nil ? .idle : .connecting
        guard let server else { return }
        task = Task { [weak self, observation] in
            for await event in observation.observe(server) {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
    }

    /// Starts the session again, e.g. after the Agent was installed.
    public func reconnect() { observe(server) }

    private func handle(_ event: ObservationEvent) {
        switch event {
        case .connecting: connection = .connecting
        case .noAgent: connection = .noAgent
        case .agentOutdated(let installed, let bundled): outdated = (installed, bundled)
        case .unsupportedFormat(let version): connection = .unsupportedFormat(version: version)
        case .connectionLost(let reason): connection = .lost(reason: reason)
        case .reconnecting(let attempt): connection = .reconnecting(attempt: attempt)
        case .snapshot(let s):
            connection = .live
            snapshot = s
            receivedAt = .now
            history.append(Sample(
                time: s.time,
                cpuPercent: s.overview.cpu.usagePercent,
                memoryPercent: s.overview.memory.fraction * 100,
                rxBytesPerSecond: Double(s.overview.network.rxBytesPerSecond),
                txBytesPerSecond: Double(s.overview.network.txBytesPerSecond)
            ))
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
    }
}
