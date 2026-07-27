import AppKit
import SwiftUI

struct ProcessHealthView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmsInitialization = false

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader

                if case .needsAttention = manager.state {
                    attentionPanel
                }

                if manager.state.isRunning {
                    runtimePanel
                }

                trustPanel

                if !manager.recentLogs.isEmpty {
                    activityPanel
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            controlBar
                .background(.bar)
        }
        .frame(minWidth: 520, minHeight: 440)
        .navigationTitle("Local Thane")
        .alert("Initialize This Workspace?", isPresented: $confirmsInitialization) {
            Button("Cancel", role: .cancel) {}
            Button("Initialize") {
                manager.initializeWorkspace()
            }
        } message: {
            Text("Thane will create the missing workspace structure and initialize a signed core. Existing files are left in place.")
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: stateIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(stateTint)
                .frame(width: 46, height: 46)
                .background(stateTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(manager.state.label)
                    .font(.title2.weight(.semibold))

                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if case .running(let pid) = manager.state {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("PID \(pid)")
                    if let startedAt = manager.startedAt {
                        Text(startedAt, style: .timer)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var attentionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("The signed core needs an operator", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(manager.lastValidationReport?.operatorSummary
                 ?? manager.lastTerminalMessage
                 ?? "Thane refused to start because retrying cannot repair this workspace.")
                .font(.callout)
                .textSelection(.enabled)

            if let checks = manager.lastValidationReport?.integrity?.failures, !checks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks) { check in
                        integrityCheck(check)
                    }
                }
            }

            HStack {
                if manager.canInitializeWorkspace {
                    Button("Initialize Workspace", systemImage: "wand.and.sparkles") {
                        confirmsInitialization = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Reveal Core in Finder", systemImage: "folder") {
                    revealCore()
                }

                if !(manager.lastValidationReport?.integrity?.repairCommands.isEmpty ?? true) {
                    Button("Copy Repair Commands", systemImage: "doc.on.doc") {
                        copyRepairCommands()
                    }
                }

                Spacer()
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.3))
        }
    }

    private func integrityCheck(_ check: CoreIntegrityCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status == "skipped" ? "minus.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.status == "skipped" ? Color.secondary : Color.red)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.name.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline.weight(.medium))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let fix = check.fix, !fix.isEmpty {
                    Text(fix)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var runtimePanel: some View {
        GroupBox("Runtime") {
            HStack(spacing: 12) {
                metric("CPU", formatCPU(manager.processStats.cpuPercent), "cpu")
                metric("Memory", formatMemory(manager.processStats.residentMemoryMB), "memorychip")
                metric("Threads", "\(manager.processStats.threadCount)", "arrow.triangle.branch")
            }
            .padding(.top, 4)
        }
    }

    private func metric(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private var trustPanel: some View {
        GroupBox("Trust & Provenance") {
            VStack(spacing: 10) {
                trustRow(
                    title: "Instance Core",
                    detail: coreTrustDetail,
                    icon: coreTrustIcon,
                    tint: coreTrustTint
                )

                Divider()

                if let signature = manager.codeSignature {
                    trustRow(
                        title: "Managed Binary",
                        detail: signature.summary,
                        icon: signature.isVerified ? "checkmark.seal.fill" : "xmark.seal",
                        tint: signature.isVerified ? .green : .secondary
                    )
                } else {
                    trustRow(
                        title: "Managed Binary",
                        detail: manager.binaryURL?.path ?? "No binary configured",
                        icon: "questionmark.seal",
                        tint: .secondary
                    )
                }

                if manager.versionIncompatible {
                    Divider()
                    trustRow(
                        title: "Version Mismatch",
                        detail: "Binary and app major versions differ.",
                        icon: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                if manager.binarySignatureMismatch {
                    Divider()
                    trustRow(
                        title: "Signature Changed",
                        detail: "The binary on disk no longer matches the trusted signer.",
                        icon: "exclamationmark.shield.fill",
                        tint: .red
                    )
                }
            }
            .padding(.top, 4)
        }
    }

    private func trustRow(title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var activityPanel: some View {
        GroupBox("Recent Activity") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(manager.recentLogs.suffix(10))) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Image(systemName: entry.isError ? "exclamationmark.circle.fill" : "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(entry.isError ? .red : .secondary)
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var controlBar: some View {
        HStack {
            switch manager.state {
            case .running:
                Button("Restart", systemImage: "arrow.clockwise") { manager.restart() }
                Button("Stop", systemImage: "stop.fill") { manager.stop() }
            case .stopped, .crashed:
                Button("Check & Start", systemImage: "play.fill") { manager.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.binaryURL == nil)
            case .needsAttention:
                Button("Check Again", systemImage: "checkmark.shield") { manager.start() }
                    .buttonStyle(.borderedProminent)
                Button("Reveal Core", systemImage: "folder") { revealCore() }
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text("Verifying signed core…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .notConfigured:
                Text("Choose a local binary in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SettingsLink {
                Label("Local Settings", systemImage: "gearshape")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var stateIcon: String {
        switch manager.state {
        case .running: "checkmark.circle.fill"
        case .starting: "checkmark.shield"
        case .needsAttention: "exclamationmark.shield.fill"
        case .crashed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .notConfigured: "questionmark.circle"
        }
    }

    private var stateTint: Color {
        switch manager.state {
        case .running: .green
        case .starting: .blue
        case .needsAttention: .orange
        case .crashed: .red
        case .stopped, .notConfigured: .secondary
        }
    }

    private var statusDetail: String {
        switch manager.state {
        case .running:
            return manager.detectedVersion.map { "Thane \($0) is serving this Mac." }
                ?? "Thane is serving this Mac."
        case .starting:
            return "Checking the config and signed core before launch."
        case .needsAttention:
            return "Automatic restart is paused because waiting cannot repair this failure."
        case .crashed(let code):
            return "The process exited unexpectedly with code \(code)."
        case .stopped:
            return "The local agent is not running."
        case .notConfigured:
            return "Choose or install a Thane binary to get started."
        }
    }

    private var coreTrustDetail: String {
        if manager.lastValidationReport?.passed == true {
            return manager.lastValidationReport?.integrity?.corePath
                ?? "Configuration verified before launch."
        }
        if case .needsAttention = manager.state {
            return "Verification failed. Review the findings above."
        }
        return "Verified automatically before every launch."
    }

    private var coreTrustIcon: String {
        if manager.lastValidationReport?.passed == true {
            return "checkmark.shield.fill"
        }
        if case .needsAttention = manager.state {
            return "xmark.shield.fill"
        }
        return "shield"
    }

    private var coreTrustTint: Color {
        if manager.lastValidationReport?.passed == true {
            return .green
        }
        if case .needsAttention = manager.state {
            return .orange
        }
        return .secondary
    }

    private func revealCore() {
        let coreURL = manager.workspaceURL.appending(path: "core", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: coreURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([coreURL])
        } else {
            NSWorkspace.shared.open(manager.workspaceURL)
        }
    }

    private func copyRepairCommands() {
        let commands = manager.lastValidationReport?.integrity?.repairCommands ?? []
        guard !commands.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
    }

    private func formatCPU(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    private func formatMemory(_ megabytes: Double) -> String {
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes)
    }
}
