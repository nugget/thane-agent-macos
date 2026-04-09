import SwiftUI

struct AboutView: View {
    @Environment(AppState.self) private var appState

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

                Text("Version \(AppVersion.current)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Runtime versions
            VStack(spacing: 6) {
                if let serverVersion = appState.connection.serverVersion {
                    LabeledContent("Server", value: serverVersion)
                }
                if let binaryVersion = manager.detectedVersion {
                    LabeledContent("Local Binary", value: binaryVersion)
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
                Link("thane-agent-macos on GitHub",
                     destination: URL(string: "https://github.com/nugget/thane-agent-macos")!)
                Link("thane-ai-agent on GitHub",
                     destination: URL(string: "https://github.com/nugget/thane-ai-agent")!)
            }
            .font(.caption)

            Text("\u{00A9} nugget")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 300)
    }
}
