import SwiftUI

/// Renders the BBCode subset TeamSpeak uses in chat, welcome messages and descriptions:
/// [b] [i] [u] [s] [color=…] [url] [url=…] [size=…] [img] [list] [*] [hr] and alignment tags.
enum BBCode {
    static func render(_ source: String) -> AttributedString {
        var out = AttributedString()
        var open: [(name: String, start: Int, value: String)] = []
        var length = 0
        var cursor = source.startIndex

        func append(_ text: some StringProtocol) {
            guard !text.isEmpty else { return }
            out += AttributedString(String(text))
            length += text.count
        }

        let tag = #/\[(\/?)([a-zA-Z*]+)(?:="?([^\]"]*)"?)?\]/#
        for match in source.matches(of: tag) {
            append(source[cursor..<match.range.lowerBound])
            cursor = match.range.upperBound
            let closing = !match.output.1.isEmpty
            let name = match.output.2.lowercased()
            let value = String(match.output.3 ?? "")

            switch (name, closing) {
            case ("hr", false):
                append("\n────────────\n")
            case ("*", false):
                append("\n • ")
            case ("list", _), ("left", _), ("center", _), ("right", _), ("size", _), ("img", _):
                // Layout tags are dropped; the text in between stays.
                if name == "list" && closing { append("\n") }
            case (_, false):
                open.append((name, length, value))
            case (_, true):
                guard let index = open.lastIndex(where: { $0.name == name }) else { continue }
                let entry = open.remove(at: index)
                style(&out, from: entry.start, to: length, tag: entry.name, value: entry.value)
            }
        }
        append(source[cursor...])
        return out
    }

    private static func style(_ out: inout AttributedString, from: Int, to: Int, tag: String, value: String) {
        guard to > from else { return }
        let start = out.characters.index(out.startIndex, offsetBy: from)
        let end = out.characters.index(out.startIndex, offsetBy: to)
        let range = start..<end
        switch tag {
        case "b":
            out[range].inlinePresentationIntent = (out[range].inlinePresentationIntent ?? []).union(.stronglyEmphasized)
        case "i":
            out[range].inlinePresentationIntent = (out[range].inlinePresentationIntent ?? []).union(.emphasized)
        case "u":
            out[range].underlineStyle = .single
        case "s":
            out[range].strikethroughStyle = .single
        case "color":
            if let color = color(value) { out[range].foregroundColor = color }
        case "url":
            let target = value.isEmpty ? String(out[range].characters) : value
            if let url = url(target) { out[range].link = url }
        default:
            break
        }
    }

    static func url(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") { return URL(string: trimmed) }
        return URL(string: "https://" + trimmed)
    }

    private static func color(_ value: String) -> Color? {
        let v = value.lowercased()
        if v.hasPrefix("#") {
            var hex = String(v.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
            return Color(red: Double(n >> 16 & 0xFF) / 255, green: Double(n >> 8 & 0xFF) / 255, blue: Double(n & 0xFF) / 255)
        }
        return switch v {
        case "red", "darkred", "firebrick", "crimson": .red
        case "green", "darkgreen", "lime", "limegreen": .green
        case "blue", "darkblue", "navy", "royalblue": .blue
        case "yellow", "gold": .yellow
        case "orange", "darkorange": .orange
        case "purple", "violet", "magenta": .purple
        case "pink", "hotpink": .pink
        case "cyan", "aqua", "teal": .teal
        case "gray", "grey", "silver": .gray
        case "brown": .brown
        case "black": .primary
        case "white": .primary
        default: nil
        }
    }
}
