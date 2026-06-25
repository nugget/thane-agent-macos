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

/// `nonisolated` so its Codable conformance carries no actor isolation under
/// the app's `default-isolation=MainActor` default — it is encoded both from
/// the main-actor connection path and from the nonisolated test target.
nonisolated struct AuthMessage: Codable {
    let type: String // "auth"
    let token: String
    let clientName: String
    let clientID: String
    /// Selects the server's request envelope for this connection. The app
    /// handles only the platform envelope (`platform_request`), so this is
    /// always "platform". On the canonical `/v1/realtime/ws` endpoint the
    /// server picks the envelope from this field; omitting it would default to
    /// the companion envelope, which this client does not decode.
    let connectionProtocol: String

    enum CodingKeys: String, CodingKey {
        case type, token
        case clientName = "client_name"
        case clientID = "client_id"
        case connectionProtocol = "protocol"
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
    /// Full LLM tool definitions this capability authors. Optional and
    /// additive: when present, the server synthesizes one model-facing tool
    /// per entry and dispatches it back to `method`, making this app
    /// authoritative over the schema the model sees. When nil (the field is
    /// omitted from the wire payload), the server falls back to its
    /// hand-coded tools for this capability's methods. Older servers ignore
    /// the unknown field.
    let tools: [PlatformToolDefinition]?
}

/// A companion-authored LLM tool. `inputSchema` is a JSON Schema object used
/// verbatim by the server as the tool's input schema, so the params the
/// model produces are exactly what `method`'s `Codable` request struct
/// decodes — the schema and the decoder cannot drift.
///
/// Keep composition keywords (oneOf/allOf/anyOf) out of the schema root: the
/// model providers strip top-level composition before dispatch.
nonisolated struct PlatformToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let method: String
    let tags: [String]?
    let inputSchema: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case method
        case tags
        case inputSchema = "input_schema"
    }

    /// Builds a definition whose input schema is authored as a JSON string
    /// literal — readable and reviewable as the exact schema the model sees.
    /// A unit test decodes every schema and round-trips an example payload
    /// through the paired `Codable` request struct, so a malformed literal
    /// fails CI rather than shipping a broken tool.
    ///
    /// The schema literals are compile-time constants, so a malformed or
    /// empty one is a programmer error, not runtime input. It traps via
    /// `preconditionFailure` — which is enforced in release builds too — so
    /// a bad literal can never silently advertise an invalid tool to the
    /// server. (`assertionFailure` would be compiled out of release.)
    static func make(
        name: String,
        description: String,
        method: String,
        tags: [String]? = nil,
        schemaJSON: String
    ) -> PlatformToolDefinition {
        guard let data = schemaJSON.data(using: .utf8),
              let schema = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              !schema.isEmpty else {
            preconditionFailure("invalid or empty tool schema JSON for \(name)")
        }
        return PlatformToolDefinition(
            name: name,
            description: description,
            method: method,
            tags: tags,
            inputSchema: schema
        )
    }
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

// MARK: - Heartbeat

struct PingMessage: Codable {
    let type: String // "ping"
}

struct PongMessage: Codable {
    let type: String // "pong"
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for dynamic JSON payloads.
///
/// Marked `nonisolated` so its Codable conformance carries no actor
/// isolation under the app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// default. Without it, the synthesized witness asserts it is running on the
/// main actor and traps (`dispatch_assert_queue`) when encode/decode is
/// driven from any other executor — e.g. the nonisolated test target, or any
/// future off-main caller.
nonisolated struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    static func fromEncodable<T: Encodable>(_ value: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
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

nonisolated func decodePlatformParams<T: Decodable>(_ type: T.Type, from params: [String: AnyCodable]) throws -> T {
    let data = try JSONEncoder().encode(params)
    return try JSONDecoder().decode(type, from: data)
}
