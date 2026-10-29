import Foundation
import Synchronization

/// Runs a short-lived command (always the system `ssh` here) and collects its output.
enum Subprocess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool

        var output: String { String(decoding: stdout, as: UTF8.self) }
        var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    }

    static func run(
        _ executable: String, _ arguments: [String], stdin: Data? = nil, timeout: Duration = .seconds(10)
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input

        let collected = Mutex((Data(), Data()))
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            collected.withLock { $0.0.append(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            collected.withLock { $0.1.append(d) }
        }
        let timedOut = Mutex(false)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            if let stdin {
                input.fileHandleForWriting.write(stdin)
                try? input.fileHandleForWriting.close()
            }
            Task {
                try? await Task.sleep(for: timeout)
                if process.isRunning {
                    timedOut.withLock { $0 = true }
                    process.terminate()
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let restOut = (try? out.fileHandleForReading.readToEnd()) ?? nil
        let restErr = (try? err.fileHandleForReading.readToEnd()) ?? nil
        let (o, e) = collected.withLock { $0 }
        return Result(status: status, stdout: o + (restOut ?? Data()), stderr: e + (restErr ?? Data()),
                      timedOut: timedOut.withLock { $0 })
    }
}

/// How massh invokes the system `/usr/bin/ssh` (ADR 0004).
public struct SSHCommand: Sendable, Hashable {
    public var executable: String
    /// Optional `-F` config file; nil means the user's `~/.ssh/config`. Tests point it at a temp file.
    public var configFile: URL?
    /// Directory for massh's own ControlMaster sockets. Kept short: unix socket paths are limited to 104 bytes.
    public var controlDirectory: URL

    public init(
        executable: String = "/usr/bin/ssh",
        configFile: URL? = nil,
        controlDirectory: URL = URL(filePath: NSHomeDirectory()).appending(path: "Library/Caches/massh/cm")
    ) {
        self.executable = executable
        self.configFile = configFile
        self.controlDirectory = controlDirectory
    }

    /// massh's ControlPath; `%C` is a hash of the connection, so one socket per Server.
    public var controlPath: String { controlDirectory.path + "/%C" }

    /// ControlPath of the master terminal tabs share. Separate from `controlPath`: the Inspector's tunnel closes
    /// its master when another Server is selected, which would cut every session riding on it.
    public var tabControlPath: String { controlDirectory.path + "/t%C" }

    /// Seconds a tab master stays after its last tab closes, so the next tab or a reconnect skips the handshake.
    static let tabPersist = 60

    var baseArguments: [String] {
        configFile.map { ["-F", $0.path] } ?? []
    }

    /// Arguments that reuse (or create) massh's ControlMaster connection to a Server.
    func multiplexed(master: Bool = false) -> [String] {
        baseArguments + [
            "-o", "ControlPath=\(controlPath)",
            "-o", master ? "ControlMaster=auto" : "ControlMaster=no",
            "-o", "BatchMode=yes",
        ]
    }

    /// Effective configuration of a Server as `ssh -G` reports it: keys are lowercased.
    func resolve(_ name: String) async throws -> [String: String] {
        let result = try await Subprocess.run(executable, baseArguments + ["-G", name], timeout: .seconds(5))
        var values: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, values[String(parts[0])] == nil { values[String(parts[0])] = String(parts[1]) }
        }
        return values
    }

    /// Opens the tab master to `server` in the background, so the next terminal tab starts without a handshake.
    /// Non-interactive: when the Server needs a password or a passphrase, it does nothing and the tab connects itself.
    public func warmUp(_ server: Server) async {
        try? FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if await hasMaster(server.name, controlPath: tabControlPath) { return }
        _ = try? await Subprocess.run(executable, baseArguments + [
            "-o", "ControlPath=\(tabControlPath)", "-o", "ControlMaster=auto", "-o", "ControlPersist=\(Self.tabPersist)",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-N", "-f", server.name,
        ], timeout: .seconds(15))
    }

    /// Closes the tab master to `server` now instead of after `tabPersist`.
    public func closeTabMaster(_ server: Server) async {
        _ = try? await Subprocess.run(executable, baseArguments + ["-o", "ControlPath=\(tabControlPath)", "-O", "exit", server.name],
                                      timeout: .seconds(3))
    }

    /// Whether a master to `name` answers at `controlPath`.
    public func hasMaster(_ name: String, controlPath: String) async -> Bool {
        let r = try? await Subprocess.run(executable, baseArguments + ["-o", "ControlPath=\(controlPath)", "-O", "check", name],
                                          timeout: .seconds(3))
        return r?.status == 0
    }

    /// Whether a ControlMaster connection to `name` is alive, at massh's ControlPath or the user's own.
    func hasMaster(_ name: String) async -> String? {
        var paths = [controlPath]
        if let user = try? await resolve(name)["controlpath"], user != "none" { paths.insert(user, at: 0) }
        for path in paths {
            let result = try? await Subprocess.run(
                executable, baseArguments + ["-o", "ControlPath=\(path)", "-O", "check", name], timeout: .seconds(3)
            )
            if result?.status == 0 { return path }
        }
        return nil
    }
}
