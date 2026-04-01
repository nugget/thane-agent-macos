import Foundation
import os

/// Manages the WebSocket connection to a thane-ai-agent server.
/// Handles auth handshake, capability registration, message routing,
/// and reconnection with exponential backoff.
@Observable
final class ServerConnection: @unchecked Sendable {
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

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var nextID: Int64 = 1
    private var pendingResponses: [Int64: CheckedContinuation<WSMessage, Error>] = [:]
    private let pendingLock = NSLock()
    private var reconnectTask: Task<Void, Never>?
    private var readLoopTask: Task<Void, Never>?
    private var intentionalDisconnect = false

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "connection")

    var onPlatformRequest: ((PlatformRequest) async -> PlatformResponse)?

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
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
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
        try await sendJSON(request)
        // Streaming responses arrive via readLoop and are dispatched to the callback.
        // Register a stream handler keyed by message ID.
        streamHandlers[id] = onStream
    }

    // MARK: - Private

    private var streamHandlers: [Int64: (ChatStreamData) -> Void] = [:]
    private let streamLock = NSLock()

    private func nextMessageID() -> Int64 {
        let id = nextID
        nextID += 1
        return id
    }

    private func performConnect(url: URL, token: String, clientID: String, clientName: String) {
        let wsURL = url.appendingPathComponent("v1/platform/ws")
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
            guard authReq.type == "auth_required" else {
                throw ConnectionError.unexpectedMessage("Expected auth_required, got \(authReq.type)")
            }
            if let version = try? JSONDecoder().decode(AuthRequiredMessage.self, from: encodeToData(authReq)).version {
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
            if authResp.type == "auth_failed" {
                let invalid = try JSONDecoder().decode(AuthInvalidMessage.self, from: encodeToData(authResp))
                throw ConnectionError.authFailed(invalid.message)
            }
            guard authResp.type == "auth_ok" else {
                throw ConnectionError.unexpectedMessage("Expected auth_ok, got \(authResp.type)")
            }
            if let authOK = try? JSONDecoder().decode(AuthOKMessage.self, from: encodeToData(authResp)) {
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
            }
            logger.info("Connected to server, provider ID: \(self.providerID ?? "unknown")")

            // Step 5: Read loop
            try await readLoop()

        } catch is CancellationError {
            return
        } catch {
            logger.error("Connection error: \(error.localizedDescription)")
            Task { @MainActor in lastError = error.localizedDescription }
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
            capabilities: [
                // Initially empty — capabilities are registered as platform providers are implemented
            ]
        )
        try await sendJSON(msg)
        // Await acknowledgment
        _ = try await waitForResponse(id: id, timeout: 10)
    }

    private func readLoop() async throws {
        while !Task.isCancelled {
            let message = try await receiveMessage()

            switch message.type {
            case "ping":
                try await sendJSON(PongMessage(type: "pong"))

            case "result":
                if let id = message.id {
                    deliverResponse(id: id, message: message)
                }

            case "platform_request":
                let data = try encodeToData(message)
                let request = try JSONDecoder().decode(PlatformRequest.self, from: data)
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
                let data = try encodeToData(message)
                let stream = try JSONDecoder().decode(ChatStreamMessage.self, from: data)
                streamLock.lock()
                let handler = streamHandlers[stream.id]
                if stream.data.kind == "done" {
                    streamHandlers.removeValue(forKey: stream.id)
                }
                streamLock.unlock()
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
        try await webSocketTask?.send(.string(string))
    }

    private func receiveMessage() async throws -> WSMessage {
        guard let task = webSocketTask else {
            throw ConnectionError.notConnected
        }
        let result = try await task.receive()
        switch result {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw ConnectionError.decodingFailed
            }
            return try JSONDecoder().decode(WSMessage.self, from: data)
        case .data(let data):
            return try JSONDecoder().decode(WSMessage.self, from: data)
        @unknown default:
            throw ConnectionError.unexpectedMessage("Unknown WebSocket message format")
        }
    }

    // MARK: - Response Correlation

    private func waitForResponse(id: Int64, timeout: TimeInterval) async throws -> WSMessage {
        try await withCheckedThrowingContinuation { continuation in
            pendingLock.lock()
            pendingResponses[id] = continuation
            pendingLock.unlock()

            Task {
                try await Task.sleep(for: .seconds(timeout))
                pendingLock.lock()
                let cont = pendingResponses.removeValue(forKey: id)
                pendingLock.unlock()
                cont?.resume(throwing: ConnectionError.timeout)
            }
        }
    }

    private func deliverResponse(id: Int64, message: WSMessage) {
        pendingLock.lock()
        let continuation = pendingResponses.removeValue(forKey: id)
        pendingLock.unlock()
        continuation?.resume(returning: message)
    }

    private func cancelAllPending(error: Error) {
        pendingLock.lock()
        let pending = pendingResponses
        pendingResponses.removeAll()
        pendingLock.unlock()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }

        streamLock.lock()
        streamHandlers.removeAll()
        streamLock.unlock()
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

    private func encodeToData(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
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
