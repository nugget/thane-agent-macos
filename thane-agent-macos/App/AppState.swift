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

nonisolated enum AdvancedConnectionActivation: Equatable {
    case disconnect
    case reuse
    case connect

    static func decide(
        activeServer: ActiveServer?,
        isConnected: Bool,
        selectedURL: URL?,
        selectedToken: String?,
        forceReconnect: Bool
    ) -> Self {
        guard let selectedURL, let selectedToken else { return .disconnect }
        if forceReconnect { return .connect }

        let selection = ActiveServer(
            baseURL: selectedURL,
            token: selectedToken,
            isLocal: false
        )
        return isConnected && activeServer == selection ? .reuse : .connect
    }
}

enum AppSettingsTab: Hashable {
    case general
    case agent
    case capabilities
    case access
}

nonisolated enum AgentConfigurationMode: String, CaseIterable, Identifiable, Sendable {
    case managed
    case advanced

    static let defaultsKey = "agentConfigurationMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .managed: "Managed"
        case .advanced: "Advanced"
        }
    }

    var detail: String {
        switch self {
        case .managed: "Thane is installed, verified, and supervised by this app."
        case .advanced: "Connect to a Thane instance you operate yourself."
        }
    }
}

nonisolated enum MenuBarTextStyle: String, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case status
    case version
    case statusAndVersion

    static let defaultsKey = "menuBarTextStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: "Icon Only"
        case .status: "Status"
        case .version: "Version"
        case .statusAndVersion: "Status & Version"
        }
    }

    func text(status: String, version: String?) -> String? {
        switch self {
        case .iconOnly:
            nil
        case .status:
            status
        case .version:
            version ?? status
        case .statusAndVersion:
            if let version {
                "\(status) · \(version)"
            } else {
                status
            }
        }
    }
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
    let systemContextPreferences: SystemContextPreferences
    let systemContextService: SystemContextService

    // Native REST API panel managers — each polls only while its panel is visible.
    let systemStatusManager = SystemStatusManager()
    let identityManager = IdentityManager()
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
    let hadStoredConfigurationMode: Bool
    private(set) var configurationMode: AgentConfigurationMode {
        didSet {
            UserDefaults.standard.set(configurationMode.rawValue, forKey: AgentConfigurationMode.defaultsKey)
            if configurationMode == .managed {
                binaryManager.autoStartIfNeeded()
            }
        }
    }
    var menuBarTextStyle: MenuBarTextStyle {
        didSet {
            UserDefaults.standard.set(menuBarTextStyle.rawValue, forKey: MenuBarTextStyle.defaultsKey)
        }
    }

    var connectionState: ServerConnection.State {
        connection.state
    }

    var isConnected: Bool {
        connection.state == .connected
    }

    var statusText: String {
        if configurationMode == .managed {
            switch binaryManager.state {
            case .starting:
                return "Starting…"
            case .stopped:
                return "Stopped"
            case .crashed:
                return "Crashed"
            case .needsAttention:
                return "Needs Attention"
            case .notConfigured:
                return "Not Configured"
            case .running:
                break
            }
        }
        return switch connection.state {
        case .disconnected: "Unavailable"
        case .connecting: "Connecting…"
        case .authenticating: "Authenticating…"
        case .connected: "Ready"
        case .reconnecting(let attempt): "Reconnecting (\(attempt))…"
        }
    }

    var menuBarSymbol: String {
        if identityManager.pinState.hasChanged {
            return "exclamationmark.shield.fill"
        }
        if configurationMode == .managed {
            switch binaryManager.state {
            case .needsAttention:
                return "exclamationmark.shield.fill"
            case .crashed:
                return "exclamationmark.triangle.fill"
            case .starting:
                return "ellipsis.circle"
            case .stopped:
                return "pause.circle"
            default:
                break
            }
        }
        if updateAvailable || appUpdateAvailable {
            return "arrow.down.circle.fill"
        }
        return switch connection.state {
        case .connected: "brain.head.profile.fill"
        case .connecting, .authenticating, .reconnecting: "ellipsis.circle"
        case .disconnected: "brain.head.profile"
        }
    }

    var menuBarText: String? {
        let version = configurationMode == .managed ? binaryManager.detectedVersion : nil
        return menuBarTextStyle.text(status: statusText, version: version)
    }

    var managedRuntimeIsRelevant: Bool {
        configurationMode == .managed && binaryManager.state != .notConfigured
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
    private var shouldOpenProcessHealth = false

    /// Base URL of the active Thane configuration.
    /// Used by the dashboard window without exposing where Thane is running.
    var dashboardURL: URL? { activeServerURL }

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
        let systemContextPreferences = SystemContextPreferences()
        self.systemContextPreferences = systemContextPreferences
        systemContextService = SystemContextService(preferences: systemContextPreferences)

        hadStoredConfigurationMode = UserDefaults.standard.object(
            forKey: AgentConfigurationMode.defaultsKey
        ) != nil
        configurationMode = AgentConfigurationMode(
            rawValue: UserDefaults.standard.string(forKey: AgentConfigurationMode.defaultsKey) ?? ""
        ) ?? .managed
        menuBarTextStyle = MenuBarTextStyle(
            rawValue: UserDefaults.standard.string(forKey: MenuBarTextStyle.defaultsKey) ?? ""
        ) ?? .iconOnly

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
        platformRouter.register(
            capability: "macos.system-context",
            handler: SystemContextPlatformHandler(service: systemContextService)
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
                if self.configurationMode == .managed, !self.isConnected {
                    self.connectLocal()
                }
            case .stopped, .crashed, .needsAttention, .notConfigured:
                if self.isLocallyConnected { self.disconnect() }
            default:
                break
            }
        }

        binaryManager.onLogEntry = { [weak self] entry in
            guard let self, self.configurationMode == .managed else { return }
            self.localNotificationManager.handle(entry)
        }

        Task {
            await refreshCalendarAuthorization()
            await refreshContactsAuthorization()
            await refreshRemindersAuthorization()
            await localNotificationManager.refreshAuthorization()
        }

        if configurationMode == .managed {
            binaryManager.autoStartIfNeeded()
        }

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

    /// Selects and activates an operator configuration independently of any
    /// window lifecycle. Changing modes from Settings must take effect even
    /// when the chat window is closed.
    func selectConfiguration(
        _ mode: AgentConfigurationMode,
        advancedConfig: ServerConfig? = nil,
        forceReconnect: Bool = false
    ) {
        configurationMode = mode
        activateSelectedConfiguration(
            advancedConfig: advancedConfig,
            forceReconnect: forceReconnect
        )
    }

    /// Activates the persisted configuration after SwiftData has made the
    /// optional Advanced connection available to the view layer.
    func activateSelectedConfiguration(
        advancedConfig: ServerConfig?,
        forceReconnect: Bool = false
    ) {
        switch configurationMode {
        case .managed:
            if activeServer?.isLocal == false {
                disconnect()
            }
            if binaryManager.state.isRunning {
                connectLocal()
            }
        case .advanced:
            guard let advancedConfig else {
                disconnect()
                return
            }
            let activation = AdvancedConnectionActivation.decide(
                activeServer: activeServer,
                isConnected: isConnected,
                selectedURL: advancedConfig.url,
                selectedToken: loadToken(for: advancedConfig),
                forceReconnect: forceReconnect
            )
            switch activation {
            case .disconnect:
                // Reuse connect(config:) so invalid URLs and absent Keychain
                // tokens retain their specific logs before clearing state.
                connect(config: advancedConfig)
            case .reuse:
                return
            case .connect:
                connect(config: advancedConfig)
            }
        }
    }

    /// Connect to a remote server using the given config and stored token.
    func connect(config: ServerConfig) {
        guard let url = config.url else {
            logger.error("Invalid URL in server config: \(config.urlString)")
            disconnect()
            return
        }

        let tokenKey = "token-\(config.clientID)"
        guard let token = KeychainHelper.load(key: tokenKey) else {
            logger.warning("No token stored for server config \(config.name)")
            disconnect()
            return
        }

        let clientName = Host.current().localizedName ?? "Mac"
        isLocallyConnected = false
        activeServerURL = url
        activeServer = ActiveServer(baseURL: url, token: token, isLocal: false)
        identityManager.start { [weak self] in self?.nativeClient }

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
        identityManager.stop()
        connection.disconnect()
    }

    /// Register with the locally running binary as a companion provider.
    /// Reads the native port and token from the parsed config — no-ops if
    /// the companion endpoint isn't configured (or is configured but
    /// missing a usable token).
    func connectLocal() {
        guard configurationMode == .managed else { return }
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
        identityManager.start { [weak self] in self?.nativeClient }
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
