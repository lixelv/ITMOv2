import Foundation
import Testing
@testable import MasshCore

/// Integration tests need OrbStack/Docker, the `massh-test-server` images and `make agent`; run with
/// `MASSH_INTEGRATION=1 make test-core` (or `make test-integration`).
let integrationEnabled = ProcessInfo.processInfo.environment["MASSH_INTEGRATION"] == "1"

let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized

/// A Linux test Server in a container: systemd, sshd reachable on a local port, key auth for user `tester`.
final class TestServerContainer: @unchecked Sendable {
    let name: String
    let sshPort: Int
    let dir: URL
    let ssh: SSHCommand

    static let docker = "/usr/local/bin/docker"

    init(image: String = "massh-test-server:docker") async throws {
        name = "massh-swift-it-\(UUID().uuidString.prefix(8).lowercased())"
        dir = URL(filePath: "/tmp/massh-it-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appending(path: "cm"), withIntermediateDirectories: true)

        // A fixed host port, so the Server keeps its address across `docker restart`.
        sshPort = try SSHTunnel.freeLocalPort()
        let dist = repoRoot.appending(path: "agent/dist").path
        try await Self.run(Self.docker, [
            "run", "-d", "--rm", "--name", name, "--privileged", "--cgroupns=host",
            "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/run", "--tmpfs", "/run/lock",
            "-v", "/var/lib/docker", "-v", "/var/lib/containerd",
            "-v", "\(dist):/opt/massh-test:ro", "-p", "127.0.0.1:\(sshPort):22", image,
        ])

        let key = dir.appending(path: "id_ed25519")
        try await Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path])
        let config = dir.appending(path: "config")
        let common = """
          User tester
          IdentityFile \(key.path)
          IdentitiesOnly yes
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
          LogLevel ERROR
        """
        try """
        Host it
          HostName 127.0.0.1
          Port \(sshPort)
        \(common)
        Host inner-ok
          HostName 127.0.0.1
          Port 22
          ProxyJump it
        \(common)
        Host inner-closed
          HostName 127.0.0.1
          Port 1
          ProxyJump it
        \(common)
        """.write(to: config, atomically: true, encoding: .utf8)
        ssh = SSHCommand(configFile: config, controlDirectory: dir.appending(path: "cm"))

        try await waitFor("systemctl is-active ssh", timeout: .seconds(60))
        let pub = try String(contentsOf: dir.appending(path: "id_ed25519.pub"), encoding: .utf8)
        try await exec("install -d -m 700 -o tester -g tester /home/tester/.ssh && echo '\(pub.trimmingCharacters(in: .newlines))' > /home/tester/.ssh/authorized_keys && chown tester:tester /home/tester/.ssh/authorized_keys && chmod 600 /home/tester/.ssh/authorized_keys")
        for _ in 0..<50 {
            let r = try await Subprocess.run(ssh.executable, ssh.baseArguments + ["it", "true"], timeout: .seconds(5))
            if r.status == 0 { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ObservationError.ssh("sshd in \(name) never accepted the test key")
    }

    @discardableResult
    func exec(_ script: String) async throws -> String {
        try await Self.run(Self.docker, ["exec", name, "sh", "-c", script])
    }

    func waitFor(_ script: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if (try? await exec(script)) != nil { return }
            if ContinuousClock.now > deadline { throw ObservationError.ssh("timed out: \(script)") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func startTestAgent() async throws {
        try await exec("nohup /opt/massh-test/massh-agent-linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') >/tmp/agent.log 2>&1 &")
        try await waitFor("ss -ltn | grep -q 127.0.0.1:12092", timeout: .seconds(10))
    }

    func stopTestAgent() async throws {
        try await exec("pkill -f '[m]assh-agent-linux' || true")
    }

    /// massh's ssh processes for this container still running on the Mac.
    func leftoverSSHProcesses() async throws -> String {
        let r = try await Subprocess.run("/usr/bin/pgrep", ["-fl", dir.path])
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() async {
        _ = try? await Subprocess.run(Self.docker, ["rm", "-f", "-v", name])
        _ = try? await Subprocess.run("/usr/bin/pkill", ["-f", dir.path])
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String]) async throws -> String {
        let r = try await Subprocess.run(executable, args, timeout: .seconds(120))
        guard r.status == 0 else {
            throw ObservationError.ssh("\(executable) \(args.joined(separator: " ")): \(r.errorOutput)")
        }
        return r.output
    }
}

/// Runs `body` against a fresh test Server and always removes it afterwards.
func withTestServer(image: String = "massh-test-server:docker", _ body: (TestServerContainer) async throws -> Void) async throws {
    let box = try await TestServerContainer(image: image)
    do {
        try await body(box)
    } catch {
        await box.remove()
        throw error
    }
    await box.remove()
}
