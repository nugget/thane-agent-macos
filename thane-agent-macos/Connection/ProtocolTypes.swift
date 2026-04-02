import Foundation

// MARK: - Message Envelope

/// Base envelope for all WebSocket messages. Uses ID-based correlation
/// matching the pattern in thane-ai-agent's HA WebSocket client.
struct WSMessage: Codable {
    let id: Int64?
    let type: String
    let success: Bool?
    let result: AnyCodable?
    let error: WSError?
}

struct WSError: Codable {
    let code: String
    let message: String
}

// MARK: - Auth Handshake

struct AuthRequiredMessage: Codable {
    let type: String // "auth_required"
    let version: String
}

struct AuthMessage: Codable {
    let type: String // "auth"
    let token: String
    let clientName: String
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case type, token
        case clientName = "client_name"
        case clientID = "client_id"
    }
}

struct AuthOKMessage: Codable {
    let type: String // "auth_ok"
    let providerID: String
    let account: String

    enum CodingKeys: String, CodingKey {
        case type, account
        case providerID = "provider_id"
    }
}

struct AuthInvalidMessage: Codable {
    let type: String // "auth_failed"
    let message: String
}

// MARK: - Capability Registration

struct Capability: Codable {
    let name: String
    let version: String
    let methods: [String]
}

struct RegisterCapabilitiesMessage: Codable {
    let id: Int64
    let type: String // "register_capabilities"
    let capabilities: [Capability]
}

// MARK: - Platform Service Requests (Server → Client)

struct PlatformRequest: Codable {
    let id: Int64
    let type: String // "platform_request"
    let capability: String
    let method: String
    let params: [String: AnyCodable]?
}

struct PlatformResponse: Codable {
    let id: Int64
    let type: String // "result"
    let success: Bool
    let result: AnyCodable?
    let error: WSError?
}

// MARK: - Chat Messages (Client → Server)

struct ChatRequest: Codable {
    let id: Int64
    let type: String // "chat_request"
    let conversationID: String
    let message: String
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, message, stream
        case conversationID = "conversation_id"
    }
}

struct ChatStreamData: Codable {
    let kind: String // "token", "tool_call_start", "tool_call_done", "done"
    let content: String?
    let tool: String?
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case kind, content, tool, model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct ChatStreamMessage: Codable {
    let id: Int64
    let type: String // "chat_stream"
    let data: ChatStreamData
}

// MARK: - Heartbeat

struct PingMessage: Codable {
    let type: String // "ping"
}

struct PongMessage: Codable {
    let type: String // "pong"
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for dynamic JSON payloads.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int64.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int64:
            try container.encode(int)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type: \(type(of: value))"))
        }
    }
}
