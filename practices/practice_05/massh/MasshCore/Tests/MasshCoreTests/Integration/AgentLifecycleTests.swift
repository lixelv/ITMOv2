import Foundation
import Testing
@testable import MasshCore

@Suite("Agent install, update and removal", .serialized, .enabled(if: integrationEnabled))
struct AgentLifecycleTests {
    static let dist = repoRoot.appending(path: "agent/dist")

    /// Runs the terminal-tab command headless. The test Server lets `tester` sudo without a password;
    /// for users the password goes to sudo in the tab, never through massh.
    func runInTerminal(_ command: TerminalCommand) async throws -> Subprocess.Result {
        try await Subprocess.run(command.executable, command.arguments, timeout: .seconds(120))
    }

    func firstSnapshot(_ service: SSHObservationService, _ name: String) async -> Snapshot? {
        for await event in service.observe(server(name)) {
            switch event {
            case .snapshot(let s): return s
            case .noAgent: return nil
            default: continue
            }
        }
        return nil
    }

    @Test func fullLifecycle() async throws {
        try await withTestServer { box in
            try await box.exec("echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester && chmod 440 /etc/sudoers.d/tester")
            try await box.waitFor("docker info >/dev/null 2>&1", timeout: .seconds(60))
            let ops = SSHAgentOperations(ssh: box.ssh, binaries: Self.dist)
            let it = server("it")

            // Install, twice: the second run must be harmless.
            let install = try await ops.install(on: it)
            #expect(install.arguments.last?.contains("sudo sh /tmp/massh-agent.") == true)
            #expect(!install.arguments.joined().lowercased().contains("password"))
            for command in [install, try await ops.install(on: it)] {
                let r = try await runInTerminal(command)
                #expect(r.status == 0, "\(r.output)\(r.errorOutput)")
            }
            #expect(try await box.exec("getent passwd massh | wc -l").trimmingCharacters(in: .whitespacesAndNewlines) == "1")
            #expect(try await box.exec("systemctl is-enabled massh-agent").hasPrefix("enabled"))
            #expect(try await box.exec("ps -o user= -p $(systemctl show -p MainPID --value massh-agent)").hasPrefix("massh"))
            #expect(try await box.exec("id -nG massh").contains("docker"))
            let leftovers = try await box.exec("ls /tmp | grep '^massh-agent[.]' || true")
            #expect(leftovers.isEmpty, "upload dir is cleaned up: \(leftovers)")

            let service = SSHObservationService(ssh: box.ssh)
            let installed = try #require(await firstSnapshot(service, "it"))
            #expect(installed.agentVersion == AgentRelease.bundledVersion)
            #expect(installed.docker != .notInstalled, "Agent in group docker sees Docker")
            #expect(installed.ports.contains { $0.port == 22 && $0.owner != nil }, "capabilities let it see port owners")

            // Survives a service restart and a reboot of the Server.
            try await box.exec("systemctl restart massh-agent")
            try await box.waitFor("systemctl is-active massh-agent", timeout: .seconds(10))
            _ = try await TestServerContainer.run(TestServerContainer.docker, ["restart", box.name])
            try await box.waitFor("systemctl is-active massh-agent", timeout: .seconds(60))

            // Update to a newer build: binary replaced, service restarted, version in the Snapshot changes.
            let newer = try await buildAgent(version: "0.2.0")
            let update = try await runInTerminal(try await SSHAgentOperations(ssh: box.ssh, binaries: newer).update(on: it))
            #expect(update.status == 0, "\(update.output)\(update.errorOutput)")
            #expect(await firstSnapshot(service, "it")?.agentVersion == "0.2.0")

            // Removal.
            let removal = try await runInTerminal(try await ops.uninstall(from: it))
            #expect(removal.status == 0, "\(removal.output)\(removal.errorOutput)")
            #expect(try await box.exec("test ! -e /etc/systemd/system/massh-agent.service && test ! -e /usr/local/bin/massh-agent && ! id massh && echo gone").hasPrefix("gone"))
            #expect(await firstSnapshot(service, "it") == nil)
        }
    }

    /// Shell start-up files that print (fastfetch, MOTD-style echoes) must not break preparing the install.
    @Test func noisyLoginShellIsIgnored() async throws {
        try await withTestServer { box in
            try await box.exec("""
            echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester && chmod 440 /etc/sudoers.d/tester
            printf 'echo "  .-/+oossssoo+/-.   tester@box"\\necho "x86_64 /tmp/massh-agent.fake"\\n' > /tmp/banner
            cat /tmp/banner /home/tester/.bashrc > /tmp/bashrc && mv /tmp/bashrc /home/tester/.bashrc && chown tester /home/tester/.bashrc
            """)
            // The banner really shows up in non-interactive ssh commands.
            let probe = try await Subprocess.run(box.ssh.executable, box.ssh.baseArguments + ["it", "true"])
            #expect(probe.output.contains("tester@box"))

            let ops = SSHAgentOperations(ssh: box.ssh, binaries: Self.dist)
            let install = try await ops.install(on: server("it"))
            let run = try await runInTerminal(install)
            #expect(run.status == 0, "\(run.output)\(run.errorOutput)")
            #expect(try await box.exec("systemctl is-active massh-agent").hasPrefix("active"))
        }
    }

    /// An Agent build with another version, next to the bundled installer.
    func buildAgent(version: String) async throws -> URL {
        let dir = URL(filePath: "/tmp/massh-agent-\(version)-\(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.dist.appending(path: SSHAgentOperations.installerName),
                                         to: dir.appending(path: SSHAgentOperations.installerName))
        let script = """
        cd '\(repoRoot.appending(path: "agent").path)' && \
        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags '-X main.version=\(version)' -o '\(dir.path)/massh-agent-linux-arm64' ./cmd/massh-agent && \
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags '-X main.version=\(version)' -o '\(dir.path)/massh-agent-linux-amd64' ./cmd/massh-agent
        """
        let r = try await Subprocess.run("/bin/sh", ["-lc", script], timeout: .seconds(300))
        guard r.status == 0 else { throw AgentOperationError.ssh(r.errorOutput) }
        return dir
    }
}

@Suite("Agent operations without a Server")
struct AgentOperationsTests {
    @Test func onlyTheCommandsOwnOutputCounts() {
        let fence = "__MASSH_test__"
        let noisy = "  .-/+oossssoo+/-.  me@box\nx86_64 decoy\n\(fence)\nx86_64\nsystemd\n\n\(fence)\nbye\n"
        #expect(SSHAgentOperations.fencedOutput(noisy, fence: fence) == "x86_64\nsystemd\n")
        #expect(SSHAgentOperations.fencedOutput("plain", fence: fence) == "plain")
    }

    @Test func architectures() throws {
        #expect(try SSHAgentOperations.architecture("x86_64") == "amd64")
        #expect(try SSHAgentOperations.architecture("aarch64") == "arm64")
        #expect(throws: AgentOperationError.unsupportedArchitecture("armv7l")) { try SSHAgentOperations.architecture("armv7l") }
    }
}
