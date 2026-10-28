import Foundation

/// Command for a terminal tab; the user types the sudo password there, massh never sees it.
public struct TerminalCommand: Sendable, Hashable {
    public var title: String
    public var executable: String
    public var arguments: [String]

    public init(title: String, executable: String, arguments: [String]) {
        self.title = title
        self.executable = executable
        self.arguments = arguments
    }

    /// `ssh <server>` as the user would type it.
    public static func ssh(_ server: Server) -> TerminalCommand {
        TerminalCommand(title: server.name, executable: "/usr/bin/ssh", arguments: [server.name])
    }
}

public enum AgentRelease {
    /// Version of the Agent binaries bundled with this build of massh.
    public static let bundledVersion = "0.1.0"

    /// Whether `installed` is older than `bundled`, comparing dotted numeric versions.
    public static func isOutdated(_ installed: String, comparedTo bundled: String = bundledVersion) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(installed), b = parts(bundled)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// Install, update and remove the Agent. Each operation prepares the Server (architecture, upload)
/// and returns the installer command to run in a terminal tab. Call only after the user agreed.
public protocol AgentOperations: Sendable {
    func install(on server: Server) async throws -> TerminalCommand
    func update(on server: Server) async throws -> TerminalCommand
    func uninstall(from server: Server) async throws -> TerminalCommand
}
