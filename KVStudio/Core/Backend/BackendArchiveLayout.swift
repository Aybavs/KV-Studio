import Foundation

struct ArchiveEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case regularFile
        case directory
        case other
    }

    let kind: Kind
    let path: String

    // `tar -tvzf` prints the mode first and the path last; anything that is not a plain file or a
    // directory is `.other` so the layout check can refuse it without enumerating link types.
    static func parse(listing: String) -> [ArchiveEntry] {
        listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let mode = fields.first?.first else { return nil }
            let kind: Kind = switch mode {
            case "-": .regularFile
            case "d": .directory
            default: .other
            }
            return ArchiveEntry(kind: kind, path: String(fields[8]))
        }
    }
}

enum BackendArchiveLayout {
    static let executableName = "kv-server"

    // The release ships exactly one top-level directory holding the binary. Anything else -- a
    // second root, an absolute path, a `..` component, a link -- is refused rather than extracted.
    static func executablePath(in entries: [ArchiveEntry]) throws -> String {
        guard !entries.isEmpty else {
            throw BackendStagingError.archiveUnreadable("the archive is empty")
        }

        var roots: Set<String> = []
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !entry.path.hasPrefix("/"),
                  !components.contains(".."),
                  entry.kind != .other else {
                throw BackendStagingError.unsafeArchiveEntry(entry.path)
            }
            guard let root = components.first else {
                throw BackendStagingError.unsafeArchiveEntry(entry.path)
            }
            guard components.count > 1 || entry.kind == .directory else {
                throw BackendStagingError.archiveUnreadable("\(entry.path) is not inside a release directory")
            }
            roots.insert(String(root))
        }

        guard roots.count == 1, let root = roots.first else {
            throw BackendStagingError.archiveUnreadable("the archive does not hold a single release directory")
        }

        let expected = "\(root)/\(executableName)"
        guard let executable = entries.first(where: { $0.path == expected }) else {
            throw BackendStagingError.missingExecutable(expected)
        }
        guard executable.kind == .regularFile else {
            throw BackendStagingError.unsafeArchiveEntry(expected)
        }
        return expected
    }
}
