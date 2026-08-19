import Foundation

enum FakeKV {
    static func reply(to command: [Data]) -> Data {
        switch name(of: command) {
        case "PING": return Data("+PONG\r\n".utf8)
        case "DBSIZE": return Data(":0\r\n".utf8)
        case "SCAN": return Data("*2\r\n$1\r\n0\r\n*0\r\n".utf8)
        case let other: return Data("-ERR unknown command '\(other)'\r\n".utf8)
        }
    }

    static func name(of command: [Data]) -> String {
        String(decoding: command.first ?? Data(), as: UTF8.self).uppercased()
    }

    static func serve(_ peer: FakePeer) {
        while let command = peer.readCommand() {
            peer.write(reply(to: command))
        }
    }
}
