import Foundation

// Wire models for the Thane Native API (`/v1/...`), consumed by the native data
// panels. All `nonisolated` + `Sendable` so they decode off the main actor
// (the polling managers and the test target). snake_case is mapped per-type via
// `CodingKeys`, matching `ProtocolTypes.swift` (not `.convertFromSnakeCase`).
//
// Anything the OpenAPI spec marks omittable or nullable is modeled optional so
// a partial/churn-prone schema change degrades gracefully rather than failing
// the whole decode. `telemetry/*` and Model Routing are intentionally NOT
// modeled here — they are flagged churn-prone and get their own adapter later.

// MARK: - System

/// Open string map of build/runtime metadata (version, commit, branch,
/// go_version, build_time, …). The spec declares these keys open, not fixed.
typealias VersionInfo = [String: String]

nonisolated struct SystemStatus: Decodable, Sendable {
    let uptimeSeconds: Int?
    let version: VersionInfo?
    let health: [String: ServiceHealth]?

    enum CodingKeys: String, CodingKey {
        case uptimeSeconds = "uptime_seconds"
        case version
        case health
    }
}

nonisolated struct ServiceHealth: Decodable, Sendable {
    let name: String
    let ready: Bool
    let lastCheck: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case name, ready
        case lastCheck = "last_check"
        case lastError = "last_error"
    }
}

nonisolated struct LogEntry: Decodable, Sendable, Identifiable {
    let id: Int64
    let ts: String
    let level: String
    let msg: String
    let subsystem: String?
    let loopName: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case id, ts, level, msg, subsystem
        case loopName = "loop_name"
        case requestID = "request_id"
    }
}

// MARK: - Sessions

nonisolated struct SessionStats: Decodable, Sendable {
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheCreationInputTokens: Int
    let totalCacheReadInputTokens: Int
    let cacheHitRate: Double
    let totalRequests: Int
    let estimatedCostUSD: Double
    let reportedBalanceUSD: Double?
    let contextTokens: Int
    let contextWindow: Int
    let messageCount: Int
    let byModel: [String: UsageSummary]?
    let build: VersionInfo?

    enum CodingKeys: String, CodingKey {
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case totalCacheCreationInputTokens = "total_cache_creation_input_tokens"
        case totalCacheReadInputTokens = "total_cache_read_input_tokens"
        case cacheHitRate = "cache_hit_rate"
        case totalRequests = "total_requests"
        case estimatedCostUSD = "estimated_cost_usd"
        case reportedBalanceUSD = "reported_balance_usd"
        case contextTokens = "context_tokens"
        case contextWindow = "context_window"
        case messageCount = "message_count"
        case byModel = "by_model"
        case build
    }
}

nonisolated struct UsageSummary: Decodable, Sendable {
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCostUSD: Double

    enum CodingKeys: String, CodingKey {
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case totalCostUSD = "total_cost_usd"
    }
}

// MARK: - Loops

nonisolated struct LoopStatus: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let state: String
    let startedAt: String
    let iterations: Int
    let attempts: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let consecutiveErrors: Int
    let contextWindow: Int?
    let lastError: String?
    let handlerOnly: Bool?
    let eventDriven: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, state, iterations, attempts
        case startedAt = "started_at"
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case consecutiveErrors = "consecutive_errors"
        case contextWindow = "context_window"
        case lastError = "last_error"
        case handlerOnly = "handler_only"
        case eventDriven = "event_driven"
    }
}

/// A single loop lifecycle event from the `/v1/loops/events` SSE stream. We use
/// it only as a "something changed" wake signal, so the kind-specific `data` is
/// kept dynamic.
nonisolated struct LoopEvent: Decodable, Sendable {
    let kind: String
    let ts: String
    let data: AnyCodable?
}

// MARK: - Conversations

nonisolated struct ChannelBinding: Decodable, Sendable {
    let channel: String?
    let address: String?
    let contactName: String?
    let trustZone: String?
    let isOwner: Bool?

    enum CodingKeys: String, CodingKey {
        case channel, address
        case contactName = "contact_name"
        case trustZone = "trust_zone"
        case isOwner = "is_owner"
    }
}

nonisolated struct ConversationSummary: Decodable, Sendable, Identifiable {
    let id: String
    let messageCount: Int
    let createdAt: String
    let updatedAt: String
    let channelBinding: ChannelBinding?

    enum CodingKeys: String, CodingKey {
        case id
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case channelBinding = "channel_binding"
    }
}

nonisolated struct ConversationPage: Decodable, Sendable {
    let conversations: [ConversationSummary]
    let count: Int
    let total: Int
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case conversations, count, total
        case nextCursor = "next_cursor"
    }
}

// MARK: - Schedules (read-only)

nonisolated struct ScheduleSpec: Decodable, Sendable {
    let kind: String
    let at: String?
    let every: String?
    let cron: String?
    let timezone: String?
}

nonisolated struct SchedulePayload: Decodable, Sendable {
    let kind: String
    let target: String?
    let data: AnyCodable?
}

nonisolated struct ScheduledTask: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let schedule: ScheduleSpec
    let payload: SchedulePayload
    let enabled: Bool
    let createdAt: String
    let updatedAt: String
    let createdBy: String?
    let nextRun: String?

    enum CodingKeys: String, CodingKey {
        case id, name, schedule, payload, enabled
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
        case nextRun = "next_run"
    }
}
