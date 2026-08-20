import Foundation
import Observation
import Sparkle

// SPUUserDriver is NS_SWIFT_UI_ACTOR, so every callback already arrives on the main actor.
@MainActor
@Observable
final class AppUpdatePresenter: NSObject, SPUUserDriver {
    private(set) var phase: AppUpdatePhase = .idle

    @ObservationIgnored private var updateChoice: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var installChoice: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var acknowledge: (() -> Void)?
    @ObservationIgnored private var cancelCheck: (() -> Void)?
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0

    // MARK: - What the UI calls

    func install() {
        if let installChoice {
            self.installChoice = nil
            installChoice(.install)
            return
        }
        updateChoice?(.install)
        updateChoice = nil
    }

    func skip() {
        updateChoice?(.skip)
        updateChoice = nil
        dismiss()
    }

    func dismiss() {
        cancelCheck?()
        cancelCheck = nil
        updateChoice?(.dismiss)
        updateChoice = nil
        installChoice?(.dismiss)
        installChoice = nil
        acknowledge?()
        acknowledge = nil
        phase = .idle
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // The plan forbids silent updates, so automatic checking is never granted here.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelCheck = cancellation
        phase = .checking
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        cancelCheck = nil
        updateChoice = reply
        phase = .found(version: appcastItem.displayVersionString)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancelCheck = nil
        acknowledge = acknowledgement
        phase = .upToDate
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancelCheck = nil
        acknowledge = acknowledgement
        phase = .failed(error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelCheck = cancellation
        expectedBytes = 0
        receivedBytes = 0
        phase = .downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        phase = .downloading(fraction: min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting(fraction: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        phase = .extracting(fraction: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installChoice = reply
        phase = .readyToInstall
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        phase = .installing
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledge = acknowledgement
        phase = .idle
        acknowledgement()
        self.acknowledge = nil
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        cancelCheck = nil
        updateChoice = nil
        installChoice = nil
        acknowledge = nil
        phase = .idle
    }
}
