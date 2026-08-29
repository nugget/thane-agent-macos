import Foundation

/// How one event's start and end are written on the wire.
///
/// A calendar event is not an instant with a zone bolted on; it is either a
/// span of clock time in a particular place, or a run of whole days in no
/// place at all. The two need different shapes, and conflating them is what
/// made every event read as UTC and pushed all-day events east of the
/// meridian onto the wrong date.
///
/// Kept free of EventKit so the date arithmetic — which is where the day
/// boundaries and DST transitions bite — is testable without a store, a
/// permission prompt, or a real calendar behind it.
nonisolated enum CalendarEventTimestamps {
    /// A timed event's boundary, written with the offset of the zone the
    /// event is scheduled in (`2026-08-29T09:00:00-05:00`).
    ///
    /// The offset is the whole point. A default-constructed
    /// `ISO8601DateFormatter` writes GMT, which discards the only evidence
    /// the far side has of what clock the event sits on.
    static func timestamp(_ date: Date, in zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    /// An all-day event's boundary, written as a bare calendar date
    /// (`2026-08-29`).
    ///
    /// An all-day event has no time and no zone: it occupies a date in
    /// whatever place the person keeping it will be. Writing it as an
    /// instant forces a zone onto it, and the reader then has to guess
    /// which one — the guess this format exists to eliminate.
    static func date(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The last day an all-day event actually occupies, as an inclusive
    /// date.
    ///
    /// EventKit is not consistent about what the end of an all-day event
    /// means: depending on how the event was authored and synced, the end
    /// is either the final moment of the last day (23:59:59) or midnight
    /// beginning the day after. Only one of those days is occupied, and
    /// only this side can tell which — it has the event's own calendar and
    /// zone, where the far side has neither.
    ///
    /// Deciding it here is the point. It replaces a downstream heuristic
    /// that subtracted a fixed 24 hours and was therefore wrong for one of
    /// the two conventions, and it means the wire carries an answer rather
    /// than a value needing interpretation.
    static func inclusiveLastDay(start: Date, end: Date?, in zone: TimeZone) -> Date {
        let calendar = dayCalendar(in: zone)
        let firstDay = calendar.startOfDay(for: start)

        guard let end else {
            return firstDay
        }

        // Midnight means the event stopped before that day began, so the
        // day it occupies last is the one before. Any other time of day
        // falls inside the final day itself.
        var lastDay = calendar.startOfDay(for: end)
        if end == lastDay {
            lastDay = calendar.date(byAdding: .day, value: -1, to: lastDay) ?? firstDay
        }

        return max(lastDay, firstDay)
    }

    /// The half-open instants EventKit wants for an all-day event covering
    /// an inclusive range of dates, resolved in the target calendar's zone.
    ///
    /// Written as midnight-to-midnight rather than by adding hours: a day
    /// containing a DST transition is 23 or 25 hours long, and arithmetic
    /// that assumes 24 lands an event an hour into the wrong day twice a
    /// year.
    static func allDayInterval(firstDay: Date, lastDay: Date, in zone: TimeZone) -> DateInterval {
        let calendar = dayCalendar(in: zone)
        let start = calendar.startOfDay(for: firstDay)
        let inclusiveEnd = max(calendar.startOfDay(for: lastDay), start)
        let end = calendar.date(byAdding: .day, value: 1, to: inclusiveEnd) ?? inclusiveEnd
        return DateInterval(start: start, end: end)
    }

    private static func dayCalendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}
