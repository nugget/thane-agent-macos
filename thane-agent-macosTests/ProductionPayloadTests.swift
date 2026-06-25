import Foundation
import Testing
@testable import thane_agent_macos

/// Decode tests against the EXACT shapes the production agent (v0.9.2-655)
/// returns, captured live from pocket. Guards against the System/Sessions panels
/// silently failing to populate.
struct ProductionPayloadTests {
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesProductionSystem() throws {
        let status = try Self.decode(SystemStatus.self, """
        {"health":{"companion":{"name":"companion","ready":true,"last_check":"2026-06-25T16:01:24-05:00"},"lmstudio:centro":{"name":"lmstudio:centro","ready":true,"last_check":"2026-06-25T16:01:19-05:00"}},"status":"healthy","uptime_seconds":1228,"version":{"arch":"arm64","build_time":"2026-06-25T17:43:30Z","git_branch":"main","git_commit":"d2cc2108","go_version":"go1.26.1","os":"darwin","uptime":"20m28s","version":"v0.9.2-655-gd2cc2108"}}
        """)
        #expect(status.uptimeSeconds == 1228)
        #expect(status.version?["version"] == "v0.9.2-655-gd2cc2108")
        #expect(status.health?.count == 2)
        #expect(status.health?["companion"]?.ready == true)
    }

    @Test func decodesProductionSessionStats() throws {
        let stats = try Self.decode(SessionStats.self, """
        {"total_input_tokens":0,"total_output_tokens":0,"total_cache_creation_input_tokens":0,"total_cache_read_input_tokens":0,"cache_hit_rate":0,"total_requests":0,"estimated_cost_usd":0,"context_tokens":0,"context_window":1000000,"message_count":31445,"build":{"arch":"arm64","build_time":"2026-06-25T17:43:30Z","git_branch":"main","git_commit":"d2cc2108","go_version":"go1.26.1","os":"darwin","uptime":"20m29s","version":"v0.9.2-655-gd2cc2108"}}
        """)
        #expect(stats.contextWindow == 1_000_000)
        #expect(stats.messageCount == 31445)
        #expect(stats.cacheHitRate == 0)
        #expect(stats.reportedBalanceUSD == nil)
    }
}
