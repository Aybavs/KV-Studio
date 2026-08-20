import Foundation
import Testing
@testable import KV_Studio

@Suite
struct BackendArchiveLayoutTests {

    private let root = "kv-server_v1.1.0_darwin_arm64"

    private func realLayout() -> [ArchiveEntry] {
        [
            ArchiveEntry(kind: .directory, path: "\(root)/"),
            ArchiveEntry(kind: .regularFile, path: "\(root)/kv-server"),
            ArchiveEntry(kind: .regularFile, path: "\(root)/README.md"),
            ArchiveEntry(kind: .regularFile, path: "\(root)/LICENSE")
        ]
    }

    @Test func acceptsTheRealReleaseLayout() throws {
        let path = try BackendArchiveLayout.executablePath(in: realLayout())
        #expect(path == "\(root)/kv-server")
    }

    @Test func rejectsAnEntryThatEscapesUpwards() {
        var entries = realLayout()
        entries.append(ArchiveEntry(kind: .regularFile, path: "\(root)/../evil"))

        #expect(throws: BackendStagingError.unsafeArchiveEntry("\(root)/../evil")) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }

    @Test func rejectsAnEntryThatIsOnlyDotDot() {
        let entries = [ArchiveEntry(kind: .regularFile, path: "../kv-server")]
        #expect(throws: BackendStagingError.unsafeArchiveEntry("../kv-server")) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }

    @Test func rejectsAnAbsolutePath() {
        var entries = realLayout()
        entries.append(ArchiveEntry(kind: .regularFile, path: "/etc/passwd"))

        #expect(throws: BackendStagingError.unsafeArchiveEntry("/etc/passwd")) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }

    @Test func rejectsASymbolicLink() {
        var entries = realLayout()
        entries.append(ArchiveEntry(kind: .other, path: "\(root)/link"))

        #expect(throws: BackendStagingError.unsafeArchiveEntry("\(root)/link")) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }

    // A second root would mean the archive is not the single-directory release layout.
    @Test func rejectsMoreThanOneTopLevelDirectory() {
        var entries = realLayout()
        entries.append(ArchiveEntry(kind: .regularFile, path: "another-root/kv-server"))

        #expect(throws: BackendStagingError.self) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }

    @Test func rejectsAnArchiveWithoutTheExecutable() {
        let entries = [
            ArchiveEntry(kind: .directory, path: "\(root)/"),
            ArchiveEntry(kind: .regularFile, path: "\(root)/README.md")
        ]

        #expect(throws: BackendStagingError.missingExecutable("\(root)/kv-server")) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }

    @Test func rejectsAnExecutableThatIsNotARegularFile() {
        let entries = [
            ArchiveEntry(kind: .directory, path: "\(root)/"),
            ArchiveEntry(kind: .other, path: "\(root)/kv-server")
        ]

        #expect(throws: BackendStagingError.unsafeArchiveEntry("\(root)/kv-server")) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }

    @Test func rejectsAnEmptyArchive() {
        #expect(throws: BackendStagingError.self) {
            try BackendArchiveLayout.executablePath(in: [])
        }
    }

    @Test func rejectsAnEntryAtTheTopLevelWithNoDirectory() {
        let entries = [ArchiveEntry(kind: .regularFile, path: "kv-server")]
        #expect(throws: BackendStagingError.self) {
            try BackendArchiveLayout.executablePath(in: entries)
        }
    }
}

@Suite
struct ArchiveEntryParsingTests {

    // The shape `tar -tvzf` prints; the leading character is the entry type.
    @Test func readsTheTypeAndPathFromATarListing() throws {
        let listing = """
        drwxr-xr-x  0 runner staff       0 Aug 19 03:00 kv-server_v1.1.0_darwin_arm64/
        -rwxr-xr-x  0 runner staff 4485666 Aug 19 03:00 kv-server_v1.1.0_darwin_arm64/kv-server
        lrwxr-xr-x  0 runner staff       0 Aug 19 03:00 kv-server_v1.1.0_darwin_arm64/link
        """

        let entries = ArchiveEntry.parse(listing: listing)

        #expect(entries.count == 3)
        #expect(entries[0].kind == .directory)
        #expect(entries[0].path == "kv-server_v1.1.0_darwin_arm64/")
        #expect(entries[1].kind == .regularFile)
        #expect(entries[1].path == "kv-server_v1.1.0_darwin_arm64/kv-server")
        #expect(entries[2].kind == .other)
    }

    @Test func keepsPathsThatContainSpaces() throws {
        let listing = "-rw-r--r--  0 runner staff 10 Aug 19 03:00 root/a file.txt"
        let entries = ArchiveEntry.parse(listing: listing)
        #expect(entries.first?.path == "root/a file.txt")
    }

    @Test func ignoresBlankLines() throws {
        let entries = ArchiveEntry.parse(listing: "\n\n")
        #expect(entries.isEmpty)
    }
}
