import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel

    init(paths: ManagedPaths) {
        _viewModel = State(initialValue: SettingsViewModel(paths: paths))
    }

    init(viewModel: SettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $viewModel.appearance) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .accessibilityIdentifier("settings.appearance")
                Toggle("Reopen last connection", isOn: $viewModel.reopenLastConnection)
                    .accessibilityIdentifier("settings.reopen")
            }

            Section("Updates") {
                Toggle("Auto-check for updates", isOn: $viewModel.autoCheckUpdates)
                    .accessibilityIdentifier("settings.autoCheck")
                Button("Check for Updates") { viewModel.checkForUpdates() }
                    .disabled(!viewModel.canCheckForUpdates)
                    .accessibilityIdentifier("settings.checkUpdates")
                if !viewModel.canCheckForUpdates {
                    Text("This build has no update feed, so it cannot check.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.updatesUnavailable")
                }
            }

            Section("Backend") {
                LabeledContent("Installed", value: viewModel.managedInstalledDescription)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("settings.installedVersion")
                LabeledContent("Bundled", value: viewModel.bundledVersion)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("settings.bundledVersion")
                LabeledContent("Recommended", value: viewModel.recommendedVersion)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("settings.recommendedVersion")
                Button("Reveal Application Support") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: viewModel.applicationSupportPath)
                }
                .accessibilityIdentifier("settings.reveal")
                Text(viewModel.applicationSupportPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.appSupportPath")
            }

            Section("About") {
                LabeledContent("Studio version", value: viewModel.studioVersion)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("settings.studioVersion")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 600)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.view")
    }
}
