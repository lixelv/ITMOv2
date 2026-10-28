import Foundation
import Testing
import MasshCore

func sshConfigFixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/ssh-configs/\(name)"))
}

/// A throwaway home directory with `.ssh/config` and friends.
struct TempHome {
    let url: URL
    var ssh: URL { url.appending(path: ".ssh") }
    var config: URL { ssh.appending(path: "config") }

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "massh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: ".ssh"), withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ path: String) throws -> String { try String(contentsOf: url.appending(path: path), encoding: .utf8) }

    func store() -> SSHConfigStore { SSHConfigStore(configURL: config, homeDirectory: url) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Reading ~/.ssh/config")
struct SSHConfigReadTests {
    static let configs = ["personal.conf", "tabs-and-equals.conf", "crlf.conf", "includes.conf", "weird.conf"]

    @Test(arguments: configs)
    func roundTripIsByteIdentical(_ name: String) throws {
        let data = try sshConfigFixture(name)
        let document = SSHConfigDocument(data: data)
        #expect(document.data == data)
    }

    @Test func serverListSkipsPatternsAndMatchBlocks() throws {
        let document = SSHConfigDocument(data: try sshConfigFixture("personal.conf"))
        #expect(document.hosts.map(\.name) == ["bastion", "web-1", "web1"])

        let odd = SSHConfigDocument(data: try sshConfigFixture("tabs-and-equals.conf"))
        #expect(odd.hosts.map(\.name) == ["pi", "quoted name", "noeol"])

        let weird = SSHConfigDocument(data: try sshConfigFixture("weird.conf"))
        #expect(weird.hosts.map(\.name) == ["spaced", "gw"])
    }

    @Test func sixFieldsAreRead() throws {
        let hosts = SSHConfigDocument(data: try sshConfigFixture("personal.conf")).hosts
        #expect(hosts[0] == ServerFields(name: "bastion", hostName: "bastion.example.com", user: "ops", port: 2222,
                                         identityFile: "~/.ssh/id_ed25519"))
        // First IdentityFile wins, as in ssh.
        #expect(hosts[1] == ServerFields(name: "web-1", hostName: "203.0.113.10", user: "deploy",
                                         identityFile: "~/.ssh/legacy_rsa", proxyJump: "bastion"))

        let odd = SSHConfigDocument(data: try sshConfigFixture("tabs-and-equals.conf")).hosts
        #expect(odd[0] == ServerFields(name: "pi", hostName: "raspberrypi.local", user: "pi", port: 22))
        #expect(odd[1].hostName == "10.0.0.2")
        #expect(odd[2].hostName == "10.9.9.9")

        let crlf = SSHConfigDocument(data: try sshConfigFixture("crlf.conf")).hosts
        #expect(crlf.map(\.hostName) == ["192.168.1.20", "192.168.1.21"])

        let weird = SSHConfigDocument(data: try sshConfigFixture("weird.conf")).hosts
        #expect(weird[0] == ServerFields(name: "spaced", hostName: "spaced.example.com", user: "me"))
    }

    @Test func includesExpandAndAreReadOnly() async throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".ssh/config", String(decoding: try sshConfigFixture("includes.conf"), as: UTF8.self))
        try home.write(".ssh/config.d/10-work", "Host ci-runner\n  HostName 198.51.100.7\nInclude nested.conf\n")
        try home.write(".ssh/config.d/20-lab", "Host lab-*\n  User lab\nHost lab-1\n  HostName 10.1.0.1\n")
        try home.write(".ssh/nested.conf", "Host nested\n  HostName 10.2.0.1\n")
        try home.write("extra/servers.conf", "Host extra\n  HostName extra.example.com\n")

        let servers = try await home.store().servers()
        #expect(servers.map(\.name) == ["ci-runner", "nested", "lab-1", "extra", "local-box"])
        #expect(servers.filter(\.isReadOnly).map(\.name) == ["ci-runner", "nested", "lab-1", "extra"])
        let local = try #require(servers.last)
        #expect(local.source == home.config)
        #expect(servers[0].source.lastPathComponent == "10-work")
    }

    @Test func missingConfigIsAnEmptyList() async throws {
        let home = try TempHome()
        defer { home.remove() }
        #expect(try await home.store().servers().isEmpty)
    }

    @Test func externalEditsPublishANewServerList() async throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".ssh/config", "Host one\n  HostName 10.0.0.1\n")
        let store = home.store()
        var updates = store.serverListUpdates().makeAsyncIterator()
        #expect(await updates.next()?.map(\.name) == ["one"])

        // Like vim: write a new file and rename it over the old one.
        try home.write(".ssh/config.tmp", "Host one\n  HostName 10.0.0.1\nHost two\n  HostName 10.0.0.2\n")
        _ = try FileManager.default.replaceItemAt(home.config, withItemAt: home.ssh.appending(path: "config.tmp"))
        #expect(await updates.next()?.map(\.name) == ["one", "two"])

        // And a plain in-place write afterwards.
        try home.write(".ssh/config", "Host two\n  HostName 10.0.0.2\n")
        #expect(await updates.next()?.map(\.name) == ["two"])
    }
}
