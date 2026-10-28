import Foundation

public enum AgentOperationError: Error, LocalizedError, Equatable {
    case unsupportedArchitecture(String)
    case noSystemd
    case missingBinary(String)
    case ssh(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch): String(localized: "The Agent does not support the \(arch) architecture: it needs amd64 or arm64.", bundle: .module)
        case .noSystemd: String(localized: "The Server has no systemd: the Agent only runs as a systemd service.", bundle: .module)
        case .missingBinary(let name): String(localized: "massh is missing the file \(name).", bundle: .module)
        case .ssh(let message): message
        }
    }
}

/// Prepares Agent installation over the system `ssh`: picks the binary for the Server's architecture and uploads it
/// with the installer, then hands back the `sudo` command for a terminal tab.
public struct SSHAgentOperations: AgentOperations {
    public static let installerName = "massh-agent-install.sh"

    let ssh: SSHCommand
    /// Directory with `massh-agent-linux-amd64`, `massh-agent-linux-arm64` and the installer.
    let binaries: URL

    public init(ssh: SSHCommand = SSHCommand(), binaries: URL) {
        self.ssh = ssh
        self.binaries = binaries
    }

    public func install(on server: Server) async throws -> TerminalCommand {
        try await prepare(server, action: "install", title: String(localized: "Installing Agent", bundle: .module))
    }

    public func update(on server: Server) async throws -> TerminalCommand {
        try await prepare(server, action: "update", title: String(localized: "Updating Agent", bundle: .module))
    }

    public func uninstall(from server: Server) async throws -> TerminalCommand {
        try await prepare(server, action: "uninstall", title: String(localized: "Removing Agent", bundle: .module))
    }

    private func prepare(_ server: Server, action: String, title: String) async throws -> TerminalCommand {
        try FileManager.default.createDirectory(at: ssh.controlDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let probe = try await remote(server, "uname -m; test -d /run/systemd/system && echo systemd")
        let lines = probe.split(separator: "\n").map(String.init)
        guard lines.contains("systemd") else { throw AgentOperationError.noSystemd }

        let installer = try read(Self.installerName)
        let dir = try await remote(server, "umask 077; mktemp -d /tmp/massh-agent.XXXXXX")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard dir.hasPrefix("/tmp/massh-agent.") else { throw AgentOperationError.ssh("mktemp: \(dir)") }
        try await upload(installer, to: "\(dir)/\(Self.installerName)", on: server)

        var command = "sh \(dir)/\(Self.installerName) \(action)"
        if action != "uninstall" {
            let arch = try Self.architecture(lines.first ?? "")
            try await upload(try read("massh-agent-linux-\(arch)"), to: "\(dir)/massh-agent", on: server)
            command += " \(dir)/massh-agent"
        }
        // Root logins (common on minimal Debian) may have no sudo at all.
        let script = "if [ \"$(id -u)\" -eq 0 ]; then \(command); else sudo \(command); fi"
        // Interactive: the user types the sudo password in the tab. Reuses massh's connection when there is one.
        return TerminalCommand(
            title: "\(title) — \(server.name)",
            executable: ssh.executable,
            arguments: ssh.baseArguments + ["-o", "ControlPath=\(ssh.controlPath)", "-o", "ControlMaster=no",
                                            "-t", server.name, script]
        )
    }

    static func architecture(_ uname: String) throws -> String {
        switch uname {
        case "x86_64", "amd64": "amd64"
        case "aarch64", "arm64": "arm64"
        default: throw AgentOperationError.unsupportedArchitecture(uname)
        }
    }

    private func read(_ name: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: binaries.appending(path: name).path) else {
            throw AgentOperationError.missingBinary(name)
        }
        return data
    }

    @discardableResult
    private func remote(_ server: Server, _ command: String, stdin: Data? = nil) async throws -> String {
        let result = try await Subprocess.run(
            ssh.executable,
            ssh.multiplexed(master: true) + ["-o", "ControlPersist=no", "-o", "ConnectTimeout=10", server.name, command],
            stdin: stdin, timeout: .seconds(120)
        )
        guard result.status == 0 else {
            throw AgentOperationError.ssh(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    private func upload(_ data: Data, to path: String, on server: Server) async throws {
        try await remote(server, "cat > '\(path)'", stdin: data)
    }
}
