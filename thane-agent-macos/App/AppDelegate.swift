import AppKit

/// Handles AppKit delegate callbacks that have no SwiftUI equivalent.
/// Injected via @NSApplicationDelegateAdaptor in ThaneApp.
final class AppDelegate: NSObject, NSApplicationDelegate {

    var appState: AppState?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let appState else { return nil }
        let menu = NSMenu()

        if appState.dashboardURL != nil {
            let item = NSMenuItem(
                title: "Open Dashboard",
                action: #selector(openDashboard),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        if appState.binaryManager.state != .notConfigured {
            let item = NSMenuItem(
                title: "Process Health",
                action: #selector(openConsole),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func openDashboard() {
        appState?.openDashboardWindow?()
    }

    @objc private func openConsole() {
        appState?.openConsoleWindow?()
    }
}
