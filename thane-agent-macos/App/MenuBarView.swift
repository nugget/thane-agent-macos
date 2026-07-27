import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        Button("Open Chat", systemImage: "bubble.left.and.bubble.right") {
            activate()
            openWindow(id: "main")
        }

        Divider()

        Label(appState.statusText, systemImage: appState.menuBarSymbol)

        if appState.managedRuntimeIsRelevant {
            Button(managedStatusTitle, systemImage: managedStatusIcon) {
                activate()
                openWindow(id: "process-health")
            }
        }

        Divider()

        if appState.dashboardURL != nil {
            Button("Web Dashboard", systemImage: "rectangle.3.group") {
                activate()
                openWindow(id: "dashboard")
            }
        }

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

        Button("Thane Settings…", systemImage: "gearshape.2") {
            appState.selectedSettingsTab = .agent
            showSettings()
        }
        .keyboardShortcut(",", modifiers: [.command, .option])

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

    private var managedStatusTitle: String {
        switch manager.state {
        case .running:
            "Agent Health…"
        case .stopped:
            "Managed Agent Stopped…"
        case .crashed:
            "Managed Agent Crashed…"
        case .needsAttention:
            "Managed Agent Needs Attention…"
        case .starting:
            "Verifying Managed Agent…"
        case .notConfigured:
            "Managed Agent"
        }
    }

    private var managedStatusIcon: String {
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
