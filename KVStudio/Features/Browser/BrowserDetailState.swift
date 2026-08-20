import Foundation

enum BrowserDetailState: Equatable, Sendable {
    case idle
    case loading(key: Data)
    case loaded(key: Data, value: Data, ttl: TTLState)
    case missing(key: Data)
    case failed(key: Data, message: String)
}
