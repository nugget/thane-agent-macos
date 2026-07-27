import AppKit

/// Handles AppKit delegate callbacks that have no SwiftUI equivalent.
/// Injected via @NSApplicationDelegateAdaptor in ThaneApp. Marked @MainActor
/// because all NSApplicationDelegate callbacks fire on the main thread and
/// the class reaches into @MainActor AppState.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    var appState: AppState?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let appState else { return nil }
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open Thane",
            action: #selector(openMain),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState?.openMainWindow?()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.binaryManager.prepareForApplicationTermination()
    }

    @objc private func openMain() {
        appState?.openMainWindow?()
    }

    @objc private func openDashboard() {
        appState?.openDashboardWindow?()
    }

    @objc private func openConsole() {
        appState?.openConsoleWindow?()
    }
}
