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
    let calendarNames: [String]
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

    nonisolated func dateInterval() throws -> DateInterval {
        let startDate = try CalendarTimestamp.parse(start, field: "start")
        let endDate = try CalendarTimestamp.parse(end, field: "end")
        guard endDate > startDate else {
            throw CalendarServiceError.invalidWindow
        }
        return DateInterval(start: startDate, end: endDate)
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
    let start: String
    let end: String
    let allDay: Bool
    let location: String?
    let notesExcerpt: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case title
        case calendar
        case start
        case end
        case allDay = "all_day"
        case location
        case notesExcerpt = "notes_excerpt"
        case url
    }
}

actor CalendarService {
    private let store: EKEventStore
    private let eventTimestampFormatter: ISO8601DateFormatter

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
        self.eventTimestampFormatter = Self.makeEventTimestampFormatter()
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
        let calendars = try selectedCalendars(named: request.calendarNames)
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

        let interval = try request.dateInterval()
        let calendar = try targetCalendar(named: request.calendarName)

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = request.title
        event.startDate = interval.start
        event.endDate = interval.end
        event.isAllDay = request.allDay ?? false
        event.location = Self.normalizedOrNil(request.location)
        event.notes = Self.normalizedOrNil(request.notes)
        if let urlString = Self.normalizedOrNil(request.url) {
            event.url = URL(string: urlString)
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.saveFailed(error.localizedDescription)
        }

        return CalendarCreateEventResponse(
            eventIdentifier: event.eventIdentifier ?? "",
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
        CalendarEventSummary(
            title: Self.normalizedOrNil(event.title) ?? "(untitled event)",
            calendar: event.calendar.title,
            start: formatTimestamp(event.startDate),
            end: formatTimestamp(event.endDate),
            allDay: event.isAllDay,
            location: Self.normalizedOrNil(event.location),
            notesExcerpt: Self.truncateNotes(event.notes),
            url: event.url?.absoluteString
        )
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

    private func formatTimestamp(_ date: Date) -> String {
        eventTimestampFormatter.string(from: date)
    }

    nonisolated private static func makeEventTimestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

struct CalendarPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_events", "create_event"]

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
