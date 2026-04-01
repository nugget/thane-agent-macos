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

    /// Ollama-compatible API — port 11434, used for chat.
    var ollamaURL: URL? {
        derivedURL(port: 11434)
    }

    /// Thane API — port 8080, used for platform WebSocket and REST.
    var apiURL: URL? {
        derivedURL(port: 8080)
    }

    private func derivedURL(port: Int) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.port = port
        // Strip any path — base URL only
        components.path = ""
        return components.url
    }
}
