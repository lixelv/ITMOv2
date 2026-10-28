import Foundation
import Testing
@testable import MasshCore

/// The whole path a user takes, through the public API only: add a Server to the ssh config, see it Online,
/// install the Agent with the terminal-tab command, then watch live overview, ports, Process and Container.
@Suite("End to end on a test Server", .serialized, .enabled(if: integrationEnabled))
struct EndToEndTests {
    @Test func addServerInstallAgentAndObserve() async throws {
        try await withTestServer { box in
            try await box.exec("echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester && chmod 440 /etc/sudoers.d/tester")
            try await box.waitFor("docker info >/dev/null 2>&1", timeout: .seconds(60))
            try await Self.loadBusybox(into: box)
            try await box.exec("docker run -d --name web -p 8080:80 busybox:1.36 httpd -f -p 80")

            // A user config: a catch-all block of their own, which massh must keep and keep last.
            let config = box.dir.appending(path: "user-config")
            let catchAll = """
            # my defaults
            Host *
              StrictHostKeyChecking no
              UserKnownHostsFile /dev/null
              LogLevel ERROR
              IdentitiesOnly yes

            """
            try catchAll.write(to: config, atomically: true, encoding: .utf8)
            let store = SSHConfigStore(configURL: config, homeDirectory: box.dir)
            let ssh = SSHCommand(configFile: config, controlDirectory: box.ssh.controlDirectory)

            try await store.add(ServerFields(name: "e2e", hostName: "127.0.0.1", user: "tester", port: box.sshPort,
                                             identityFile: box.dir.appending(path: "id_ed25519").path))
            let text = try String(contentsOf: config, encoding: .utf8)
            #expect(text.hasPrefix("Host e2e\n"))
            #expect(text.hasSuffix(catchAll), "the catch-all block and its comment stay last, untouched")
            let server = try #require(try await store.servers().first { $0.name == "e2e" })

            let monitor = SSHReachabilityMonitor(ssh: ssh, interval: .seconds(3600), wakeEvents: AsyncStream { _ in })
            #expect(try await firstComplete(monitor.statuses(of: [server]), count: 1) == ["e2e": .online])

            let observation = SSHObservationService(ssh: ssh)
            var events = observation.observe(server).makeAsyncIterator()
            #expect(await events.next() == .connecting)
            #expect(await events.next() == .noAgent)

            let install = try await SSHAgentOperations(ssh: ssh, binaries: AgentLifecycleTests.dist).install(on: server)
            let run = try await Subprocess.run(install.executable, install.arguments, timeout: .seconds(120))
            #expect(run.status == 0, "\(run.output)\(run.errorOutput)")

            // The open session notices the Agent by itself.
            var snapshot: Snapshot?
            while snapshot == nil, let e = await events.next() {
                if case .snapshot(let s) = e, !s.processes.isEmpty, !s.docker.containers.isEmpty { snapshot = s }
            }
            let s = try #require(snapshot)
            #expect(s.overview.cpu.cores > 0 && s.overview.memory.totalBytes > 0 && !s.overview.disks.isEmpty)
            #expect(s.processes.contains { $0.name == "sshd" })
            #expect(s.docker.containers.map(\.name) == ["web"])
            #expect(s.ports.contains { $0.port == 8080 && $0.owner == .container(name: "web") })
            #expect(s.ports.contains { $0.port == 22 && $0.owner != nil })
        }
    }

    static func loadBusybox(into box: TestServerContainer) async throws {
        let docker = TestServerContainer.docker
        if (try? await TestServerContainer.run(docker, ["image", "inspect", "busybox:1.36"])) == nil {
            try await TestServerContainer.run(docker, ["pull", "busybox:1.36"])
        }
        let r = try await Subprocess.run("/bin/sh", ["-c", "\(docker) save busybox:1.36 | \(docker) exec -i \(box.name) docker load"],
                                         timeout: .seconds(120))
        guard r.status == 0 else { throw ObservationError.ssh(r.errorOutput) }
    }
}
