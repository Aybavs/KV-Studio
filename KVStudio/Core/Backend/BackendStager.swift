import CryptoKit
import Foundation

protocol ReleaseAssetDownloading: Sendable {
    func download(_ asset: BackendReleaseAsset, to destination: URL) async throws
}

struct BackendStagedStaging: Equatable, Sendable {
    let executable: URL
    let metadata: URL
    let version: SemanticVersion
    let sha256: String
}

// Verification happens before the archive is ever handed to tar, and only the one expected member
// is extracted. Nothing here executes what it downloaded.
struct BackendStager: Sendable {
    let paths: ManagedPaths
    let downloader: any ReleaseAssetDownloading

    init(paths: ManagedPaths, downloader: any ReleaseAssetDownloading = URLSessionAssetDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    func stage(_ release: BackendRelease) async throws -> BackendStagedStaging {
        let work = paths.backendStagingDir.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try create(work)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent(release.archive.name)
        let sums = work.appendingPathComponent(release.checksums.name)
        try await downloader.download(release.archive, to: archive)
        try await downloader.download(release.checksums, to: sums)

        let manifest = try ChecksumManifest(data: try read(sums))
        guard let expected = manifest.digest(for: release.archive.name) else {
            throw BackendStagingError.checksumMissing(release.archive.name)
        }
        let actual = try digest(of: archive)
        guard actual == expected else {
            throw BackendStagingError.checksumMismatch(expected: expected, actual: actual)
        }

        let member = try BackendArchiveLayout.executablePath(in: try listEntries(of: archive))
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try create(extracted)
        try extract(member: member, from: archive, into: extracted)

        return try install(
            extracted.appendingPathComponent(member),
            version: release.version,
            sha256: actual
        )
    }

    // MARK: - Steps

    private func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func listEntries(of archive: URL) throws -> [ArchiveEntry] {
        let listing = try run(["-tvzf", archive.path])
        return ArchiveEntry.parse(listing: listing)
    }

    private func extract(member: String, from archive: URL, into directory: URL) throws {
        _ = try run(["-xzf", archive.path, "-C", directory.path, member])
    }

    private func install(_ executable: URL, version: SemanticVersion, sha256: String) throws -> BackendStagedStaging {
        let manager = FileManager.default
        guard manager.fileExists(atPath: executable.path) else {
            throw BackendStagingError.missingExecutable(executable.lastPathComponent)
        }

        let destination = paths.backendStagingDir.appendingPathComponent(BackendArchiveLayout.executableName)
        let metadata = paths.backendStagingDir.appendingPathComponent("metadata.json")
        do {
            try create(paths.backendStagingDir)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: executable, to: destination)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            let payload = try JSONSerialization.data(
                withJSONObject: ["version": version.description, "sha256": sha256],
                options: [.sortedKeys, .prettyPrinted]
            )
            try payload.write(to: metadata, options: .atomic)
        } catch let error as BackendStagingError {
            throw error
        } catch {
            throw BackendStagingError.stagingFailed(error.localizedDescription)
        }

        return BackendStagedStaging(executable: destination, metadata: metadata, version: version, sha256: sha256)
    }

    // MARK: - Plumbing

    private func read(_ file: URL) throws -> Data {
        do { return try Data(contentsOf: file) } catch {
            throw BackendStagingError.checksumsUnreadable
        }
    }

    private func create(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BackendStagingError.stagingFailed(error.localizedDescription)
        }
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw BackendStagingError.archiveUnreadable(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackendStagingError.archiveUnreadable("tar exited with status \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct URLSessionAssetDownloader: ReleaseAssetDownloading {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func download(_ asset: BackendReleaseAsset, to destination: URL) async throws {
        let (temporary, _) = try await session.download(from: asset.url)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
