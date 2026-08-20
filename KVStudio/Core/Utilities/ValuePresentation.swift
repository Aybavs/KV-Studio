import Foundation

enum ValueFormat: String, CaseIterable, Sendable {
    case auto
    case text
    case json
    case hex
}

enum ValuePresentation {
    static func isValidUTF8(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        return String(data: data, encoding: .utf8) != nil
    }

    static func textString(from data: Data) -> String? {
        if data.isEmpty { return "" }
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        // Extra round-trip guard against future non-strict decoders
        guard str.data(using: .utf8) == data else { return nil }
        return str
    }

    static func isValidJSON(_ data: Data) -> Bool {
        guard isValidUTF8(data) else { return false }
        if data.isEmpty { return false }
        // Trim? JSONSerialization handles whitespace, but empty whitespace should be false
        // Quick check: try parsing
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
            return true
        } catch {
            return false
        }
    }

    static func prettyJSONString(from data: Data) -> String? {
        guard isValidJSON(data) else { return nil }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
            // JSONSerialization.data(withJSONObject:) throws ObjC exception for fragments on newer OS
            // Only pretty-print collections; fragments round-trip as-is to avoid crash
            if obj is [Any] || obj is [String: Any] {
                let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                return String(data: pretty, encoding: .utf8)
            } else {
                return String(data: data, encoding: .utf8)
            }
        } catch {
            return nil
        }
    }

    // Simple space-separated hex, e.g. "48 65 6c 6c 6f"
    static func hexString(from data: Data) -> String {
        if data.isEmpty { return "" }
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // Hex dump with offsets, grouped bytes, ASCII gutter
    static func hexDump(from data: Data, bytesPerLine: Int = 16, showASCII: Bool = true) -> String {
        if data.isEmpty { return "" }
        let count = data.count
        var lines: [String] = []
        lines.reserveCapacity((count + bytesPerLine - 1) / bytesPerLine)
        for offset in stride(from: 0, to: count, by: bytesPerLine) {
            let end = min(offset + bytesPerLine, count)
            let chunk = data[offset..<end]
            let offsetStr = String(format: "%08x", offset)

            var hexParts: [String] = []
            hexParts.reserveCapacity(bytesPerLine + 1)
            for i in 0..<bytesPerLine {
                if offset + i < end {
                    let b = data[offset + i]
                    hexParts.append(String(format: "%02x", b))
                } else {
                    hexParts.append("  ")
                }
                if i == 7 {
                    // marker for extra gap; we join specially below
                }
            }
            // Build hex column with single spaces and double space after 8
            var hexColumn = ""
            for i in 0..<bytesPerLine {
                hexColumn += hexParts[i]
                if i != bytesPerLine - 1 {
                    hexColumn += " "
                    if i == 7 {
                        hexColumn += " "
                    }
                }
            }

            if showASCII {
                var ascii = ""
                ascii.reserveCapacity(chunk.count)
                for b in chunk {
                    if b >= 0x20 && b <= 0x7E {
                        ascii.append(Character(UnicodeScalar(b)))
                    } else {
                        ascii.append(".")
                    }
                }
                lines.append("\(offsetStr)  \(hexColumn)  |\(ascii)|")
            } else {
                lines.append("\(offsetStr)  \(hexColumn)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func autoDetectedFormat(for data: Data) -> ValueFormat {
        if isValidJSON(data) {
            return .json
        }
        if isValidUTF8(data) {
            return .text
        }
        return .hex
    }

    static func resolvedFormat(for data: Data, selected: ValueFormat) -> ValueFormat {
        if selected == .auto {
            return autoDetectedFormat(for: data)
        }
        return selected
    }

    enum HexParseError: Error, Equatable, Sendable {
        case oddLength
        case invalidCharacter
    }

    static func data(fromHex string: String) throws(HexParseError) -> Data {
        let stripped = string.filter { !$0.isWhitespace }
        if stripped.isEmpty { return Data() }
        guard stripped.count % 2 == 0 else { throw HexParseError.oddLength }
        var result = Data()
        result.reserveCapacity(stripped.count / 2)
        var index = stripped.startIndex
        while index < stripped.endIndex {
            let next = stripped.index(index, offsetBy: 2)
            let pair = String(stripped[index..<next])
            guard let byte = UInt8(pair, radix: 16) else { throw HexParseError.invalidCharacter }
            result.append(byte)
            index = next
        }
        return result
    }
}
