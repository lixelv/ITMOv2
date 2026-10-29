import Foundation
import Testing
@testable import MasshCore

@Suite("Against a real Server over SSH", .serialized, .enabled(if: integrationEnabled))
struct SSHIntegrationTests {
    private func isSnapshot(_ e: ObservationEvent) -> Bool {
        if case .snapshot = e { true } else { false }
    }

    @Test func observationSessionLifecycle() async throws {
        try await withTestServer { box in
            let it = server("it")
            let service = SSHObservationService(ssh: box.ssh)

            // No Agent yet.
            var events = service.observe(it).makeAsyncIterator()
            #expect(await events.next() == .connecting)
            #expect(await events.next() == .noAgent)

            // Agent appears: Snapshots once per second.
            try await box.startTestAgent()
            var times: [Date] = []
            while times.count < 3, let e = await events.next() {
                if case .snapshot(let s) = e { times.append(s.time) }
            }
            #expect(times.count == 3)
            let gap = times[2].timeIntervalSince(times[1])
            #expect(gap > 0.8 && gap < 1.3)

            // Agent dies: connection lost, then back on its own once it returns.
            try await box.stopTestAgent()
            var sawLost = false
            while let e = await events.next() {
                if case .connectionLost = e { sawLost = true; break }
            }
            #expect(sawLost)
            try await box.startTestAgent()
            var recovered = false
            while let e = await events.next() {
                if isSnapshot(e) { recovered = true; break }
            }
            #expect(recovered)
        }
    }

    @Test func closingTheSessionLeavesNoSSHProcesses() async throws {
        try await withTestServer { box in
            try await box.startTestAgent()
            let service = SSHObservationService(ssh: box.ssh)

            let task = Task {
                for await e in service.observe(server("it")) where isSnapshot(e) { return true }
                return false
            }
            #expect(await task.value)
            try await Task.sleep(for: .seconds(2))
            #expect(try await box.leftoverSSHProcesses() == "")
        }
    }

    /// A ControlMaster left behind by a crashed massh (or the user's own) already holds the connection: the tunnel
    /// ssh then hands its forward to that master and exits 0, which must not read as a lost connection.
    @Test func observingThroughAnExistingMaster() async throws {
        try await withTestServer { box in
            try await box.startTestAgent()
            let master = Process()
            master.executableURL = URL(filePath: box.ssh.executable)
            master.arguments = box.ssh.multiplexed(master: true) + ["-o", "ControlPersist=no", "-N", "it"]
            try master.run()
            defer { master.terminate() }
            var ready = false
            for _ in 0..<50 where !ready {
                ready = await box.ssh.hasMaster("it") != nil
                if !ready { try await Task.sleep(for: .milliseconds(200)) }
            }
            #expect(ready)

            let service = SSHObservationService(ssh: box.ssh)
            var events = service.observe(server("it")).makeAsyncIterator()
            var first: ObservationEvent?
            while let e = await events.next() {
                if e == .connecting { continue }
                first = e
                break
            }
            #expect(first.map(isSnapshot) == true, "got \(String(describing: first))")
        }
    }

    /// A warmed-up Server opens its terminal over the tab master, and closing the Inspector's session (another Server
    /// selected) leaves the tab running.
    @Test func terminalTabOutlivesTheInspectorSession() async throws {
        try await withTestServer { box in
            try await box.startTestAgent()
            let it = server("it")
            await box.ssh.warmUp(it)
            #expect(await box.ssh.hasMaster(it.name, controlPath: box.ssh.tabControlPath))

            let tab = TerminalCommand.ssh(it, using: box.ssh)
            let session = Task {
                try await Subprocess.run(tab.executable, tab.arguments.dropLast() + ["-o", "BatchMode=yes", it.name, "sleep 3; echo alive"],
                                         timeout: .seconds(15))
            }
            try await Task.sleep(for: .seconds(1))

            // The Inspector observes, then stops: its tunnel and master close mid-way through the tab's command.
            let service = SSHObservationService(ssh: box.ssh)
            let inspector = Task {
                for await e in service.observe(it) where isSnapshot(e) { return true }
                return false
            }
            #expect(await inspector.value)

            let result = try await session.value
            #expect(result.status == 0)
            #expect(result.output.contains("alive"))
            await box.ssh.closeTabMaster(it)
        }
    }

    @Test func reachabilityThroughBastion() async throws {
        try await withTestServer { box in
            let monitor = SSHReachabilityMonitor(ssh: box.ssh, interval: .seconds(3600), wakeEvents: AsyncStream { _ in })
            let servers = [server("it"), server("inner-ok", proxyJump: "it"), server("inner-closed", proxyJump: "it")]

            let before = try await firstComplete(monitor.statuses(of: servers), count: 3)
            #expect(before == ["it": .online, "inner-ok": .unknown, "inner-closed": .unknown])

            // Open a ControlMaster connection to the Bastion, as an observation session would.
            let master = try await Subprocess.run(
                box.ssh.executable, box.ssh.multiplexed(master: true) + ["-o", "ControlPersist=yes", "-f", "-N", "it"]
            )
            #expect(master.status == 0, "\(master.errorOutput)")
            let after = try await firstComplete(monitor.statuses(of: servers), count: 3)
            _ = try? await Subprocess.run(box.ssh.executable, box.ssh.multiplexed() + ["-O", "exit", "it"])
            #expect(after == ["it": .online, "inner-ok": .online, "inner-closed": .offline])
        }
    }
}
