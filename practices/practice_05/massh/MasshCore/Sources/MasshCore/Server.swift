import Foundation

/// The six fields of a `Host` block that massh reads and edits.
public struct ServerFields: Sendable, Hashable {
    public var name: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public init(
        name: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
        identityFile: String? = nil, proxyJump: String? = nil
    ) {
        self.name = name
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }
}

/// A remote Linux machine described by a `Host` block in `~/.ssh/config`, identified by the block's name.
@dynamicMemberLookup
public struct Server: Sendable, Hashable, Identifiable {
    public var fields: ServerFields
    /// File the `Host` block lives in: `~/.ssh/config` itself or a file pulled in by `Include`.
    public var source: URL
    /// Servers from `Include` files are shown but never written to.
    public var isReadOnly: Bool

    public init(fields: ServerFields, source: URL, isReadOnly: Bool = false) {
        self.fields = fields
        self.source = source
        self.isReadOnly = isReadOnly
    }

    public var id: String { fields.name }

    public subscript<T>(dynamicMember keyPath: KeyPath<ServerFields, T>) -> T { fields[keyPath: keyPath] }

    /// Port sshd listens on, falling back to the SSH default.
    public var sshPort: Int { fields.port ?? 22 }
    /// Address to connect to, falling back to the block name like `ssh` does.
    public var address: String { fields.hostName ?? fields.name }
}

public enum ServerStoreError: Error, Hashable, LocalizedError {
    case nameTaken(String)
    case readOnly(String)
    case notFound(String)
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): "Server «\(name)» уже есть в ~/.ssh/config."
        case .readOnly(let name): "Server «\(name)» описан в Include-файле и не редактируется в massh."
        case .notFound(let name): "Server «\(name)» не найден."
        case .invalidName(let name): "Имя «\(name)» не подходит: нужно одно слово без пробелов, «*» и «?»."
        }
    }
}

/// Server storage. The real implementation is `~/.ssh/config` (ADR 0002).
public protocol ServerStore: Sendable {
    func servers() async throws -> [Server]
    func add(_ fields: ServerFields) async throws
    func update(_ name: String, to fields: ServerFields) async throws
    func remove(_ name: String) async throws
    /// Current Server List first, then a new value on every change, including edits made outside massh.
    func serverListUpdates() -> AsyncStream<[Server]>
}
