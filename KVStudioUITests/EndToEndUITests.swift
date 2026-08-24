import AppKit
import Darwin
import XCTest

extension XCUIApplication {
    /// Matches on identifier alone, whatever element type SwiftUI happened to produce.
    func node(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

/// The nine scenarios the plan names, driven through the real app.
///
/// Everything is matched by accessibility identifier through `node(_:)` rather than by element type:
/// how SwiftUI maps a view to an AX element is an implementation detail that has already changed
/// under this suite once.
///
/// Each test gets its own Application Support directory through `KV_STUDIO_SUPPORT_DIR`, so a run
/// can never read or damage real user data, and scenarios cannot leak state into each other.
///
/// Scenarios that need a managed server also need a real `kv-server`. They resolve it the same way
/// the integration suites do and skip with a message when it is absent, rather than failing or
/// silently passing.
@MainActor
final class EndToEndUITests: XCTestCase {

    private var supportDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // An instance the runner did not launch cannot be terminated if a debugger holds it, and
        // every launch afterwards drives that app instead of a configured one. Say so in one second
        // rather than through nine tests of timeouts.
        let running = XCUIApplication()
        if running.state != .notRunning {
            _ = running.wait(for: .notRunning, timeout: 10)
        }
        try XCTSkipUnless(
            running.state == .notRunning,
            "A KV Studio instance is already running; stop it, including an Xcode Run session, since a debugger-attached app refuses termination."
        )
        supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for process in spawned { process.terminate() }
        spawned.removeAll()
        try? FileManager.default.removeItem(at: supportDirectory)
    }

    private var spawned: [Process] = []

    // MARK: - Harness

    private func launchApp(backend: URL? = nil, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        // terminate() kills the app before it can stop the server it started, which would outlive
        // the run and take a port with it; quit the way the app expects, then reap what is left.
        let record = supportDirectory.appendingPathComponent("state/managed-server.json")
        addTeardownBlock {
            if app.state != .notRunning {
                app.typeKey("q", modifierFlags: .command)
                _ = app.wait(for: .notRunning, timeout: 20)
                app.terminate()
            }
            if let data = try? Data(contentsOf: record),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = json["pid"] as? Int, kill(pid_t(pid), 0) == 0 {
                kill(pid_t(pid), SIGTERM)
            }
        }
        app.launchEnvironment["KV_STUDIO_SUPPORT_DIR"] = supportDirectory.path
        if let backend { app.launchEnvironment["KV_SERVER_BINARY"] = backend.path }
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launch()
        // Each run costs minutes of someone's screen, so a failure carries the tree that caused it.
        addTeardownBlock { [weak self] in
            guard (self?.testRun?.failureCount ?? 0) > 0 else { return }
            print("KVUI-TREE-BEGIN\n\(app.debugDescription)\nKVUI-TREE-END")
        }
        XCTAssertTrue(app.node("app.title").waitForExistence(timeout: 30), "the app never presented its shell")
        return app
    }

    /// Mirrors the integration suites: `KV_SERVER_BINARY`, then `<repo>/.build/kv-server`.
    private func backendBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["KV_SERVER_BINARY"] {
            return URL(fileURLWithPath: override)
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { root.deleteLastPathComponent() }
        let built = root.appendingPathComponent(".build/kv-server")
        guard FileManager.default.isExecutableFile(atPath: built.path) else {
            throw XCTSkip("No kv-server. Run scripts/build-test-backend.sh, or set KV_SERVER_BINARY.")
        }
        return built
    }

    private func startExternalServer(_ binary: URL, port: UInt16, appendOnly: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = binary
        var arguments = ["--host", "127.0.0.1", "--port", String(port), "--loglevel", "error"]
        if appendOnly {
            arguments += ["--appendonly", "--appendfilename", supportDirectory.appendingPathComponent("external.aof").path]
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)
        try waitUntilListening(port: port, process: process)
        return process
    }

    private func waitUntilListening(port: UInt16, process: Process) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard process.isRunning else {
                throw PortError.failed("the server exited before it listened on \(port); status \(process.terminationStatus)", 0)
            }
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(descriptor) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected == 0 { return }
            usleep(100_000)
        }
        throw PortError.failed("the server never listened on \(port)", 0)
    }

    /// The runner is sandboxed with network.client only, so bind() is denied outright. A port is
    /// taken to be free when connecting to it is refused.
    private func freePort() throws -> UInt16 {
        for _ in 0..<64 {
            let candidate = UInt16.random(in: 49152...65535)
            if !isListening(port: candidate) { return candidate }
        }
        throw PortError.failed("no free port found in the ephemeral range", 0)
    }

    private func isListening(port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private enum PortError: Error, CustomStringConvertible {
        case failed(String, Int32)
        var description: String {
            guard case .failed(let step, let code) = self else { return "" }
            return code == 0 ? "cannot allocate a test port: \(step)"
                             : "cannot allocate a test port: \(step) failed, errno \(code) (\(String(cString: strerror(code))))"
        }
    }

    private func usePreferredLocalPort(_ port: UInt16) throws {
        let state = supportDirectory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let preferences: [String: Any] = [
            "localBindHost": "127.0.0.1",
            "localPort": Int(port),
            "appearance": "system",
            "reopenLastConnection": true,
            "autoCheckUpdates": false
        ]
        try JSONSerialization.data(withJSONObject: preferences)
            .write(to: state.appendingPathComponent("preferences.json"))
    }

    private func connectToExisting(_ app: XCUIApplication, port: UInt16) {
        let host = app.textFields["connection.existing.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        type("127.0.0.1", into: host)
        type(String(port), into: app.textFields["connection.existing.port"])
        app.buttons["connection.existing.connect"].click()
    }

    /// Fields arrive prefilled, so typing into one appends rather than replaces. Synthesised
    /// keystrokes also go through the active keyboard layout — on a Turkish one the i in
    /// "e2e:binary" never arrives — so the text is pasted, which no layout can reinterpret.
    private func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, text, "the field did not take the text pasted into it", file: file, line: line)
    }

    // MARK: - 1. First launch through a key's whole life

    func testFirstLaunchCreateEditPreserveTTLAndDelete() throws {
        let binary = try backendBinary()
        try usePreferredLocalPort(try freePort())
        let app = launchApp(backend: binary)

        app.buttons["connection.local.start"].click()
        XCTAssertTrue(app.node("browser.view").waitForExistence(timeout: 60), "never reached the Browser")

        app.buttons["browser.newKeyButton"].click()
        XCTAssertTrue(app.node("newKey.view").waitForExistence(timeout: 10))
        type("e2e:key", into: app.textFields["newKey.keyField"])
        type("first", into: app.textViews["newKey.valueField"])
        // The preserve-TTL control only exists for a key that actually expires.
        app.popUpButtons["newKey.expiryPicker"].click()
        app.menuItems["Seconds"].click()
        type("600", into: app.textFields["newKey.expiryValueField"])
        app.buttons["newKey.createButton"].click()

        let row = app.node("browser.row.e2e:key")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the created key never appeared")
        row.click()
        XCTAssertTrue(app.node("browser.detail.loaded").waitForExistence(timeout: 10))

        // Editing with Preserve TTL on must not drop the remaining expiry.
        let preserve = app.switches["browser.preserveTTLToggle"]
        XCTAssertTrue(preserve.waitForExistence(timeout: 10), "the preserve-TTL control is missing")
        XCTAssertEqual(String(describing: preserve.value ?? ""), "1", "preserve TTL should default to on for an expiring key")
        type("second", into: app.textViews["browser.editField"])
        app.buttons["browser.saveButton"].click()

        let ttl = app.node("browser.detail.ttl")
        XCTAssertTrue(ttl.waitForExistence(timeout: 10))
        XCTAssertNotEqual(ttl.value as? String, "No expiry", "saving with Preserve TTL on dropped the expiry")

        app.buttons["browser.deleteButton"].click()
        app.buttons["browser.delete.confirm"].click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 15), "the deleted key is still listed")
    }

    // MARK: - 2. An existing compatible server

    func testConnectsToAnExistingCompatibleServer() throws {
        let binary = try backendBinary()
        let port = try freePort()
        _ = try startExternalServer(binary, port: port)

        let app = launchApp()
        connectToExisting(app, port: port)

        XCTAssertTrue(app.node("browser.view").waitForExistence(timeout: 60))
        app.node("sidebar.server").click()
        XCTAssertTrue(app.node("server.existingView").waitForExistence(timeout: 10))
        XCTAssertTrue(app.node("server.externalBadge").exists, "an external server must be badged as external")
    }

    // MARK: - 3. An incompatible old server

    func testRejectsAServerThatDoesNotSpeakTheRequiredCommands() throws {
        // A listener that answers PING and then refuses DBSIZE is exactly a 1.0.x backend.
        let port = try freePort()
        let stub = Process()
        stub.executableURL = URL(fileURLWithPath: "/bin/sh")
        stub.arguments = ["-c", """
        while :; do
          printf '+PONG\\r\\n-ERR unknown command '"'"'DBSIZE'"'"'\\r\\n' | nc -l 127.0.0.1 \(port) >/dev/null 2>&1
        done
        """]
        try stub.run()
        spawned.append(stub)
        // Without this the scenario passes when nothing is listening at all, which is a different
        // rejection than the one it claims to cover.
        try waitUntilListening(port: port, process: stub)

        let app = launchApp()
        connectToExisting(app, port: port)

        let error = app.node("connection.error")
        XCTAssertTrue(error.waitForExistence(timeout: 30), "no compatibility error was shown")
        XCTAssertEqual(error.value as? String, "Incompatible server", "the server was refused for the wrong reason")
        XCTAssertFalse(app.node("browser.view").exists, "an incompatible server must not reach the Browser")
    }

    // MARK: - 4. A binary value is shown as hex

    func testBinaryValueIsShownInHex() throws {
        let binary = try backendBinary()
        let port = try freePort()
        _ = try startExternalServer(binary, port: port)

        let app = launchApp()
        connectToExisting(app, port: port)
        XCTAssertTrue(app.node("browser.view").waitForExistence(timeout: 60))

        app.buttons["browser.newKeyButton"].click()
        XCTAssertTrue(app.node("newKey.view").waitForExistence(timeout: 10))
        type("e2e:binary", into: app.textFields["newKey.keyField"])
        app.radioGroups["newKey.valueModePicker"].radioButtons["Hex"].click()
        // Hex mode swaps the editor for a single-line field, so this is not the text-mode control.
        let hexValue = app.textFields["newKey.valueField"]
        XCTAssertTrue(hexValue.waitForExistence(timeout: 10), "the hex value field never appeared")
        type("00ff10", into: hexValue)
        app.buttons["newKey.createButton"].click()

        let row = app.node("browser.row.e2e:binary")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        // Auto mode must land on Hex by itself for bytes that are not text.
        XCTAssertTrue(app.node("valueViewer.hex").waitForExistence(timeout: 10), "binary value did not display as hex")
    }

    // MARK: - 5. Search runs server-side

    func testSearchFiltersWithScanMatch() throws {
        let binary = try backendBinary()
        let port = try freePort()
        _ = try startExternalServer(binary, port: port)

        let app = launchApp()
        connectToExisting(app, port: port)
        XCTAssertTrue(app.node("browser.view").waitForExistence(timeout: 60))

        for name in ["alpha:1", "beta:1"] {
            app.buttons["browser.newKeyButton"].click()
            XCTAssertTrue(app.node("newKey.view").waitForExistence(timeout: 10))
            type(name, into: app.textFields["newKey.keyField"])
            type("v", into: app.textViews["newKey.valueField"])
            app.buttons["newKey.createButton"].click()
            XCTAssertTrue(app.node("browser.row.\(name)").waitForExistence(timeout: 15))
        }

        let search = app.textFields["browser.searchField"]
        type("alpha", into: search)

        XCTAssertTrue(app.node("browser.row.alpha:1").waitForExistence(timeout: 15))
        XCTAssertTrue(app.node("browser.row.beta:1").waitForNonExistence(timeout: 15), "search did not filter")
    }

    // MARK: - 6. A managed restart keeps AOF data

    func testManagedServerRestartKeepsData() throws {
        let binary = try backendBinary()
        try usePreferredLocalPort(try freePort())
        let app = launchApp(backend: binary)

        app.buttons["connection.local.start"].click()
        XCTAssertTrue(app.node("browser.view").waitForExistence(timeout: 60))

        app.buttons["browser.newKeyButton"].click()
        XCTAssertTrue(app.node("newKey.view").waitForExistence(timeout: 10))
        type("e2e:durable", into: app.textFields["newKey.keyField"])
        type("survives", into: app.textViews["newKey.valueField"])
        app.buttons["newKey.createButton"].click()
        XCTAssertTrue(app.node("browser.row.e2e:durable").waitForExistence(timeout: 15))

        app.node("sidebar.server").click()
        XCTAssertTrue(app.node("server.managedView").waitForExistence(timeout: 10))
        app.buttons["server.restartButton"].click()

        app.node("sidebar.browser").click()
        XCTAssertTrue(
            app.node("browser.row.e2e:durable").waitForExistence(timeout: 60),
            "the key did not survive a managed restart, so the append-only file was not replayed"
        )
    }

    // MARK: - 7. Quitting stops the managed backend

    func testQuittingStopsTheManagedBackend() throws {
        let binary = try backendBinary()
        try usePreferredLocalPort(try freePort())
        let app = launchApp(backend: binary)

        app.buttons["connection.local.start"].click()
        XCTAssertTrue(app.node("browser.view").waitForExistence(timeout: 60))

        let record = supportDirectory.appendingPathComponent("state/managed-server.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "no managed server was recorded")
        let pid = try managedServerPID(from: record)

        // Quit the way a person does: terminate() can kill the app before it has stopped anything.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 60), "the app did not quit")

        let deadline = Date().addingTimeInterval(30)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(200_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the managed server outlived the app that started it")
    }

    private func managedServerPID(from record: URL) throws -> pid_t {
        let data = try Data(contentsOf: record)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return pid_t(try XCTUnwrap(json["pid"] as? Int))
    }

    // MARK: - 8. Someone else already owns the port

    func testPortConflictOffersTheExistingServerInsteadOfClaimingIt() throws {
        let binary = try backendBinary()
        let port = try freePort()
        let squatter = try startExternalServer(binary, port: port)

        // Point the managed server at the squatted port through the same preferences file the app
        // reads, rather than inventing a production environment variable for a test.
        try usePreferredLocalPort(port)
        let app = launchApp(backend: binary)
        app.buttons["connection.local.start"].click()

        XCTAssertTrue(app.node("connection.error").waitForExistence(timeout: 60), "no port conflict was reported")
        XCTAssertTrue(squatter.isRunning, "KV Studio must never kill a server it does not own")
    }

    // MARK: - 10. Leaving a server Studio did not start

    func testDisconnectingFromAnExternalServerReturnsToTheConnectionScreen() throws {
        let binary = try backendBinary()
        let port = try freePort()
        let external = try startExternalServer(binary, port: port)

        let app = launchApp()
        connectToExisting(app, port: port)
        XCTAssertTrue(app.node("browser.view").waitForExistence(timeout: 60))

        app.node("sidebar.server").click()
        XCTAssertTrue(app.node("server.existingView").waitForExistence(timeout: 15))
        app.buttons["server.disconnectButton"].click()

        XCTAssertTrue(
            app.staticTexts["connection.onboarding.title"].waitForExistence(timeout: 15),
            "disconnecting left nowhere to go"
        )
        XCTAssertTrue(external.isRunning, "disconnecting must not stop a server Studio does not own")
    }

    // MARK: - 9. A bad backend update rolls back

    func testABadBackendUpdateRollsBackToThePreviousOne() throws {
        let binary = try backendBinary()

        // current = a working backend; staging = one that cannot run. Activation must restore current.
        let current = supportDirectory.appendingPathComponent("backend/current", isDirectory: true)
        let staging = supportDirectory.appendingPathComponent("backend/staging", isDirectory: true)
        for directory in [current, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: binary, to: current.appendingPathComponent("kv-server"))
        try JSONSerialization.data(withJSONObject: ["version": "1.1.0", "sha256": String(repeating: "a", count: 64)])
            .write(to: current.appendingPathComponent("metadata.json"))

        let broken = staging.appendingPathComponent("kv-server")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        try JSONSerialization.data(withJSONObject: ["version": "9.9.9", "sha256": String(repeating: "b", count: 64)])
            .write(to: staging.appendingPathComponent("metadata.json"))

        let app = launchApp()
        app.node("sidebar.settings").click()
        XCTAssertTrue(app.node("settings.view").waitForExistence(timeout: 15))

        // The staged backend is activated at launch; a broken one must be rolled back, leaving the
        // working 1.1.0 installed rather than the 9.9.9 that could not start.
        let installed = app.node("settings.installedVersion")
        XCTAssertTrue(installed.waitForExistence(timeout: 30))
        let restored = current.appendingPathComponent("metadata.json")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: restored)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? String, "1.1.0", "the broken backend was not rolled back")
    }
}
