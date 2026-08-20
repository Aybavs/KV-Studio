import SwiftUI

enum ConsoleRESPFormatting {
    static func string(for data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ValuePresentation.hexString(from: data)
    }

    static func isServerError(_ value: RESPValue) -> Bool {
        if case .error = value { return true }
        return false
    }
}

struct RESPValueView: View {
    let value: RESPValue

    var body: some View {
        Group {
            switch value {
            case .simpleString(let data):
                Text(ConsoleRESPFormatting.string(for: data))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("console.response.simpleString")
            case .error(let data):
                Text("(error) \(ConsoleRESPFormatting.string(for: data))")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("console.response.error")
            case .integer(let n):
                Text("(integer) \(n)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("console.response.integer")
            case .bulkString(nil):
                Text("(nil)")
                    .foregroundStyle(.secondary)
                    .italic()
                    .accessibilityIdentifier("console.response.nil")
            case .bulkString(let data?):
                if data.isEmpty {
                    Text("(empty string)")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("console.response.bulkEmpty")
                } else {
                    Text(ConsoleRESPFormatting.string(for: data))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("console.response.bulkString")
                }
            case .array(nil):
                Text("(nil)")
                    .foregroundStyle(.secondary)
                    .italic()
                    .accessibilityIdentifier("console.response.array.nil")
            case .array(let elements?):
                if elements.isEmpty {
                    Text("(empty array)")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("console.response.array.empty")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(elements.enumerated()), id: \.offset) { index, element in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(index + 1))")
                                    .foregroundStyle(.secondary)
                                    .font(.caption.monospaced())
                                    .frame(minWidth: 24, alignment: .trailing)
                                Group {
                                    if case .array(let nested?) = element, !nested.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(Array(nested.enumerated()), id: \.offset) { j, inner in
                                                HStack(alignment: .top, spacing: 6) {
                                                    Text("\(j + 1))")
                                                        .foregroundStyle(.secondary)
                                                        .font(.caption2.monospaced())
                                                    RESPValueView(value: inner)
                                                }
                                            }
                                        }
                                    } else {
                                        RESPValueView(value: element)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("console.response.array")
                }
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}

struct ConsoleResponseContentView: View {
    let response: ConsoleResponse

    var body: some View {
        Group {
            switch response {
            case .resp(let value):
                RESPValueView(value: value)
            case .localError(let msg):
                Text(msg)
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("console.response.localError")
            case .transportError(let msg):
                Text(msg)
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("console.response.transportError")
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}
