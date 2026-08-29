import Foundation
import Testing
@testable import thane_agent_macos

/// The date arithmetic behind the wire shapes. Kept away from EventKit on
/// purpose: these are the rules that decide which day an event lands on,
/// and they should be provable without a store, a permission prompt, or
/// whatever happens to be on this machine's calendar.
struct CalendarEventTimestampsTests {
    private static let chicago = TimeZone(identifier: "America/Chicago")!
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func instant(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    @Test
    func timestampCarriesTheEventsOwnOffsetRatherThanZulu() {
        let date = Self.instant("2026-08-29T14:00:00Z")

        // The bug this replaces: a default ISO8601DateFormatter is GMT, so
        // a 9am Chicago event went over the wire as 14:00Z with nothing to
        // say it had ever been anywhere else.
        #expect(CalendarEventTimestamps.timestamp(date, in: Self.chicago) == "2026-08-29T09:00:00-05:00")
        #expect(CalendarEventTimestamps.timestamp(date, in: Self.berlin) == "2026-08-29T16:00:00+02:00")
    }

    @Test
    func timestampReportsStandardTimeOffsetsOutsideDaylightSaving() {
        let winter = Self.instant("2026-01-15T15:00:00Z")
        #expect(CalendarEventTimestamps.timestamp(winter, in: Self.chicago) == "2026-01-15T09:00:00-06:00")
    }

    @Test
    func dateRendersTheCalendarDayInTheGivenZone() {
        // Local midnight in Berlin is the previous evening in UTC. Reading
        // the instant literally is exactly how an all-day event lost a day.
        let berlinMidnight = Self.instant("2026-08-28T22:00:00Z")
        #expect(CalendarEventTimestamps.date(berlinMidnight, in: Self.berlin) == "2026-08-29")
        #expect(CalendarEventTimestamps.date(berlinMidnight, in: Self.chicago) == "2026-08-28")
    }

    @Test
    func inclusiveLastDayTreatsAMidnightEndAsTheDayBefore() {
        // EventKit's exclusive convention: the event stopped before that
        // day began, so it does not occupy it.
        let start = Self.instant("2026-08-29T05:00:00Z")  // Aug 29 00:00 CDT
        let end = Self.instant("2026-09-01T05:00:00Z")    // Sep 1 00:00 CDT

        let last = CalendarEventTimestamps.inclusiveLastDay(start: start, end: end, in: Self.chicago)
        #expect(CalendarEventTimestamps.date(last, in: Self.chicago) == "2026-08-31")
    }

    @Test
    func inclusiveLastDayTreatsALastMomentEndAsThatSameDay() {
        // EventKit's other convention: 23:59:59 on the final day, which the
        // event does occupy. A blanket "subtract 24 hours" was wrong here.
        let start = Self.instant("2026-08-29T05:00:00Z")
        let end = Self.instant("2026-09-01T04:59:59Z")    // Aug 31 23:59:59 CDT

        let last = CalendarEventTimestamps.inclusiveLastDay(start: start, end: end, in: Self.chicago)
        #expect(CalendarEventTimestamps.date(last, in: Self.chicago) == "2026-08-31")
    }

    @Test
    func inclusiveLastDayCollapsesASingleDayEvent() {
        let start = Self.instant("2026-08-29T05:00:00Z")
        let end = Self.instant("2026-08-30T05:00:00Z")

        let last = CalendarEventTimestamps.inclusiveLastDay(start: start, end: end, in: Self.chicago)
        #expect(CalendarEventTimestamps.date(last, in: Self.chicago) == "2026-08-29")
    }

    @Test
    func inclusiveLastDayNeverPrecedesTheFirstDay() {
        let start = Self.instant("2026-08-29T05:00:00Z")

        let noEnd = CalendarEventTimestamps.inclusiveLastDay(start: start, end: nil, in: Self.chicago)
        #expect(CalendarEventTimestamps.date(noEnd, in: Self.chicago) == "2026-08-29")

        let backwards = CalendarEventTimestamps.inclusiveLastDay(
            start: start,
            end: Self.instant("2026-08-20T05:00:00Z"),
            in: Self.chicago
        )
        #expect(CalendarEventTimestamps.date(backwards, in: Self.chicago) == "2026-08-29")
    }

    @Test
    func allDayIntervalSpansMidnightToMidnightInTheTargetZone() {
        let day = Self.instant("2026-08-29T05:00:00Z")

        let interval = CalendarEventTimestamps.allDayInterval(firstDay: day, lastDay: day, in: Self.chicago)

        #expect(CalendarEventTimestamps.timestamp(interval.start, in: Self.chicago) == "2026-08-29T00:00:00-05:00")
        #expect(CalendarEventTimestamps.timestamp(interval.end, in: Self.chicago) == "2026-08-30T00:00:00-05:00")
    }

    @Test
    func allDayIntervalCoversEveryDayOfAnInclusiveRange() {
        let first = Self.instant("2026-08-31T05:00:00Z")
        let last = Self.instant("2026-09-02T05:00:00Z")

        let interval = CalendarEventTimestamps.allDayInterval(firstDay: first, lastDay: last, in: Self.chicago)

        #expect(CalendarEventTimestamps.timestamp(interval.start, in: Self.chicago) == "2026-08-31T00:00:00-05:00")
        // Exclusive end: the three days are the 31st, 1st, and 2nd.
        #expect(CalendarEventTimestamps.timestamp(interval.end, in: Self.chicago) == "2026-09-03T00:00:00-05:00")
    }

    @Test
    func allDayIntervalIsShortOnASpringForwardDay() {
        // 2026-03-08 loses an hour in Chicago, so the day is 23 hours long.
        // Adding a literal 24 hours would push the end into the next day.
        let day = Self.instant("2026-03-08T06:00:00Z")  // Mar 8 00:00 CST

        let interval = CalendarEventTimestamps.allDayInterval(firstDay: day, lastDay: day, in: Self.chicago)

        #expect(interval.duration == 23 * 3600)
        #expect(CalendarEventTimestamps.timestamp(interval.end, in: Self.chicago) == "2026-03-09T00:00:00-05:00")
    }

    @Test
    func allDayIntervalIsLongOnAFallBackDay() {
        // 2026-11-01 gains an hour in Chicago: 25 hours.
        let day = Self.instant("2026-11-01T05:00:00Z")  // Nov 1 00:00 CDT

        let interval = CalendarEventTimestamps.allDayInterval(firstDay: day, lastDay: day, in: Self.chicago)

        #expect(interval.duration == 25 * 3600)
    }

    @Test
    func allDayIntervalClampsABackwardsRange() {
        let first = Self.instant("2026-08-29T05:00:00Z")
        let last = Self.instant("2026-08-20T05:00:00Z")

        let interval = CalendarEventTimestamps.allDayInterval(firstDay: first, lastDay: last, in: Self.chicago)

        #expect(interval.duration == 24 * 3600)
        #expect(CalendarEventTimestamps.timestamp(interval.start, in: Self.chicago) == "2026-08-29T00:00:00-05:00")
    }
}
