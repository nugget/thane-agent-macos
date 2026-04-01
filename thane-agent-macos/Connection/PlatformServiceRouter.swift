import Foundation
import os

/// Routes incoming platform_request messages to the appropriate handler.
/// Each platform provider (Contacts, Calendar, etc.) registers itself here.
final class PlatformServiceRouter: Sendable {
    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "platform")

    // nonisolated(unsafe) because handlers are registered at startup before any requests arrive
    nonisolated(unsafe) private var handlers: [String: PlatformServiceHandler] = [:]

    func register(capability: String, handler: PlatformServiceHandler) {
        handlers[capability] = handler
    }

    /// Returns the list of capabilities for registration with the server.
    var capabilities: [Capability] {
        handlers.map { name, handler in
            Capability(name: name, version: handler.version, methods: handler.supportedMethods)
        }
    }

    /// Handle an incoming platform request and return a response.
    func handle(request: PlatformRequest) async -> PlatformResponse {
        guard let handler = handlers[request.capability] else {
            logger.warning("No handler for capability: \(request.capability)")
            return PlatformResponse(
                id: request.id,
                type: "result",
                success: false,
                result: nil,
                error: WSError(code: "unknown_capability", message: "No handler for \(request.capability)")
            )
        }

        guard handler.supportedMethods.contains(request.method) else {
            logger.warning("Unsupported method \(request.method) for \(request.capability)")
            return PlatformResponse(
                id: request.id,
                type: "result",
                success: false,
                result: nil,
                error: WSError(code: "unknown_method", message: "Method \(request.method) not supported by \(request.capability)")
            )
        }

        do {
            let result = try await handler.handle(method: request.method, params: request.params ?? [:])
            return PlatformResponse(
                id: request.id,
                type: "result",
                success: true,
                result: result,
                error: nil
            )
        } catch {
            logger.error("Handler error for \(request.capability).\(request.method): \(error.localizedDescription)")
            return PlatformResponse(
                id: request.id,
                type: "result",
                success: false,
                result: nil,
                error: WSError(code: "handler_error", message: error.localizedDescription)
            )
        }
    }
}

/// Protocol for platform service providers (Contacts, Calendar, etc.)
protocol PlatformServiceHandler: Sendable {
    var version: String { get }
    var supportedMethods: [String] { get }
    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable
}
