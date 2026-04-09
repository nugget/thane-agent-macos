import SwiftUI

struct ProcessHealthView: View {
    @Environment(AppState.self) private var appState

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        VStack(spacing: 0) {
            healthHeader
            Divider()
            statsPanel
            Spacer()
            Divider()
            controlBar
        }
        .frame(minWidth: 320, minHeight: 260)
    }

    // MARK: - Health Header

    private var healthHeader: some View {
        HStack(spacing: 12) {
            // Health indicator light
            Circle()
                .fill(healthColor)
                .frame(width: 12, height: 12)
                .shadow(color: healthColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.healthStatus.rawValue)
                    .font(.headline)

                if let url = manager.binaryURL {
                    HStack(spacing: 6) {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let version = manager.detectedVersion {
                            Text(version)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }
                        if case .available(let newVersion) = appState.updateManager.state,
                           let release = appState.updateManager.availableRelease {
                            Link(destination: release.htmlURL) {
                                Text("v\(newVersion) available")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue, in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                }
            }

            Spacer()

            // PID + uptime when running
            if case .running(let pid) = manager.state {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("PID \(pid)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let startedAt = manager.startedAt {
                        Text(startedAt, style: .timer)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Stats Panel

    private var statsPanel: some View {
        Group {
            if manager.state.isRunning {
                runningStats
            } else {
                stoppedMessage
            }
        }
        .padding(16)
    }

    private var runningStats: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                StatCard(
                    label: "CPU",
                    value: formatCPU(manager.processStats.cpuPercent),
                    icon: "cpu"
                )
                StatCard(
                    label: "Memory",
                    value: formatMemory(manager.processStats.residentMemoryMB),
                    icon: "memorychip"
                )
                StatCard(
                    label: "Threads",
                    value: "\(manager.processStats.threadCount)",
                    icon: "arrow.triangle.branch"
                )
            }

            if manager.binarySignatureMismatch {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                    Text("Binary on disk has a different code signature — not auto-restarting")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if manager.recentCrashCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("\(manager.recentCrashCount) crash\(manager.recentCrashCount == 1 ? "" : "es") in the last 5 minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let sig = manager.codeSignature {
                HStack(spacing: 6) {
                    Image(systemName: sig.isVerified ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(sig.isVerified ? .green : .secondary)
                    Text(sig.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stoppedMessage: some View {
        VStack(spacing: 8) {
            Image(systemName: stoppedIcon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text(stoppedLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if case .crashed(let code) = manager.state {
                Text("Exit code: \(code)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack {
            switch manager.state {
            case .running:
                Button("Restart") { manager.restart() }
                Button("Stop", role: .destructive) { manager.stop() }
            case .stopped, .crashed:
                Button("Start") { manager.start() }
                    .disabled(manager.binaryURL == nil)
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text("Starting...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .notConfigured:
                Text("Binary not configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Helpers

    private var healthColor: Color {
        switch manager.healthStatus {
        case .healthy:   .green
        case .degraded:  .yellow
        case .crashLoop: .red
        case .stopped:   .secondary
        }
    }

    private var stoppedIcon: String {
        switch manager.state {
        case .crashed:       "exclamationmark.triangle"
        case .notConfigured: "questionmark.circle"
        default:             "stop.circle"
        }
    }

    private var stoppedLabel: String {
        switch manager.state {
        case .crashed:       "Process crashed"
        case .notConfigured: "No binary configured"
        default:             "Process stopped"
        }
    }

    private func formatCPU(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    private func formatMemory(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
