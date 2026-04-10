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

    /// Override the standard "About" menu item to open our custom About window
    /// instead of the generic system panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    @objc func showAboutWindow(_ sender: Any?) {
        appState?.openAboutWindow?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Replace the default About menu item action with our custom window.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let aboutItem = appMenu.items.first(where: { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) }) {
            aboutItem.action = #selector(showAboutWindow(_:))
            aboutItem.target = self
        }
    }

    @objc private func openDashboard() {
        appState?.openDashboardWindow?()
    }

    @objc private func openConsole() {
        appState?.openConsoleWindow?()
    }
}
