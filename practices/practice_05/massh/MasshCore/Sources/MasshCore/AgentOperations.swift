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

    /// `ssh <server>` as the user would type it, over the master tabs share (`SSHCommand.tabControlPath`): the first
    /// tab to a Server opens it, later tabs and reconnects within a minute of the last one skip the SSH handshake.
    /// `SSHCommand.warmUp` opens it ahead of time when a Server is selected.
    public static func ssh(_ server: Server, using ssh: SSHCommand = SSHCommand()) -> TerminalCommand {
        TerminalCommand(title: server.name, executable: ssh.executable, arguments: ssh.baseArguments + [
            "-o", "ControlPath=\(ssh.tabControlPath)", "-o", "ControlMaster=auto",
            "-o", "ControlPersist=\(SSHCommand.tabPersist)", server.name,
        ])
    }
}

public enum AgentRelease {
    /// Version of the Agent binaries bundled with this build of massh.
    public static let bundledVersion = "0.1.1"

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
    func install(on server: Server, progress: @escaping @Sendable (AgentStep) -> Void) async throws -> TerminalCommand
    func update(on server: Server, progress: @escaping @Sendable (AgentStep) -> Void) async throws -> TerminalCommand
    func uninstall(from server: Server, progress: @escaping @Sendable (AgentStep) -> Void) async throws -> TerminalCommand
}

extension AgentOperations {
    public func install(on server: Server) async throws -> TerminalCommand { try await install(on: server, progress: { _ in }) }
    public func update(on server: Server) async throws -> TerminalCommand { try await update(on: server, progress: { _ in }) }
    public func uninstall(from server: Server) async throws -> TerminalCommand { try await uninstall(from: server, progress: { _ in }) }
}

/// What an Agent operation is doing before its terminal tab opens.
public enum AgentStep: Sendable, Hashable {
    /// Architecture and systemd on the Server.
    case checking
    /// Installer and Agent binary going up to the Server.
    case uploading
}
