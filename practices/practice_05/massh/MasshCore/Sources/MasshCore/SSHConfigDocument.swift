import Foundation

/// Lossless model of one ssh_config file. Rendering an unedited document gives back the original bytes;
/// edits touch only the lines of the affected `Host` block.
public struct SSHConfigDocument: Sendable, Equatable {
    /// Each line with its own terminator ("\n", "\r\n" or none for the last line).
    var lines: [Line]

    struct Line: Sendable, Equatable {
        var content: String
        var terminator: String

        var directive: Directive? { Directive(parsing: content) }
        var isTrivia: Bool { directive == nil }
    }

    public init(data: Data) {
        self.init(text: String(decoding: data, as: UTF8.self))
    }

    public init(text: String) {
        lines = []
        var rest = Substring(text)
        while !rest.isEmpty {
            // "\r\n" is a single Character in Swift, so look for both.
            if let newline = rest.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
                let terminator = String(rest[newline])
                lines.append(Line(content: String(rest[..<newline]), terminator: terminator))
                rest = rest[rest.index(after: newline)...]
            } else {
                lines.append(Line(content: String(rest), terminator: ""))
                rest = ""
            }
        }
    }

    public var text: String { lines.map { $0.content + $0.terminator }.joined() }
    public var data: Data { Data(text.utf8) }

    /// Concrete Servers in file order: one per non-pattern name of every `Host` block.
    public var hosts: [ServerFields] {
        blocks.flatMap { block in block.names.map { fields(of: block, named: $0) } }
    }

    enum Item {
        case host(ServerFields)
        case include([String])
    }

    /// Concrete Servers and `Include` directives in file order, for expanding includes in place.
    var items: [Item] {
        let blocksByHeader = Dictionary(blocks.map { ($0.header, $0) }, uniquingKeysWith: { a, _ in a })
        return lines.indices.flatMap { i -> [Item] in
            if let block = blocksByHeader[i] { return block.names.map { .host(fields(of: block, named: $0)) } }
            if let d = lines[i].directive, d.key == "include" { return [.include(d.arguments)] }
            return []
        }
    }

    // MARK: Blocks

    struct Block {
        /// Index of the `Host` line.
        var header: Int
        /// One past the last line belonging to the block (the next `Host`/`Match` or end of file).
        var end: Int
        var patterns: [String]

        /// Names that denote a concrete Server: no wildcards, no negation.
        var names: [String] {
            patterns.filter { !$0.hasPrefix("!") && !$0.contains("*") && !$0.contains("?") }
        }

        var isWildcardOnly: Bool { names.isEmpty }
    }

    /// `Host` blocks; `Match` blocks only terminate the preceding `Host` block.
    var blocks: [Block] {
        var result: [Block] = []
        var current: Block?
        for (i, line) in lines.enumerated() {
            guard let d = line.directive, d.key == "host" || d.key == "match" else { continue }
            if var open = current {
                open.end = i
                result.append(open)
                current = nil
            }
            if d.key == "host" { current = Block(header: i, end: lines.count, patterns: d.arguments) }
        }
        if let open = current { result.append(open) }
        return result
    }

    func block(named name: String) -> Block? {
        blocks.first { $0.names.contains(name) }
    }

    func fields(of block: Block, named name: String) -> ServerFields {
        var values: [String: String] = [:]
        for line in lines[(block.header + 1)..<block.end] {
            guard let d = line.directive, values[d.key] == nil else { continue } // first value wins
            values[d.key] = d.arguments.first.map { _ in d.value }
        }
        return ServerFields(
            name: name,
            hostName: values["hostname"],
            user: values["user"],
            port: values["port"].flatMap { Int($0) },
            identityFile: values["identityfile"],
            proxyJump: values["proxyjump"]
        )
    }
}

/// One `Keyword value` or `Keyword=value` line.
struct Directive: Equatable {
    /// Lowercased keyword.
    var key: String
    /// Value with surrounding quotes removed when the whole value is quoted.
    var value: String
    var arguments: [String]
    /// Text up to the start of the value: indentation, keyword and separator, kept on edits.
    var prefix: String
    /// Whitespace after the value.
    var suffix: String

    init?(parsing content: String) {
        let trimmedStart = content.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmedStart.first, first != "#" else { return nil }
        let keywordEnd = trimmedStart.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? trimmedStart.endIndex
        key = trimmedStart[..<keywordEnd].lowercased()

        var valueStart = keywordEnd
        var seenEquals = false
        while valueStart < trimmedStart.endIndex {
            let c = trimmedStart[valueStart]
            if c == " " || c == "\t" || (c == "=" && !seenEquals) {
                seenEquals = seenEquals || c == "="
                valueStart = trimmedStart.index(after: valueStart)
            } else {
                break
            }
        }
        let raw = trimmedStart[valueStart...]
        let rawValue = raw.reversed().drop { $0 == " " || $0 == "\t" }.reversed()
        prefix = String(content[..<valueStart])
        suffix = String(raw.dropFirst(rawValue.count))
        arguments = Directive.split(String(rawValue))
        let joined = String(rawValue)
        if joined.count >= 2, joined.first == "\"", joined.last == "\"", arguments.count == 1 {
            value = arguments[0]
        } else {
            value = joined
        }
    }

    /// Whitespace-separated arguments; double quotes group words and are removed.
    static func split(_ value: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for c in value {
            if c == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if (c == " " || c == "\t") && !inQuotes {
                if hasToken { args.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(c)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return args
    }
}
