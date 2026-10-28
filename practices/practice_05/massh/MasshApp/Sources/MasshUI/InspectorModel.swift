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
        releaseTask?.cancel()
        releaseTask = nil
        held = nil
        heldSince = nil
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
            receive(s)
        }
    }

    /// Newest Snapshot not yet shown because the user is typing.
    @ObservationIgnored private var held: Snapshot?
    @ObservationIgnored private var heldSince: ContinuousClock.Instant?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    /// Typing has priority: while keys are being pressed the Snapshot waits (at most 2 s) and the newest one is shown
    /// in the next pause, so relayouting the inspector never delays a terminal echo.
    private func receive(_ snapshot: Snapshot) {
        guard TypingActivity.isTyping() || held != nil else {
            apply(snapshot)
            return
        }
        held = snapshot
        if heldSince == nil { heldSince = .now }
        guard releaseTask == nil else { return }
        releaseTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                let waited = self.heldSince.map { ContinuousClock.now - $0 } ?? .zero
                if !TypingActivity.isTyping() || waited > .seconds(2) {
                    if let held = self.held { self.apply(held) }
                    self.held = nil
                    self.heldSince = nil
                    self.releaseTask = nil
                    return
                }
            }
        }
    }

    private func apply(_ s: Snapshot) {
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
