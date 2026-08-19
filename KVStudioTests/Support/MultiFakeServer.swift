import Foundation
import Darwin
@testable import KV_Studio

// FakeServer stops accepting after its first peer; the coordinator opens three connections.
final class MultiFakeServer: @unchecked Sendable {
    let port: UInt16

    private let acceptSource: DispatchSourceRead
    private let lock = NSLock()
    private var peers: [FakePeer] = []

    init(label: String = #function, handler: @escaping @Sendable (FakePeer) -> Void) throws {
        let bound = try boundLoopbackSocket(backlog: 16)
        let descriptor = bound.descriptor
        port = bound.port

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "multi-fake-server.accept.\(label)")
        )
        acceptSource = source
        source.setEventHandler { [weak self] in
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else {
                if errno == EAGAIN || errno == ECONNABORTED { return }
                source.cancel()
                return
            }
            var noDelay: Int32 = 1
            setsockopt(accepted, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            let peer = FakePeer(descriptor: accepted)
            self?.track(peer)
            // A peer that parks mid-command must not stall the peers beside it.
            DispatchQueue(label: "multi-fake-server.peer.\(UUID().uuidString)").async {
                handler(peer)
                peer.finish()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    var endpoint: ConnectionEndpoint { ConnectionEndpoint(host: "127.0.0.1", port: port) }

    func stop() {
        acceptSource.cancel()
        lock.lock()
        let open = peers
        peers = []
        lock.unlock()
        open.forEach { $0.close() }
    }

    private func track(_ peer: FakePeer) {
        lock.lock()
        peers.append(peer)
        lock.unlock()
    }
}

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
