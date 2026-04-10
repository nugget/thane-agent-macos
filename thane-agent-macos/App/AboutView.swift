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

                Text(AppVersion.current)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)

                if let buildDate = AppVersion.buildDate {
                    Text("Built \(buildDate, style: .date) by \(AppVersion.builtBy)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // Runtime versions
            VStack(spacing: 6) {
                if let binaryVersion = manager.detectedVersion {
                    LabeledContent("Local Binary", value: binaryVersion)
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
    }

    private func aboutLink(_ title: String, url: String) -> some View {
        Link(title, destination: URL(string: url)!)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
