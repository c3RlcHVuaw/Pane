import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case quote(String)
    case code(String)
    case rule
}

/// Just enough Markdown to lay out an answer: blocks here, bold/italic/code/links inline in the view.
public enum Markdown {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() { if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }

        for raw in source.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if code != nil {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"))); code = nil }
                else { code!.append(raw) }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if let h = heading(line) { flush(); out.append(h); continue }
            if ["---", "***", "___"].contains(line) { flush(); out.append(.rule); continue }
            if line.hasPrefix("> ") { flush(); out.append(.quote(String(line.dropFirst(2)))); continue }
            if let b = bullet(line) { flush(); out.append(.bullet(b)); continue }
            if let (n, t) = numbered(line) { flush(); out.append(.numbered(n, t)); continue }
            paragraph.append(line)
        }
        flush()
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }  // an unfinished fence while streaming
        return out
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...4).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }
    private static func bullet(_ line: String) -> String? {
        for p in ["- ", "* ", "• "] where line.hasPrefix(p) { return String(line.dropFirst(2)) }
        return nil
    }
    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }
}
