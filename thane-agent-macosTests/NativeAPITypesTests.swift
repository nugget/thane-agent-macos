import Foundation
import Testing
@testable import thane_agent_macos

/// Decode tests for the native API wire models. One representative payload per
/// model plus the omitted-optional / null variants the spec allows, and one
/// negative case — per AGENTS.md's parser-coverage baseline.
struct NativeAPITypesTests {
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesSystemStatus() throws {
        let status = try Self.decode(SystemStatus.self, """
        {
          "uptime_seconds": 480600,
          "version": { "version": "v0.9.2", "git_commit": "f92a9208" },
          "health": {
            "signal": { "name": "Signal", "ready": true, "last_check": "2026-06-24T14:30:55Z" }
          }
        }
        """)
        #expect(status.uptimeSeconds == 480600)
        #expect(status.version?["version"] == "v0.9.2")
        #expect(status.health?["signal"]?.ready == true)
        #expect(status.health?["signal"]?.name == "Signal")
    }

    @Test func decodesServiceHealthWithoutOptionalFields() throws {
        let health = try Self.decode(ServiceHealth.self, """
        { "name": "MQTT", "ready": false }
        """)
        #expect(health.name == "MQTT")
        #expect(health.ready == false)
        #expect(health.lastCheck == nil)
        #expect(health.lastError == nil)
    }

    @Test func decodesSessionStatsWithAllOptionals() throws {
        let stats = try Self.decode(SessionStats.self, """
        {
          "total_input_tokens": 148213, "total_output_tokens": 28104,
          "total_cache_creation_input_tokens": 96000, "total_cache_read_input_tokens": 312500,
          "cache_hit_rate": 0.765, "total_requests": 137, "estimated_cost_usd": 1.2843,
          "reported_balance_usd": 48.72, "context_tokens": 148213, "context_window": 200000,
          "message_count": 312,
          "by_model": {
            "thane:latest": { "total_input_tokens": 1, "total_output_tokens": 2, "total_cost_usd": 0.5 }
          }
        }
        """)
        #expect(stats.totalInputTokens == 148213)
        #expect(stats.reportedBalanceUSD == 48.72)
        #expect(stats.byModel?["thane:latest"]?.totalCostUSD == 0.5)
    }

    @Test func decodesSessionStatsWithoutOptionals() throws {
        let stats = try Self.decode(SessionStats.self, """
        {
          "total_input_tokens": 1, "total_output_tokens": 2,
          "total_cache_creation_input_tokens": 0, "total_cache_read_input_tokens": 0,
          "cache_hit_rate": 0.0, "total_requests": 0, "estimated_cost_usd": 0.0,
          "context_tokens": 0, "context_window": 200000, "message_count": 0
        }
        """)
        #expect(stats.reportedBalanceUSD == nil)
        #expect(stats.byModel == nil)
        #expect(stats.build == nil)
    }

    @Test func decodesLoopStatusWithoutOptionalFields() throws {
        let loop = try Self.decode(LoopStatus.self, """
        {
          "id": "019e7469", "name": "signal-interactive", "state": "processing",
          "started_at": "2026-06-24T14:03:21Z", "iterations": 142, "attempts": 145,
          "total_input_tokens": 1284532, "total_output_tokens": 318204, "consecutive_errors": 0
        }
        """)
        #expect(loop.name == "signal-interactive")
        #expect(loop.state == "processing")
        #expect(loop.lastError == nil)
        #expect(loop.contextWindow == nil)
    }

    @Test func decodesConversationPageWithNullCursor() throws {
        let page = try Self.decode(ConversationPage.self, """
        {
          "conversations": [
            { "id": "signal-alice", "message_count": 42,
              "created_at": "2026-06-20T08:15:00Z", "updated_at": "2026-06-24T14:31:07Z",
              "channel_binding": { "channel": "signal", "contact_name": "Alice", "is_owner": false } }
          ],
          "count": 1, "total": 1, "next_cursor": null
        }
        """)
        #expect(page.count == 1)
        #expect(page.nextCursor == nil)
        #expect(page.conversations.first?.channelBinding?.contactName == "Alice")
    }

    @Test func decodesConversationSummaryWithoutChannelBinding() throws {
        let summary = try Self.decode(ConversationSummary.self, """
        { "id": "sched-morning", "message_count": 7,
          "created_at": "2026-06-22T08:15:00Z", "updated_at": "2026-06-24T08:15:03Z" }
        """)
        #expect(summary.id == "sched-morning")
        #expect(summary.channelBinding == nil)
    }

    @Test func decodesScheduledTaskWithNullNextRun() throws {
        let task = try Self.decode(ScheduledTask.self, """
        {
          "id": "019e7469", "name": "Morning briefing",
          "schedule": { "kind": "every", "every": "15m0s", "timezone": "America/New_York" },
          "payload": { "kind": "wake", "target": "session-7f3a9c", "data": { "message": "go" } },
          "enabled": true, "created_at": "2026-06-24T08:15:00Z", "created_by": "session-7f3a9c",
          "updated_at": "2026-06-24T09:42:00Z", "next_run": null
        }
        """)
        #expect(task.name == "Morning briefing")
        #expect(task.schedule.kind == "every")
        #expect(task.schedule.every == "15m0s")
        #expect(task.payload.kind == "wake")
        #expect(task.nextRun == nil)
    }

    @Test func decodesLogEntryWithIntegerID() throws {
        let entry = try Self.decode(LogEntry.self, """
        { "id": 184213, "ts": "2026-06-24T14:31:07Z", "level": "INFO",
          "msg": "loop iteration complete", "subsystem": "scheduler" }
        """)
        #expect(entry.id == 184213)
        #expect(entry.level == "INFO")
        #expect(entry.subsystem == "scheduler")
    }

    @Test func decodesLoopEvent() throws {
        let event = try Self.decode(LoopEvent.self, """
        { "kind": "loop_iteration_complete", "ts": "2026-06-24T14:31:11Z",
          "data": { "loop_id": "019e7469", "input_tokens": 9123 } }
        """)
        #expect(event.kind == "loop_iteration_complete")
        #expect(event.ts == "2026-06-24T14:31:11Z")
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try Self.decode(SystemStatus.self, "{ not json")
        }
    }
}
