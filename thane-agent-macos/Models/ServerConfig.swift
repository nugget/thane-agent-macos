import Foundation
import SwiftData

@Model
final class ServerConfig {
    var name: String
    var urlString: String
    var isDefault: Bool
    var createdAt: Date

    /// Persistent client UUID identifying this Mac to the server.
    /// Generated once on first config creation, stored in SwiftData.
    var clientID: String

    init(name: String = "Default", urlString: String = "", isDefault: Bool = true) {
        self.name = name
        self.urlString = urlString
        self.isDefault = isDefault
        self.createdAt = Date()
        self.clientID = UUID().uuidString
    }

    /// The base URL as entered by the user, e.g. http://pocket.local
    var url: URL? {
        URL(string: urlString)
    }

    /// URL used for Ollama-compatible chat API.
    /// Uses the base URL as-is — port routing is handled by the reverse proxy.
    var ollamaURL: URL? { url }

    /// URL used for the platform WebSocket and native REST API.
    /// Uses the base URL as-is — port routing is handled by the reverse proxy.
    var apiURL: URL? { url }

    /// The host of `urlString` when it would be blocked by App Transport
    /// Security — plaintext http:// to a non-local host — otherwise nil. Remote
    /// servers must use https://; localhost, loopback, and *.local are exempt.
    /// Pure helper; the Settings UI turns the host into a user-facing warning.
    nonisolated static func insecurePlaintextHost(in urlString: String) -> String? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "http" else { return nil }
        let host = (url.host ?? "").lowercased()
        guard !host.isEmpty else { return nil }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return nil
        }
        return host
    }
}
