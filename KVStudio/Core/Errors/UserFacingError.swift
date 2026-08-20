import Foundation

// Every failure the user can see is named here. No raw implementation error is ever the primary
// message; the underlying text is kept as `detail` for the places that show it in small print.
struct UserFacingError: Equatable, Sendable, Identifiable {
    enum Kind: String, Equatable, Sendable {
        case unreachable
        case incompatibleBackend
        case connectionClosed
        case serverShuttingDown
        case portConflict
        case malformedResponse
        case updateChecksumFailure
        case backendStartFailure
        case storagePathFailure
        case permissionFailure
        case unexpected
    }

    let kind: Kind
    let message: String
    let recovery: String?
    let detail: String?

    var id: String { "\(kind.rawValue):\(message)" }
}

extension UserFacingError {
    static func describing(_ error: any Error) -> UserFacingError {
        switch error {
        case let error as ConnectionError: return from(error)
        case let error as ManagedServerError: return from(error)
        case let error as RESPError: return from(error)
        case let error as KVClientError: return from(error)
        case let error as BackendStagingError: return from(error)
        case let error as BackendReleaseError: return from(error)
        case let error as BackendActivationError: return from(error)
        default:
            return UserFacingError(
                kind: .unexpected,
                message: "Something went wrong.",
                recovery: "Try again. If it keeps happening, check the Logs screen.",
                detail: String(describing: error)
            )
        }
    }

    static func from(_ outcome: CompatibilityOutcome) -> UserFacingError? {
        switch outcome {
        case .compatible:
            return nil
        case .unreachable(let reason):
            return UserFacingError(
                kind: .unreachable,
                message: "KV Studio could not reach that server.",
                recovery: "Check the host and port, and that the server is running.",
                detail: String(describing: reason)
            )
        case .incompatible(let step, let reason):
            return UserFacingError(
                kind: .incompatibleBackend,
                message: "That server is not a compatible go-kv-store.",
                recovery: "KV Studio needs go-kv-store 1.1.0 or later, which answers PING, DBSIZE and SCAN.",
                detail: "\(step): \(reason)"
            )
        case .protocolFailure(let step, let reason):
            return UserFacingError(
                kind: .malformedResponse,
                message: "That server did not answer in a protocol KV Studio understands.",
                recovery: "Confirm the port belongs to go-kv-store and not another service.",
                detail: "\(step): \(reason)"
            )
        }
    }

    // MARK: - Per-domain mapping

    private static func from(_ error: ConnectionError) -> UserFacingError {
        switch error {
        case .notConnected:
            return UserFacingError(
                kind: .connectionClosed,
                message: "KV Studio is not connected to a server.",
                recovery: "Connect from the Server screen and try again.",
                detail: nil
            )
        case .invalidPort(let port):
            return UserFacingError(
                kind: .unreachable,
                message: "Port \(port) is not a port KV Studio can use.",
                recovery: "Choose a port between 1 and 65535.",
                detail: nil
            )
        case .connectFailed(let detail):
            return UserFacingError(
                kind: .unreachable,
                message: "KV Studio could not reach that server.",
                recovery: "Check the host and port, and that the server is running.",
                detail: detail
            )
        case .connectionClosed:
            return UserFacingError(
                kind: .connectionClosed,
                message: "The server closed the connection.",
                recovery: "Reconnect from the Server screen.",
                detail: nil
            )
        case .transportFailure(let detail):
            return UserFacingError(
                kind: .connectionClosed,
                message: "The connection to the server was lost.",
                recovery: "Reconnect from the Server screen.",
                detail: detail
            )
        case .protocolViolation(let respError):
            return from(respError)
        }
    }

    private static func from(_ error: RESPError) -> UserFacingError {
        UserFacingError(
            kind: .malformedResponse,
            message: "The server sent a reply KV Studio could not read.",
            recovery: "Confirm the port belongs to go-kv-store and not another service.",
            detail: String(describing: error)
        )
    }

    private static func from(_ error: KVClientError) -> UserFacingError {
        switch error {
        case .serverError(let payload):
            let text = String(decoding: payload, as: UTF8.self)
            if text.hasPrefix("ERR server is shutting down") {
                return UserFacingError(
                    kind: .serverShuttingDown,
                    message: "The server is shutting down.",
                    recovery: "Wait for it to stop, then start it again from the Server screen.",
                    detail: text
                )
            }
            return UserFacingError(
                kind: .unexpected,
                message: "The server refused that command.",
                recovery: nil,
                detail: text
            )
        case .unexpectedReply(let value):
            return UserFacingError(
                kind: .malformedResponse,
                message: "The server answered in a shape KV Studio did not expect.",
                recovery: "Confirm the server is go-kv-store 1.1.0 or later.",
                detail: String(describing: value)
            )
        }
    }

    private static func from(_ error: ManagedServerError) -> UserFacingError {
        switch error {
        case .binaryUnavailable(let checked):
            return UserFacingError(
                kind: .backendStartFailure,
                message: "KV Studio could not find a kv-server to run.",
                recovery: "Install a backend from Settings, or set KV_SERVER_BINARY for development.",
                detail: checked.joined(separator: "\n")
            )
        case .storageUnavailable(let detail):
            return UserFacingError(
                kind: .storagePathFailure,
                message: "KV Studio could not use its Application Support folder.",
                recovery: "Check that ~/Library/Application Support is writable.",
                detail: detail
            )
        case .launchFailed(let detail):
            return UserFacingError(
                kind: .backendStartFailure,
                message: "The local server did not start.",
                recovery: "Check the Logs screen for what it printed.",
                detail: detail
            )
        case .exitedDuringStartup(let status):
            return UserFacingError(
                kind: .backendStartFailure,
                message: "The local server stopped while starting up.",
                recovery: "Check the Logs screen for what it printed.",
                detail: "exit status \(status)"
            )
        case .readinessTimedOut(let endpoint, let budget):
            return UserFacingError(
                kind: .backendStartFailure,
                message: "The local server did not become ready in time.",
                recovery: "Check the Logs screen, then try starting it again.",
                detail: "\(endpoint.host):\(endpoint.port) after \(budget)"
            )
        case .portInUse(let endpoint):
            return UserFacingError(
                kind: .portConflict,
                message: "Port \(endpoint.port) is already in use.",
                recovery: "Connect to that server instead, stop whatever is using the port, or choose another port in Settings.",
                detail: nil
            )
        case .terminationFailed(let pid):
            return UserFacingError(
                kind: .backendStartFailure,
                message: "KV Studio could not stop the local server.",
                recovery: "The process is still running; stop it yourself, then try again.",
                detail: "pid \(pid)"
            )
        case .unreclaimedServer(let endpoint):
            return UserFacingError(
                kind: .portConflict,
                message: "A server KV Studio started earlier is still holding port \(endpoint.port).",
                recovery: "Stop it yourself, or connect to it instead.",
                detail: nil
            )
        }
    }

    private static func from(_ error: BackendStagingError) -> UserFacingError {
        switch error {
        case .checksumMismatch, .checksumMissing, .checksumsUnreadable:
            return UserFacingError(
                kind: .updateChecksumFailure,
                message: "The downloaded backend did not match its published checksum.",
                recovery: "Nothing was installed. Try the update again later.",
                detail: (error as LocalizedError).errorDescription
            )
        case .unsafeArchiveEntry, .archiveUnreadable, .missingExecutable:
            return UserFacingError(
                kind: .updateChecksumFailure,
                message: "The downloaded backend archive was not in the expected shape.",
                recovery: "Nothing was installed. Try the update again later.",
                detail: (error as LocalizedError).errorDescription
            )
        case .stagingFailed(let detail):
            return UserFacingError(
                kind: .storagePathFailure,
                message: "KV Studio could not store the downloaded backend.",
                recovery: "Check that ~/Library/Application Support is writable.",
                detail: detail
            )
        }
    }

    private static func from(_ error: BackendReleaseError) -> UserFacingError {
        UserFacingError(
            kind: .unreachable,
            message: "KV Studio could not read the list of backend releases.",
            recovery: "Check your network connection and try again.",
            detail: error.errorDescription
        )
    }

    private static func from(_ error: BackendActivationError) -> UserFacingError {
        switch error {
        case .nothingStaged:
            return UserFacingError(
                kind: .unexpected,
                message: "There is no verified backend waiting to be installed.",
                recovery: nil,
                detail: nil
            )
        case .swapFailed(let detail):
            return UserFacingError(
                kind: .storagePathFailure,
                message: "KV Studio could not swap the backend into place.",
                recovery: "Check that ~/Library/Application Support is writable.",
                detail: detail
            )
        case .rolledBack(let reason):
            return UserFacingError(
                kind: .backendStartFailure,
                message: "The new backend did not work, so the previous one was restored.",
                recovery: "You can keep using KV Studio. Try the update again later.",
                detail: reason
            )
        case .rollbackFailed(let reason, let detail):
            return UserFacingError(
                kind: .backendStartFailure,
                message: "The new backend failed and the previous one could not be restored.",
                recovery: "Start the server again from the Server screen.",
                detail: "\(reason)\n\(detail)"
            )
        }
    }
}
