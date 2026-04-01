import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading) {
            Label(appState.statusText, systemImage: appState.isConnected ? "circle.fill" : "circle")
                .foregroundStyle(appState.isConnected ? .green : .secondary)

            Divider()

            if appState.isConnected {
                Button("Disconnect") {
                    appState.disconnect()
                }
            }

            Divider()

            if appState.binaryManager.state != .notConfigured {
                Button("Open Console") {
                    NotificationCenter.default.post(name: .openConsoleWindow, object: nil)
                }
            }

            Divider()

            SettingsLink {
                Text("Settings...")
            }

            Button("Quit Thane") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
