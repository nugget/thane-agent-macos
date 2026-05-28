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
    func createEventRequestDecodesFromParams() throws {
        let json = Data(#"""
        {"title":"Dentist","calendar_name":"Personal","start":"2026-04-02T09:00:00Z","end":"2026-04-02T10:00:00Z","all_day":false,"location":"Downtown","notes":"bring forms","url":"https://example.com"}
        """#.utf8)
        let params = try JSONDecoder().decode([String: AnyCodable].self, from: json)

        let request = try decodePlatformParams(CalendarCreateEventRequest.self, from: params)

        #expect(request.title == "Dentist")
        #expect(request.calendarName == "Personal")
        #expect(request.allDay == false)
        #expect(request.location == "Downtown")
        #expect(request.notes == "bring forms")
        #expect(request.url == "https://example.com")
        #expect(try request.dateInterval().duration == 3600)
    }

    @Test
    func createEventRequestDefaultsOptionalFieldsToNil() throws {
        let json = Data(#"""
        {"title":"Quick","start":"2026-04-02T09:00:00Z","end":"2026-04-02T10:00:00Z"}
        """#.utf8)
        let params = try JSONDecoder().decode([String: AnyCodable].self, from: json)

        let request = try decodePlatformParams(CalendarCreateEventRequest.self, from: params)

        #expect(request.calendarName == nil)
        #expect(request.allDay == nil)
        #expect(request.location == nil)
        #expect(request.notes == nil)
        #expect(request.url == nil)
    }

    @Test
    func createEventRequestRejectsBackwardsWindow() {
        let request = CalendarCreateEventRequest(
            title: "Bad",
            calendarName: nil,
            start: "2026-04-02T10:00:00Z",
            end: "2026-04-02T09:00:00Z",
            allDay: nil,
            location: nil,
            notes: nil,
            url: nil
        )

        do {
            _ = try request.dateInterval()
            Issue.record("Expected CalendarCreateEventRequest.dateInterval() to reject a backwards window.")
        } catch let error as CalendarServiceError {
            #expect(error.code == "invalid_window")
        } catch {
            Issue.record("Expected CalendarServiceError.invalidWindow, got \(error.localizedDescription)")
        }
    }

    @Test
    @MainActor
    func calendarHandlerSupportsListAndCreate() {
        let handler = CalendarPlatformHandler(calendarService: CalendarService())
        #expect(handler.supportedMethods == ["list_events", "create_event"])
    }
}

private struct FailingCalendarHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_events"]

    func handle(method: String, params: [String : AnyCodable]) async throws -> AnyCodable {
        throw CalendarServiceError.accessDenied
    }
}
