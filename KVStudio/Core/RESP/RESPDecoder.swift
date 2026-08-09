import Foundation

/// Incremental RESP2 reply decoder.
///
/// TCP delivers bytes, not messages: a single `read` may carry half a reply, seven
/// replies, or one byte. The decoder therefore owns a buffer that callers feed with
/// `append(_:)` and drain with `nextValue()`.
///
/// The contract:
/// - `nextValue()` returns a value and consumes exactly that reply's bytes, leaving
///   anything that followed it buffered for the next call.
/// - `nextValue()` returns `nil` when the buffered bytes do not yet hold a *complete*
///   reply. This leaves the decoder's state untouched, so appending more bytes and
///   calling again produces the correct value. `nil` is not an error.
/// - `nextValue()` throws `RESPError` only for bytes that can never become a valid
///   reply. That is fatal for the connection — the stream can no longer be resynchronised.
///
/// Payloads stay `Data` end to end and are consumed by declared byte count, never by
/// scanning for a terminator, so bulk strings containing NUL bytes, embedded CRLF, or
/// invalid UTF-8 round-trip byte for byte.
struct RESPDecoder {

    // MARK: - Limits

    /// Deepest array nesting the decoder will recurse through. RESP2 replies from the
    /// server nest two levels at most (SCAN); this only exists so a hostile or corrupt
    /// stream of `*1\r\n` cannot drive unbounded recursion.
    private static let maximumDepth = 64

    /// Largest bulk payload the decoder will accept, matching the 512 MB protocol limit.
    private static let maximumBulkLength = 512 * 1024 * 1024

    /// Buffered bytes ahead of `consumed` must exceed this before a compaction is
    /// considered, so draining many small replies does not memmove on every one.
    private static let compactionThreshold = 64 * 1024

    // MARK: - Bytes

    private static let carriageReturn = UInt8(ascii: "\r")
    private static let lineFeed = UInt8(ascii: "\n")
    private static let zero = UInt8(ascii: "0")
    private static let nine = UInt8(ascii: "9")
    private static let minus = UInt8(ascii: "-")
    private static let plus = UInt8(ascii: "+")

    // MARK: - State

    /// Unparsed bytes. `[UInt8]` rather than `Data` so indices are always zero-based —
    /// `Data` slices keep the parent's indices, which is an easy source of off-by-one bugs.
    private var buffer: [UInt8] = []

    /// How many leading bytes of `buffer` have been handed out as complete replies.
    /// Consumed bytes are dropped lazily (see `compactIfNeeded`) rather than on every
    /// reply, so draining a chunk full of replies stays linear instead of quadratic.
    private var consumed = 0

    init() {}

    // MARK: - Input

    /// Adds freshly read bytes to the end of the buffer.
    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(contentsOf: data)
    }

    // MARK: - Output

    /// Decodes the next complete reply, or returns `nil` if more bytes are needed.
    ///
    /// Parsing runs against a local cursor and only commits it on success, which is what
    /// makes the `nil` case free of side effects: an incomplete reply leaves `buffer` and
    /// `consumed` exactly as they were, no matter how deeply nested the partial frame was.
    mutating func nextValue() throws -> RESPValue? {
        var cursor = consumed
        guard let value = try parseValue(at: &cursor, depth: 0) else { return nil }

        consumed = cursor
        compactIfNeeded()
        return value
    }

    // MARK: - Parsing

    /// Parses one value starting at `cursor`, advancing it past the value on success.
    /// Returns `nil` (leaving `cursor` untouched) when more bytes are needed.
    private func parseValue(at cursor: inout Int, depth: Int) throws -> RESPValue? {
        guard depth <= Self.maximumDepth else { throw RESPError.nestingTooDeep }
        guard cursor < buffer.count else { return nil }

        let typeByte = buffer[cursor]
        var index = cursor + 1

        switch typeByte {
        case UInt8(ascii: "+"):
            guard let line = try readLine(at: &index) else { return nil }
            cursor = index
            return .simpleString(Data(line))

        case UInt8(ascii: "-"):
            guard let line = try readLine(at: &index) else { return nil }
            cursor = index
            return .error(Data(line))

        case UInt8(ascii: ":"):
            guard let line = try readLine(at: &index) else { return nil }
            let number = try parseInteger(line)
            cursor = index
            return .integer(number)

        case UInt8(ascii: "$"):
            guard let value = try parseBulkString(at: &index) else { return nil }
            cursor = index
            return value

        case UInt8(ascii: "*"):
            guard let value = try parseArray(at: &index, depth: depth) else { return nil }
            cursor = index
            return value

        default:
            throw RESPError.unknownTypeByte(typeByte)
        }
    }

    /// `$<length>\r\n<length bytes>\r\n`, or `$-1\r\n` for the null bulk string.
    ///
    /// The payload is taken by declared byte count. It is never scanned for CRLF — doing
    /// so is exactly how a value containing `\r\n` corrupts the rest of the stream.
    private func parseBulkString(at index: inout Int) throws -> RESPValue? {
        var cursor = index
        guard let line = try readLine(at: &cursor) else { return nil }

        let declared = try parseInteger(line)
        if declared == -1 {
            index = cursor
            return .bulkString(nil)
        }
        guard declared >= 0, declared <= Int64(Self.maximumBulkLength) else {
            throw RESPError.invalidLength
        }

        let length = Int(declared)
        // The payload plus its CRLF terminator must both have arrived.
        guard buffer.count - cursor >= length + 2 else { return nil }

        let terminator = cursor + length
        guard buffer[terminator] == Self.carriageReturn,
              buffer[terminator + 1] == Self.lineFeed else {
            throw RESPError.invalidTerminator
        }

        let payload = Data(buffer[cursor..<terminator])
        index = terminator + 2
        return .bulkString(payload)
    }

    /// `*<count>\r\n` followed by `count` values of any type, or `*-1\r\n` for the null array.
    private func parseArray(at index: inout Int, depth: Int) throws -> RESPValue? {
        var cursor = index
        guard let line = try readLine(at: &cursor) else { return nil }

        let declared = try parseInteger(line)
        if declared == -1 {
            index = cursor
            return .array(nil)
        }
        guard declared >= 0, declared <= Int64(Int.max) else { throw RESPError.invalidLength }

        let count = Int(declared)
        var elements: [RESPValue] = []
        // A hostile count must not become a hostile allocation, so only reserve what a
        // plausible reply needs up front; the array grows naturally beyond that.
        elements.reserveCapacity(Swift.min(count, 1024))

        for _ in 0..<count {
            guard let element = try parseValue(at: &cursor, depth: depth + 1) else { return nil }
            elements.append(element)
        }

        index = cursor
        return .array(elements)
    }

    /// Reads a CRLF-terminated line, advancing `index` past the terminator on success.
    ///
    /// Returns `nil` if the terminator has not arrived yet — including the case where the
    /// buffer ends on a lone CR, which is not yet provably malformed.
    private func readLine(at index: inout Int) throws -> ArraySlice<UInt8>? {
        var scan = index

        while scan < buffer.count {
            switch buffer[scan] {
            case Self.carriageReturn:
                guard scan + 1 < buffer.count else { return nil } // need the byte after CR
                guard buffer[scan + 1] == Self.lineFeed else { throw RESPError.invalidTerminator }
                let line = buffer[index..<scan]
                index = scan + 2
                return line

            case Self.lineFeed:
                // A LF that was not preceded by CR can never become a valid terminator.
                throw RESPError.invalidTerminator

            default:
                scan += 1
            }
        }

        return nil
    }

    /// Parses a base-10 signed integer from raw bytes.
    ///
    /// Digits accumulate negatively so that `Int64.min` — whose magnitude does not fit in
    /// `Int64` — parses without overflowing.
    private func parseInteger(_ line: ArraySlice<UInt8>) throws -> Int64 {
        var index = line.startIndex
        guard index < line.endIndex else { throw RESPError.invalidInteger }

        var isNegative = false
        if line[index] == Self.minus || line[index] == Self.plus {
            isNegative = line[index] == Self.minus
            index = line.index(after: index)
        }
        guard index < line.endIndex else { throw RESPError.invalidInteger }

        var accumulator: Int64 = 0
        while index < line.endIndex {
            let byte = line[index]
            guard byte >= Self.zero, byte <= Self.nine else { throw RESPError.invalidInteger }

            let (scaled, scaleOverflowed) = accumulator.multipliedReportingOverflow(by: 10)
            guard !scaleOverflowed else { throw RESPError.invalidInteger }

            let (next, addOverflowed) = scaled.subtractingReportingOverflow(Int64(byte - Self.zero))
            guard !addOverflowed else { throw RESPError.invalidInteger }

            accumulator = next
            index = line.index(after: index)
        }

        if isNegative { return accumulator }

        let (positive, overflowed) = Int64(0).subtractingReportingOverflow(accumulator)
        guard !overflowed else { throw RESPError.invalidInteger }
        return positive
    }

    // MARK: - Buffer maintenance

    /// Drops already-consumed bytes, but only when it is worth the copy.
    ///
    /// Compaction happens when the buffer has been fully drained (free) or when the dead
    /// prefix is both large and at least half the buffer. That bounds the wasted memory to
    /// roughly the live bytes while keeping the amortised cost of copying constant per byte.
    private mutating func compactIfNeeded() {
        if consumed == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            consumed = 0
        } else if consumed >= Self.compactionThreshold, consumed >= buffer.count - consumed {
            buffer.removeFirst(consumed)
            consumed = 0
        }
    }
}
