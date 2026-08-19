import Foundation
import Darwin
@testable import KV_Studio

// A listening socket that never accepts or replies: connects succeed, reads never do.
final class PortHolder: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init() throws {
        let bound = try boundLoopbackSocket(backlog: 8)
        descriptor = bound.descriptor
        port = bound.port
    }

    var endpoint: ConnectionEndpoint { ConnectionEndpoint(host: "127.0.0.1", port: port) }

    var isStillListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        return named == 0 && UInt16(bigEndian: address.sin_port) == port
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    deinit { close() }
}
