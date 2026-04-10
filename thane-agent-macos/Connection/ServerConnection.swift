import Foundation
import os

private struct ReceivedMessage {
    let envelope: WSMessage
    let rawData: Data
}

/// Manages the WebSocket connection to a thane-ai-agent server.
/// Handles auth handshake, capability registration, message routing,
/// and reconnection with exponential backoff.
@Observable @MainActor
final class ServerConnection {
    enum State: Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var state: State = .disconnected
    private(set) var providerID: String?
    private(set) var account: String?
    private(set) var serverVersion: String?
    private(set) var lastError: String?

    /// Called after the connection is fully established and capabilities registered.
    var onConnected: (() -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var nextID: Int64 = 1
    private var pendingResponses: [Int64: CheckedContinuation<WSMessage, Error>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var readLoopTask: Task<Void, Never>?
    private var intentionalDisconnect = false

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "connection")

    var onPlatformRequest: ((PlatformRequest) async -> PlatformResponse)?
    var registeredCapabilities: [Capability] = []

    // MARK: - Public API

    func connect(url: URL, token: String, clientID: String, clientName: String) {
        intentionalDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { @MainActor in
            state = .connecting
            lastError = nil
        }
        performConnect(url: url, token: token, clientID: clientID, clientName: clientName)
    }

    func disconnect() {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        readLoopTask?.cancel()
        readLoopTask = nil
        cleanupTransport(closeCode: .goingAway)
        cancelAllPending(error: CancellationError())
        Task { @MainActor in
            state = .disconnected
            providerID = nil
            account = nil
        }
    }

    /// Send a chat request and return streamed tokens via the callback.
    /// The final ChatStreamData with kind "done" contains the complete response.
    func sendChatRequest(
        conversationID: String,
        message: String,
        stream: Bool = true,
        onStream: @escaping (ChatStreamData) -> Void
    ) async throws {
        let id = nextMessageID()
        let request = ChatRequest(
            id: id,
            type: "chat_request",
            conversationID: conversationID,
            message: message,
            stream: stream
        )
        streamHandlers[id] = onStream
        do {
            try await sendJSON(request)
        } catch {
            streamHandlers.removeValue(forKey: id)
            throw error
        }
    }

    // MARK: - Private

    private var streamHandlers: [Int64: (ChatStreamData) -> Void] = [:]

    private func nextMessageID() -> Int64 {
        let id = nextID
        nextID += 1
        return id
    }

    private func performConnect(url: URL, token: String, clientID: String, clientName: String) {
        cleanupTransport(closeCode: .goingAway)

        // Build the WebSocket URL. Using wss:// (instead of https://) forces HTTP/1.1
        // upgrade (RFC 6455) rather than HTTP/2 extended CONNECT (RFC 8441), which is
        // required for compatibility with Traefik and most reverse proxies.
        let rawURL = url.appendingPathComponent("v1/platform/ws")
        var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http":  components.scheme = "ws"
        default: break
        }
        let wsURL = components.url ?? rawURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)

        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 30
        let task = session!.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        readLoopTask = Task { [weak self] in
            await self?.runConnection(token: token, clientID: clientID, clientName: clientName)
        }
    }

    private func runConnection(token: String, clientID: String, clientName: String) async {
        do {
            // Step 1: Receive auth_required
            Task { @MainActor in state = .authenticating }
            let authReq = try await receiveMessage()
            guard authReq.envelope.type == "auth_required" else {
                throw ConnectionError.unexpectedMessage("Expected auth_required, got \(authReq.envelope.type)")
            }
            if let version = try? JSONDecoder().decode(AuthRequiredMessage.self, from: authReq.rawData).version {
                Task { @MainActor in serverVersion = version }
            }

            // Step 2: Send auth
            let authMsg = AuthMessage(
                type: "auth",
                token: token,
                clientName: clientName,
                clientID: clientID
            )
            try await sendJSON(authMsg)

            // Step 3: Receive auth_ok or auth_failed
            let authResp = try await receiveMessage()
            if authResp.envelope.type == "auth_failed" {
                let invalid = try JSONDecoder().decode(AuthInvalidMessage.self, from: authResp.rawData)
                throw ConnectionError.authFailed(invalid.message)
            }
            guard authResp.envelope.type == "auth_ok" else {
                throw ConnectionError.unexpectedMessage("Expected auth_ok, got \(authResp.envelope.type)")
            }
            if let authOK = try? JSONDecoder().decode(AuthOKMessage.self, from: authResp.rawData) {
                Task { @MainActor in
                    providerID = authOK.providerID
                    account = authOK.account
                }
            }

            // Step 4: Register capabilities
            try await registerCapabilities()

            Task { @MainActor in
                state = .connected
                lastError = nil
                onConnected?()
            }
            logger.info("Connected to server, provider ID: \(self.providerID ?? "unknown")")

            // Step 5: Read loop
            try await readLoop()

        } catch is CancellationError {
            return
        } catch {
            logger.error("Connection error: \(error.localizedDescription)")
            Task { @MainActor in lastError = error.localizedDescription }
            cleanupTransport(closeCode: .abnormalClosure)
            cancelAllPending(error: error)
            if !intentionalDisconnect {
                scheduleReconnect(token: token, clientID: clientID, clientName: clientName)
            }
        }
    }

    private func registerCapabilities() async throws {
        let id = nextMessageID()
        let msg = RegisterCapabilitiesMessage(
            id: id,
            type: "register_capabilities",
            capabilities: registeredCapabilities
        )
        try await sendJSON(msg)
    }

    private func readLoop() async throws {
        while !Task.isCancelled {
            let received = try await receiveMessage()
            let message = received.envelope

            switch message.type {
            case "ping":
                try await sendJSON(PongMessage(type: "pong"))

            case "result":
                if let id = message.id {
                    deliverResponse(id: id, message: message)
                }

            case "platform_request":
                let request = try JSONDecoder().decode(PlatformRequest.self, from: received.rawData)
                Task { [weak self] in
                    guard let self, let handler = self.onPlatformRequest else {
                        let errorResp = PlatformResponse(
                            id: request.id,
                            type: "result",
                            success: false,
                            result: nil,
                            error: WSError(code: "not_implemented", message: "No platform handler registered")
                        )
                        try? await self?.sendJSON(errorResp)
                        return
                    }
                    let response = await handler(request)
                    try? await self.sendJSON(response)
                }

            case "chat_stream":
                let stream = try JSONDecoder().decode(ChatStreamMessage.self, from: received.rawData)
                let handler = streamHandlers[stream.id]
                if stream.data.kind == "done" {
                    streamHandlers.removeValue(forKey: stream.id)
                }
                handler?(stream.data)

            default:
                logger.debug("Unhandled message type: \(message.type)")
            }
        }
    }

    // MARK: - WebSocket I/O

    private func sendJSON<T: Encodable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ConnectionError.encodingFailed
        }
        guard let task = webSocketTask else {
            throw ConnectionError.notConnected
        }
        try await task.send(.string(string))
    }

    private func receiveMessage() async throws -> ReceivedMessage {
        guard let task = webSocketTask else {
            throw ConnectionError.notConnected
        }
        let result = try await task.receive()
        switch result {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw ConnectionError.decodingFailed
            }
            let envelope = try JSONDecoder().decode(WSMessage.self, from: data)
            return ReceivedMessage(envelope: envelope, rawData: data)
        case .data(let data):
            let envelope = try JSONDecoder().decode(WSMessage.self, from: data)
            return ReceivedMessage(envelope: envelope, rawData: data)
        @unknown default:
            throw ConnectionError.unexpectedMessage("Unknown WebSocket message format")
        }
    }

    // MARK: - Response Correlation

    private func waitForResponse(id: Int64, timeout: TimeInterval) async throws -> WSMessage {
        try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation

            Task {
                try await Task.sleep(for: .seconds(timeout))
                let cont = pendingResponses.removeValue(forKey: id)
                cont?.resume(throwing: ConnectionError.timeout)
            }
        }
    }

    private func deliverResponse(id: Int64, message: WSMessage) {
        let continuation = pendingResponses.removeValue(forKey: id)
        continuation?.resume(returning: message)
    }

    private func cancelAllPending(error: Error) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        streamHandlers.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Reconnection

    private var reconnectAttempt = 0
    private var savedURL: URL?
    private var savedToken: String?
    private var savedClientID: String?
    private var savedClientName: String?

    private func scheduleReconnect(token: String, clientID: String, clientName: String) {
        reconnectAttempt += 1
        let delay = min(Double(1 << min(reconnectAttempt, 6)), 60.0) // 2, 4, 8, 16, 32, 60, 60...

        Task { @MainActor in
            state = .reconnecting(attempt: reconnectAttempt)
        }

        logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempt))")

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return // Cancelled
            }
            guard !intentionalDisconnect else { return }
            if let url = savedURL {
                performConnect(url: url, token: token, clientID: clientID, clientName: clientName)
            }
        }
    }

    /// Call connect() to also persist the URL for reconnection.
    func connect(url: URL, token: String, clientID: String, clientName: String, persist: Bool) {
        savedURL = url
        savedToken = token
        savedClientID = clientID
        savedClientName = clientName
        connect(url: url, token: token, clientID: clientID, clientName: clientName)
    }

    // MARK: - Helpers

    private func cleanupTransport(closeCode: URLSessionWebSocketTask.CloseCode) {
        webSocketTask?.cancel(with: closeCode, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

// MARK: - Errors

enum ConnectionError: LocalizedError {
    case notConnected
    case encodingFailed
    case decodingFailed
    case unexpectedMessage(String)
    case authFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to server"
        case .encodingFailed: "Failed to encode message"
        case .decodingFailed: "Failed to decode message"
        case .unexpectedMessage(let msg): "Unexpected message: \(msg)"
        case .authFailed(let msg): "Authentication failed: \(msg)"
        case .timeout: "Request timed out"
        }
    }
}
