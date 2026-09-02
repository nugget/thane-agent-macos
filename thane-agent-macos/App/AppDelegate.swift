import AppKit
@preconcurrency import UserNotifications

/// Handles AppKit delegate callbacks that have no SwiftUI equivalent.
/// Injected via @NSApplicationDelegateAdaptor in ThaneApp. Marked @MainActor
/// because all NSApplicationDelegate callbacks fire on the main thread and
/// the class reaches into @MainActor AppState.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    var appState: AppState? {
        didSet {
            if let pendingMuteUntil {
                self.pendingMuteUntil = nil
                appState?.localNotificationManager.mute(until: pendingMuteUntil)
            }
            if shouldOpenNotificationSettings {
                shouldOpenNotificationSettings = false
                showNotificationSettings()
            }
            guard shouldOpenProcessHealth else { return }
            shouldOpenProcessHealth = false
            appState?.showProcessHealth()
        }
    }
    private var shouldOpenProcessHealth = false
    private var shouldOpenNotificationSettings = false
    private var pendingMuteUntil: Date?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        LocalThaneNotificationManager.registerNotificationCategory(center: center)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let appState else { return nil }
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open Chat",
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

        if appState.managedRuntimeIsRelevant {
            let item = NSMenuItem(
                title: "Agent Health",
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

    func applicationDidBecomeActive(_ notification: Notification) {
        Task {
            await appState?.localNotificationManager.refreshAuthorization()
        }
    }

    @objc private func openMain() {
        appState?.openMainWindow?()
    }

    @objc private func openDashboard() {
        appState?.openDashboardWindow?()
    }

    @objc private func openConsole() {
        appState?.showProcessHealth()
    }
}

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard appState?.localNotificationManager.preferences.notifyWhileAppIsActive == true else {
            return []
        }

        let level = notification.request.content.userInfo[
            LocalThaneNotificationManager.levelUserInfoKey
        ] as? String
        if level == BinaryManager.RuntimeLogLevel.error.rawValue {
            var options: UNNotificationPresentationOptions = [.banner, .list]
            if appState?.localNotificationManager.preferences.playSoundForErrors == true {
                options.insert(.sound)
            }
            return options
        }
        return [.list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        switch response.actionIdentifier {
        case LocalThaneNotificationManager.muteActionIdentifier:
            let muteUntil = Date().addingTimeInterval(60 * 60)
            UserDefaults.standard.set(
                muteUntil,
                forKey: LocalNotificationPreferences.muteUntilKey
            )
            if let appState {
                appState.localNotificationManager.mute(until: muteUntil)
            } else {
                pendingMuteUntil = muteUntil
            }
        case UNNotificationDefaultActionIdentifier:
            NSApp.activate()
            if let appState {
                appState.showProcessHealth()
            } else {
                shouldOpenProcessHealth = true
            }
        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        guard appState != nil else {
            shouldOpenNotificationSettings = true
            return
        }
        showNotificationSettings()
    }

    private func showNotificationSettings() {
        NSApp.activate()
        appState?.selectConfiguration(.managed)
        appState?.showSettings(tab: .agent)
    }
}
