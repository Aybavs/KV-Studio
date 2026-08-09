import Testing
import Foundation
import Darwin
@testable import KV_Studio

// MARK: - Loopback fake server

private enum FakeServerError: Error {
    case setupFailed
}

private final class FakePeer: @unchecked Sendable {
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
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
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
        lock.lock()
        let alreadyClosed = isClosed
        lock.unlock()
        guard !alreadyClosed else { return }

        shutdown(descriptor, SHUT_WR)
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &scratch, scratch.count)
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
            let result = Darwin.read(descriptor, &byte, 1)
            if result == 1 { return byte }
            if result < 0 && errno == EINTR { continue }
            return nil
        }
    }
}

private final class FakeServer: @unchecked Sendable {
    let port: UInt16
    private let acceptSource: DispatchSourceRead

    init(label: String = #function, handler: @escaping @Sendable (FakePeer) -> Void) throws {
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
        guard bound == 0, listen(descriptor, 8) == 0 else {
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

        port = UInt16(bigEndian: assigned.sin_port)

        // A readable-source accept never blocks a thread, so `stop()` is deterministic.
        let work = DispatchQueue(label: "fake-server.work.\(label)")
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "fake-server.accept.\(label)")
        )
        acceptSource = source
        source.setEventHandler {
            let accepted = accept(descriptor, nil, nil)
            source.cancel()
            guard accepted >= 0 else { return }
            var noDelay: Int32 = 1
            setsockopt(accepted, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            let peer = FakePeer(descriptor: accepted)
            work.async {
                handler(peer)
                peer.finish()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    func stop() {
        acceptSource.cancel()
    }
}

// MARK: - Async signal

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        isSet = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isSet {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

// MARK: - Tests

// A stalled connection would otherwise hang the suite instead of failing it.
@Suite(.timeLimit(.minutes(1))) struct KVConnectionTests {

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func connect(to server: FakeServer) async throws -> KVConnection {
        let connection = KVConnection()
        try await connection.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: server.port))
        return connection
    }

    @Test func concurrentSendsEachReceiveTheirOwnReply() async throws {
        let commandCount = 64
        let server = try FakeServer { peer in
            while let arguments = peer.readCommand() {
                guard arguments.count == 2 else { return }
                let token = arguments[1]
                // Split so a reply straddles two writes and widens any interleaving window.
                peer.write(Data("$\(token.count)\r\n".utf8))
                peer.write(token + Data("\r\n".utf8))
            }
        }
        defer { server.stop() }

        let connection = try await connect(to: server)
        let replies = try await withThrowingTaskGroup(of: (Int, RESPValue).self) { group in
            for index in 0..<commandCount {
                group.addTask {
                    let token = Data("token-\(index)".utf8)
                    return (index, try await connection.send([Data("ECHO".utf8), token]))
                }
            }
            var collected: [Int: RESPValue] = [:]
            for try await (index, value) in group {
                collected[index] = value
            }
            return collected
        }

        for index in 0..<commandCount {
            #expect(replies[index] == .bulkString(bytes("token-\(index)")))
        }
        await connection.disconnect()
    }

    @Test func fragmentedReplyDecodesAsASingleValue() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            for chunk in ["$1", "1\r\nhel", "lo wo", "rld", "\r\n"] {
                peer.write(Data(chunk.utf8))
            }
        }
        defer { server.stop() }

        let connection = try await connect(to: server)
        let value = try await connection.send([bytes("GET"), bytes("greeting")])
        #expect(value == .bulkString(bytes("hello world")))
        await connection.disconnect()
    }

    @Test func errorReplyIsAValueAndKeepsTheConnectionUsable() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(Data("-ERR unknown command\r\n".utf8))
            _ = peer.readCommand()
            peer.write(Data("+OK\r\n".utf8))
        }
        defer { server.stop() }

        let connection = try await connect(to: server)
        let failure = try await connection.send([bytes("BOGUS")])
        #expect(failure == .error(bytes("ERR unknown command")))
        #expect(await connection.isConnected)

        let success = try await connection.send([bytes("PING")])
        #expect(success == .simpleString(bytes("OK")))
        await connection.disconnect()
    }

    @Test func endOfStreamFailsTheRequestAndDisconnects() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.close()
        }
        defer { server.stop() }

        let connection = try await connect(to: server)
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.send([self.bytes("GET"), self.bytes("key")])
        }
        #expect(await connection.isConnected == false)
        await #expect(throws: ConnectionError.notConnected) {
            _ = try await connection.send([self.bytes("GET"), self.bytes("key")])
        }
    }

    @Test func malformedReplyFailsTheRequestAndDisconnects() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(Data("%not-a-resp-type\r\n".utf8))
            _ = peer.readCommand()
        }
        defer { server.stop() }

        let connection = try await connect(to: server)
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.send([self.bytes("GET"), self.bytes("key")])
        }
        #expect(await connection.isConnected == false)
    }

    @Test func cancellingAWrittenCommandKeepsTheStreamAlignedForTheNextCaller() async throws {
        let commandRead = Signal()
        let releaseReply = DispatchSemaphore(value: 0)
        let server = try FakeServer { peer in
            guard let first = peer.readCommand(), first.count == 2 else { return }
            commandRead.fire()
            releaseReply.wait()
            peer.write(Data("$\(first[1].count)\r\n".utf8) + first[1] + Data("\r\n".utf8))
            guard let second = peer.readCommand(), second.count == 2 else { return }
            peer.write(Data("$\(second[1].count)\r\n".utf8) + second[1] + Data("\r\n".utf8))
        }
        defer { server.stop() }

        let connection = try await connect(to: server)
        let cancelled = Task {
            try await connection.send([Data("ECHO".utf8), Data("first".utf8)])
        }

        await commandRead.wait()
        cancelled.cancel()
        releaseReply.signal()

        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }

        let value = try await connection.send([bytes("ECHO"), bytes("second")])
        #expect(value == .bulkString(bytes("second")))
        #expect(await connection.isConnected)
        await connection.disconnect()
    }

    @Test func reconnectStartsWithCleanDecoderState() async throws {
        let brokenServer = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(Data("$100\r\nleftover".utf8))
            peer.close()
        }
        defer { brokenServer.stop() }

        let connection = try await connect(to: brokenServer)
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.send([self.bytes("GET"), self.bytes("key")])
        }

        let healthyServer = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(Data("$1\r\nZ\r\n".utf8))
        }
        defer { healthyServer.stop() }

        try await connection.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: healthyServer.port))
        let value = try await connection.send([bytes("GET"), bytes("key")])
        #expect(value == .bulkString(bytes("Z")))
        await connection.disconnect()
    }

    @Test func sendBeforeConnectFailsFast() async throws {
        let connection = KVConnection()
        await #expect(throws: ConnectionError.notConnected) {
            _ = try await connection.send([self.bytes("PING")])
        }
        #expect(await connection.isConnected == false)
    }

    // Port 1 is privileged and outside the ephemeral range, so no other test can occupy it.
    @Test func connectToAPortWithNoListenerFails() async throws {
        let connection = KVConnection()
        await #expect(throws: ConnectionError.self) {
            try await connection.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: 1))
        }
        #expect(await connection.isConnected == false)
    }

    @Test func portZeroIsRejectedBeforeDialling() async throws {
        let connection = KVConnection()
        await #expect(throws: ConnectionError.invalidPort(0)) {
            try await connection.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: 0))
        }
        #expect(await connection.isConnected == false)
    }

    @Test func disconnectClearsConnectedStateAndFailsLaterSends() async throws {
        let server = try FakeServer { peer in
            _ = peer.readCommand()
        }
        defer { server.stop() }

        let connection = try await connect(to: server)
        #expect(await connection.isConnected)

        await connection.disconnect()
        #expect(await connection.isConnected == false)
        await #expect(throws: ConnectionError.notConnected) {
            _ = try await connection.send([self.bytes("PING")])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func disconnectWhileDiallingLeavesTheActorUsable() async throws {
        let connection = KVConnection()

        for _ in 0..<20 {
            let server = try FakeServer { peer in
                _ = peer.readCommand()
            }
            let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: server.port)
            let dialling = Task { try await connection.connect(to: endpoint) }
            await Task.yield()
            await connection.disconnect()
            // Deadlocks here before the fix: the pending readiness continuation is dropped.
            _ = try? await dialling.value
            server.stop()
        }

        let healthy = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(Data("+PONG\r\n".utf8))
        }
        defer { healthy.stop() }

        try await connection.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: healthy.port))
        let value = try await connection.send([bytes("PING")])
        #expect(value == .simpleString(bytes("PONG")))
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func disconnectInterruptsAnInFlightSendAndTheActorReconnects() async throws {
        let commandRead = Signal()
        let silentServer = try FakeServer { peer in
            _ = peer.readCommand()
            commandRead.fire()
            while peer.readCommand() != nil {}
        }
        defer { silentServer.stop() }

        let connection = try await connect(to: silentServer)
        let stalled = Task { try await connection.send([self.bytes("GET"), self.bytes("key")]) }

        await commandRead.wait()
        await connection.disconnect()

        await #expect(throws: ConnectionError.self) {
            _ = try await stalled.value
        }
        #expect(await connection.isConnected == false)

        let healthy = try FakeServer { peer in
            _ = peer.readCommand()
            peer.write(Data("+PONG\r\n".utf8))
        }
        defer { healthy.stop() }

        try await connection.connect(to: ConnectionEndpoint(host: "127.0.0.1", port: healthy.port))
        let value = try await connection.send([bytes("PING")])
        #expect(value == .simpleString(bytes("PONG")))
        await connection.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAParkedCallerFailsFastAndKeepsTheQueueIntact() async throws {
        let commandRead = Signal()
        let releaseReply = DispatchSemaphore(value: 0)
        let server = try FakeServer { peer in
            guard let first = peer.readCommand(), first.count == 2 else { return }
            commandRead.fire()
            releaseReply.wait()
            peer.write(Data("$\(first[1].count)\r\n".utf8) + first[1] + Data("\r\n".utf8))
            while let next = peer.readCommand(), next.count == 2 {
                peer.write(Data("$\(next[1].count)\r\n".utf8) + next[1] + Data("\r\n".utf8))
            }
        }
        defer {
            releaseReply.signal()
            server.stop()
        }

        let connection = try await connect(to: server)
        let holder = Task { try await connection.send([self.bytes("ECHO"), self.bytes("held")]) }
        await commandRead.wait()

        let parkedEntered = Signal()
        let parked = Task { () -> RESPValue in
            parkedEntered.fire()
            return try await connection.send([self.bytes("ECHO"), self.bytes("parked")])
        }
        await parkedEntered.wait()
        await Task.yield()

        let followerEntered = Signal()
        let follower = Task { () -> RESPValue in
            followerEntered.fire()
            return try await connection.send([self.bytes("ECHO"), self.bytes("follower")])
        }
        await followerEntered.wait()
        await Task.yield()

        parked.cancel()
        // Hangs until the holder finishes before the fix; the holder is still stalled here.
        await #expect(throws: CancellationError.self) {
            _ = try await parked.value
        }

        releaseReply.signal()
        #expect(try await holder.value == .bulkString(bytes("held")))
        #expect(try await follower.value == .bulkString(bytes("follower")))
        #expect(await connection.isConnected)
        await connection.disconnect()
    }
}
