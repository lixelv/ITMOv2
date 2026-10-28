import Foundation

public enum ObservationEvent: Sendable, Hashable {
    case connecting
    case snapshot(Snapshot)
    /// The Server is reachable over SSH but no Agent answers on it.
    case noAgent
    /// The Agent is older than the one bundled with massh; Snapshots keep coming.
    case agentOutdated(installed: String, bundled: String)
    /// The Agent speaks a newer Snapshot format than this build understands.
    case unsupportedFormat(version: Int)
    case connectionLost(reason: String)
    case reconnecting(attempt: Int)
}

public protocol ObservationService: Sendable {
    /// Stream of Snapshots and session states for one Server. Cancelling the iteration closes the session,
    /// its tunnel and every `ssh` process it started.
    func observe(_ server: Server) -> AsyncStream<ObservationEvent>
}
