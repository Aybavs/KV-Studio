import Foundation

enum GlobPattern {
    static let searchDebounceNanoseconds: UInt64 = 250_000_000

    static func matchPattern(for text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") {
            return Data(trimmed.utf8)
        }
        return Data("*\(escaped(trimmed))*".utf8)
    }

    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if ch == "*" || ch == "?" || ch == "[" || ch == "]" || ch == "\\" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}
