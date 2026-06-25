import Foundation
import os

/// Minimal authenticated JSON client for the Thane **Native API** (`/v1/...`).
///
/// Mirrors `OllamaClient`: a small value type holding the base URL and token,
/// with a single generic `GET`. `nonisolated` + `Sendable` so the per-domain
/// `@Observable` managers can call it from any executor without a main-actor
/// hop. The bearer header is sent when a token is present — the native API
/// declares bearer auth (not enforced server-side yet; this is forward-compat).
nonisolated struct NativeAPIClient: Sendable {
    /// Same origin as the WebSocket / dashboard host; the reverse proxy fronts
    /// the native port, so requests are just `baseURL` + `/v1/...`.
    let baseURL: URL
    let token: String?

    private static let logger = Logger(
        subsystem: "info.nugget.thane-agent-macos", category: "native-api")

    /// GET `path` (e.g. `"v1/system"`) and decode the JSON body as `T`.
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = try Self.makeRequest(baseURL: baseURL, token: token, path: path, query: query)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.decodeError(status: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error("decode failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw NativeAPIError.decodingFailed(path: path, message: error.localizedDescription)
        }
    }

    /// Builds the request: `baseURL` + `path` (+ query), `Accept: application/json`,
    /// and a bearer header when a non-empty token is present.
    ///
    /// `nonisolated static` so it is unit-testable without a live session — the
    /// pure surface where the URL/header contract is pinned.
    static func makeRequest(
        baseURL: URL,
        token: String?,
        path: String,
        query: [URLQueryItem],
        accept: String = "application/json"
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw NativeAPIError.badURL(path)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NativeAPIError.badURL(path) }

        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Maps a non-2xx response to a typed error, decoding the `{ "error": … }`
    /// envelope when the body carries one. `nonisolated static` so it is
    /// unit-testable.
    static func decodeError(status: Int, data: Data) -> NativeAPIError {
        if let envelope = try? JSONDecoder().decode(NativeAPIErrorEnvelope.self, from: data),
           !envelope.error.isEmpty {
            return .server(status: status, message: envelope.error)
        }
        return .httpStatus(status)
    }
}

/// The native API's standard error envelope.
nonisolated struct NativeAPIErrorEnvelope: Decodable, Sendable {
    let error: String
}

nonisolated enum NativeAPIError: LocalizedError {
    case badURL(String)
    case invalidResponse
    case httpStatus(Int)
    case server(status: Int, message: String)
    case decodingFailed(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case .badURL(let path): "Could not build a request URL for \(path)"
        case .invalidResponse: "The server returned an invalid response"
        case .httpStatus(let code): "The server returned HTTP \(code)"
        case .server(let code, let message): "Server error (\(code)): \(message)"
        case .decodingFailed(let path, _): "Could not decode the response from \(path)"
        }
    }
}

// MARK: - Server-Sent Events

extension NativeAPIClient {
    /// Opens a Server-Sent Events stream at `path` (e.g. "v1/loops/events") and
    /// yields each event's `data:` payload decoded as `T`. Mirrors
    /// `OllamaClient.chat`: one producer task, cancelled on termination.
    ///
    /// `bufferingPolicy` defaults to `.unbounded` (lossless). Pass
    /// `.bufferingNewest(1)` for a wake-signal consumer that only needs the most
    /// recent event while it catches up.
    func stream<T: Decodable & Sendable>(
        _ path: String,
        as type: T.Type = T.self,
        bufferingPolicy: AsyncThrowingStream<T, Error>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let producer = Task {
                do {
                    let request = try Self.makeRequest(
                        baseURL: baseURL, token: token, path: path, query: [], accept: "text/event-stream")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw NativeAPIError.invalidResponse
                    }
                    guard (200...299).contains(http.statusCode) else {
                        throw NativeAPIError.httpStatus(http.statusCode)
                    }
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // A blank line terminates the current event.
                            if let payload = Self.joinSSEData(dataLines),
                               let data = payload.data(using: .utf8) {
                                continuation.yield(try JSONDecoder().decode(T.self, from: data))
                            }
                            dataLines.removeAll(keepingCapacity: true)
                        } else if let value = Self.sseDataValue(line) {
                            dataLines.append(value)
                        }
                        // event: / id: / retry: / comment (":") lines are ignored.
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    /// The value of an SSE `data:` line (prefix and one optional leading space
    /// stripped), or nil for non-data lines. Pure; unit-tested.
    static func sseDataValue(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst("data:".count)
        return value.hasPrefix(" ") ? String(value.dropFirst()) : String(value)
    }

    /// Joins one event's accumulated `data:` values with newlines (SSE allows
    /// multi-line data); nil when there were none. Pure; unit-tested.
    static func joinSSEData(_ lines: [String]) -> String? {
        lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
