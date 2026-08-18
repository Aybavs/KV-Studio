import Foundation

enum TTLState: Equatable, Sendable {
    case missing
    case persistent
    case expiring(seconds: Int64)
}
