import Foundation
import Observation

struct ConsoleEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let command: String
    let response: ConsoleResponse

    init(id: UUID = UUID(), command: String, response: ConsoleResponse) {
        self.id = id
        self.command = command
        self.response = response
    }
}

enum ConsoleResponse: Equatable, Sendable {
    case resp(RESPValue)
    case localError(String)
    case transportError(String)
}

@MainActor
@Observable
final class ConsoleViewModel {
    var input: String = ""
    private(set) var entries: [ConsoleEntry] = []
    private(set) var history: [String] = []
    private var historyIndex: Int?
    private var draftInput: String = ""
    private(set) var isRunning: Bool = false

    var canClear: Bool { !entries.isEmpty }

    func clear() {
        entries.removeAll()
    }

    // Test helpers
    func _setHistory(_ h: [String]) { history = h }
    func _appendHistory(_ s: String) { history.append(s) }

    func historyUp() {
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            draftInput = input
            historyIndex = 0
            input = history[history.count - 1]
        } else if let idx = historyIndex, idx + 1 < history.count {
            historyIndex = idx + 1
            input = history[history.count - 1 - historyIndex!]
        }
    }

    func historyDown() {
        guard let idx = historyIndex else { return }
        if idx == 0 {
            historyIndex = nil
            input = draftInput
        } else {
            historyIndex = idx - 1
            input = history[history.count - 1 - historyIndex!]
        }
    }

    func submit(using coordinator: ConnectionCoordinator) async {
        await submit(using: coordinator.console)
    }

    func submit(using client: KVClient?) async {
        let rawInput = input
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.append(trimmed)
        historyIndex = nil
        draftInput = ""
        input = ""
        isRunning = true
        defer { isRunning = false }

        let args: [Data]
        do {
            args = try ConsoleTokenizer.tokenizeToData(rawInput)
        } catch {
            entries.append(ConsoleEntry(command: rawInput, response: .localError("Parse error: unterminated quote")))
            return
        }
        if args.isEmpty { return }
        guard let client else {
            entries.append(ConsoleEntry(command: rawInput, response: .localError("Not connected to a server.")))
            return
        }
        do {
            let reply = try await client.raw(args)
            entries.append(ConsoleEntry(command: rawInput, response: .resp(reply)))
        } catch {
            let msg: String
            if let ce = error as? ConnectionError {
                msg = ce.localizedDescription
            } else if let kv = error as? KVClientError {
                switch kv {
                case .serverError(let data):
                    msg = String(decoding: data, as: UTF8.self)
                case .unexpectedReply(let v):
                    msg = "Unexpected reply: \(v)"
                }
            } else {
                msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            entries.append(ConsoleEntry(command: rawInput, response: .transportError(msg)))
        }
    }

    // Test helper
    func appendEntry(_ entry: ConsoleEntry) {
        entries.append(entry)
    }
}
