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

/// The wire shapes the calendar capability emits and accepts, and the zone
/// rules behind them.
struct PlatformCalendarWireTests {
    private static let chicago = TimeZone(identifier: "America/Chicago")!

    @Test
    func eventSummaryEncodesTheDeclaredZoneAndOmitsItWhenAbsent() throws {
        let zoned = CalendarEventSummary(
            title: "Berlin kickoff",
            calendar: "Work",
            start: "2026-09-02T10:00:00+02:00",
            end: "2026-09-02T11:30:00+02:00",
            allDay: false,
            timeZone: "Europe/Berlin",
            location: nil,
            notesExcerpt: nil,
            url: nil
        )
        let zonedJSON = String(decoding: try JSONEncoder().encode(zoned), as: UTF8.self)
        #expect(zonedJSON.contains("\"time_zone\":\"Europe\\/Berlin\""))

        // A floating event declares nothing, and the key must be absent
        // rather than null so the far side can tell "no zone" from "UTC".
        let floating = CalendarEventSummary(
            title: "Focus block",
            calendar: "Work",
            start: "2026-09-02T10:00:00-05:00",
            end: "2026-09-02T11:00:00-05:00",
            allDay: false,
            timeZone: nil,
            location: nil,
            notesExcerpt: nil,
            url: nil
        )
        let encoder = JSONEncoder()
        let floatingJSON = String(decoding: try encoder.encode(floating), as: UTF8.self)
        #expect(!floatingJSON.contains("time_zone"))
    }

    @Test
    func eventSummaryRoundTripsThroughTheWire() throws {
        let original = CalendarEventSummary(
            title: "Conference",
            calendar: "Work",
            start: "2026-09-02",
            end: "2026-09-04",
            allDay: true,
            timeZone: nil,
            location: nil,
            notesExcerpt: nil,
            url: nil
        )

        let decoded = try JSONDecoder().decode(
            CalendarEventSummary.self,
            from: try JSONEncoder().encode(original)
        )

        #expect(decoded == original)
    }

    @Test
    func createEventResolvesAnAllDayRangeAsWholeDaysInTheTargetZone() throws {
        let request = CalendarCreateEventRequest(
            title: "Conference",
            calendarName: "Work",
            start: "2026-09-02",
            end: "2026-09-04",
            allDay: true,
            location: nil,
            notes: nil,
            url: nil
        )

        let interval = try request.dateInterval(in: Self.chicago)

        #expect(CalendarEventTimestamps.timestamp(interval.start, in: Self.chicago) == "2026-09-02T00:00:00-05:00")
        // Inclusive through the 4th, so the exclusive end is the 5th.
        #expect(CalendarEventTimestamps.timestamp(interval.end, in: Self.chicago) == "2026-09-05T00:00:00-05:00")
    }

    @Test
    func createEventAcceptsASingleAllDayDate() throws {
        let request = CalendarCreateEventRequest(
            title: "Trash day",
            calendarName: nil,
            start: "2026-08-30",
            end: "2026-08-30",
            allDay: true,
            location: nil,
            notes: nil,
            url: nil
        )

        let interval = try request.dateInterval(in: Self.chicago)

        #expect(interval.duration == 24 * 3600)
        #expect(CalendarEventTimestamps.timestamp(interval.start, in: Self.chicago) == "2026-08-30T00:00:00-05:00")
    }

    @Test
    func createEventIgnoresTheClockOnAnAllDayTimestamp() throws {
        // The write-side twin of the read bug: a UTC midnight handed to an
        // all-day event is the previous evening in Chicago, and reading it
        // as an instant files the event a day early. Only the date counts.
        let request = CalendarCreateEventRequest(
            title: "Conference",
            calendarName: nil,
            start: "2026-09-02T00:00:00Z",
            end: "2026-09-02T00:00:00Z",
            allDay: true,
            location: nil,
            notes: nil,
            url: nil
        )

        let interval = try request.dateInterval(in: Self.chicago)

        #expect(CalendarEventTimestamps.timestamp(interval.start, in: Self.chicago) == "2026-09-02T00:00:00-05:00")
    }

    @Test
    func createEventRejectsABackwardsAllDayRange() {
        let request = CalendarCreateEventRequest(
            title: "Impossible",
            calendarName: nil,
            start: "2026-09-04",
            end: "2026-09-02",
            allDay: true,
            location: nil,
            notes: nil,
            url: nil
        )

        do {
            _ = try request.dateInterval(in: Self.chicago)
            Issue.record("Expected a backwards all-day range to be rejected.")
        } catch let error as CalendarServiceError {
            #expect(error.code == "invalid_window")
        } catch {
            Issue.record("Expected CalendarServiceError.invalidWindow, got \(error.localizedDescription)")
        }
    }

    @Test
    func createEventStillTreatsATimedRangeAsInstants() throws {
        let request = CalendarCreateEventRequest(
            title: "Dentist",
            calendarName: nil,
            start: "2026-09-02T09:00:00-05:00",
            end: "2026-09-02T10:00:00-05:00",
            allDay: false,
            location: nil,
            notes: nil,
            url: nil
        )

        #expect(try request.dateInterval(in: Self.chicago).duration == 3600)
    }

    @Test
    func createEventRejectsAMalformedAllDayBound() {
        // Truncating to the first ten characters before validating would
        // accept these as September 2. Both are malformed and must say so.
        for bad in ["2026-09-02garbage", "2026-09-02T25:99:99Z", "2026-09-02T"] {
            let request = CalendarCreateEventRequest(
                title: "Conference",
                calendarName: nil,
                start: bad,
                end: "2026-09-02",
                allDay: true,
                location: nil,
                notes: nil,
                url: nil
            )

            do {
                _ = try request.dateInterval(in: Self.chicago)
                Issue.record("Expected \(bad) to be rejected as an all-day bound.")
            } catch let error as CalendarServiceError {
                #expect(error.code == "invalid_timestamp")
            } catch {
                Issue.record("Expected invalid_timestamp for \(bad), got \(error.localizedDescription)")
            }
        }
    }

    @Test
    func dateOnlyDetectionSeparatesDatesFromTimestamps() {
        #expect(CalendarTimestamp.isDateOnly("2026-08-29"))
        #expect(!CalendarTimestamp.isDateOnly("2026-08-29T00:00:00Z"))
        #expect(!CalendarTimestamp.isDateOnly("2026-08-2"))
        #expect(!CalendarTimestamp.isDateOnly("not a date"))
    }
}

/// The list_events request contract: what a bound may look like, and how
/// many events can come back.
struct PlatformCalendarRequestContractTests {
    private static let chicago = TimeZone(identifier: "America/Chicago")!

    private static func request(start: String, end: String, limit: Int? = nil) -> CalendarListRequest {
        CalendarListRequest(start: start, end: end, calendarNames: nil, query: nil, limit: limit)
    }

    private static func iso(_ date: Date) -> String {
        CalendarEventTimestamps.timestamp(date, in: chicago)
    }

    @Test
    func aBoundWithItsOwnOffsetIsTakenAtFaceValue() throws {
        // The offsets deliberately differ from the zoneless fallback zone:
        // Chicago is -05:00 on this date, and a bound at -05:00 would pass
        // even if the implementation threw the offset away and parsed the
        // digits locally. +02:00 only lands on 2:00 AM Chicago if the
        // embedded offset actually won.
        let interval = try Self.request(
            start: "2026-08-29T09:00:00+02:00",
            end: "2026-08-29T17:00:00+02:00"
        ).dateInterval(zonelessIn: Self.chicago)

        #expect(Self.iso(interval.start) == "2026-08-29T02:00:00-05:00")
        #expect(Self.iso(interval.end) == "2026-08-29T10:00:00-05:00")
        #expect(interval.duration == 8 * 3600)
    }

    @Test
    func aZonelessBoundIsReadLocallyRatherThanAsUTC() throws {
        // Reading these as UTC is the silent five-hour shift the zone work
        // removed; rejecting them outright was the behaviour before this.
        for start in ["2026-08-29T09:00:00", "2026-08-29 09:00:00", "2026-08-29 09:00", "2026-08-29T09:00"] {
            let interval = try Self.request(start: start, end: "2026-08-29T17:00:00-05:00")
                .dateInterval(zonelessIn: Self.chicago)
            #expect(Self.iso(interval.start) == "2026-08-29T09:00:00-05:00", "start form \(start)")
        }
    }

    @Test
    func aBareDateIsLocalMidnight() throws {
        let interval = try Self.request(start: "2026-08-29", end: "2026-08-30")
            .dateInterval(zonelessIn: Self.chicago)

        #expect(Self.iso(interval.start) == "2026-08-29T00:00:00-05:00")
        #expect(Self.iso(interval.end) == "2026-08-30T00:00:00-05:00")
    }

    @Test
    func aMalformedBoundIsStillRejected() {
        do {
            _ = try Self.request(start: "next tuesday", end: "2026-08-30")
                .dateInterval(zonelessIn: Self.chicago)
            Issue.record("Expected an unparseable bound to be rejected.")
        } catch let error as CalendarServiceError {
            #expect(error.code == "invalid_timestamp")
        } catch {
            Issue.record("Expected invalid_timestamp, got \(error.localizedDescription)")
        }
    }

    @Test
    func anOmittedLimitTakesTheDefault() throws {
        #expect(try Self.request(start: "2026-08-29", end: "2026-08-30").resolvedLimit()
            == CalendarService.defaultEventLimit)
    }

    @Test
    func anOversizedLimitIsCappedRatherThanRejected() throws {
        // The ceiling exists to protect the reader's context, not to police
        // the caller — asking for too much should still answer.
        #expect(try Self.request(start: "2026-08-29", end: "2026-08-30", limit: 5000).resolvedLimit()
            == CalendarService.maxEventLimit)
    }

    @Test
    func aReasonableLimitIsHonoured() throws {
        #expect(try Self.request(start: "2026-08-29", end: "2026-08-30", limit: 5).resolvedLimit() == 5)
    }

    @Test
    func aNonPositiveLimitIsRejected() {
        // Zero could mean "none" or "no limit". Both are guesses at intent,
        // and either guess silently changes how much calendar comes back.
        for bad in [0, -1] {
            do {
                _ = try Self.request(start: "2026-08-29", end: "2026-08-30", limit: bad).resolvedLimit()
                Issue.record("Expected limit \(bad) to be rejected.")
            } catch let error as CalendarServiceError {
                #expect(error.code == "invalid_limit")
            } catch {
                Issue.record("Expected invalid_limit for \(bad), got \(error.localizedDescription)")
            }
        }
    }

    @Test
    func theResponseCarriesWhetherItWasTruncated() throws {
        let complete = CalendarListResponse(events: [], truncated: false)
        let capped = CalendarListResponse(events: [], truncated: true)

        let completeJSON = String(decoding: try JSONEncoder().encode(complete), as: UTF8.self)
        let cappedJSON = String(decoding: try JSONEncoder().encode(capped), as: UTF8.self)

        #expect(completeJSON.contains("\"truncated\":false"))
        #expect(cappedJSON.contains("\"truncated\":true"))

        let decoded = try JSONDecoder().decode(CalendarListResponse.self, from: Data(cappedJSON.utf8))
        #expect(decoded.truncated)
    }
}
