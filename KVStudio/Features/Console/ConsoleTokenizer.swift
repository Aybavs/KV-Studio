import Foundation

enum ConsoleTokenizerError: Error, Equatable, Sendable {
    case unterminatedQuote
}

enum ConsoleTokenizer {
    /// Tokenizes a console command line into whitespace-separated tokens.
    /// Supports:
    /// - whitespace separation (space, tab, newline)
    /// - single and double quoted strings that preserve whitespace
    /// - backslash escapes (backslash escapes next character, in or out of quotes)
    /// - empty quoted arguments (`""` and `''` produce an empty token)
    /// Does not encode binary; all tokens are UTF-8 strings.
    static func tokenize(_ input: String) throws(ConsoleTokenizerError) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false

        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]

            if ch == "\\" {
                let nextIndex = input.index(after: index)
                if nextIndex < input.endIndex {
                    let next = input[nextIndex]
                    current.append(next)
                    hasToken = true
                    index = input.index(after: nextIndex)
                } else {
                    // trailing backslash treated as literal
                    current.append("\\")
                    hasToken = true
                    index = input.index(after: index)
                }
                continue
            }

            if ch == "'" && !inDouble {
                if inSingle {
                    inSingle = false
                } else {
                    inSingle = true
                    hasToken = true
                }
                index = input.index(after: index)
                continue
            }

            if ch == "\"" && !inSingle {
                if inDouble {
                    inDouble = false
                } else {
                    inDouble = true
                    hasToken = true
                }
                index = input.index(after: index)
                continue
            }

            if ch.isWhitespace && !inSingle && !inDouble {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                index = input.index(after: index)
                continue
            }

            current.append(ch)
            hasToken = true
            index = input.index(after: index)
        }

        if inSingle || inDouble {
            throw ConsoleTokenizerError.unterminatedQuote
        }

        if hasToken {
            tokens.append(current)
        }

        return tokens
    }

    /// Convenience that returns UTF-8 encoded data for each token, ready for `KVClient.raw`.
    static func tokenizeToData(_ input: String) throws(ConsoleTokenizerError) -> [Data] {
        try tokenize(input).map { Data($0.utf8) }
    }
}
