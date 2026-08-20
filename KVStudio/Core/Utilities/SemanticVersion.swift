import Foundation

/// `MAJOR.MINOR.PATCH`, optional leading `v` and `-prerelease` suffix. No build metadata.
struct SemanticVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    init?(string: String) {
        var remainder = Substring(string)

        if remainder.first == "v" {
            remainder = remainder.dropFirst()
        }

        let core: Substring
        let prerelease: String?
        if let dashIndex = remainder.firstIndex(of: "-") {
            core = remainder[remainder.startIndex..<dashIndex]
            let suffix = remainder[remainder.index(after: dashIndex)...]
            guard !suffix.isEmpty else { return nil }
            prerelease = String(suffix)
        } else {
            core = remainder
            prerelease = nil
        }

        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }

        guard
            let major = Self.parseNonNegativeInt(components[0]),
            let minor = Self.parseNonNegativeInt(components[1]),
            let patch = Self.parseNonNegativeInt(components[2])
        else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    private static func parseNonNegativeInt(_ substring: Substring) -> Int? {
        guard !substring.isEmpty, substring.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(substring)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A prerelease orders below the plain release; finer precedence is not needed.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(lhsPrerelease), .some(rhsPrerelease)):
            return lhsPrerelease < rhsPrerelease
        }
    }
}
