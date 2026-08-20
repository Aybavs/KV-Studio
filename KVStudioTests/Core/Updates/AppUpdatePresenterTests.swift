import Foundation
import Sparkle
import Testing
@testable import KV_Studio

@MainActor
@Suite
struct AppUpdatePresenterTests {

    @Test func startsIdle() {
        #expect(AppUpdatePresenter().phase == .idle)
    }

    // The plan forbids silent updates, so the permission request must never grant automatic checks.
    @Test func refusesAutomaticUpdateChecks() {
        let presenter = AppUpdatePresenter()
        var response: SUUpdatePermissionResponse?

        presenter.show(SPUUpdatePermissionRequest(systemProfile: [])) { response = $0 }

        #expect(response?.automaticUpdateChecks == false)
        #expect(response?.sendSystemProfile == false)
    }

    @Test func showsCheckingWhenTheUserAsks() {
        let presenter = AppUpdatePresenter()
        presenter.showUserInitiatedUpdateCheck {}
        #expect(presenter.phase == .checking)
    }

    @Test func showsUpToDateWhenNothingIsFound() {
        let presenter = AppUpdatePresenter()
        presenter.showUserInitiatedUpdateCheck {}
        presenter.showUpdateNotFoundWithError(CocoaError(.fileNoSuchFile)) {}
        #expect(presenter.phase == .upToDate)
    }

    @Test func surfacesAnUpdaterError() {
        let presenter = AppUpdatePresenter()
        presenter.showUpdaterError(CocoaError(.fileNoSuchFile)) {}
        guard case .failed = presenter.phase else {
            Issue.record("expected a failed phase, got \(presenter.phase)")
            return
        }
    }

    @Test func reportsDownloadProgressOnlyOnceTheLengthIsKnown() {
        let presenter = AppUpdatePresenter()
        presenter.showDownloadInitiated {}
        #expect(presenter.phase == .downloading(fraction: nil))

        presenter.showDownloadDidReceiveData(ofLength: 50)
        #expect(presenter.phase == .downloading(fraction: nil))

        presenter.showDownloadDidReceiveExpectedContentLength(200)
        presenter.showDownloadDidReceiveData(ofLength: 50)
        #expect(presenter.phase == .downloading(fraction: 0.5))
    }

    @Test func neverReportsMoreThanAWholeDownload() {
        let presenter = AppUpdatePresenter()
        presenter.showDownloadInitiated {}
        presenter.showDownloadDidReceiveExpectedContentLength(10)
        presenter.showDownloadDidReceiveData(ofLength: 999)
        #expect(presenter.phase == .downloading(fraction: 1))
    }

    @Test func reportsExtractionProgress() {
        let presenter = AppUpdatePresenter()
        presenter.showDownloadDidStartExtractingUpdate()
        #expect(presenter.phase == .extracting(fraction: 0))

        presenter.showExtractionReceivedProgress(0.4)
        #expect(presenter.phase == .extracting(fraction: 0.4))
    }

    @Test func waitsForTheUserBeforeInstalling() {
        let presenter = AppUpdatePresenter()
        var choice: SPUUserUpdateChoice?
        presenter.showReady { choice = $0 }

        #expect(presenter.phase == .readyToInstall)
        #expect(choice == nil)

        presenter.install()
        #expect(choice == .install)
    }

    @Test func dismissingAnswersSparkleSoTheFlowDoesNotHang() {
        let presenter = AppUpdatePresenter()
        var choice: SPUUserUpdateChoice?
        presenter.showReady { choice = $0 }

        presenter.dismiss()

        #expect(choice == .dismiss)
        #expect(presenter.phase == .idle)
    }

    @Test func dismissingACheckCancelsIt() {
        let presenter = AppUpdatePresenter()
        var cancelled = false
        presenter.showUserInitiatedUpdateCheck { cancelled = true }

        presenter.dismiss()

        #expect(cancelled)
        #expect(presenter.phase == .idle)
    }

    @Test func dismissingAnInstallationResetsEverything() {
        let presenter = AppUpdatePresenter()
        presenter.showDownloadInitiated {}
        presenter.dismissUpdateInstallation()
        #expect(presenter.phase == .idle)
    }

    @Test func knowsWhichPhasesAreBusyAndWhichArePresentable() {
        #expect(AppUpdatePhase.checking.isBusy)
        #expect(AppUpdatePhase.installing.isBusy)
        #expect(AppUpdatePhase.readyToInstall.isBusy == false)
        #expect(AppUpdatePhase.idle.isPresentable == false)
        #expect(AppUpdatePhase.upToDate.isPresentable)
    }
}
