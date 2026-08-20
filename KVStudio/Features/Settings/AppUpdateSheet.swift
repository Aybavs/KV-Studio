import SwiftUI

// KV Studio's own update UI: Sparkle never shows its standard windows because this app supplies
// its own user driver.
struct AppUpdateSheet: View {
    let presenter: AppUpdatePresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let fraction {
                ProgressView(value: fraction)
            } else if presenter.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            HStack {
                Spacer()
                Button(dismissTitle) { presenter.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("update.dismiss")
                if showsInstall {
                    Button("Install and Relaunch") { presenter.install() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("update.install")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .accessibilityIdentifier("update.sheet")
    }

    private var title: String {
        switch presenter.phase {
        case .idle, .checking: return "Checking for Updates…"
        case .upToDate: return "KV Studio is up to date"
        case .found(let version): return "KV Studio \(version) is available"
        case .downloading: return "Downloading update…"
        case .extracting: return "Preparing update…"
        case .readyToInstall: return "Ready to install"
        case .installing: return "Installing…"
        case .failed: return "Update failed"
        }
    }

    private var detail: String? {
        switch presenter.phase {
        case .failed(let message): return message
        case .readyToInstall: return "KV Studio will relaunch. The managed server is stopped first."
        case .found: return "Downloading does not install anything until you choose to."
        default: return nil
        }
    }

    private var fraction: Double? {
        switch presenter.phase {
        case .downloading(let value): return value
        case .extracting(let value): return value
        default: return nil
        }
    }

    private var showsInstall: Bool {
        switch presenter.phase {
        case .found, .readyToInstall: return true
        default: return false
        }
    }

    private var dismissTitle: String {
        switch presenter.phase {
        case .upToDate, .failed: return "Close"
        default: return "Not Now"
        }
    }
}
