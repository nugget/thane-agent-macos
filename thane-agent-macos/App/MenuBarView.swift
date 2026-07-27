import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        Button("Open Thane", systemImage: "macwindow") {
            activate()
            openWindow(id: "main")
        }

        Divider()

        connectionStatus
        localStatus

        Divider()

        if appState.activeServer != nil {
            Button("Server Status", systemImage: "server.rack") {
                activate()
                openWindow(id: "server")
            }
        }

        if appState.dashboardURL != nil {
            Button("Web Dashboard", systemImage: "rectangle.3.group") {
                activate()
                openWindow(id: "dashboard")
            }
        }

        Button("Local Thane…", systemImage: localStatusIcon) {
            activate()
            openWindow(id: "process-health")
        }
        .disabled(manager.state == .notConfigured)

        if appState.updateAvailable || appState.appUpdateAvailable {
            Divider()
            Button("Updates Available…", systemImage: "arrow.down.circle.fill") {
                showSettings()
            }
        }

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }

        Button("About Thane") {
            activate()
            openWindow(id: "about")
        }

        Divider()

        Button("Quit Thane") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if appState.isConnected {
            Button("Disconnect", systemImage: "checkmark.circle.fill") {
                appState.disconnect()
            }
        } else {
            Text(appState.statusText)
        }
    }

    @ViewBuilder
    private var localStatus: some View {
        switch manager.state {
        case .running:
            Button("Stop Local Thane", systemImage: "stop.circle") {
                manager.stop()
            }
        case .stopped, .crashed:
            Button("Check & Start Local Thane", systemImage: "play.circle") {
                manager.start()
            }
        case .needsAttention:
            Button("Local Thane Needs Attention…", systemImage: "exclamationmark.shield.fill") {
                activate()
                openWindow(id: "process-health")
            }
        case .starting:
            Text("Verifying Local Thane…")
        case .notConfigured:
            Text("Local Thane Not Configured")
        }
    }

    private var localStatusIcon: String {
        switch manager.state {
        case .running: "checkmark.circle.fill"
        case .starting: "checkmark.shield"
        case .needsAttention: "exclamationmark.shield.fill"
        case .crashed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .notConfigured: "questionmark.circle"
        }
    }

    private func activate() {
        NSApp.activate()
    }

    private func showSettings() {
        activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
