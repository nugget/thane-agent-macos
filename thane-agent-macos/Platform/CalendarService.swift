import EventKit
import Foundation

enum CalendarServiceError: PlatformServiceError, Sendable {
    case invalidTimestamp(String, String)
    case invalidWindow
    case accessDenied
    case restricted
    case writeOnlyAccess
    case noMatchingCalendars([String])
    case noWritableCalendar
    case saveFailed(String)
    case invalidURL(String)
    case unsupportedMethod(String)

    nonisolated var code: String {
        switch self {
        case .invalidTimestamp:
            "invalid_timestamp"
        case .invalidWindow:
            "invalid_window"
        case .accessDenied:
            "calendar_access_denied"
        case .restricted:
            "calendar_access_restricted"
        case .writeOnlyAccess:
            "calendar_access_write_only"
        case .noMatchingCalendars:
            "calendar_not_found"
        case .noWritableCalendar:
            "calendar_no_writable_calendar"
        case .saveFailed:
            "calendar_save_failed"
        case .invalidURL:
            "invalid_url"
        case .unsupportedMethod:
            "unknown_method"
        }
    }

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidTimestamp(let field, let value):
            "Invalid \(field) timestamp: \(value)"
        case .invalidWindow:
            "Calendar request end must be after start."
        case .accessDenied:
            "Calendar access was denied."
        case .restricted:
            "Calendar access is restricted on this Mac."
        case .writeOnlyAccess:
            "Calendar access is write-only; read access is required."
        case .noMatchingCalendars(let names):
            "No matching calendars found for: \(names.joined(separator: ", "))"
        case .noWritableCalendar:
            "No writable calendar is available for new events."
        case .saveFailed(let reason):
            "Failed to save calendar event: \(reason)"
        case .invalidURL(let value):
            "Invalid event URL: \(value)"
        case .unsupportedMethod(let method):
            "Method \(method) is not supported by macos.calendar."
        }
    }
}

/// ISO8601 timestamp parsing shared by the calendar request types.
nonisolated enum CalendarTimestamp {
    static func parse(_ value: String, field: String) throws -> Date {
        if let date = formatter(fractionalSeconds: false).date(from: value) {
            return date
        }
        if let date = formatter(fractionalSeconds: true).date(from: value) {
            return date
        }
        throw CalendarServiceError.invalidTimestamp(field, value)
    }

    /// Parses a bare `yyyy-MM-dd` date as midnight in the given zone.
    ///
    /// An all-day event is a run of days, so its bounds arrive as dates.
    /// Reading one as a UTC instant and handing that to EventKit is how an
    /// all-day event ends up on the day before in every zone west of the
    /// meridian, which is the write-side twin of the read bug.
    static func parseDate(_ value: String, field: String, in zone: TimeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else {
            throw CalendarServiceError.invalidTimestamp(field, value)
        }
        return date
    }

    /// Whether a value names a whole date rather than a moment.
    static func isDateOnly(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 10 else {
            return false
        }
        return trimmed.allSatisfy { $0.isNumber || $0 == "-" }
    }

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

// Marked `nonisolated` so the test target can decode/read these under the
// app's MainActor-default isolation (see ContactsService for the rationale).
nonisolated struct CalendarListRequest: Codable, Equatable, Sendable {
    let start: String
    let end: String
    // Optional, not required. The upstream agent tags this field
    // `json:"calendar_names,omitempty"` and omits it entirely for the
    // common "all calendars" query, so the key is absent from the wire
    // payload. A non-optional `[String]` made JSONDecoder throw
    // `keyNotFound` and fail every unfiltered list_events request. nil
    // and [] are both treated as "no calendar filter" downstream.
    let calendarNames: [String]?
    let query: String?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case calendarNames = "calendar_names"
        case query
        case limit
    }

    nonisolated func dateInterval() throws -> DateInterval {
        let startDate = try CalendarTimestamp.parse(start, field: "start")
        let endDate = try CalendarTimestamp.parse(end, field: "end")
        guard endDate > startDate else {
            throw CalendarServiceError.invalidWindow
        }
        return DateInterval(start: startDate, end: endDate)
    }
}

nonisolated struct CalendarListResponse: Codable, Equatable, Sendable {
    let events: [CalendarEventSummary]
}

// Marked `nonisolated` so the test target can decode/read these under the
// app's MainActor-default isolation (see ContactsService for the rationale).
nonisolated struct CalendarCreateEventRequest: Codable, Equatable, Sendable {
    let title: String
    let calendarName: String?
    let start: String
    let end: String
    let allDay: Bool?
    let location: String?
    let notes: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case title
        case calendarName = "calendar_name"
        case start
        case end
        case allDay = "all_day"
        case location
        case notes
        case url
    }

    /// Resolves the interval to store, in the zone the event will live in.
    ///
    /// An all-day event is given as inclusive dates and becomes the
    /// midnight-to-midnight span covering them; both bounds are resolved in
    /// `zone` rather than UTC, so the days written are the days meant. A
    /// timed event keeps the instants it was given.
    nonisolated func dateInterval(in zone: TimeZone = .current) throws -> DateInterval {
        if allDay == true {
            let firstDay = try CalendarTimestamp.parseDate(startDateValue, field: "start", in: zone)
            let lastDay = try CalendarTimestamp.parseDate(endDateValue, field: "end", in: zone)
            guard lastDay >= firstDay else {
                throw CalendarServiceError.invalidWindow
            }
            return CalendarEventTimestamps.allDayInterval(firstDay: firstDay, lastDay: lastDay, in: zone)
        }

        let startDate = try CalendarTimestamp.parse(start, field: "start")
        let endDate = try CalendarTimestamp.parse(end, field: "end")
        guard endDate > startDate else {
            throw CalendarServiceError.invalidWindow
        }
        return DateInterval(start: startDate, end: endDate)
    }

    /// The date portion of `start`, so an all-day event can be given either
    /// as a bare date or as a full timestamp whose clock is ignored.
    private var startDateValue: String { Self.dateComponent(of: start) }
    private var endDateValue: String { Self.dateComponent(of: end) }

    private static func dateComponent(of value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if CalendarTimestamp.isDateOnly(trimmed) {
            return trimmed
        }
        return String(trimmed.prefix(10))
    }
}

nonisolated struct CalendarCreateEventResponse: Codable, Equatable, Sendable {
    let eventIdentifier: String
    let event: CalendarEventSummary

    enum CodingKeys: String, CodingKey {
        case eventIdentifier = "event_identifier"
        case event
    }
}

nonisolated struct CalendarEventSummary: Codable, Equatable, Sendable {
    let title: String
    let calendar: String
    /// Inclusive start. For a timed event an RFC3339 timestamp carrying the
    /// offset of the zone the event is scheduled in; for an all-day event a
    /// bare `yyyy-MM-dd` date, which has no time and no zone.
    let start: String
    /// End of the event, in the same shape as `start`. For a timed event
    /// this is exclusive; for an all-day event it is the **inclusive** last
    /// date the event occupies, already resolved against the event's own
    /// calendar so the reader never has to guess whether EventKit meant
    /// 23:59:59 or the following midnight.
    let end: String
    let allDay: Bool
    /// IANA name of the zone the event is scheduled in, when it declares
    /// one. This is intent, not decoration: an event recorded in
    /// `Europe/Berlin` says the person keeping it expects to be in Berlin.
    /// Absent for all-day events, which have no zone, and for floating
    /// events, where the offset on the timestamps is all that is known.
    let timeZone: String?
    let location: String?
    let notesExcerpt: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case title
        case calendar
        case start
        case end
        case allDay = "all_day"
        case timeZone = "time_zone"
        case location
        case notesExcerpt = "notes_excerpt"
        case url
    }
}

actor CalendarService {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func authorizationState() -> EventKitAuthorizationState {
        EventKitAuthorizationState(status: EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccessIfNeeded() async throws -> EventKitAuthorizationState {
        let current = authorizationState()
        guard current == .notDetermined else {
            return current
        }

        // EKEventStore.requestFullAccessToEvents() needs the main run loop to be
        // servicing events for the TCC dialog to appear. Use a dedicated store on
        // the main actor so we don't send the actor-isolated store across boundaries.
        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            Task { @MainActor in
                let requestStore = EKEventStore()
                requestStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        // The completion handler result is authoritative — tccd may not have
        // committed to the database yet when authorizationStatus(for:) is called.
        return granted ? .fullAccess : .denied
    }

    func listEvents(request: CalendarListRequest) async throws -> CalendarListResponse {
        try await ensureReadAccess()

        let interval = try request.dateInterval()
        let calendars = try selectedCalendars(named: request.calendarNames ?? [])
        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: calendars
        )

        let normalizedQuery = request.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var events = store.events(matching: predicate)
            .sorted { lhs, rhs in
                lhs.startDate < rhs.startDate
            }
            .filter { event in
                guard let normalizedQuery, !normalizedQuery.isEmpty else {
                    return true
                }

                let haystack = [
                    event.title,
                    event.location,
                    event.notes,
                ]
                .compactMap { $0?.lowercased() }
                .joined(separator: "\n")

                return haystack.contains(normalizedQuery)
            }

        if let limit = request.limit, limit > 0, events.count > limit {
            events = Array(events.prefix(limit))
        }

        return CalendarListResponse(events: events.map(makeSummary))
    }

    func createEvent(request: CalendarCreateEventRequest) async throws -> CalendarCreateEventResponse {
        try await ensureWriteAccess()

        let calendar = try targetCalendar(named: request.calendarName)
        let interval = try request.dateInterval(in: .current)

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = request.title
        event.startDate = interval.start
        event.endDate = interval.end
        event.isAllDay = request.allDay ?? false
        event.location = Self.normalizedOrNil(request.location)
        event.notes = Self.normalizedOrNil(request.notes)
        if let urlString = Self.normalizedOrNil(request.url) {
            guard let url = URL(string: urlString) else {
                throw CalendarServiceError.invalidURL(urlString)
            }
            event.url = url
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.saveFailed(error.localizedDescription)
        }

        // A successful save must yield an identifier; without it the caller
        // can't reference the event for follow-up (update/delete). Fail loudly
        // rather than returning an empty identifier that looks like success.
        guard let identifier = event.eventIdentifier else {
            throw CalendarServiceError.saveFailed("event was saved but no identifier was assigned")
        }

        return CalendarCreateEventResponse(
            eventIdentifier: identifier,
            event: makeSummary(event: event)
        )
    }

    private func ensureReadAccess() async throws {
        switch authorizationState() {
        case .fullAccess:
            return
        case .notDetermined:
            let updatedState = try await requestAccessIfNeeded()
            if updatedState != .fullAccess {
                throw CalendarServiceError.accessDenied
            }
        case .denied:
            throw CalendarServiceError.accessDenied
        case .restricted:
            throw CalendarServiceError.restricted
        case .writeOnly:
            throw CalendarServiceError.writeOnlyAccess
        case .unknown:
            throw CalendarServiceError.accessDenied
        }
    }

    private func ensureWriteAccess() async throws {
        switch authorizationState() {
        case .fullAccess, .writeOnly:
            return
        case .notDetermined:
            let updatedState = try await requestAccessIfNeeded()
            guard updatedState == .fullAccess || updatedState == .writeOnly else {
                throw CalendarServiceError.accessDenied
            }
        case .denied:
            throw CalendarServiceError.accessDenied
        case .restricted:
            throw CalendarServiceError.restricted
        case .unknown:
            throw CalendarServiceError.accessDenied
        }
    }

    private func targetCalendar(named name: String?) throws -> EKCalendar {
        if let trimmed = Self.normalizedOrNil(name) {
            let normalized = trimmed.lowercased()
            if let match = store.calendars(for: .event).first(where: { $0.title.lowercased() == normalized }) {
                return match
            }
            throw CalendarServiceError.noMatchingCalendars([trimmed])
        }

        guard let defaultCalendar = store.defaultCalendarForNewEvents else {
            throw CalendarServiceError.noWritableCalendar
        }
        return defaultCalendar
    }

    private func selectedCalendars(named names: [String]) throws -> [EKCalendar]? {
        let normalizedNames = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !normalizedNames.isEmpty else {
            return nil
        }

        let matches = store.calendars(for: .event).filter { calendar in
            normalizedNames.contains(calendar.title.lowercased())
        }

        guard !matches.isEmpty else {
            throw CalendarServiceError.noMatchingCalendars(names)
        }

        return matches
    }

    private func makeSummary(event: EKEvent) -> CalendarEventSummary {
        // EKEvent.calendar is implicitly unwrapped and is nil on an event
        // that has not been filed yet, so read it defensively rather than
        // trapping on a shape the type system claims cannot happen.
        let calendarTitle = Self.normalizedOrNil(event.calendar?.title) ?? "(unknown calendar)"
        let common = (
            title: Self.normalizedOrNil(event.title) ?? "(untitled event)",
            calendar: calendarTitle,
            location: Self.normalizedOrNil(event.location),
            notes: Self.truncateNotes(event.notes),
            url: event.url?.absoluteString
        )

        if event.isAllDay {
            // Resolve the days in the event's own zone. A day boundary is
            // only meaningful somewhere, and this side is the only one that
            // knows where.
            let zone = Self.allDayZone(for: event)
            let lastDay = CalendarEventTimestamps.inclusiveLastDay(
                start: event.startDate,
                end: event.endDate,
                in: zone
            )
            return CalendarEventSummary(
                title: common.title,
                calendar: common.calendar,
                start: CalendarEventTimestamps.date(event.startDate, in: zone),
                end: CalendarEventTimestamps.date(lastDay, in: zone),
                allDay: true,
                timeZone: nil,
                location: common.location,
                notesExcerpt: common.notes,
                url: common.url
            )
        }

        let zone = event.timeZone ?? .current
        return CalendarEventSummary(
            title: common.title,
            calendar: common.calendar,
            start: CalendarEventTimestamps.timestamp(event.startDate, in: zone),
            end: CalendarEventTimestamps.timestamp(event.endDate, in: zone),
            allDay: false,
            // Only a zone the event actually declares is reported. Falling
            // back to this Mac's current zone would dress up "we do not
            // know" as a statement about where the event is, which is the
            // class of invention this whole change removes.
            timeZone: event.timeZone?.identifier,
            location: common.location,
            notesExcerpt: common.notes,
            url: common.url
        )
    }

    /// The zone an all-day event's dates are resolved against. All-day
    /// events rarely carry one of their own — they are days, not times —
    /// and EventKit stores their bounds as midnight on this Mac's clock, so
    /// the current zone is the frame those bounds were written in.
    private static func allDayZone(for event: EKEvent) -> TimeZone {
        event.timeZone ?? .current
    }

    private static func normalizedOrNil(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncateNotes(_ notes: String?) -> String? {
        guard let notes else {
            return nil
        }

        let normalized = notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return nil
        }

        let limit = 280
        if normalized.count <= limit {
            return normalized
        }

        let index = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<index]) + "..."
    }

}

struct CalendarPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_events", "create_event"]

    // Only the read tool (list_events) is authored. create_event stays a
    // supported method but is intentionally not exposed as an LLM tool until
    // the operator read/write policy lands; advertising no write tool is how
    // a read-only posture is enforced. The tool keeps the established
    // macos_calendar_events name so it shadows the server's legacy hand-coded
    // tool (and inherits its prose result formatting) rather than adding a
    // second calendar tool.
    let toolDefinitions: [PlatformToolDefinition] = [
        .make(
            name: "macos_calendar_events",
            description: "List events from the user's macOS Calendar within a time window. Served by a connected macOS companion app.",
            method: "list_events",
            schemaJSON: """
            {
              "type": "object",
              "properties": {
                "start": {
                  "type": "string",
                  "description": "Required. Inclusive start of the window, RFC3339 (e.g. 2026-06-23T00:00:00Z)."
                },
                "end": {
                  "type": "string",
                  "description": "Required. Exclusive end of the window, RFC3339."
                },
                "calendar_names": {
                  "type": "array",
                  "items": {"type": "string"},
                  "description": "Calendar display names to include. Omit for all calendars."
                },
                "query": {
                  "type": "string",
                  "description": "Case-insensitive term matched against event title, location, and notes."
                },
                "limit": {
                  "type": "integer",
                  "description": "Maximum number of events to return."
                }
              },
              "required": ["start", "end"]
            }
            """
        ),
    ]

    private let calendarService: CalendarService

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        switch method {
        case "list_events":
            let request = try decodePlatformParams(CalendarListRequest.self, from: params)
            return try AnyCodable.fromEncodable(try await calendarService.listEvents(request: request))
        case "create_event":
            let request = try decodePlatformParams(CalendarCreateEventRequest.self, from: params)
            return try AnyCodable.fromEncodable(try await calendarService.createEvent(request: request))
        default:
            throw CalendarServiceError.unsupportedMethod(method)
        }
    }
}
