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

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "app")

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

    init() {
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
    }

    /// Connect to a server using the given config and stored token.
    func connect(config: ServerConfig) {
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
        connection.disconnect()
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

    /// Load the stored token for a server config.
    func loadToken(for config: ServerConfig) -> String? {
        let tokenKey = "token-\(config.clientID)"
        return KeychainHelper.load(key: tokenKey)
    }
}
