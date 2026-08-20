import Testing
import Foundation
@testable import KV_Studio

@Suite struct ValuePresentationUTF8Tests {
    @Test func validUTF8Empty() {
        #expect(ValuePresentation.isValidUTF8(Data()) == true)
        #expect(ValuePresentation.textString(from: Data()) == "")
    }

    @Test func validUTF8ASCII() {
        let d = Data("hello".utf8)
        #expect(ValuePresentation.isValidUTF8(d) == true)
        #expect(ValuePresentation.textString(from: d) == "hello")
    }

    @Test func validUTF8Multibyte() {
        let s = "merhaba dünya 🌍"
        let d = Data(s.utf8)
        #expect(ValuePresentation.isValidUTF8(d) == true)
        #expect(ValuePresentation.textString(from: d) == s)
        #expect(ValuePresentation.textString(from: d)?.data(using: .utf8) == d)
    }

    @Test func invalidUTF8SingleFF() {
        let d = Data([0xFF])
        #expect(ValuePresentation.isValidUTF8(d) == false)
        #expect(ValuePresentation.textString(from: d) == nil)
    }

    @Test func invalidUTF8TruncatedSequence() {
        // 0xC3 0x28 is invalid 2-byte start followed by non-continuation
        let d = Data([0xC3, 0x28])
        #expect(ValuePresentation.isValidUTF8(d) == false)
        #expect(ValuePresentation.textString(from: d) == nil)
    }

    @Test func noReplacementCharacterForInvalid() {
        let d = Data([0xFF, 0xFE, 0x00, 0x01])
        let str = ValuePresentation.textString(from: d)
        #expect(str == nil)
        // Ensure we never produce string containing replacement char
        if let s = str {
            #expect(!s.contains("\u{FFFD}"))
        }
        // Also isValidUTF8 must be false
        #expect(ValuePresentation.isValidUTF8(d) == false)
    }

    @Test func binarySafeRoundTrip() {
        let d = Data([0x00, 0xFF, 0xFE, 0x0A, 0x0D])
        #expect(ValuePresentation.isValidUTF8(d) == false)
        // hexString must not be lossy
        let hex = ValuePresentation.hexString(from: d)
        #expect(hex == "00 ff fe 0a 0d")
    }
}

@Suite struct ValuePresentationJSONTests {
    @Test func validJSONObject() {
        let d = Data("{\"a\":1,\"b\":[2,3]}".utf8)
        #expect(ValuePresentation.isValidJSON(d) == true)
        let pretty = ValuePresentation.prettyJSONString(from: d)
        #expect(pretty != nil)
        #expect(pretty!.contains("\"a\""))
        #expect(pretty!.contains("\n"))
    }

    @Test func validJSONArray() {
        let d = Data("[1,2,3]".utf8)
        #expect(ValuePresentation.isValidJSON(d) == true)
        #expect(ValuePresentation.prettyJSONString(from: d) != nil)
    }

    @Test func validJSONFragments() {
        #expect(ValuePresentation.isValidJSON(Data("\"hello\"".utf8)) == true)
        #expect(ValuePresentation.isValidJSON(Data("42".utf8)) == true)
        #expect(ValuePresentation.isValidJSON(Data("true".utf8)) == true)
        #expect(ValuePresentation.isValidJSON(Data("null".utf8)) == true)
        let prettyString = ValuePresentation.prettyJSONString(from: Data("\"hello\"".utf8))
        #expect(prettyString != nil)
        let prettyNumber = ValuePresentation.prettyJSONString(from: Data("42".utf8))
        #expect(prettyNumber != nil)
    }

    @Test func invalidJSONPlainText() {
        let d = Data("hello".utf8)
        #expect(ValuePresentation.isValidJSON(d) == false)
        #expect(ValuePresentation.prettyJSONString(from: d) == nil)
    }

    @Test func invalidJSONMalformed() {
        let d = Data("{\"a\":}".utf8)
        #expect(ValuePresentation.isValidJSON(d) == false)
        #expect(ValuePresentation.prettyJSONString(from: d) == nil)
    }

    @Test func invalidJSONNotUTF8() {
        let d = Data([0xFF, 0x7B, 0x22]) // invalid prefix before json
        #expect(ValuePresentation.isValidJSON(d) == false)
        #expect(ValuePresentation.prettyJSONString(from: d) == nil)
    }

    @Test func validUTF8ButNotJSON() {
        let d = Data("not json".utf8)
        #expect(ValuePresentation.isValidUTF8(d) == true)
        #expect(ValuePresentation.isValidJSON(d) == false)
    }

    @Test func prettyDoesNotMutateBytesUntilSave() {
        // pretty is for display only; original data preserved
        let original = Data("{\"b\":2,\"a\":1}".utf8)
        let pretty = ValuePresentation.prettyJSONString(from: original)
        #expect(pretty != nil)
        // pretty contains sorted keys and newlines, but original unchanged
        #expect(original == Data("{\"b\":2,\"a\":1}".utf8))
        // pretty when parsed again equals original object
        if let p = pretty, let pd = p.data(using: .utf8) {
            let o1 = try? JSONSerialization.jsonObject(with: original, options: [.allowFragments])
            let o2 = try? JSONSerialization.jsonObject(with: pd, options: [.allowFragments])
            #expect((o1 as? NSObject) == (o2 as? NSObject))
        }
    }

    @Test func emptyDataNotJSON() {
        #expect(ValuePresentation.isValidJSON(Data()) == false)
        #expect(ValuePresentation.prettyJSONString(from: Data()) == nil)
    }
}

@Suite struct ValuePresentationHexTests {
    @Test func hexStringEmpty() {
        #expect(ValuePresentation.hexString(from: Data()) == "")
    }

    @Test func hexStringSimple() {
        let d = Data([0x00, 0xFF, 0x0A, 0x1B])
        #expect(ValuePresentation.hexString(from: d) == "00 ff 0a 1b")
    }

    @Test func hexDumpEmpty() {
        #expect(ValuePresentation.hexDump(from: Data()) == "")
    }

    @Test func hexDumpContainsOffsetsAndHexAndASCII() {
        let d = Data("Hello World\n".utf8) // 12 bytes
        let dump = ValuePresentation.hexDump(from: d)
        // offset
        #expect(dump.contains("00000000"))
        // hex bytes lower case
        #expect(dump.contains("48 65 6c 6c 6f"))
        // ascii gutter
        #expect(dump.contains("|Hello World|") || dump.contains("Hello"))
        // Should not contain replacement char
        #expect(!dump.contains("\u{FFFD}"))
    }

    @Test func hexDumpGroupedBytes() {
        let d = Data((0..<16).map { UInt8($0) })
        let dump = ValuePresentation.hexDump(from: d)
        // Must contain 16 bytes line with offset 00000000
        #expect(dump.contains("00000000"))
        #expect(dump.contains("00 01 02 03 04 05 06 07"))
        #expect(dump.contains("08 09 0a 0b 0c 0d 0e 0f"))
        // grouped extra space between 07 and 08 => we check two spaces exist
        // At least hex column length is consistent
        #expect(dump.contains("  |"))
    }

    @Test func hexDumpMultipleLinesOffsets() {
        let d = Data(repeating: 0x41, count: 32) // 32 'A's -> 2 lines
        let dump = ValuePresentation.hexDump(from: d)
        #expect(dump.contains("00000000"))
        #expect(dump.contains("00000010"))
        let lines = dump.split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test func hexDumpNonPrintableAsDot() {
        let d = Data([0x00, 0x1F, 0x20, 0x41, 0x7E, 0x7F, 0xFF])
        let dump = ValuePresentation.hexDump(from: d)
        #expect(dump.contains(".. A~..") || dump.contains("|.. A~..|") || dump.contains("."))
        // Ensure ASCII gutter uses dot for non-printables
        #expect(dump.contains("|"))
    }

    @Test func hexDumpNoLossyReplacement() {
        let d = Data([0xFF, 0xFE, 0xFD])
        let dump = ValuePresentation.hexDump(from: d)
        #expect(dump.contains("ff fe fd"))
        #expect(!dump.contains("\u{FFFD}"))
    }
}

@Suite struct ValuePresentationAutoTests {
    @Test func autoDetectsJSONWhenValidJSON() {
        let d = Data("{\"key\":\"value\"}".utf8)
        #expect(ValuePresentation.autoDetectedFormat(for: d) == .json)
        #expect(ValuePresentation.resolvedFormat(for: d, selected: .auto) == .json)
    }

    @Test func autoDetectsTextWhenValidUTF8NotJSON() {
        let d = Data("plain text hello".utf8)
        #expect(ValuePresentation.autoDetectedFormat(for: d) == .text)
        #expect(ValuePresentation.resolvedFormat(for: d, selected: .auto) == .text)
    }

    @Test func autoDetectsHexWhenInvalidUTF8() {
        let d = Data([0xFF, 0x00, 0x01])
        #expect(ValuePresentation.autoDetectedFormat(for: d) == .hex)
        #expect(ValuePresentation.resolvedFormat(for: d, selected: .auto) == .hex)
    }

    @Test func manualOverridesAuto() {
        let json = Data("{\"a\":1}".utf8)
        #expect(ValuePresentation.resolvedFormat(for: json, selected: .text) == .text)
        #expect(ValuePresentation.resolvedFormat(for: json, selected: .hex) == .hex)
        #expect(ValuePresentation.resolvedFormat(for: json, selected: .json) == .json)

        let binary = Data([0xFF, 0x00])
        #expect(ValuePresentation.resolvedFormat(for: binary, selected: .text) == .text)
        #expect(ValuePresentation.resolvedFormat(for: binary, selected: .json) == .json)
    }

    @Test func emptyDataAutoIsTextOrJSON() {
        // Empty is valid UTF8 but not JSON => should be text per spec: else if valid UTF-8 then Text else Hex
        // JSON check fails, UTF8 passes => Text
        let d = Data()
        #expect(ValuePresentation.autoDetectedFormat(for: d) == .text)
    }

    @Test func binaryJSONPrefixNotValid() {
        // Invalid UTF8 that looks like json prefix should be hex, not json
        var d = Data([0xFF])
        d.append(Data("{\"a\":1}".utf8))
        #expect(ValuePresentation.autoDetectedFormat(for: d) == .hex)
    }
}
