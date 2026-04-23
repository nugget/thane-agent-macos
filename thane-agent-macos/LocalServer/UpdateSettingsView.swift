import SwiftUI

// MARK: - Update Settings Section

struct UpdateSettingsSection: View {
    @Environment(AppState.self) private var appState

    private var manager: UpdateManager { appState.updateManager }
    private var binaryManager: BinaryManager { appState.binaryManager }

    var body: some View {
        @Bindable var mgr = manager

        Toggle("Check for updates automatically", isOn: $mgr.autoUpdateEnabled)
        Toggle("Include pre-release versions", isOn: $mgr.includePreReleases)

        HStack {
            Button("Check Now") {
                Task {
                    await manager.checkForUpdate(currentVersion: binaryManager.detectedVersion)
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

                if let release = manager.availableRelease {
                    if let changelog = release.changelog, !changelog.isEmpty {
                        Text(String(changelog.prefix(300)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }

                    HStack(spacing: 12) {
                        Button("Download & Install") {
                            manager.downloadAndInstall(binaryManager: binaryManager)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Link("Release Notes", destination: release.htmlURL)
                            .font(.caption)
                    }
                }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
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
                Text("Verifying checksum...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installed(let version):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Version \(version) installed")
                    .font(.subheadline.weight(.medium))
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
                        await manager.checkForUpdate(currentVersion: binaryManager.detectedVersion)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Code Signature Section

struct CodeSignatureSection: View {
    @Environment(AppState.self) private var appState

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        if manager.binaryURL == nil {
            Text("No binary selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let sig = manager.codeSignature {
            // Binary code signature
            HStack(spacing: 6) {
                Image(systemName: sig.isVerified ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundStyle(sig.isVerified ? .green : .secondary)
                Text(sig.summary)
                    .font(.subheadline)
            }

            ForEach(Array(sig.details.enumerated()), id: \.offset) { _, detail in
                LabeledContent(detail.label, value: detail.value)
                    .font(.caption)
            }

            // Install provenance
            provenanceRow

            HStack {
                Spacer()
                Button("Refresh") {
                    Task { await manager.refreshCodeSignature() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Inspecting signature...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var provenanceRow: some View {
        let provenance = manager.installProvenance
        switch provenance {
        case .notarizedPackage:
            LabeledContent("Installer Package", value: "Notarized")
                .font(.caption)
                .foregroundStyle(.green)
        case .signedPackage:
            LabeledContent("Installer Package", value: "Signed")
                .font(.caption)
        case .unsignedPackage:
            LabeledContent("Installer Package", value: "Unsigned")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .manual:
            LabeledContent("Install Source", value: "External update")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unknown:
            LabeledContent("Install Source", value: "Unknown")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
