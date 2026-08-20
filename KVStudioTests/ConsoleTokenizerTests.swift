import Testing
import Foundation
@testable import KV_Studio

@Suite struct ConsoleTokenizerTests {
    @Test func emptyInputReturnsEmpty() throws {
        #expect(try ConsoleTokenizer.tokenize("") == [])
        #expect(try ConsoleTokenizer.tokenize("   ") == [])
        #expect(try ConsoleTokenizer.tokenize("\t\n ") == [])
    }

    @Test func whitespaceSeparatedTokens() throws {
        #expect(try ConsoleTokenizer.tokenize("GET mykey") == ["GET", "mykey"])
        #expect(try ConsoleTokenizer.tokenize("  GET   mykey  ") == ["GET", "mykey"])
        #expect(try ConsoleTokenizer.tokenize("PING") == ["PING"])
        #expect(try ConsoleTokenizer.tokenize("SET a b c") == ["SET", "a", "b", "c"])
    }

    @Test func doubleQuotedStringPreservesSpaces() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET mykey "hello world""#) == ["SET", "mykey", "hello world"])
        #expect(try ConsoleTokenizer.tokenize(#"GET "my key""#) == ["GET", "my key"])
    }

    @Test func singleQuotedStringPreservesSpaces() throws {
        #expect(try ConsoleTokenizer.tokenize("SET mykey 'hello world'") == ["SET", "mykey", "hello world"])
        #expect(try ConsoleTokenizer.tokenize("GET 'my key'") == ["GET", "my key"])
    }

    @Test func emptyQuotedArgument() throws {
        #expect(try ConsoleTokenizer.tokenize("SET mykey \"\"") == ["SET", "mykey", ""])
        #expect(try ConsoleTokenizer.tokenize("SET mykey ''") == ["SET", "mykey", ""])
        #expect(try ConsoleTokenizer.tokenize("\"\"") == [""])
        #expect(try ConsoleTokenizer.tokenize("''") == [""])
        #expect(try ConsoleTokenizer.tokenize("SET \"\" \"\"") == ["SET", "", ""])
    }

    @Test func backslashEscapesSpaceOutsideQuotes() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET my\ key value"#) == ["SET", "my key", "value"])
        #expect(try ConsoleTokenizer.tokenize(#"GET a\ b\ c"#) == ["GET", "a b c"])
    }

    @Test func backslashEscapesQuotesInsideDouble() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET key "a \"b\" c""#) == ["SET", "key", #"a "b" c"#])
    }

    @Test func backslashEscapesQuotesInsideSingle() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET key 'a \'b\' c'"#) == ["SET", "key", "a 'b' c"])
    }

    @Test func backslashEscapesBackslash() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET key "a\\b""#) == ["SET", "key", "a\\b"])
        #expect(try ConsoleTokenizer.tokenize(#"SET key a\\b"#) == ["SET", "key", "a\\b"])
    }

    @Test func doubleQuotesContainSingleQuotesLiterally() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET key "a 'b' c""#) == ["SET", "key", "a 'b' c"])
    }

    @Test func singleQuotesContainDoubleQuotesLiterally() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET key 'a "b" c'"#) == ["SET", "key", #"a "b" c"#])
    }

    @Test func mixedQuotedAndUnquoted() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET "my key" 'your key' plain"#) == ["SET", "my key", "your key", "plain"])
    }

    @Test func unterminatedDoubleQuoteThrows() {
        #expect(throws: ConsoleTokenizerError.unterminatedQuote) {
            try ConsoleTokenizer.tokenize(#"SET key "hello"#)
        }
    }

    @Test func unterminatedSingleQuoteThrows() {
        #expect(throws: ConsoleTokenizerError.unterminatedQuote) {
            try ConsoleTokenizer.tokenize("SET key 'hello")
        }
    }

    @Test func consecutiveWhitespaceCollapsed() throws {
        #expect(try ConsoleTokenizer.tokenize("GET\tmykey\nmyvalue") == ["GET", "mykey", "myvalue"])
    }

    @Test func backslashEscapesAnyCharacter() throws {
        #expect(try ConsoleTokenizer.tokenize(#"SET key "a\ b""#) == ["SET", "key", "a b"])
        #expect(try ConsoleTokenizer.tokenize(#"SET key \a"#) == ["SET", "key", "a"])
    }

    @Test func tokenToDataConversion() throws {
        let tokens = try ConsoleTokenizer.tokenize(#"SET mykey "hello world""#)
        let data = tokens.map { Data($0.utf8) }
        #expect(data == [Data("SET".utf8), Data("mykey".utf8), Data("hello world".utf8)])
    }

    @Test func emptyQuotedInMiddle() throws {
        #expect(try ConsoleTokenizer.tokenize("SET \"\" value") == ["SET", "", "value"])
        #expect(try ConsoleTokenizer.tokenize("A '' B") == ["A", "", "B"])
    }
}
