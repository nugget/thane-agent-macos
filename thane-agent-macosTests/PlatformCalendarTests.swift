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

    @Test
    @MainActor
    func calendarListRequestDecodesWhenCalendarNamesOmitted() throws {
        // Mirrors the upstream agent's wire payload for an unfiltered
        // "what's on my calendar" call: calendar_names/query/limit are
        // omitempty on the Go side and absent from the JSON. This is the
        // exact decode path (decodePlatformParams) that threw keyNotFound
        // and failed every default list_events request before the field
        // was made optional.
        let params: [String: AnyCodable] = [
            "start": AnyCodable("2026-04-02T12:00:00Z"),
            "end": AnyCodable("2026-04-02T13:00:00Z"),
        ]

        let request = try decodePlatformParams(CalendarListRequest.self, from: params)

        #expect(request.calendarNames == nil)
        #expect(request.query == nil)
        #expect(request.limit == nil)

        let interval = try request.dateInterval()
        #expect(interval.duration == 3600)
    }

    @Test
    @MainActor
    func calendarListRequestDecodesWithCalendarNames() throws {
        let params: [String: AnyCodable] = [
            "start": AnyCodable("2026-04-02T12:00:00Z"),
            "end": AnyCodable("2026-04-02T13:00:00Z"),
            "calendar_names": AnyCodable(["Work", "Home"]),
            "query": AnyCodable("standup"),
            "limit": AnyCodable(5),
        ]

        let request = try decodePlatformParams(CalendarListRequest.self, from: params)

        #expect(request.calendarNames == ["Work", "Home"])
        #expect(request.query == "standup")
        #expect(request.limit == 5)
    }
}

private struct FailingCalendarHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_events"]

    func handle(method: String, params: [String : AnyCodable]) async throws -> AnyCodable {
        throw CalendarServiceError.accessDenied
    }
}
