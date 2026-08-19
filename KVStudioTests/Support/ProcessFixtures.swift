import Foundation
import Darwin

// Fixture executables written at runtime, so the test target needs no bundled resources.
struct ProcessFixtures {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func script(named name: String, body: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try "#!/bin/sh\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // macOS spends a few hundred ms vetting a freshly written executable on its first exec, and longer
    // under load. Paying that once up front keeps the timings a test measures about the code under test.
    func launchableScript(named name: String, body: String) async throws -> URL {
        let url = try script(named: name, body: body)
        let process = Process()
        process.executableURL = url
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let marker = URL(fileURLWithPath: url.path + ".ready")
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while process.isRunning && !FileManager.default.fileExists(atPath: marker.path) {
            if ContinuousClock.now >= deadline {
                kill(process.processIdentifier, SIGKILL)
                throw ProcessFixtureError.fixtureNeverSignalledReadiness(url.path)
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        kill(process.processIdentifier, SIGKILL)
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".pid"))
        return url
    }

    // proc_pidpath reports a script's interpreter, so identifying a process by path needs a real
    // Mach-O. System binaries are arm64e and refuse to run as copies, so callers pass their own.
    func executableCopy(named name: String, of source: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func nonExecutableFile(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try "not a program\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        return url
    }

    func missingPath(named name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    // Fixtures announce themselves once their signal disposition is installed, so tests never race the shell.
    func waitUntilReady(_ script: URL, timeout: Duration = .seconds(10)) async throws {
        let marker = URL(fileURLWithPath: script.path + ".ready")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: marker.path) {
            if ContinuousClock.now >= deadline { throw ProcessFixtureError.fixtureNeverSignalledReadiness(script.path) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func pid(of script: URL) throws -> pid_t {
        let text = try String(contentsOf: URL(fileURLWithPath: script.path + ".pid"), encoding: .utf8)
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProcessFixtureError.fixtureNeverSignalledReadiness(script.path)
        }
        return pid
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum ProcessFixtureError: Error {
    case fixtureNeverSignalledReadiness(String)
}

enum FixtureScript {
    private static let announceReady = "printf %s \"$$\" > \"$0.pid\"\n: > \"$0.ready\"\n"

    static let sleepsForever = announceReady + "while true; do sleep 0.2; done\n"

    static let ignoresTermination = "trap '' TERM\n" + announceReady + "while true; do sleep 0.2; done\n"

    static let recordsArguments = "printf '%s\\n' \"$@\" > \"$0.args\"\n" + sleepsForever

    static let exitsEarly = "sleep 0.05\nexit 3\n"

    static let floodsStandardError = """
    i=0
    while [ "$i" -lt 4000 ]; do
      echo "line $i 0123456789012345678901234567890123456789012345678901234567890123456789" >&2
      i=$((i + 1))
    done
    echo "DRAIN-SENTINEL" >&2
    exit 0

    """
}
