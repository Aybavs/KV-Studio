import Foundation
import Darwin
@testable import KV_Studio

// MARK: - Loopback fake server

enum FakeServerError: Error {
    case setupFailed
}

func boundLoopbackSocket(backlog: Int32) throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw FakeServerError.setupFailed }

    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(descriptor, backlog) == 0 else {
        Darwin.close(descriptor)
        throw FakeServerError.setupFailed
    }

    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard named == 0 else {
        Darwin.close(descriptor)
        throw FakeServerError.setupFailed
    }
    return (descriptor, UInt16(bigEndian: assigned.sin_port))
}

final class FakePeer: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    // A dropped tail would hang the client until the suite time limit; closing fails it now.
    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                guard let fd = openDescriptor() else { return }
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                close()
                return
            }
        }
    }

    // Half-closes and drains, so the client always sees every written byte then a clean EOF.
    // A plain close() while unread bytes remain would send RST and discard them.
    func finish() {
        guard let fd = openDescriptor() else { return }
        shutdown(fd, SHUT_WR)
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            guard let fd = openDescriptor() else { break }
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count > 0 { continue }
            if count < 0 && errno == EINTR { continue }
            break
        }
        close()
    }

    func readCommand() -> [Data]? {
        guard let header = readLine(), header.first == UInt8(ascii: "*"),
              let count = Int(String(decoding: header.dropFirst(), as: UTF8.self)) else { return nil }

        var arguments: [Data] = []
        for _ in 0..<count {
            guard let lengthLine = readLine(), lengthLine.first == UInt8(ascii: "$"),
                  let length = Int(String(decoding: lengthLine.dropFirst(), as: UTF8.self)),
                  let framed = readExactly(length + 2) else { return nil }
            arguments.append(framed.prefix(length))
        }
        return arguments
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        // Wake a handler parked in read() before the descriptor goes away, so it sees EOF instead
        // of having the number freed under an in-flight syscall.
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func readLine() -> [UInt8]? {
        var line: [UInt8] = []
        while true {
            guard let byte = readByte() else { return nil }
            if byte == UInt8(ascii: "\r") {
                guard let feed = readByte(), feed == UInt8(ascii: "\n") else { return nil }
                return line
            }
            line.append(byte)
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            guard let byte = readByte() else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            guard let fd = openDescriptor() else { return nil }
            let result = Darwin.read(fd, &byte, 1)
            if result == 1 { return byte }
            if result < 0 && errno == EINTR { continue }
            return nil
        }
    }

    private func openDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return isClosed ? nil : descriptor
    }
}

final class FakeServer: @unchecked Sendable {
    let port: UInt16
    private let acceptSource: DispatchSourceRead
    private let ledger = PeerLedger()

    // The coordinator opens a probe connection and one connection per lane, so a server that
    // stops accepting after its first peer cannot stand in for a real one.
    init(label: String = #function, maxPeers: Int = 1, handler: @escaping @Sendable (FakePeer) -> Void) throws {
        let bound = try boundLoopbackSocket(backlog: 8)
        let descriptor = bound.descriptor
        port = bound.port

        // A readable-source accept never blocks a thread, so `stop()` is deterministic.
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "fake-server.accept.\(label)")
        )
        acceptSource = source
        let ledger = ledger
        source.setEventHandler {
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else {
                if errno == EAGAIN || errno == ECONNABORTED { return }
                source.cancel()
                return
            }
            var noDelay: Int32 = 1
            setsockopt(accepted, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            let peer = FakePeer(descriptor: accepted)
            let count = ledger.track(peer)
            if count >= maxPeers { source.cancel() }
            // Each peer gets its own queue: one parked mid-command must not stall the others.
            DispatchQueue(label: "fake-server.peer.\(label).\(count)").async {
                handler(peer)
                peer.finish()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    var endpoint: ConnectionEndpoint { ConnectionEndpoint(host: "127.0.0.1", port: port) }

    var acceptedCount: Int { ledger.accepted }

    func stop() {
        acceptSource.cancel()
        ledger.closeAll()
    }
}

private final class PeerLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [FakePeer] = []
    private var count = 0

    var accepted: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func track(_ peer: FakePeer) -> Int {
        lock.lock()
        peers.append(peer)
        count += 1
        let current = count
        lock.unlock()
        return current
    }

    func closeAll() {
        lock.lock()
        let open = peers
        peers = []
        lock.unlock()
        open.forEach { $0.close() }
    }
}

// MARK: - Async signal

final class Signal: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false
    }

    private let lock = NSLock()
    private var isSet = false
    private var waiters: [ObjectIdentifier: Waiter] = [:]

    func fire() {
        lock.lock()
        isSet = true
        let pending = waiters.values.compactMap { $0.continuation }
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        let token = Waiter()
        let key = ObjectIdentifier(token)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isSet || token.cancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    token.continuation = continuation
                    waiters[key] = token
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            // onCancel can run before the continuation is registered; the flag covers that case.
            if let waiter = waiters.removeValue(forKey: key) {
                lock.unlock()
                waiter.continuation?.resume()
            } else {
                token.cancelled = true
                lock.unlock()
            }
        }
    }
}
