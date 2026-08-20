import Foundation

enum BackendStagingError: Error, Equatable {
    case checksumsUnreadable
    case checksumMissing(String)
    case checksumMismatch(expected: String, actual: String)
    case archiveUnreadable(String)
    case unsafeArchiveEntry(String)
    case missingExecutable(String)
    case stagingFailed(String)
}

extension BackendStagingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .checksumsUnreadable:
            return "The release checksum file could not be read."
        case .checksumMissing(let name):
            return "The checksum file does not list \(name)."
        case .checksumMismatch:
            return "The downloaded archive did not match its published checksum and was discarded."
        case .archiveUnreadable(let detail):
            return "The downloaded archive could not be read: \(detail)"
        case .unsafeArchiveEntry(let entry):
            return "The archive contains an entry KV Studio will not extract: \(entry)"
        case .missingExecutable(let path):
            return "The archive does not contain \(path)."
        case .stagingFailed(let detail):
            return "The verified backend could not be staged: \(detail)"
        }
    }
}
