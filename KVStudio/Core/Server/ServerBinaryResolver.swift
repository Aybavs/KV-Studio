import Foundation

struct ServerBinaryResolver: Sendable {
    static let overrideEnvironmentKey = "KV_SERVER_BINARY"

    private let overridePath: String?
    private let bundledBinary: URL?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinary: URL? = Bundle.main.url(forResource: "kv-server", withExtension: nil)
    ) {
        let override = environment[Self.overrideEnvironmentKey]
        self.overridePath = (override?.isEmpty == false) ? override : nil
        self.bundledBinary = bundledBinary
    }

    func resolve(in paths: ManagedPaths) throws -> URL {
        var checked: [String] = []
        for candidate in candidates(in: paths) {
            checked.append(candidate.path)
            if Self.isExecutableProgram(at: candidate) { return candidate }
        }
        throw ManagedServerError.binaryUnavailable(checked)
    }

    private func candidates(in paths: ManagedPaths) -> [URL] {
        var urls: [URL] = []
        if let overridePath { urls.append(URL(fileURLWithPath: overridePath)) }
        urls.append(paths.backendCurrentBinary)
        if let bundledBinary { urls.append(bundledBinary) }
        return urls
    }

    // isExecutableFile also answers true for searchable directories.
    private static func isExecutableProgram(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}
