import Foundation
import Testing
@testable import MasshCore

@Suite("Terminal tab command")
struct TerminalCommandTests {
    /// Tabs share their own master (not the Inspector's tunnel, which closes when another Server is selected) and keep
    /// it a minute after the last tab, so a new tab or a reconnect skips the SSH handshake.
    @Test func terminalTabsShareTheirOwnPersistentConnection() {
        let ssh = SSHCommand(configFile: URL(filePath: "/tmp/cfg"), controlDirectory: URL(filePath: "/tmp/cm"))
        let server = FakeServerStore.sampleServers[0]
        let command = TerminalCommand.ssh(server, using: ssh)

        #expect(command.arguments.suffix(7) == [
            "-o", "ControlPath=/tmp/cm/t%C", "-o", "ControlMaster=auto", "-o", "ControlPersist=60", server.name,
        ])
        #expect(ssh.tabControlPath != ssh.controlPath)
        #expect(!command.arguments.contains("BatchMode=yes"), "a tab may ask for a password")
    }
}
