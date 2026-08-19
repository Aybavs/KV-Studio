import Darwin
import Foundation

// The seam over ManagedServerController, which is settled and unmodified. It owns the record
// store alongside the controller it wraps, so the post-stop truth is read from the same paths.
struct ManagedServerHost: ManagedServerHosting {

    private let controller: ManagedServerController
    private let records: ManagedServerRecordStore

    init(paths: ManagedPaths) {
        self.init(controller: ManagedServerController(paths: paths), paths: paths)
    }

    init(controller: ManagedServerController, paths: ManagedPaths) {
        self.controller = controller
        self.records = ManagedServerRecordStore(paths: paths)
    }

    func start() async throws -> ManagedServerHandle {
        let pid = try await controller.start()
        guard let endpoint = await controller.endpoint else {
            throw ManagedServerError.launchFailed("started pid \(pid) without an endpoint")
        }
        return ManagedServerHandle(pid: pid, endpoint: endpoint)
    }

    // The controller reports `.stopped` even when it deliberately preserved the record of a
    // process it could not kill; that record is what says whether the process outlived the stop.
    func stop() async -> ManagedServerStopOutcome {
        await controller.stop()
        guard let record = records.load(), record.identifiesLiveProcess, let pid = record.pid else {
            return .stopped
        }
        return .unreclaimed(pid)
    }
}
