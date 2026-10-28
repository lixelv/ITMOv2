import Foundation
import Synchronization

/// Server storage on `~/.ssh/config` (ADR 0002). Servers from `Include` files are read-only.
public final class SSHConfigStore: ServerStore {
    public let configURL: URL
    let homeDirectory: URL
    private let broadcast = Broadcast<[Server]>()
    private let watcher = Mutex<FileWatcher?>(nil)

    public init(
        configURL: URL = URL(filePath: NSHomeDirectory()).appending(path: ".ssh/config"),
        homeDirectory: URL = URL(filePath: NSHomeDirectory())
    ) {
        self.configURL = configURL
        self.homeDirectory = homeDirectory
    }

    deinit { watcher.withLock { $0?.cancel() } }

    public func servers() async throws -> [Server] { load().servers }

    public func serverListUpdates() -> AsyncStream<[Server]> {
        startWatching()
        return broadcast.stream()
    }

    // MARK: Reading

    struct Loaded {
        var servers: [Server]
        /// Every file read, for watching.
        var files: [URL]
    }

    func load() -> Loaded {
        var loaded = Loaded(servers: [], files: [])
        var seen = Set<String>()
        read(configURL, readOnly: false, depth: 0, into: &loaded, seen: &seen)
        return loaded
    }

    private func read(_ url: URL, readOnly: Bool, depth: Int, into loaded: inout Loaded, seen: inout Set<String>) {
        loaded.files.append(url)
        guard depth < 16, let data = try? Data(contentsOf: url) else { return }
        for item in SSHConfigDocument(data: data).items {
            switch item {
            case .host(let fields):
                // ssh uses the first block for a name; later duplicates are not separate Servers.
                guard seen.insert(fields.name).inserted else { continue }
                loaded.servers.append(Server(fields: fields, source: url, isReadOnly: readOnly))
            case .include(let patterns):
                for pattern in patterns {
                    for file in expand(pattern) {
                        read(file, readOnly: true, depth: depth + 1, into: &loaded, seen: &seen)
                    }
                }
            }
        }
    }

    /// Resolves an `Include` argument like ssh: `~` is the home directory, relative paths are under `~/.ssh`,
    /// globs are expanded and sorted.
    func expand(_ pattern: String) -> [URL] {
        var path = pattern
        if path == "~" || path.hasPrefix("~/") {
            path = homeDirectory.path + path.dropFirst()
        } else if !path.hasPrefix("/") {
            path = homeDirectory.appending(path: ".ssh").path + "/" + path
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { i in
            result.gl_pathv[i].map { URL(filePath: String(cString: $0)) }
        }.sorted { $0.path < $1.path }
    }

    // MARK: Watching

    private func startWatching() {
        let shouldStart = watcher.withLock { $0 == nil }
        guard shouldStart else { return }
        let loaded = load()
        broadcast.send(loaded.servers)
        let fileWatcher = FileWatcher { [weak self] in self?.reload() }
        fileWatcher.watch(loaded.files)
        watcher.withLock { $0 = fileWatcher }
    }

    /// Re-reads after a change on disk, re-targets the watcher (files may have been replaced) and
    /// publishes the Server List if it changed.
    func reload() {
        let loaded = load()
        watcher.withLock { $0?.watch(loaded.files) }
        if broadcast.latest != loaded.servers { broadcast.send(loaded.servers) }
    }
}

/// Watches files and their directories, so replacing a file by rename (as vim does) is noticed too.
final class FileWatcher: Sendable {
    private let queue = DispatchQueue(label: "massh.file-watcher")
    private let sources = Mutex<[any DispatchSourceFileSystemObject]>([])
    private let onChange: @Sendable () -> Void
    private let pending = Mutex(false)

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func watch(_ files: [URL]) {
        let paths = Set(files.map(\.path) + files.map { $0.deletingLastPathComponent().path })
        var created: [any DispatchSourceFileSystemObject] = []
        for path in paths.sorted() {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: queue
            )
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }
            source.resume()
            created.append(source)
        }
        let old = sources.withLock { s in
            defer { s = created }
            return s
        }
        old.forEach { $0.cancel() }
    }

    func cancel() {
        sources.withLock { s in
            s.forEach { $0.cancel() }
            s = []
        }
    }

    /// Coalesces bursts of events (write + rename + attrib) into one reload.
    private func changed() {
        let alreadyPending = pending.withLock { p in
            defer { p = true }
            return p
        }
        guard !alreadyPending else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.pending.withLock { $0 = false }
            self?.onChange()
        }
    }
}
