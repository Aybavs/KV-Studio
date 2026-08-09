import Testing
import Foundation
@testable import KV_Studio

struct RESPDecoderTests {

    // MARK: - Helpers

    /// Wire bytes from an ASCII literal. Only used for frames that are pure ASCII.
    private func wire(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// Builds a bulk string frame around arbitrary bytes, counting bytes (not characters).
    private func bulkFrame(_ payload: [UInt8]) -> Data {
        var bytes = Array("$\(payload.count)\r\n".utf8)
        bytes += payload
        bytes += Array("\r\n".utf8)
        return Data(bytes)
    }

    /// Feeds `frame` to a fresh decoder one byte at a time, asserting that every byte
    /// except the last yields `nil` (incomplete), and returning whatever the final byte yields.
    private func decodeByteAtATime(
        _ frame: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> RESPValue? {
        var decoder = RESPDecoder()
        var final: RESPValue?
        let bytes = Array(frame)

        for (offset, byte) in bytes.enumerated() {
            decoder.append(Data([byte]))
            let value = try decoder.nextValue()

            if offset < bytes.count - 1 {
                #expect(
                    value == nil,
                    "decoder produced a value after only \(offset + 1) of \(bytes.count) bytes",
                    sourceLocation: sourceLocation
                )
            } else {
                final = value
                // Nothing follows the frame, so the decoder must now be empty again.
                #expect(
                    try decoder.nextValue() == nil,
                    "decoder produced a second value from a single frame",
                    sourceLocation: sourceLocation
                )
            }
        }

        return final
    }

    /// Decodes a single complete frame delivered in one chunk.
    private func decodeWhole(_ frame: Data) throws -> RESPValue? {
        var decoder = RESPDecoder()
        decoder.append(frame)
        return try decoder.nextValue()
    }

    // MARK: - Simple string

    @Test func decodesSimpleString() throws {
        #expect(try decodeWhole(wire("+OK\r\n")) == .simpleString(Data("OK".utf8)))
    }

    @Test func decodesEmptySimpleString() throws {
        #expect(try decodeWhole(wire("+\r\n")) == .simpleString(Data()))
    }

    // MARK: - Error

    @Test func decodesError() throws {
        let frame = wire("-ERR unknown command 'nope'\r\n")
        #expect(try decodeWhole(frame) == .error(Data("ERR unknown command 'nope'".utf8)))
    }

    // MARK: - Integer

    @Test func decodesPositiveInteger() throws {
        #expect(try decodeWhole(wire(":1000\r\n")) == .integer(1000))
    }

    @Test func decodesZeroInteger() throws {
        #expect(try decodeWhole(wire(":0\r\n")) == .integer(0))
    }

    @Test func decodesNegativeInteger() throws {
        #expect(try decodeWhole(wire(":-42\r\n")) == .integer(-42))
    }

    @Test func decodesInt64Bounds() throws {
        #expect(try decodeWhole(wire(":9223372036854775807\r\n")) == .integer(Int64.max))
        #expect(try decodeWhole(wire(":-9223372036854775808\r\n")) == .integer(Int64.min))
    }

    // MARK: - Bulk string

    @Test func decodesBulkString() throws {
        #expect(try decodeWhole(wire("$5\r\nhello\r\n")) == .bulkString(Data("hello".utf8)))
    }

    @Test func decodesEmptyBulkStringAsEmptyDataNotNil() throws {
        let value = try decodeWhole(wire("$0\r\n\r\n"))
        #expect(value == .bulkString(Data()))
        #expect(value != .bulkString(nil))
    }

    @Test func decodesNullBulkStringAsNilNotEmptyData() throws {
        let value = try decodeWhole(wire("$-1\r\n"))
        #expect(value == .bulkString(nil))
        #expect(value != .bulkString(Data()))
    }

    @Test func decodesBinaryBulkStringContainingNulAndCRLFByteForByte() throws {
        let payload: [UInt8] = [0x00, 0x0D, 0x0A, 0xFF, 0x41, 0x00, 0x0D, 0x0A, 0xFE]
        let value = try decodeWhole(bulkFrame(payload))
        #expect(value == .bulkString(Data(payload)))
    }

    @Test func decodesBulkStringWhoseLengthIsHonouredOverEmbeddedCRLF() throws {
        // The payload's own CRLF must not be mistaken for the frame terminator:
        // "a\r\nb" is 4 bytes, and the reply that follows must still decode.
        var buffer = bulkFrame(Array("a\r\nb".utf8))
        buffer.append(wire("+OK\r\n"))

        var decoder = RESPDecoder()
        decoder.append(buffer)
        #expect(try decoder.nextValue() == .bulkString(Data("a\r\nb".utf8)))
        #expect(try decoder.nextValue() == .simpleString(Data("OK".utf8)))
        #expect(try decoder.nextValue() == nil)
    }

    @Test func decodesBulkStringWithInvalidUTF8() throws {
        let payload: [UInt8] = [0xC3, 0x28, 0xA0, 0xA1, 0xFF, 0xFE]
        #expect(try decodeWhole(bulkFrame(payload)) == .bulkString(Data(payload)))
    }

    // MARK: - Array

    @Test func decodesEmptyArrayAsEmptyNotNil() throws {
        let value = try decodeWhole(wire("*0\r\n"))
        #expect(value == .array([]))
        #expect(value != .array(nil))
    }

    @Test func decodesNullArrayAsNilNotEmpty() throws {
        let value = try decodeWhole(wire("*-1\r\n"))
        #expect(value == .array(nil))
        #expect(value != .array([]))
    }

    @Test func decodesFlatArrayOfBulkStrings() throws {
        let frame = wire("*3\r\n$3\r\nfoo\r\n$0\r\n\r\n$-1\r\n")
        let expected = RESPValue.array([
            .bulkString(Data("foo".utf8)),
            .bulkString(Data()),
            .bulkString(nil),
        ])
        #expect(try decodeWhole(frame) == expected)
    }

    @Test func decodesArrayOfMixedTypes() throws {
        let frame = wire("*3\r\n:1\r\n+OK\r\n-ERR bad\r\n")
        let expected = RESPValue.array([
            .integer(1),
            .simpleString(Data("OK".utf8)),
            .error(Data("ERR bad".utf8)),
        ])
        #expect(try decodeWhole(frame) == expected)
    }

    @Test func decodesNestedScanReply() throws {
        let frame = wire("*2\r\n$2\r\n17\r\n*3\r\n$4\r\nkey1\r\n$4\r\nkey2\r\n$4\r\nkey3\r\n")
        let expected = RESPValue.array([
            .bulkString(Data("17".utf8)),
            .array([
                .bulkString(Data("key1".utf8)),
                .bulkString(Data("key2".utf8)),
                .bulkString(Data("key3".utf8)),
            ]),
        ])
        #expect(try decodeWhole(frame) == expected)
    }

    @Test func decodesScanReplyWithEmptyKeyList() throws {
        let frame = wire("*2\r\n$1\r\n0\r\n*0\r\n")
        let expected = RESPValue.array([.bulkString(Data("0".utf8)), .array([])])
        #expect(try decodeWhole(frame) == expected)
    }

    // MARK: - Byte-at-a-time fragmentation

    @Test func decodesSimpleStringOneByteAtATime() throws {
        #expect(try decodeByteAtATime(wire("+PONG\r\n")) == .simpleString(Data("PONG".utf8)))
    }

    @Test func decodesIntegerOneByteAtATime() throws {
        #expect(try decodeByteAtATime(wire(":-1234\r\n")) == .integer(-1234))
    }

    @Test func decodesNullBulkStringOneByteAtATime() throws {
        #expect(try decodeByteAtATime(wire("$-1\r\n")) == .bulkString(nil))
    }

    @Test func decodesEmptyBulkStringOneByteAtATime() throws {
        #expect(try decodeByteAtATime(wire("$0\r\n\r\n")) == .bulkString(Data()))
    }

    @Test func decodesBinaryBulkStringOneByteAtATime() throws {
        // Contains NUL, a bare CR, a bare LF, a full CRLF, and invalid UTF-8.
        let payload: [UInt8] = [0x00, 0x0D, 0x0A, 0x00, 0xFF, 0x0D, 0x41, 0x0A, 0xC3, 0x28]
        #expect(try decodeByteAtATime(bulkFrame(payload)) == .bulkString(Data(payload)))
    }

    @Test func decodesNestedScanReplyOneByteAtATime() throws {
        let frame = wire("*2\r\n$3\r\n256\r\n*2\r\n$5\r\nalpha\r\n$0\r\n\r\n")
        let expected = RESPValue.array([
            .bulkString(Data("256".utf8)),
            .array([
                .bulkString(Data("alpha".utf8)),
                .bulkString(Data()),
            ]),
        ])
        #expect(try decodeByteAtATime(frame) == expected)
    }

    @Test func decodesEveryFrameShapeOneByteAtATime() throws {
        let cases: [(Data, RESPValue)] = [
            (wire("+OK\r\n"), .simpleString(Data("OK".utf8))),
            (wire("-ERR nope\r\n"), .error(Data("ERR nope".utf8))),
            (wire(":0\r\n"), .integer(0)),
            (wire("*0\r\n"), .array([])),
            (wire("*-1\r\n"), .array(nil)),
            (wire("*1\r\n*1\r\n*1\r\n$1\r\nx\r\n"), .array([.array([.array([.bulkString(Data("x".utf8))])])])),
        ]

        for (frame, expected) in cases {
            #expect(try decodeByteAtATime(frame) == expected)
        }
    }

    // MARK: - Arbitrary split points

    @Test func decodesCorrectlyAtEverySplitPoint() throws {
        let frame = wire("*2\r\n$3\r\n256\r\n*2\r\n$5\r\nalpha\r\n$-1\r\n")
        let expected = RESPValue.array([
            .bulkString(Data("256".utf8)),
            .array([.bulkString(Data("alpha".utf8)), .bulkString(nil)]),
        ])

        for split in 0...frame.count {
            var decoder = RESPDecoder()
            decoder.append(frame.prefix(split))
            let early = try decoder.nextValue()
            if split < frame.count {
                #expect(early == nil, "value produced from only \(split) of \(frame.count) bytes")
            }
            decoder.append(frame.suffix(from: split))
            let value = split < frame.count ? try decoder.nextValue() : early
            #expect(value == expected, "wrong value for split at \(split)")
        }
    }

    // MARK: - Truncated frames must not corrupt state

    @Test func truncatedBulkStringWaitsForMoreBytes() throws {
        var decoder = RESPDecoder()
        decoder.append(wire("$5\r\nhel"))

        // Repeated polling of an incomplete frame must be side-effect free.
        #expect(try decoder.nextValue() == nil)
        #expect(try decoder.nextValue() == nil)
        #expect(try decoder.nextValue() == nil)

        decoder.append(wire("lo\r\n"))
        #expect(try decoder.nextValue() == .bulkString(Data("hello".utf8)))
        #expect(try decoder.nextValue() == nil)
    }

    @Test func truncatedHeaderWaitsForMoreBytes() throws {
        var decoder = RESPDecoder()
        decoder.append(wire("$1"))
        #expect(try decoder.nextValue() == nil)
        decoder.append(wire("2\r\nhello, world\r\n"))
        #expect(try decoder.nextValue() == .bulkString(Data("hello, world".utf8)))
    }

    @Test func truncatedCRLFWaitsForMoreBytes() throws {
        // A lone CR is not yet known to be a bad terminator - it needs one more byte.
        var decoder = RESPDecoder()
        decoder.append(wire("+OK\r"))
        #expect(try decoder.nextValue() == nil)
        decoder.append(wire("\n"))
        #expect(try decoder.nextValue() == .simpleString(Data("OK".utf8)))
    }

    @Test func truncatedNestedArrayWaitsForMoreBytes() throws {
        var decoder = RESPDecoder()
        decoder.append(wire("*2\r\n$1\r\n0\r\n*2\r\n$4\r\nkey1\r\n"))
        #expect(try decoder.nextValue() == nil)
        #expect(try decoder.nextValue() == nil)

        decoder.append(wire("$4\r\nkey2\r\n"))
        let expected = RESPValue.array([
            .bulkString(Data("0".utf8)),
            .array([.bulkString(Data("key1".utf8)), .bulkString(Data("key2".utf8))]),
        ])
        #expect(try decoder.nextValue() == expected)
        #expect(try decoder.nextValue() == nil)
    }

    @Test func completeReplyFollowedByPartialReplyDecodesFirstAndWaits() throws {
        var decoder = RESPDecoder()
        decoder.append(wire("+OK\r\n$3\r\nfo"))
        #expect(try decoder.nextValue() == .simpleString(Data("OK".utf8)))
        #expect(try decoder.nextValue() == nil)

        decoder.append(wire("o\r\n"))
        #expect(try decoder.nextValue() == .bulkString(Data("foo".utf8)))
        #expect(try decoder.nextValue() == nil)
    }

    // MARK: - Multiple replies in one chunk

    @Test func drainsMultipleRepliesFromOneChunkInOrder() throws {
        var decoder = RESPDecoder()
        decoder.append(wire("+OK\r\n:42\r\n$-1\r\n$0\r\n\r\n*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n*-1\r\n-ERR x\r\n"))

        #expect(try decoder.nextValue() == .simpleString(Data("OK".utf8)))
        #expect(try decoder.nextValue() == .integer(42))
        #expect(try decoder.nextValue() == .bulkString(nil))
        #expect(try decoder.nextValue() == .bulkString(Data()))
        #expect(try decoder.nextValue() == .array([
            .bulkString(Data("foo".utf8)),
            .bulkString(Data("bar".utf8)),
        ]))
        #expect(try decoder.nextValue() == .array(nil))
        #expect(try decoder.nextValue() == .error(Data("ERR x".utf8)))
        #expect(try decoder.nextValue() == nil)
    }

    @Test func drainsRepliesWhoseBulkPayloadsLookLikeFrames() throws {
        // Payloads that themselves spell valid RESP must be consumed by length only.
        var buffer = bulkFrame(Array("+OK\r\n:1\r\n".utf8))
        buffer.append(wire(":7\r\n"))

        var decoder = RESPDecoder()
        decoder.append(buffer)
        #expect(try decoder.nextValue() == .bulkString(Data("+OK\r\n:1\r\n".utf8)))
        #expect(try decoder.nextValue() == .integer(7))
        #expect(try decoder.nextValue() == nil)
    }

    // MARK: - Malformed input

    @Test func throwsOnUnknownTypeByte() {
        var decoder = RESPDecoder()
        decoder.append(wire("%2\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnUnknownTypeByteInsideArray() {
        var decoder = RESPDecoder()
        decoder.append(wire("*1\r\n#t\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnNonNumericBulkLength() {
        var decoder = RESPDecoder()
        decoder.append(wire("$abc\r\nhello\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnEmptyBulkLength() {
        var decoder = RESPDecoder()
        decoder.append(wire("$\r\n\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnNegativeBulkLengthOtherThanMinusOne() {
        var decoder = RESPDecoder()
        decoder.append(wire("$-2\r\nab\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnNonNumericArrayLength() {
        var decoder = RESPDecoder()
        decoder.append(wire("*x\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnNegativeArrayLengthOtherThanMinusOne() {
        var decoder = RESPDecoder()
        decoder.append(wire("*-3\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnNonNumericInteger() {
        var decoder = RESPDecoder()
        decoder.append(wire(":12x\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnIntegerOutOfInt64Range() {
        var decoder = RESPDecoder()
        decoder.append(wire(":9223372036854775808\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsWhenBulkBodyIsNotFollowedByCRLF() {
        var decoder = RESPDecoder()
        decoder.append(wire("$5\r\nhelloXX"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsWhenBulkBodyIsFollowedByLoneLF() {
        var decoder = RESPDecoder()
        decoder.append(wire("$5\r\nhello\n\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnBareCarriageReturnInsideLine() {
        var decoder = RESPDecoder()
        decoder.append(wire("+O\rK\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func throwsOnBareLineFeedTerminator() {
        var decoder = RESPDecoder()
        decoder.append(wire("+OK\nmore"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    @Test func doesNotThrowOnGarbageThatIsStillIncomplete() throws {
        // "$abc" without a terminator is not yet provably malformed: more bytes are needed
        // to even find the end of the line. Only a complete bad line is an error.
        var decoder = RESPDecoder()
        decoder.append(wire("$abc"))
        #expect(try decoder.nextValue() == nil)

        decoder.append(wire("\r\n"))
        #expect(throws: RESPError.self) { try decoder.nextValue() }
    }

    // MARK: - Scale

    @Test func decodesLargeArrayDeliveredInChunks() throws {
        let count = 10_000
        var bytes = Array("*\(count)\r\n".utf8)
        for index in 0..<count {
            let element = Array("key:\(index)".utf8)
            bytes += Array("$\(element.count)\r\n".utf8)
            bytes += element
            bytes += Array("\r\n".utf8)
        }
        let frame = Data(bytes)

        var decoder = RESPDecoder()
        var offset = 0
        let chunkSize = 997
        var value: RESPValue?
        while offset < frame.count {
            let end = min(offset + chunkSize, frame.count)
            decoder.append(frame[frame.startIndex + offset..<frame.startIndex + end])
            value = try decoder.nextValue()
            if end < frame.count {
                #expect(value == nil)
            }
            offset = end
        }

        guard case .array(let elements)? = value else {
            Issue.record("expected an array, got \(String(describing: value))")
            return
        }
        #expect(elements?.count == count)
        #expect(elements?.first == .bulkString(Data("key:0".utf8)))
        #expect(elements?.last == .bulkString(Data("key:\(count - 1)".utf8)))
    }

    @Test func drainsManySmallRepliesWithoutLosingOrder() throws {
        var decoder = RESPDecoder()
        let total = 5_000
        var bytes: [UInt8] = []
        for index in 0..<total {
            bytes += Array(":\(index)\r\n".utf8)
        }
        decoder.append(Data(bytes))

        for index in 0..<total {
            #expect(try decoder.nextValue() == .integer(Int64(index)))
        }
        #expect(try decoder.nextValue() == nil)
    }
}
