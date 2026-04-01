import Foundation
import SwiftData

@Model
final class ServerConfig {
    var name: String
    var urlString: String
    var isDefault: Bool
    var createdAt: Date

    /// Persistent client UUID identifying this Mac to the server.
    /// Stored alongside the config rather than in Keychain for simplicity.
    /// Generated once on first config creation.
    var clientID: String

    init(name: String = "Default", urlString: String = "", isDefault: Bool = true) {
        self.name = name
        self.urlString = urlString
        self.isDefault = isDefault
        self.createdAt = Date()
        self.clientID = UUID().uuidString
    }

    var url: URL? {
        URL(string: urlString)
    }
}
