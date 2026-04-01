import AppKit

/// Handles AppKit delegate callbacks that have no SwiftUI equivalent.
/// Injected via @NSApplicationDelegateAdaptor in ThaneApp.
final class AppDelegate: NSObject, NSApplicationDelegate {

    var appState: AppState?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let appState, appState.binaryManager.state != .notConfigured else {
            return nil
        }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Open Console",
            action: #selector(openConsole),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openConsole() {
        appState?.openConsoleWindow?()
    }
}
