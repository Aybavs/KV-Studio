import Foundation

/// Incremental RESP2 reply decoder. `nextValue()` returns `nil` when more bytes are needed;
/// that case leaves state untouched and is not an error.
struct RESPDecoder {

    private static let maximumDepth = 64
    private static let maximumBulkLength = 512 * 1024 * 1024
    private static let compactionThreshold = 64 * 1024

    private static let carriageReturn = UInt8(ascii: "\r")
    private static let lineFeed = UInt8(ascii: "\n")
    private static let zero = UInt8(ascii: "0")
    private static let nine = UInt8(ascii: "9")
    private static let minus = UInt8(ascii: "-")
    private static let plus = UInt8(ascii: "+")

    // [UInt8] rather than Data so indices stay zero-based; Data slices inherit parent indices.
    private var buffer: [UInt8] = []
    private var consumed = 0

    init() {}

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(contentsOf: data)
    }

    mutating func nextValue() throws -> RESPValue? {
        var cursor = consumed
        guard let value = try parseValue(at: &cursor, depth: 0) else { return nil }

        consumed = cursor
        compactIfNeeded()
        return value
    }

    // Non-mutating, and commits `cursor` only on success, so an incomplete reply cannot
    // advance or corrupt state at any nesting depth.
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

    // Payload is taken by declared byte count and the terminator checked at a computed
    // offset; scanning for CRLF would corrupt any value that contains one.
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
        // Cap the reservation so a hostile count is not a hostile allocation.
        elements.reserveCapacity(Swift.min(count, 1024))

        for _ in 0..<count {
            guard let element = try parseValue(at: &cursor, depth: depth + 1) else { return nil }
            elements.append(element)
        }

        index = cursor
        return .array(elements)
    }

    private func readLine(at index: inout Int) throws -> ArraySlice<UInt8>? {
        var scan = index

        while scan < buffer.count {
            switch buffer[scan] {
            case Self.carriageReturn:
                guard scan + 1 < buffer.count else { return nil }
                guard buffer[scan + 1] == Self.lineFeed else { throw RESPError.invalidTerminator }
                let line = buffer[index..<scan]
                index = scan + 2
                return line

            case Self.lineFeed:
                throw RESPError.invalidTerminator

            default:
                scan += 1
            }
        }

        return nil
    }

    // Accumulates negatively so Int64.min, whose magnitude does not fit, still parses.
    // A leading `+` is accepted leniently.
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

    // Compact only when fully drained, or when the dead prefix is large and at least half
    // the buffer, so draining many small replies stays amortised.
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
