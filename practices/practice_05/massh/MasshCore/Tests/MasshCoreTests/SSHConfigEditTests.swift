import Foundation
import Testing
import MasshCore

@Suite("Editing Servers in ~/.ssh/config")
struct SSHConfigEditTests {
    static let personal = """
    # Personal machines

    Host bastion
        HostName bastion.example.com
        User ops
        Port 2222
        ForwardAgent yes

    Host web-1
    \tHostName=203.0.113.10
    \tUser deploy
    \t# legacy key
    \tIdentityFile ~/.ssh/legacy_rsa

    Host *
        ServerAliveInterval 30

    """

    func home(_ config: String = personal) throws -> TempHome {
        let home = try TempHome()
        try home.write(".ssh/config", config)
        return home
    }

    @Test func updateChangesOnlyThatBlockAndKeepsOtherDirectives() async throws {
        let home = try home()
        defer { home.remove() }
        try await home.store().update("bastion", to: ServerFields(
            name: "bastion", hostName: "10.0.0.1", user: "ops", port: nil, identityFile: "~/.ssh/id_ed25519"
        ))
        #expect(try home.read(".ssh/config") == """
        # Personal machines

        Host bastion
            HostName 10.0.0.1
            User ops
            ForwardAgent yes
            IdentityFile ~/.ssh/id_ed25519

        Host web-1
        \tHostName=203.0.113.10
        \tUser deploy
        \t# legacy key
        \tIdentityFile ~/.ssh/legacy_rsa

        Host *
            ServerAliveInterval 30

        """)
    }

    @Test func updateKeepsIndentationAndSeparatorStyle() async throws {
        let home = try home()
        defer { home.remove() }
        try await home.store().update("web-1", to: ServerFields(
            name: "web-1", hostName: "203.0.113.11", user: "deploy", identityFile: "~/.ssh/legacy_rsa", proxyJump: "bastion"
        ))
        #expect(try home.read(".ssh/config").contains("""
        Host web-1
        \tHostName=203.0.113.11
        \tUser deploy
        \t# legacy key
        \tIdentityFile ~/.ssh/legacy_rsa
        \tProxyJump bastion

        Host *
        """))
    }

    @Test func renameRewritesTheHostLine() async throws {
        let home = try home()
        defer { home.remove() }
        try await home.store().update("web-1", to: ServerFields(
            name: "web-2", hostName: "203.0.113.10", user: "deploy", identityFile: "~/.ssh/legacy_rsa"
        ))
        let text = try home.read(".ssh/config")
        #expect(text.contains("Host web-2\n\tHostName=203.0.113.10"))
        #expect(!text.contains("web-1"))
    }

    @Test func addPutsTheNewServerBeforeTheCatchAllBlock() async throws {
        let home = try home()
        defer { home.remove() }
        try await home.store().add(ServerFields(name: "db-1", hostName: "10.0.1.5", user: "deploy", port: 2200, proxyJump: "bastion"))
        let text = try home.read(".ssh/config")
        #expect(text.contains("""
        \tIdentityFile ~/.ssh/legacy_rsa

        Host db-1
            HostName 10.0.1.5
            User deploy
            Port 2200
            ProxyJump bastion

        Host *
        """))
        #expect(try await home.store().servers().map(\.name) == ["bastion", "web-1", "db-1"])
    }

    @Test func addKeepsACommentWithTheBlockItDescribes() async throws {
        let home = try home("Host a\n  HostName 1.1.1.1\n\n# defaults for everything\nHost *\n  User me\n")
        defer { home.remove() }
        try await home.store().add(ServerFields(name: "b", hostName: "2.2.2.2"))
        #expect(try home.read(".ssh/config") == """
        Host a
          HostName 1.1.1.1

        Host b
          HostName 2.2.2.2

        # defaults for everything
        Host *
          User me

        """)
    }

    @Test func addToEmptyOrMissingConfig() async throws {
        let home = try TempHome()
        defer { home.remove() }
        try await home.store().add(ServerFields(name: "first", hostName: "10.0.0.1"))
        #expect(try home.read(".ssh/config") == "Host first\n    HostName 10.0.0.1\n")

        try home.write(".ssh/config", "Host a\n  HostName 1.1.1.1") // no final newline
        try await home.store().add(ServerFields(name: "b", hostName: "2.2.2.2"))
        #expect(try home.read(".ssh/config") == "Host a\n  HostName 1.1.1.1\n\nHost b\n  HostName 2.2.2.2\n")
    }

    @Test func removeDeletesTheBlockOnly() async throws {
        let home = try home()
        defer { home.remove() }
        try await home.store().remove("web-1")
        #expect(try home.read(".ssh/config") == """
        # Personal machines

        Host bastion
            HostName bastion.example.com
            User ops
            Port 2222
            ForwardAgent yes

        Host *
            ServerAliveInterval 30

        """)
    }

    @Test func removeOneNameOfAMultiNameBlock() async throws {
        let home = try home("Host web-1 web1\n  HostName 1.2.3.4\n")
        defer { home.remove() }
        try await home.store().remove("web1")
        #expect(try home.read(".ssh/config") == "Host web-1\n  HostName 1.2.3.4\n")
    }

    @Test func everyWriteMakesABackupOfThePreviousFile() async throws {
        let home = try home()
        defer { home.remove() }
        let store = home.store()
        try await store.add(ServerFields(name: "x", hostName: "1.1.1.1"))
        #expect(try home.read(".ssh/config.massh.bak") == Self.personal)
        let afterAdd = try home.read(".ssh/config")
        try await store.remove("x")
        #expect(try home.read(".ssh/config.massh.bak") == afterAdd)
    }

    @Test func crlfFilesKeepTheirLineEndings() async throws {
        let home = try home("Host win\r\n    HostName 192.168.1.20\r\n")
        defer { home.remove() }
        try await home.store().update("win", to: ServerFields(name: "win", hostName: "192.168.1.20", user: "admin"))
        #expect(try home.read(".ssh/config") == "Host win\r\n    HostName 192.168.1.20\r\n    User admin\r\n")
    }

    @Test func rejectedEdits() async throws {
        let home = try home(Self.personal + "Include extra.conf\n")
        defer { home.remove() }
        try home.write(".ssh/extra.conf", "Host ci\n  HostName 10.9.0.1\n")
        let store = home.store()

        await #expect(throws: ServerStoreError.nameTaken("bastion")) {
            try await store.add(ServerFields(name: "bastion"))
        }
        await #expect(throws: ServerStoreError.nameTaken("ci")) {
            try await store.add(ServerFields(name: "ci"))
        }
        await #expect(throws: ServerStoreError.nameTaken("web-1")) {
            try await store.update("bastion", to: ServerFields(name: "web-1"))
        }
        await #expect(throws: ServerStoreError.readOnly("ci")) {
            try await store.update("ci", to: ServerFields(name: "ci", hostName: "x"))
        }
        await #expect(throws: ServerStoreError.readOnly("ci")) {
            try await store.remove("ci")
        }
        await #expect(throws: ServerStoreError.notFound("nope")) {
            try await store.remove("nope")
        }
        await #expect(throws: ServerStoreError.invalidName("web *")) {
            try await store.add(ServerFields(name: "web *"))
        }
        #expect(try home.read(".ssh/config") == Self.personal + "Include extra.conf\n")
        #expect(try home.read(".ssh/extra.conf") == "Host ci\n  HostName 10.9.0.1\n")
    }
}
