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
        query: [URLQueryItem]
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw NativeAPIError.badURL(path)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NativeAPIError.badURL(path) }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
