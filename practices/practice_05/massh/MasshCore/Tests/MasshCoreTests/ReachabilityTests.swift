import Foundation
import Testing
@testable import MasshCore

/// A TCP listener on 127.0.0.1 with an OS-assigned port.
final class LocalListener: @unchecked Sendable {
    let fd: Int32
    let port: Int

    init(backlog: Int32 = 16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && listen(fd, backlog) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw POSIXError(.EADDRINUSE) }
        self.fd = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
    }

    private var closed = false
    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
    deinit { close() }
}

/// A port nothing listens on: bind, read the port, close.
func closedPort() throws -> Int {
    let l = try LocalListener()
    l.close()
    return l.port
}

struct TestSSHConfig {
    let url: URL
    init(_ text: String) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "massh-ssh-\(UUID().uuidString).conf")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    var ssh: SSHCommand {
        SSHCommand(configFile: url, controlDirectory: FileManager.default.temporaryDirectory.appending(path: "massh-cm-test"))
    }
}

func server(_ name: String, proxyJump: String? = nil) -> Server {
    Server(fields: ServerFields(name: name, proxyJump: proxyJump), source: URL(filePath: "/dev/null"))
}

@Suite("Reachability monitor")
struct ReachabilityTests {
    @Test func openPortIsOnlineAndClosedPortIsOffline() async throws {
        let listener = try LocalListener()
        let closed = try closedPort()
        let config = try TestSSHConfig("""
        Host up
          HostName 127.0.0.1
          Port \(listener.port)
        Host down
          HostName 127.0.0.1
          Port \(closed)
        """)
        let monitor = SSHReachabilityMonitor(ssh: config.ssh, interval: .seconds(3600), wakeEvents: AsyncStream { _ in })
        let statuses = try await firstComplete(monitor.statuses(of: [server("up"), server("down")]), count: 2)
        #expect(statuses == ["up": .online, "down": .offline])
    }

    @Test func filteredPortIsOfflineWithinThreeSeconds() async throws {
        // Private address no one answers on; SYNs vanish like on a filtered port. (TEST-NET 192.0.2.1 is not
        // used: transparent proxies on some networks accept connections to it.)
        let config = try TestSSHConfig("Host void\n  HostName 10.255.255.1\n  Port 22\n")
        let monitor = SSHReachabilityMonitor(ssh: config.ssh, interval: .seconds(3600), wakeEvents: AsyncStream { _ in })
        let start = ContinuousClock.now
        let statuses = try await firstComplete(monitor.statuses(of: [server("void")]), count: 1)
        #expect(statuses == ["void": .offline])
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(3800))
    }

    @Test func rechecksOnTimer() async throws {
        let listener = try LocalListener()
        let config = try TestSSHConfig("Host box\n  HostName 127.0.0.1\n  Port \(listener.port)\n")
        let monitor = SSHReachabilityMonitor(ssh: config.ssh, interval: .milliseconds(200), wakeEvents: AsyncStream { _ in })
        var it = monitor.statuses(of: [server("box")]).makeAsyncIterator()
        #expect(await it.next() == ["box": .online])
        listener.close()
        var latest: Reachability?
        for _ in 0..<20 {
            latest = await it.next()?["box"]
            if latest == .offline { break }
        }
        #expect(latest == .offline)
    }

    @Test func rechecksOnWake() async throws {
        let listener = try LocalListener()
        let config = try TestSSHConfig("Host box\n  HostName 127.0.0.1\n  Port \(listener.port)\n")
        let (wake, wakeUp) = AsyncStream.makeStream(of: Void.self)
        let monitor = SSHReachabilityMonitor(ssh: config.ssh, interval: .seconds(3600), wakeEvents: wake)
        var it = monitor.statuses(of: [server("box")]).makeAsyncIterator()
        #expect(await it.next() == ["box": .online])
        listener.close()
        wakeUp.yield()
        #expect(await it.next() == ["box": .offline])
    }

    @Test func serverBehindBastionWithoutConnectionIsUnknown() async throws {
        let listener = try LocalListener()
        let config = try TestSSHConfig("""
        Host bastion
          HostName 127.0.0.1
          Port \(try closedPort())
        Host inner
          HostName 10.0.0.5
          ProxyJump bastion
        Host direct
          HostName 127.0.0.1
          Port \(listener.port)
        """)
        let monitor = SSHReachabilityMonitor(ssh: config.ssh, interval: .seconds(3600), wakeEvents: AsyncStream { _ in })
        let statuses = try await firstComplete(
            monitor.statuses(of: [server("inner", proxyJump: "bastion"), server("direct")]), count: 2
        )
        #expect(statuses == ["inner": .unknown, "direct": .online])
    }
}

/// First emitted map that has a status for `count` Servers.
func firstComplete(_ stream: AsyncStream<[String: Reachability]>, count: Int) async throws -> [String: Reachability] {
    for await statuses in stream where statuses.count >= count { return statuses }
    throw CancellationError()
}
