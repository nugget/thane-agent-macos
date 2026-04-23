import SwiftUI

// MARK: - App Update Settings Section

struct AppUpdateSettingsSection: View {
    @Environment(AppState.self) private var appState

    private var manager: AppUpdateManager { appState.appUpdateManager }

    var body: some View {
        @Bindable var mgr = manager

        LabeledContent("Current version", value: AppVersion.displayVersion)

        Toggle("Check for updates automatically", isOn: $mgr.autoUpdateEnabled)
        Toggle("Include pre-release versions", isOn: $mgr.includePreReleases)

        HStack {
            Button("Check Now") {
                Task {
                    await manager.checkForUpdate(currentVersion: AppVersion.current)
                }
            }
            .disabled(isCheckDisabled)

            Spacer()

            if let date = manager.lastCheckDate {
                Text("Last checked \(date, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        stateContent
    }

    private var isCheckDisabled: Bool {
        switch manager.state {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch manager.state {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .available(let version):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Version \(version) available")
                        .font(.subheadline.weight(.medium))
                }

                if let release = manager.availableRelease,
                   let changelog = release.changelog,
                   !changelog.isEmpty {
                    ScrollView {
                        Text(changelog)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }

                HStack {
                    if let release = manager.availableRelease {
                        Link("Release notes", destination: release.htmlURL)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Install and Restart") { manager.downloadAndInstall() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: progress).controlSize(.small)
                        .frame(maxWidth: .infinity)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { manager.cancelDownload() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying signature and checksum...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing and restarting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Update failed")
                        .font(.subheadline.weight(.medium))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Retry") {
                    Task {
                        await manager.checkForUpdate(currentVersion: AppVersion.current)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
