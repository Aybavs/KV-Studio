import AppKit
import Foundation

// Copying a key or value must not lose bytes that are not text, so binary payloads go to the
// pasteboard as hex rather than as a lossy string.
enum Pasteboard {
    static func copyableText(for data: Data) -> String {
        ValuePresentation.textString(from: data) ?? ValuePresentation.hexString(from: data)
    }

    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    static func copy(_ data: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        copy(copyableText(for: data), to: pasteboard)
    }
}

enum AccessibilityLabels {
    static func key(_ data: Data) -> String {
        guard let text = ValuePresentation.textString(from: data) else {
            return "Binary key, \(data.count) bytes"
        }
        return "Key \(text)"
    }

    static func value(_ data: Data, format: ValueFormat) -> String {
        let size = data.count == 1 ? "1 byte" : "\(data.count) bytes"
        guard case .hex = format else {
            return ValuePresentation.textString(from: data).map { "Value \($0)" } ?? "Binary value, \(size)"
        }
        return "Binary value shown as hexadecimal, \(size)"
    }

    static func ttl(_ state: TTLState) -> String {
        switch state {
        case .missing: return "No such key"
        case .persistent: return "No expiry"
        case .expiring(let seconds): return "Expires in \(seconds) seconds"
        }
    }
}
