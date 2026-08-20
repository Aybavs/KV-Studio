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

    // The probe's own connection is only observable from this side: accepting it lets a test see the
    // peer hang up, which distinguishes a torn-down connection from a leaked one.
    func acceptedPeerHungUp(within budget: Duration) -> Bool {
        lock.lock()
        let listening = closed ? -1 : descriptor
        lock.unlock()
        guard listening >= 0 else { return false }

        var timeout = timeval(tv_sec: Int(budget.components.seconds), tv_usec: 0)
        setsockopt(listening, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let peer = accept(listening, nil, nil)
        guard peer >= 0 else { return false }
        defer { Darwin.close(peer) }

        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var scratch = [UInt8](repeating: 0, count: 64)
        while true {
            let read = Darwin.read(peer, &scratch, scratch.count)
            if read == 0 { return true }
            if read < 0 { return false }
        }
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
