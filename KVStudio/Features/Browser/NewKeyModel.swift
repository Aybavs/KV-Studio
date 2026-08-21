import Foundation

enum BrowserNewKeyError: Error, Equatable, Sendable {
    case emptyKey
}

enum ExpiryUnit: String, CaseIterable, Sendable {
    case none
    case seconds
    case minutes
    case hours
}

enum NewKeyExpiry: Equatable, Sendable {
    case none
    case seconds(Int64)
    case minutes(Int64)
    case hours(Int64)

    var asSetExpiration: SetExpiration? {
        switch self {
        case .none: return nil
        case .seconds(let s): return .seconds(s)
        case .minutes(let m): return .seconds(m * 60)
        case .hours(let h): return .seconds(h * 3600)
        }
    }

    static func from(amountText: String, unit: ExpiryUnit) -> NewKeyExpiry? {
        if unit == .none { return NewKeyExpiry.none }
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int64(trimmed), value > 0 else { return nil }
        switch unit {
        case .seconds: return .seconds(value)
        case .minutes: return .minutes(value)
        case .hours: return .hours(value)
        case .none: return NewKeyExpiry.none
        }
    }
}
