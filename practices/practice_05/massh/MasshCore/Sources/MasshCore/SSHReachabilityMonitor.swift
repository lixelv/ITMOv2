import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Online/Offline/Unknown from a TCP connection to each Server's SSH port; never asks the Agent.
/// Addresses come from `ssh -G`, so `Host *` defaults, `Include` and `Match` apply exactly as in ssh.
public struct SSHReachabilityMonitor: ReachabilityMonitor {
    public static let timeout: Duration = .seconds(3)

    let ssh: SSHCommand
    let interval: Duration
    let wakeEvents: @Sendable () -> AsyncStream<Void>

    public init(ssh: SSHCommand = SSHCommand(), interval: Duration = .seconds(30)) {
        self.ssh = ssh
        self.interval = interval
        self.wakeEvents = SystemWake.events
    }

    init(ssh: SSHCommand, interval: Duration, wakeEvents: AsyncStream<Void>) {
        self.ssh = ssh
        self.interval = interval
        self.wakeEvents = { wakeEvents }
    }

    public func statuses(of servers: [Server]) -> AsyncStream<[String: Reachability]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String: Reachability].self, bufferingPolicy: .bufferingNewest(8))
        let (rounds, trigger) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let ssh = ssh, interval = interval, wake = wakeEvents()

        let timer = Task {
            while !Task.isCancelled {
                trigger.yield()
                try await Task.sleep(for: interval)
            }
        }
        let waker = Task {
            for await _ in wake { trigger.yield() }
        }
        let checker = Task {
            var statuses: [String: Reachability] = [:]
            for await _ in rounds {
                // One round: every Server in parallel; publish as each result arrives so slow ones don't hold the rest.
                await withTaskGroup(of: (String, Reachability).self) { group in
                    for server in servers {
                        group.addTask { (server.name, await Self.check(server, ssh: ssh)) }
                    }
                    for await (name, status) in group {
                        statuses[name] = status
                        continuation.yield(statuses)
                    }
                }
            }
        }
        continuation.onTermination = { _ in
            timer.cancel()
            waker.cancel()
            checker.cancel()
            trigger.finish()
        }
        return stream
    }

    static func check(_ server: Server, ssh: SSHCommand) async -> Reachability {
        guard let config = try? await ssh.resolve(server.name) else { return .unknown }
        let host = config["hostname"] ?? server.address
        let port = config["port"].flatMap(Int.init) ?? server.sshPort

        if let jump = config["proxyjump"], jump != "none" {
            // The hop that connects to the Server is the last one.
            let bastion = String(jump.split(separator: ",").last ?? Substring(jump))
            return await checkThroughBastion(bastion, host: host, port: port, ssh: ssh)
        }
        if let command = config["proxycommand"], command != "none" {
            return .unknown
        }
        return await TCPProbe.connect(host: host, port: port, timeout: timeout) ? .online : .offline
    }

    /// Asks the Bastion's existing ControlMaster connection to open a channel to the Server (`ssh -W`)
    /// and waits for the SSH banner. Without such a connection the status is Unknown.
    static func checkThroughBastion(_ bastion: String, host: String, port: Int, ssh: SSHCommand) async -> Reachability {
        let bastionName = bastion.split(separator: "@").last.map(String.init) ?? bastion
        guard let controlPath = await ssh.hasMaster(bastionName) else { return .unknown }
        let result = try? await Subprocess.run(
            ssh.executable,
            ssh.baseArguments + ["-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no",
                                 "-W", "\(host):\(port)", bastionName],
            timeout: timeout
        )
        guard let result else { return .unknown }
        return result.output.hasPrefix("SSH-") ? .online : .offline
    }
}

enum TCPProbe {
    /// Non-blocking connect to every resolved address, bounded by `timeout` overall.
    static func connect(host: String, port: Int, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Task.detached { blockingConnect(host: host, port: port, timeout: timeout) }.value
            }
            group.addTask {
                try? await Task.sleep(for: timeout + .milliseconds(200))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func blockingConnect(host: String, port: Int, timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now + timeout
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return false }
        defer { freeaddrinfo(list) }

        var current: UnsafeMutablePointer<addrinfo>? = list
        while let ai = current {
            current = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { return true }
            guard errno == EINPROGRESS else { continue }

            let remaining = deadline - ContinuousClock.now
            let ms = Int32(max(0, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, ms) == 1 else { return false } // timed out
            var error: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len)
            if error == 0 { return true }
        }
        return false
    }
}

/// Mac wake-from-sleep notifications as a stream.
enum SystemWake {
    static func events() -> AsyncStream<Void> {
        #if canImport(AppKit)
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                continuation.yield()
            }
            nonisolated(unsafe) let observer = token
            continuation.onTermination = { _ in center.removeObserver(observer) }
        }
        #else
        AsyncStream { _ in }
        #endif
    }
}
