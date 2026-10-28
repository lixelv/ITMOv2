import Foundation

/// Online: the SSH port accepts TCP connections (through the Bastion for Servers behind one).
/// Offline: it does not. Unknown: cannot check because there is no connection to the Bastion.
public enum Reachability: String, Sendable, Hashable {
    case online, offline, unknown
}

public protocol ReachabilityMonitor: Sendable {
    /// Status of every Server by name. Checks immediately, every 30 seconds and when the Mac wakes;
    /// emits after every round. Does not depend on the Agent.
    func statuses(of servers: [Server]) -> AsyncStream<[String: Reachability]>
}
