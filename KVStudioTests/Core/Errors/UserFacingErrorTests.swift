import Foundation
import Testing
@testable import KV_Studio

@Suite
struct UserFacingErrorTests {

    private func described(_ error: any Error) -> UserFacingError {
        UserFacingError.describing(error)
    }

    // The brief's list, one test per named failure.

    @Test func unreachableServer() {
        let error = described(ConnectionError.connectFailed("Connection refused"))
        #expect(error.kind == .unreachable)
        #expect(error.detail == "Connection refused")
    }

    @Test func incompatibleBackend() throws {
        let error = try #require(UserFacingError.from(.incompatible(
            step: .dbSize,
            reason: .serverError(class: .unknownCommand, message: "ERR unknown command 'DBSIZE'")
        )))
        #expect(error.kind == .incompatibleBackend)
        #expect(error.recovery?.contains("1.1.0") == true)
    }

    @Test func connectionClosed() {
        #expect(described(ConnectionError.connectionClosed).kind == .connectionClosed)
        #expect(described(ConnectionError.transportFailure("reset")).kind == .connectionClosed)
    }

    @Test func serverShuttingDown() {
        let error = described(KVClientError.serverError(Data("ERR server is shutting down".utf8)))
        #expect(error.kind == .serverShuttingDown)
    }

    @Test func portConflict() {
        let endpoint = ConnectionEndpoint(host: "127.0.0.1", port: 6380)
        let error = described(ManagedServerError.portInUse(endpoint))
        #expect(error.kind == .portConflict)
        #expect(error.message.contains("6380"))
        #expect(error.recovery?.isEmpty == false)
    }

    @Test func malformedRESP() {
        #expect(described(RESPError.unknownTypeByte(UInt8(ascii: "G"))).kind == .malformedResponse)
        #expect(described(KVClientError.unexpectedReply(.integer(1))).kind == .malformedResponse)
    }

    @Test func updateChecksumFailure() {
        let error = described(BackendStagingError.checksumMismatch(
            expected: String(repeating: "a", count: 64),
            actual: String(repeating: "b", count: 64)
        ))
        #expect(error.kind == .updateChecksumFailure)
        #expect(error.recovery?.contains("Nothing was installed") == true)
    }

    @Test func backendStartFailure() {
        #expect(described(ManagedServerError.launchFailed("no such file")).kind == .backendStartFailure)
        #expect(described(ManagedServerError.exitedDuringStartup(3)).kind == .backendStartFailure)
    }

    @Test func aofAndStoragePathFailure() {
        let error = described(ManagedServerError.storageUnavailable("read-only volume"))
        #expect(error.kind == .storagePathFailure)
        #expect(error.recovery?.contains("Application Support") == true)
    }

    @Test func permissionFailureIsNamedInTheTaxonomy() {
        #expect(UserFacingError.Kind.permissionFailure.rawValue == "permissionFailure")
    }

    // MARK: - The rule the brief states

    @Test func noPrimaryMessageIsARawImplementationError() {
        let errors: [any Error] = [
            ConnectionError.connectFailed("Connection refused"),
            ConnectionError.protocolViolation(.unknownTypeByte(0)),
            KVClientError.unexpectedReply(.integer(1)),
            ManagedServerError.binaryUnavailable(["/a", "/b"]),
            ManagedServerError.terminationFailed(1234),
            BackendStagingError.stagingFailed("disk full"),
            BackendReleaseError.unreadableResponse,
            BackendActivationError.rolledBack("probe said no"),
            CocoaError(.fileNoSuchFile)
        ]

        for error in errors {
            let described = UserFacingError.describing(error)
            #expect(described.message.isEmpty == false)
            // A message that quotes the Swift value is the thing this task exists to prevent.
            #expect(described.message.contains("Error(") == false)
            #expect(described.message.contains("KV_Studio.") == false)
            #expect(described.message.hasSuffix(".") || described.message.hasSuffix("?"))
        }
    }

    @Test func keepsTheUnderlyingTextAsDetailRatherThanThrowingItAway() {
        let error = described(ManagedServerError.binaryUnavailable(["/one", "/two"]))
        #expect(error.detail?.contains("/one") == true)
        #expect(error.detail?.contains("/two") == true)
    }

    @Test func aCompatibleServerHasNothingToReport() {
        #expect(UserFacingError.from(.compatible) == nil)
    }

    @Test func anUnknownErrorStillGetsAHumanMessage() {
        let error = described(CocoaError(.fileNoSuchFile))
        #expect(error.kind == .unexpected)
        #expect(error.message == "Something went wrong.")
        #expect(error.detail?.isEmpty == false)
    }
}
