import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(AppState.self) private var appState
    @State private var versionCopyFeedback = VersionCopyFeedback.idle
    @State private var feedbackResetTask: Task<Void, Never>?

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        VStack(spacing: 20) {
            // App icon and name
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("Thane for macOS")
                    .font(.title.weight(.semibold))

                Button(action: copyVersion) {
                    HStack(spacing: 6) {
                        Text(AppVersion.aboutVersion)
                        Image(systemName: versionCopyFeedback.symbol)
                            .foregroundStyle(versionCopyFeedback.color)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .help(versionCopyFeedback.help)
                .accessibilityLabel(versionCopyFeedback.accessibilityLabel)
                .accessibilityHint("Copies the version to the clipboard")

                if let buildDate = AppVersion.buildDate {
                    Text("Built \(buildDate, style: .date) by \(AppVersion.builtBy)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // Runtime versions
            VStack(spacing: 6) {
                if appState.configurationMode == .managed,
                   let binaryVersion = manager.detectedVersion {
                    LabeledContent("Managed Thane", value: binaryVersion)
                }
                if let serverVersion = appState.connection.serverVersion {
                    LabeledContent("Protocol", value: serverVersion)
                }
                if appState.connection.serverVersion == nil && manager.detectedVersion == nil {
                    Text("Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Divider()

            // Links
            VStack(spacing: 4) {
                aboutLink("thane-agent-macos on GitHub",
                          url: "https://github.com/nugget/thane-agent-macos")
                aboutLink("thane-ai-agent on GitHub",
                          url: "https://github.com/nugget/thane-ai-agent")
            }
            .font(.caption)

            Text("\u{00A9} nugget")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 300)
        .onDisappear {
            feedbackResetTask?.cancel()
        }
    }

    private func aboutLink(_ title: String, url: String) -> some View {
        Link(title, destination: URL(string: url)!)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func copyVersion() {
        feedbackResetTask?.cancel()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        versionCopyFeedback = pasteboard.setString(AppVersion.aboutVersion, forType: .string)
            ? .copied
            : .failed

        feedbackResetTask = Task {
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            versionCopyFeedback = .idle
        }
    }
}

private enum VersionCopyFeedback {
    case idle
    case copied
    case failed

    var symbol: String {
        switch self {
        case .idle: "doc.on.doc"
        case .copied: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .copied: .green
        case .failed: .red
        }
    }

    var help: String {
        switch self {
        case .idle: "Copy Version"
        case .copied: "Copied"
        case .failed: "Copy Failed"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Copy \(AppVersion.aboutVersion)"
        case .copied: "\(AppVersion.aboutVersion) copied"
        case .failed: "Couldn’t copy \(AppVersion.aboutVersion)"
        }
    }
}
