import Foundation

/// A TeamSpeak query-style command: `name k=v k=v|k=v …` (Messages.toml).
public struct Command: Sendable, CustomStringConvertible {
    public let name: String
    /// One dictionary per `|`-separated entry.
    public let entries: [[String: String]]

    public var first: [String: String] { entries.first ?? [:] }

    public init(_ name: String, _ args: [(String, String?)] = []) {
        self.name = name
        var entry: [String: String] = [:]
        for (k, v) in args { entry[k] = v ?? "" }
        entries = [entry]
        orderedArgs = args
    }

    private var orderedArgs: [(String, String?)] = []
    private var rawText: String?

    private init(name: String, entries: [[String: String]]) {
        self.name = name
        self.entries = entries
    }

    /// A pre-encoded command string, sent as is.
    public static func raw(_ text: String) -> Command {
        var c = parse(text)
        c.rawText = text
        return c
    }

    /// Serialises the command. A nil value is sent as a bare key (TS convention for "empty").
    public var encoded: String {
        if let rawText { return rawText }
        var parts = [name]
        for (k, v) in orderedArgs {
            if let v, !v.isEmpty {
                parts.append("\(k)=\(Self.escape(v))")
            } else {
                parts.append(k)
            }
        }
        return parts.joined(separator: " ")
    }

    public var description: String { encoded }

    // Fields that the server sends only in the first entry of a multi-entry notification.
    private static let sharedKeys: Set<String> = [
        "ctid", "cfid", "reasonid", "reasonmsg", "invokerid", "invokername", "invokeruid", "bantime",
    ]

    public static func parse(_ text: String) -> Command {
        let pieces = text.split(separator: "|", omittingEmptySubsequences: false)
        var name = ""
        var entries: [[String: String]] = []
        for (i, piece) in pieces.enumerated() {
            var entry: [String: String] = [:]
            for (j, token) in piece.split(separator: " ", omittingEmptySubsequences: true).enumerated() {
                if i == 0 && j == 0 && !token.contains("=") {
                    name = String(token)
                    continue
                }
                if let eq = token.firstIndex(of: "=") {
                    entry[String(token[..<eq])] = unescape(String(token[token.index(after: eq)...]))
                } else {
                    entry[String(token)] = ""
                }
            }
            entries.append(entry)
        }
        if entries.count > 1, let first = entries.first {
            for i in 1..<entries.count {
                for key in sharedKeys where entries[i][key] == nil {
                    if let v = first[key] { entries[i][key] = v }
                }
            }
        }
        return Command(name: name, entries: entries)
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "/": out += "\\/"
            case " ": out += "\\s"
            case "|": out += "\\p"
            case "\u{07}": out += "\\a"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{0B}": out += "\\v"
            default: out.append(c)
            }
        }
        return out
    }

    public static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else {
                if c != "\\" { out.append(c) }
                continue
            }
            switch n {
            case "s": out += " "
            case "p": out += "|"
            case "a": out += "\u{07}"
            case "b": out += "\u{08}"
            case "f": out += "\u{0C}"
            case "n": out += "\n"
            case "r": out += "\r"
            case "t": out += "\t"
            case "v": out += "\u{0B}"
            default: out.append(n) // \\ and \/
            }
        }
        return out
    }
}

extension Dictionary where Key == String, Value == String {
    public func int(_ k: String) -> Int? { self[k].flatMap { Int($0) } }
    public func uint64(_ k: String) -> UInt64? { self[k].flatMap { UInt64($0) } }
    public func bool(_ k: String) -> Bool? { self[k].map { $0 == "1" } }
}
