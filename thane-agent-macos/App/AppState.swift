import Foundation
import SwiftData
import os

/// Connection coordinates retained while a server is connected, so the native
/// REST client can reuse the same base URL and token without re-reading the
/// Keychain or re-parsing the local config.
nonisolated struct ActiveServer: Sendable, Equatable {
    let baseURL: URL
    let token: String
    let isLocal: Bool
}

enum AppSettingsTab: Hashable {
    case general
    case remote
    case local
    case permissions
}

/// Central application state coordinator.
/// Owns the server connection, platform service router, and local binary manager.
@Observable
@MainActor
final class AppState {
    let connection = ServerConnection()
    let platformRouter = PlatformServiceRouter()
    let binaryManager = BinaryManager()
    let localNotificationManager = LocalThaneNotificationManager()
    let updateManager = UpdateManager()
    let appUpdateManager = AppUpdateManager()
    let permissionsManager = PermissionsManager()
    let calendarService = CalendarService()
    let contactsService = ContactsService()
    let remindersService = RemindersService()

    // Native REST API panel managers — each polls only while its panel is visible.
    let systemStatusManager = SystemStatusManager()
    let sessionsManager = SessionsManager()
    let loopsManager = LoopsManager()
    let conversationsManager = ConversationsManager()
    let schedulesManager = SchedulesManager()
    let logsManager = LogsManager()

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "app")
    private(set) var calendarAuthorization: EventKitAuthorizationState = .notDetermined
    private(set) var contactsAuthorization: ContactsAuthorizationState = .notDetermined
    private(set) var remindersAuthorization: EventKitAuthorizationState = .notDetermined
    var selectedSettingsTab: AppSettingsTab = .general


    var connectionState: ServerConnection.State {
        connection.state
    }

    var isConnected: Bool {
        connection.state == .connected
    }

    var statusText: String {
        switch connection.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting..."
        case .authenticating: "Authenticating..."
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (\(attempt))..."
        }
    }

    var menuBarSymbol: String {
        if case .needsAttention = binaryManager.state {
            return "exclamationmark.shield"
        }
        return switch connection.state {
        case .connected: "brain.head.profile.fill"
        case .connecting, .authenticating, .reconnecting: "ellipsis.circle"
        case .disconnected: "brain.head.profile"
        }
    }

    /// True when the current WebSocket connection is to the local binary.
    /// Prevents stopping a remote connection when the local binary stops.
    private var isLocallyConnected = false

    /// Stable client ID for local connections, generated once and persisted.
    private var localClientID: String {
        if let id = UserDefaults.standard.string(forKey: "localClientID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "localClientID")
        return id
    }

    /// Called by MainView on appear to bridge SwiftUI's openWindow action to AppKit contexts.
    var openMainWindow: (() -> Void)?
    var openConsoleWindow: (() -> Void)?
    var openDashboardWindow: (() -> Void)?
    var openServerWindow: (() -> Void)?
    private var shouldOpenProcessHealth = false

    /// Base URL of the currently active server — local takes priority over remote.
    /// Used by the dashboard window to load the web UI.
    var dashboardURL: URL? {
        if binaryManager.state.isRunning {
            return URL(string: "http://localhost:\(binaryManager.localConfig.nativePort)")
        }
        return activeServerURL
    }

    /// Stored when a connection is established so dashboard can open the right URL.
    private(set) var activeServerURL: URL?

    /// Connection coordinates (base URL + token) for the active server, set in
    /// lockstep with the WebSocket connection. The source of truth for the
    /// native REST client; nil while disconnected.
    private(set) var activeServer: ActiveServer?

    /// Authenticated client for the native REST API, or nil when disconnected.
    var nativeClient: NativeAPIClient? {
        guard let server = activeServer else { return nil }
        return NativeAPIClient(baseURL: server.baseURL, token: server.token)
    }

    init() {
        platformRouter.register(
            capability: "macos.calendar",
            handler: CalendarPlatformHandler(calendarService: calendarService)
        )
        platformRouter.register(
            capability: "macos.contacts",
            handler: ContactsPlatformHandler(contactsService: contactsService)
        )
        platformRouter.register(
            capability: "macos.reminders",
            handler: RemindersPlatformHandler(remindersService: remindersService)
        )
        connection.registeredCapabilities = platformRouter.capabilities

        connection.onPlatformRequest = { [weak self] request in
            guard let self else {
                return PlatformResponse(
                    id: request.id,
                    type: "result",
                    success: false,
                    result: nil,
                    error: WSError(code: "unavailable", message: "App state unavailable")
                )
            }
            return await platformRouter.handle(request: request)
        }

        binaryManager.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .running:
                // Only auto-connect locally if not already connected to a remote server
                if !self.isConnected { self.connectLocal() }
<<<<<<< HEAD
            case .stopped, .crashed, .refused, .notConfigured:
=======
            case .stopped, .crashed, .needsAttention, .notConfigured:
>>>>>>> origin/main
                if self.isLocallyConnected { self.disconnect() }
            default:
                break
            }
        }

        binaryManager.onLogEntry = { [weak self] entry in
            self?.localNotificationManager.handle(entry)
        }

        Task {
            await refreshCalendarAuthorization()
            await refreshContactsAuthorization()
            await refreshRemindersAuthorization()
            await localNotificationManager.refreshAuthorization()
        }

        binaryManager.autoStartIfNeeded()

        updateManager.startPeriodicChecks { [weak self] in
            self?.binaryManager.detectedVersion
        }

        // App self-update uses the stamped git-describe string as the
        // current version (same source as the About window).
        appUpdateManager.startPeriodicChecks {
            AppVersion.current
        }
    }

    func showProcessHealth() {
        if let openConsoleWindow {
            openConsoleWindow()
        } else {
            shouldOpenProcessHealth = true
        }
    }

    func registerProcessHealthWindowOpener(_ opener: @escaping () -> Void) {
        openConsoleWindow = opener
        guard shouldOpenProcessHealth else { return }
        shouldOpenProcessHealth = false
        opener()
    }

    var updateAvailable: Bool {
        if case .available = updateManager.state { return true }
        return false
    }

    var appUpdateAvailable: Bool {
        if case .available = appUpdateManager.state { return true }
        return false
    }

    /// Connect to a remote server using the given config and stored token.
    func connect(config: ServerConfig) {
        isLocallyConnected = false
        activeServerURL = config.url
        guard let url = config.url else {
            logger.error("Invalid URL in server config: \(config.urlString)")
            return
        }

        let tokenKey = "token-\(config.clientID)"
        guard let token = KeychainHelper.load(key: tokenKey) else {
            logger.warning("No token stored for server config \(config.name)")
            return
        }

        let clientName = Host.current().localizedName ?? "Mac"
        activeServer = ActiveServer(baseURL: url, token: token, isLocal: false)

        connection.connect(
            url: url,
            token: token,
            clientID: config.clientID,
            clientName: clientName,
            persist: true
        )
    }

    func disconnect() {
        isLocallyConnected = false
        activeServerURL = nil
        activeServer = nil
        connection.disconnect()
    }

    /// Register with the locally running binary as a companion provider.
    /// Reads the native port and token from the parsed config — no-ops if
    /// the companion endpoint isn't configured (or is configured but
    /// missing a usable token).
    func connectLocal() {
        let config = binaryManager.localConfig
        guard config.companionEnabled, let token = config.companionToken else {
            logger.info("Local binary running but companion not configured in config — WebSocket skipped")
            return
        }
        guard let url = URL(string: "http://localhost:\(config.nativePort)") else { return }
        let clientName = Host.current().localizedName ?? "Mac"
        isLocallyConnected = true
        activeServerURL = url
        activeServer = ActiveServer(baseURL: url, token: token, isLocal: true)
        connection.connect(url: url, token: token, clientID: localClientID, clientName: clientName, persist: true)
    }

    /// Save a token for a server config to the Keychain.
    func saveToken(_ token: String, for config: ServerConfig) {
        let tokenKey = "token-\(config.clientID)"
        do {
            try KeychainHelper.save(key: tokenKey, value: token)
        } catch {
            logger.error("Failed to save token: \(error.localizedDescription)")
        }
    }

    func deleteToken(for config: ServerConfig) {
        let tokenKey = "token-\(config.clientID)"
        KeychainHelper.delete(key: tokenKey)
    }

    /// Load the stored token for a server config.
    func loadToken(for config: ServerConfig) -> String? {
        let tokenKey = "token-\(config.clientID)"
        return KeychainHelper.load(key: tokenKey)
    }

    func refreshCalendarAuthorization() async {
        calendarAuthorization = await calendarService.authorizationState()
    }

    func requestCalendarAccess() async {
        do {
            calendarAuthorization = try await calendarService.requestAccessIfNeeded()
        } catch {
            logger.error("Failed to request calendar access: \(error.localizedDescription)")
            calendarAuthorization = await calendarService.authorizationState()
        }
    }

    func refreshContactsAuthorization() async {
        contactsAuthorization = await contactsService.authorizationState()
    }

    func requestContactsAccess() async {
        do {
            contactsAuthorization = try await contactsService.requestAccessIfNeeded()
        } catch {
            logger.error("Failed to request contacts access: \(error.localizedDescription)")
            contactsAuthorization = await contactsService.authorizationState()
        }
    }

    func refreshRemindersAuthorization() async {
        remindersAuthorization = await remindersService.authorizationState()
    }

    func requestRemindersAccess() async {
        do {
            remindersAuthorization = try await remindersService.requestAccessIfNeeded()
        } catch {
            logger.error("Failed to request reminders access: \(error.localizedDescription)")
            remindersAuthorization = await remindersService.authorizationState()
        }
    }
}
