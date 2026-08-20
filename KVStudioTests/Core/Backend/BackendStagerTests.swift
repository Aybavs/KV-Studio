import CryptoKit
import Foundation
import Testing
@testable import KV_Studio

// Serves archives from a directory the test built, so the whole verify-then-extract path runs for
// real without touching the network.
private struct LocalDownloader: ReleaseAssetDownloading {
    let files: [String: URL]

    func download(_ asset: BackendReleaseAsset, to destination: URL) async throws {
        guard let source = files[asset.name] else { throw BackendStagingError.archiveUnreadable("no such asset") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

@Suite
struct BackendStagerTests {

    private let root = "kv-server_v1.1.0_darwin_arm64"

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-stager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tar(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: file))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Builds a release-shaped archive plus its SHA256SUMS, and returns a stager wired to them.
    private func makeRelease(
        in workspace: URL,
        corruptChecksum: Bool = false,
        extraEntries: [String] = []
    ) throws -> (BackendRelease, LocalDownloader) {
        let payload = workspace.appendingPathComponent(root, isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho backend\n".utf8).write(to: payload.appendingPathComponent("kv-server"))
        try Data("readme\n".utf8).write(to: payload.appendingPathComponent("README.md"))
        for name in extraEntries {
            try Data("x\n".utf8).write(to: payload.appendingPathComponent(name))
        }

        let archiveName = "kv-server_v1.1.0_darwin_arm64.tar.gz"
        try tar(["-czf", archiveName, root], in: workspace)
        let archive = workspace.appendingPathComponent(archiveName)

        let digest = corruptChecksum ? String(repeating: "0", count: 64) : try sha256(of: archive)
        let sums = workspace.appendingPathComponent("SHA256SUMS")
        try Data("\(digest)  \(archiveName)\n".utf8).write(to: sums)

        let release = BackendRelease(
            version: SemanticVersion(string: "1.1.0")!,
            archive: BackendReleaseAsset(name: archiveName, url: URL(string: "https://example.invalid/a")!, size: 1),
            checksums: BackendReleaseAsset(name: "SHA256SUMS", url: URL(string: "https://example.invalid/s")!, size: 1)
        )
        return (release, LocalDownloader(files: [archiveName: archive, "SHA256SUMS": sums]))
    }

    @Test func stagesAVerifiedBackend() async throws {
        let workspace = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let paths = ManagedPaths(root: try makeDirectory())
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (release, downloader) = try makeRelease(in: workspace)

        let staged = try await BackendStager(paths: paths, downloader: downloader).stage(release)

        #expect(staged.version == SemanticVersion(string: "1.1.0"))
        #expect(FileManager.default.isExecutableFile(atPath: staged.executable.path))
        #expect(staged.executable.lastPathComponent == "kv-server")

        let metadata = try JSONSerialization.jsonObject(with: try Data(contentsOf: staged.metadata)) as? [String: String]
        #expect(metadata?["version"] == "1.1.0")
        #expect(metadata?["sha256"] == staged.sha256)
    }

    @Test func refusesAnArchiveWhoseChecksumDoesNotMatch() async throws {
        let workspace = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let paths = ManagedPaths(root: try makeDirectory())
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (release, downloader) = try makeRelease(in: workspace, corruptChecksum: true)

        await #expect(throws: BackendStagingError.self) {
            try await BackendStager(paths: paths, downloader: downloader).stage(release)
        }
        // Nothing may be staged from an archive that failed verification.
        let staged = paths.backendStagingDir.appendingPathComponent("kv-server")
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test func refusesAnArchiveTheChecksumFileDoesNotList() async throws {
        let workspace = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let paths = ManagedPaths(root: try makeDirectory())
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var (release, downloader) = try makeRelease(in: workspace)
        let sums = workspace.appendingPathComponent("SHA256SUMS")
        try Data("\(String(repeating: "a", count: 64))  something-else.tar.gz\n".utf8).write(to: sums)
        downloader = LocalDownloader(files: downloader.files)

        await #expect(throws: BackendStagingError.checksumMissing(release.archive.name)) {
            try await BackendStager(paths: paths, downloader: downloader).stage(release)
        }
    }

    @Test func extractsOnlyTheExecutableAndNotTheRestOfTheArchive() async throws {
        let workspace = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let paths = ManagedPaths(root: try makeDirectory())
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (release, downloader) = try makeRelease(in: workspace, extraEntries: ["NOTES.txt"])

        let staged = try await BackendStager(paths: paths, downloader: downloader).stage(release)

        let stagedDirectory = try FileManager.default.contentsOfDirectory(atPath: paths.backendStagingDir.path)
        #expect(stagedDirectory.sorted() == ["kv-server", "metadata.json"])
        #expect(staged.executable.lastPathComponent == "kv-server")
    }

    @Test func leavesNoWorkingDirectoryBehind() async throws {
        let workspace = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let paths = ManagedPaths(root: try makeDirectory())
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (release, downloader) = try makeRelease(in: workspace)

        _ = try await BackendStager(paths: paths, downloader: downloader).stage(release)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: paths.backendStagingDir.path)
        #expect(remaining.contains(where: { $0.hasPrefix("work-") }) == false)
    }
}
