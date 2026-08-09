import Testing
import Foundation
@testable import KV_Studio

struct RESPEncoderTests {

    /// Builds the expected wire bytes for an array of bulk strings the same way
    /// the RESP2 protocol defines it, without going through the encoder under test.
    private func expectedFrame(_ arguments: [[UInt8]]) -> Data {
        var bytes: [UInt8] = Array("*\(arguments.count)\r\n".utf8)
        for argument in arguments {
            bytes += Array("$\(argument.count)\r\n".utf8)
            bytes += argument
            bytes += Array("\r\n".utf8)
        }
        return Data(bytes)
    }

    @Test func encodesPing() {
        let arguments = [Data("PING".utf8)]
        let expected = expectedFrame([Array("PING".utf8)])
        #expect(RESPEncoder.encodeCommand(arguments) == expected)
    }

    @Test func encodesGetWithArgument() {
        let arguments = [Data("GET".utf8), Data("language".utf8)]
        let expected = expectedFrame([Array("GET".utf8), Array("language".utf8)])
        #expect(RESPEncoder.encodeCommand(arguments) == expected)
    }

    @Test func encodesBinaryKeyContainingNulAndCRLF() {
        let binaryKey: [UInt8] = [0x00, 0x0D, 0x0A, 0x41, 0xFF]
        let arguments = [Data("SET".utf8), Data(binaryKey)]
        let expected = expectedFrame([Array("SET".utf8), binaryKey])
        #expect(RESPEncoder.encodeCommand(arguments) == expected)
    }

    @Test func encodesEmptyArgument() {
        let arguments = [Data("SET".utf8), Data(), Data("value".utf8)]
        let expected = expectedFrame([Array("SET".utf8), [], Array("value".utf8)])
        #expect(RESPEncoder.encodeCommand(arguments) == expected)
    }

    @Test func encodesMultiByteUTF8ArgumentByByteCountNotCharacterCount() {
        let value = "héllo" // 5 characters, 6 UTF-8 bytes ('é' is 2 bytes).
        let valueData = Data(value.utf8)
        #expect(valueData.count == 6)

        let arguments = [Data("SET".utf8), Data("greeting".utf8), valueData]
        let expected = expectedFrame([Array("SET".utf8), Array("greeting".utf8), Array(valueData)])
        #expect(RESPEncoder.encodeCommand(arguments) == expected)
    }
}
