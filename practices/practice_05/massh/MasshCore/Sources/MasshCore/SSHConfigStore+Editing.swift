import Foundation

extension SSHConfigStore {
    public func add(_ fields: ServerFields) async throws {
        try validate(fields.name)
        try edit { document, names in
            guard !names.contains(fields.name) else { throw ServerStoreError.nameTaken(fields.name) }
            document.addHost(fields)
        }
    }

    public func update(_ name: String, to fields: ServerFields) async throws {
        try validate(fields.name)
        try edit { document, names in
            try ensureEditable(name, in: document, names: names)
            if fields.name != name, names.contains(fields.name) { throw ServerStoreError.nameTaken(fields.name) }
            document.updateHost(name, to: fields)
        }
    }

    public func remove(_ name: String) async throws {
        try edit { document, names in
            try ensureEditable(name, in: document, names: names)
            document.removeHost(name)
        }
    }

    public static let backupSuffix = ".massh.bak"

    private func validate(_ name: String) throws {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*?!\"#,="))
        guard !name.isEmpty, name.rangeOfCharacter(from: forbidden) == nil else {
            throw ServerStoreError.invalidName(name)
        }
    }

    private func ensureEditable(_ name: String, in document: SSHConfigDocument, names: Set<String>) throws {
        guard names.contains(name) else { throw ServerStoreError.notFound(name) }
        guard document.block(named: name) != nil else { throw ServerStoreError.readOnly(name) }
    }

    /// Applies a change to the main config file only, backing up the previous contents first.
    private func edit(_ change: (inout SSHConfigDocument, Set<String>) throws -> Void) throws {
        // Write through symlinks (dotfile managers) instead of replacing them.
        let target = configURL.resolvingSymlinksInPath()
        let original = try? Data(contentsOf: target)
        var document = SSHConfigDocument(data: original ?? Data())
        try change(&document, Set(load().servers.map(\.name)))

        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if let original {
            try original.write(to: URL(filePath: target.path + Self.backupSuffix), options: .atomic)
        }
        let permissions = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) ?? 0o600
        try document.data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        reload()
    }
}

extension SSHConfigDocument {
    /// Directive spelling for each editable field, in the order new lines are written.
    static let fieldKeys: [(key: String, keyword: String, value: @Sendable (ServerFields) -> String?)] = [
        ("hostname", "HostName", \.hostName),
        ("user", "User", \.user),
        ("port", "Port", { $0.port.map(String.init) }),
        ("identityfile", "IdentityFile", \.identityFile),
        ("proxyjump", "ProxyJump", \.proxyJump),
    ]

    var terminator: String { lines.first { !$0.terminator.isEmpty }?.terminator ?? "\n" }

    /// Indentation of the first indented directive in the file, else four spaces.
    var indentation: String {
        for line in lines {
            guard line.directive != nil else { continue }
            let indent = line.content.prefix { $0 == " " || $0 == "\t" }
            if !indent.isEmpty { return String(indent) }
        }
        return "    "
    }

    mutating func addHost(_ fields: ServerFields) {
        let indent = indentation, nl = terminator
        var newLines = [Line(content: "Host \(Self.quote(fields.name))", terminator: nl)]
        for field in Self.fieldKeys {
            if let value = field.value(fields) {
                newLines.append(Line(content: "\(indent)\(field.keyword) \(Self.quote(value))", terminator: nl))
            }
        }

        // ssh takes the first value it sees, so a trailing catch-all block must stay after the new Server.
        let blocks = blocks
        let firstTrailing = (blocks.lastIndex { !$0.isWildcardOnly } ?? -1) + 1
        if firstTrailing < blocks.count {
            // Comments right above the catch-all block describe it; insert above them.
            var at = blocks[firstTrailing].header
            while at > 0, lines[at - 1].content.trimmingCharacters(in: .whitespaces).hasPrefix("#") { at -= 1 }
            newLines.append(Line(content: "", terminator: nl))
            lines.insert(contentsOf: newLines, at: at)
            return
        }
        if let last = lines.indices.last {
            if lines[last].terminator.isEmpty { lines[last].terminator = nl }
            if !lines[last].content.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(Line(content: "", terminator: nl))
            }
        }
        lines.append(contentsOf: newLines)
    }

    mutating func updateHost(_ name: String, to fields: ServerFields) {
        guard var block = block(named: name) else { return }
        if block.patterns.count > 1 {
            // `Host a b`: give this Server a block of its own (a copy) so the other names keep their settings.
            guard let copy = splitOff(name, from: block) else { return }
            block = copy
        }
        if fields.name != name {
            rewriteHeader(of: block) { patterns in patterns.map { $0 == name ? fields.name : $0 } }
        }
        for field in Self.fieldKeys {
            let matching = (block.header + 1..<block.end).filter { lines[$0].directive?.key == field.key }
            guard let value = field.value(fields) else {
                for i in matching.reversed() { lines.remove(at: i) }
                block.end -= matching.count
                continue
            }
            if let first = matching.first, let d = lines[first].directive {
                lines[first].content = d.prefix + Self.quote(value) + d.suffix
            } else {
                let lastDirective = (block.header..<block.end).last { lines[$0].directive != nil } ?? block.header
                let indent = lines[(block.header + 1)..<block.end]
                    .first { $0.directive != nil }
                    .map { String($0.content.prefix { $0 == " " || $0 == "\t" }) } ?? indentation
                if lines[lastDirective].terminator.isEmpty { lines[lastDirective].terminator = terminator }
                lines.insert(Line(content: "\(indent)\(field.keyword) \(Self.quote(value))", terminator: terminator),
                             at: lastDirective + 1)
                block.end += 1
            }
        }
    }

    mutating func removeHost(_ name: String) {
        guard let block = block(named: name) else { return }
        if block.patterns.count > 1 {
            rewriteHeader(of: block) { patterns in patterns.filter { $0 != name } }
            return
        }
        // Lines after the last directive (blank lines, comments) belong to whatever follows.
        let lastDirective = (block.header..<block.end).last { lines[$0].directive != nil } ?? block.header
        lines.removeSubrange(block.header...lastDirective)
        let i = block.header
        if i > 0, i < lines.count, lines[i - 1].isBlank, lines[i].isBlank {
            lines.remove(at: i)
        } else if i == lines.count, i > 0, lines[i - 1].isBlank {
            lines.removeLast()
        }
    }

    /// Drops `name` from a shared block and inserts a copy of the block for `name` right after it.
    private mutating func splitOff(_ name: String, from block: Block) -> Block? {
        let lastDirective = (block.header..<block.end).last { lines[$0].directive != nil } ?? block.header
        var copy = Array(lines[block.header...lastDirective])
        if copy[copy.count - 1].terminator.isEmpty { copy[copy.count - 1].terminator = terminator }
        if let d = copy[0].directive { copy[0].content = d.prefix + Self.quote(name) + d.suffix }
        rewriteHeader(of: block) { patterns in patterns.filter { $0 != name } }
        if lines[lastDirective].terminator.isEmpty { lines[lastDirective].terminator = terminator }
        let at = lastDirective + 1
        lines.insert(contentsOf: [Line(content: "", terminator: terminator)] + copy, at: at)
        return self.block(named: name)
    }

    private mutating func rewriteHeader(of block: Block, _ transform: ([String]) -> [String]) {
        guard let d = lines[block.header].directive else { return }
        lines[block.header].content = d.prefix + transform(d.arguments).map(Self.quote).joined(separator: " ") + d.suffix
    }

    static func quote(_ value: String) -> String {
        value.contains(where: { $0 == " " || $0 == "\t" }) ? "\"\(value)\"" : value
    }
}

extension SSHConfigDocument.Line {
    var isBlank: Bool { content.allSatisfy { $0 == " " || $0 == "\t" } }
}
