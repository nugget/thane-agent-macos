import Foundation
import Testing
@testable import thane_agent_macos

/// Tests for the pure `ServerFormat` display helpers. (`relative(_:)` depends on
/// the current clock, so its parsing half is covered via `parseISO`.)
struct ServerFormatTests {
    @Test func uptimeFormatsAcrossMagnitudes() {
        #expect(ServerFormat.uptime(nil) == "—")
        #expect(ServerFormat.uptime(0) == "—")
        #expect(ServerFormat.uptime(45 * 60) == "45m")
        #expect(ServerFormat.uptime(13 * 3600 + 30 * 60) == "13h 30m")
        #expect(ServerFormat.uptime(5 * 86_400 + 13 * 3600) == "5d 13h")
    }

    @Test func compactAbbreviatesThousandsAndMillions() {
        #expect(ServerFormat.compact(42) == "42")
        #expect(ServerFormat.compact(9123) == "9.1K")
        #expect(ServerFormat.compact(1_284_532) == "1.3M")
    }

    @Test func usdAndPercentFormat() {
        #expect(ServerFormat.usd(1.2843) == "$1.28")
        #expect(ServerFormat.percent(0.5) == "50%")
        #expect(ServerFormat.percent(0.766) == "77%")
        #expect(ServerFormat.percent(.nan) == "—")
    }

    @Test func scheduleDescribesEachKind() {
        #expect(ServerFormat.schedule(
            ScheduleSpec(kind: "every", at: nil, every: "15m0s", cron: nil, timezone: nil)) == "every 15m0s")
        #expect(ServerFormat.schedule(
            ScheduleSpec(kind: "cron", at: nil, every: nil, cron: "0 8 * * *", timezone: nil)) == "0 8 * * *")
    }

    @Test func parseISOHandlesFractionalAndPlainSeconds() {
        #expect(ServerFormat.parseISO("2026-06-24T14:31:07Z") != nil)
        #expect(ServerFormat.parseISO("2026-06-24T14:31:07.123Z") != nil)
        #expect(ServerFormat.parseISO("not a date") == nil)
    }
}
