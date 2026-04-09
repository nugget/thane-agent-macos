import Foundation
import SwiftData
import os

/// Central application state coordinator.
/// Owns the server connection, platform service router, and local binary manager.
@Observable
@MainActor
final class AppState {
    let connection = ServerConnection()
    let platformRouter = PlatformServiceRouter()
    let binaryManager = BinaryManager()
    let updateManager = UpdateManager()
    let permissionsManager = PermissionsManager()
    let calendarService = CalendarService()

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "app")
    private(set) var calendarAuthorization: CalendarAuthorizationState = .notDetermined

    /// Non-nil when the connected server has an incompatible major version.
    private(set) var versionMismatch: String?

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
        switch connection.state {
        case .connected: "brain.head.profile"
        case .connecting, .authenticating, .reconnecting: "brain.head.profile.fill"
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
    var openConsoleWindow: (() -> Void)?
    var openDashboardWindow: (() -> Void)?

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

    init() {
        platformRouter.register(
            capability: "macos.calendar",
            handler: CalendarPlatformHandler(calendarService: calendarService)
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

        connection.onConnected = { [weak self] in
            self?.checkServerVersionCompatibility()
        }

        binaryManager.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .running:
                // Only auto-connect locally if not already connected to a remote server
                if !self.isConnected { self.connectLocal() }
            case .stopped, .crashed, .notConfigured:
                if self.isLocallyConnected { self.disconnect() }
            default:
                break
            }
        }

        Task {
            await refreshCalendarAuthorization()
        }

        binaryManager.autoStartIfNeeded()

        updateManager.startPeriodicChecks { [weak self] in
            self?.binaryManager.detectedVersion
        }
    }

    var updateAvailable: Bool {
        if case .available = updateManager.state { return true }
        return false
    }

    // MARK: - Version Compatibility

    /// Check that the connected server's major version matches ours.
    /// Disconnects with a user-facing message if incompatible.
    private func checkServerVersionCompatibility() {
        guard let serverVersionString = connection.serverVersion,
              let serverSemver = SemanticVersion(serverVersionString),
              let appSemver = AppVersion.semver else {
            versionMismatch = nil
            return
        }

        if serverSemver.major != appSemver.major {
            let message = "Server version \(serverSemver) is incompatible with Thane for macOS \(appSemver) (major version mismatch)"
            versionMismatch = message
            logger.warning("\(message)")
            disconnect()
        } else {
            versionMismatch = nil
        }
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
        connection.disconnect()
    }

    /// Connect the platform WebSocket to the locally running binary.
    /// Reads ports and token from the parsed config — no-ops if platform isn't configured.
    func connectLocal() {
        let config = binaryManager.localConfig
        guard config.platformEnabled, let token = config.platformToken else {
            logger.info("Local binary running but platform not configured in config — WebSocket skipped")
            return
        }
        guard let url = URL(string: "http://localhost:\(config.nativePort)") else { return }
        let clientName = Host.current().localizedName ?? "Mac"
        isLocallyConnected = true
        activeServerURL = url
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
}
