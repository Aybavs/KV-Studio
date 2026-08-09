import Foundation

/// A parsed `MAJOR.MINOR.PATCH` version, with an optional leading `v` and an
/// optional `-prerelease` suffix.
///
/// This app only needs to compare go-kv-store server version strings, so parsing
/// is intentionally strict: exactly three numeric components, no build metadata.
struct SemanticVersion: Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    /// Parses a version string such as `1.1.0`, `v1.1.0`, or `1.2.3-beta`.
    /// Returns `nil` for anything that isn't exactly three non-negative integer
    /// components (with an optional leading `v` and optional prerelease suffix).
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

        // Same core version: a prerelease always orders below the plain release,
        // per SemVer. We don't need finer-grained prerelease precedence than that.
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
