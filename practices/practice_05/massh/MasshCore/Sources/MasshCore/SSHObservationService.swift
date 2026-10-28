import Foundation
import Synchronization

/// Connection to a Server's Agent: a local port that leads to `127.0.0.1:12092` on the Server.
protocol AgentTunnel: Sendable {
    /// Brings the tunnel up (or confirms it is up) and returns the local port.
    func open() async throws -> Int
    /// Whether something accepts connections on the Agent port of the Server.
    func agentListening() async -> Bool
    /// Tears the tunnel down; no process may outlive this call.
    func close() async
}

public enum ObservationError: Error, LocalizedError {
    case ssh(String)

    public var errorDescription: String? {
        switch self {
        case .ssh(let message): message
        }
    }
}

/// Observation session over the system `ssh`: ControlMaster + `-L` tunnel to the Agent, WebSocket on top (ADR 0005).
public struct SSHObservationService: ObservationService {
    /// Stops every tunnel `ssh` started by observation sessions. Call when the app terminates.
    public static func terminateAllSessions() { SSHTunnel.terminateAll() }

    struct Timing: Sendable {
        /// Silence after which the connection is considered lost.
        var staleAfter: Duration = .seconds(5)
        /// How often to look for an Agent again after "no Agent".
        var agentRecheck: Duration = .seconds(3)
        var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    }

    let makeTunnel: @Sendable (Server) -> any AgentTunnel
    let bundledVersion: String
    let timing: Timing

    public init(ssh: SSHCommand = SSHCommand(), bundledVersion: String = AgentRelease.bundledVersion) {
        self.init(bundledVersion: bundledVersion, timing: Timing()) { SSHTunnel(server: $0, ssh: ssh) }
    }

    init(bundledVersion: String, timing: Timing, makeTunnel: @escaping @Sendable (Server) -> any AgentTunnel) {
        self.makeTunnel = makeTunnel
        self.bundledVersion = bundledVersion
        self.timing = timing
    }

    public func observe(_ server: Server) -> AsyncStream<ObservationEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ObservationEvent.self, bufferingPolicy: .bufferingNewest(32))
        let tunnel = makeTunnel(server)
        let session = Session(tunnel: tunnel, bundledVersion: bundledVersion, timing: timing, emit: { continuation.yield($0) })
        let task = Task {
            await session.run()
            await tunnel.close()
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

private struct Session: Sendable {
    let tunnel: any AgentTunnel
    let bundledVersion: String
    let timing: SSHObservationService.Timing
    let emit: @Sendable (ObservationEvent) -> Void

    func run() async {
        emit(.connecting)
        var attempt = 0
        var reportedNoAgent = false
        var warnedOutdated = false
        while !Task.isCancelled {
            let outcome: Outcome
            do {
                let port = try await tunnel.open()
                if await tunnel.agentListening() {
                    reportedNoAgent = false
                    outcome = await stream(port: port, warnedOutdated: &warnedOutdated, attempt: &attempt)
                } else {
                    outcome = .noAgent
                }
            } catch {
                outcome = .lost(error.localizedDescription)
            }
            if Task.isCancelled { return }

            switch outcome {
            case .noAgent:
                if !reportedNoAgent { emit(.noAgent) }
                reportedNoAgent = true
                try? await Task.sleep(for: timing.agentRecheck)
            case .lost(let reason):
                emit(.connectionLost(reason: reason))
                let delay = timing.reconnectDelays[min(attempt, timing.reconnectDelays.count - 1)]
                try? await Task.sleep(for: delay)
                attempt += 1
                if !Task.isCancelled { emit(.reconnecting(attempt: attempt)) }
            case .unsupported:
                return
            }
        }
    }

    enum Outcome {
        case noAgent
        case lost(String)
        case unsupported
    }

    /// Receives Snapshots until the connection breaks or goes silent.
    private func stream(port: Int, warnedOutdated: inout Bool, attempt: inout Int) async -> Outcome {
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
        socket.maximumMessageSize = 64 << 20
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await receive(socket, within: timing.staleAfter)
            } catch {
                return .lost(Self.describe(error))
            }
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            switch try? SnapshotMessage.decode(data) {
            case .snapshot(let snapshot):
                attempt = 0
                if !warnedOutdated, AgentRelease.isOutdated(snapshot.agentVersion, comparedTo: bundledVersion) {
                    warnedOutdated = true
                    emit(.agentOutdated(installed: snapshot.agentVersion, bundled: bundledVersion))
                }
                emit(.snapshot(snapshot))
            case .unsupportedFormat(let version, _):
                emit(.unsupportedFormat(version: version))
                return .unsupported
            case nil:
                continue // a malformed message is skipped, the next one may be fine
            }
        }
        return .lost("cancelled")
    }

    private func receive(_ socket: URLSessionWebSocketTask, within limit: Duration) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: limit)
                // receive() ignores task cancellation; cancelling the socket makes it return.
                socket.cancel(with: .goingAway, reason: nil)
                throw ObservationError.ssh("Agent молчит дольше \(limit.components.seconds) с")
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch {
                // Whichever child failed first, make sure the other one finishes promptly.
                socket.cancel(with: .goingAway, reason: nil)
                throw error
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? ObservationError { return e.localizedDescription }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOTCONN) { return "Соединение с Agent закрыто" }
        return ns.localizedDescription
    }
}

/// `ssh -N -L` to the Server, as a ControlMaster when none exists yet. The tunnel process is a child of massh
/// and is terminated on close, together with the forward it requested.
final class SSHTunnel: AgentTunnel {
    static let agentPort = 12092

    /// Every running tunnel process, so they can be stopped when the app quits (no task cancellation runs then).
    private static let running = Mutex<[ObjectIdentifier: Process]>([:])

    static func terminateAll() {
        let processes = running.withLock { r in
            defer { r = [:] }
            return Array(r.values)
        }
        for p in processes where p.isRunning { p.terminate() }
    }

    let server: Server
    let ssh: SSHCommand
    private let state = Mutex<(process: Process?, port: Int?, stderr: Pipe?)>((nil, nil, nil))

    init(server: Server, ssh: SSHCommand) {
        self.server = server
        self.ssh = ssh
    }

    func open() async throws -> Int {
        if let (process, port) = state.withLock({ s in s.process.flatMap { p in s.port.map { (p, $0) } } }), process.isRunning {
            return port
        }
        try FileManager.default.createDirectory(at: ssh.controlDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let port = try Self.freeLocalPort()
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(filePath: ssh.executable)
        process.arguments = ssh.multiplexed(master: true) + [
            "-o", "ControlPersist=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "ConnectTimeout=10",
            "-N", "-L", forwardSpec(port), server.name,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        state.withLock { $0 = (process, port, stderr) }
        Self.running.withLock { $0[ObjectIdentifier(process)] = process }

        // Up when the local end accepts connections; dead if ssh exits first.
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if !process.isRunning {
                let message = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                state.withLock { $0 = (nil, nil, nil) }
                throw ObservationError.ssh(message.isEmpty ? "ssh завершился с кодом \(process.terminationStatus)" : message)
            }
            if await TCPProbe.connect(host: "127.0.0.1", port: port, timeout: .milliseconds(200)) { return port }
            try await Task.sleep(for: .milliseconds(100))
        }
        await close()
        throw ObservationError.ssh("Не удалось открыть туннель к \(server.name)")
    }

    func agentListening() async -> Bool {
        // `-W` through the existing connection: exit 0 once the channel to the Agent port opens, 255 if refused.
        let result = try? await Subprocess.run(
            ssh.executable,
            ssh.multiplexed() + ["-W", "127.0.0.1:\(Self.agentPort)", server.name],
            timeout: .seconds(5)
        )
        return result?.status == 0 && result?.timedOut == false
    }

    func close() async {
        let (process, port) = state.withLock { s in
            defer { s = (nil, nil, nil) }
            return (s.process, s.port)
        }
        guard let process else { return }
        _ = Self.running.withLock { $0.removeValue(forKey: ObjectIdentifier(process)) }
        if let port {
            // If another master served the forward, it would outlive our client; cancel it explicitly.
            _ = try? await Subprocess.run(ssh.executable, ssh.multiplexed() + ["-O", "cancel", "-L", forwardSpec(port), server.name],
                                          timeout: .seconds(3))
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func forwardSpec(_ port: Int) -> String { "127.0.0.1:\(port):127.0.0.1:\(Self.agentPort)" }

    static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
