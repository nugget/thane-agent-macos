import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

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

            if appState.dashboardURL != nil {
                Button("Open Dashboard") {
                    openWindow(id: "dashboard")
                }
            }

            if appState.binaryManager.state != .notConfigured {
                Button("Process Health") {
                    openWindow(id: "process-health")
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
