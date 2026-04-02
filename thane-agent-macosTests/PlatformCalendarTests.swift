import Foundation
import Testing
@testable import thane_agent_macos

struct PlatformCalendarTests {
    @Test
    func calendarListRequestParsesFractionalSeconds() throws {
        let request = CalendarListRequest(
            start: "2026-04-02T12:34:56.789Z",
            end: "2026-04-02T13:34:56.789Z",
            calendarNames: ["Work"],
            query: "standup",
            limit: 5
        )

        let interval = try request.dateInterval()

        #expect(interval.duration == 3600)
    }

    @Test
    func calendarListRequestRejectsBackwardsWindow() {
        let request = CalendarListRequest(
            start: "2026-04-02T13:34:56Z",
            end: "2026-04-02T12:34:56Z",
            calendarNames: [],
            query: nil,
            limit: nil
        )

        do {
            _ = try request.dateInterval()
            Issue.record("Expected CalendarListRequest.dateInterval() to reject a backwards window.")
        } catch let error as CalendarServiceError {
            #expect(error.code == "invalid_window")
        } catch {
            Issue.record("Expected CalendarServiceError.invalidWindow, got \(error.localizedDescription)")
        }
    }

    @Test
    @MainActor
    func routerPreservesStructuredPlatformErrorCodes() async {
        let router = PlatformServiceRouter()
        router.register(capability: "macos.calendar", handler: FailingCalendarHandler())

        let response = await router.handle(request: PlatformRequest(
            id: 42,
            type: "platform_request",
            capability: "macos.calendar",
            method: "list_events",
            params: nil
        ))

        #expect(response.success == false)
        #expect(response.error?.code == "calendar_access_denied")
        #expect(response.error?.message == "Calendar access was denied.")
    }
}

private struct FailingCalendarHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_events"]

    func handle(method: String, params: [String : AnyCodable]) async throws -> AnyCodable {
        throw CalendarServiceError.accessDenied
    }
}
