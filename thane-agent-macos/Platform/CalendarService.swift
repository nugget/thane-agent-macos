import EventKit
import Foundation

enum CalendarAuthorizationState: String, Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case fullAccess
    case writeOnly
    case unknown

    nonisolated init(status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorized:
            self = .fullAccess
        case .fullAccess:
            self = .fullAccess
        case .writeOnly:
            self = .writeOnly
        @unknown default:
            self = .unknown
        }
    }

    nonisolated var label: String {
        switch self {
        case .notDetermined:
            "Not determined"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        case .fullAccess:
            "Full access"
        case .writeOnly:
            "Write only"
        case .unknown:
            "Unknown"
        }
    }
}

enum CalendarServiceError: PlatformServiceError, Sendable {
    case invalidTimestamp(String, String)
    case invalidWindow
    case accessDenied
    case restricted
    case writeOnlyAccess
    case noMatchingCalendars([String])

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
        }
    }
}

struct CalendarListRequest: Codable, Equatable, Sendable {
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
        let startDate = try Self.parseTimestamp(start, field: "start")
        let endDate = try Self.parseTimestamp(end, field: "end")
        guard endDate > startDate else {
            throw CalendarServiceError.invalidWindow
        }
        return DateInterval(start: startDate, end: endDate)
    }

    nonisolated private static func parseTimestamp(_ value: String, field: String) throws -> Date {
        if let date = makeTimestampFormatter(fractionalSeconds: false).date(from: value) {
            return date
        }
        if let date = makeTimestampFormatter(fractionalSeconds: true).date(from: value) {
            return date
        }
        throw CalendarServiceError.invalidTimestamp(field, value)
    }

    nonisolated private static func makeTimestampFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

struct CalendarListResponse: Codable, Equatable, Sendable {
    let events: [CalendarEventSummary]
}

struct CalendarEventSummary: Codable, Equatable, Sendable {
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

    func authorizationState() -> CalendarAuthorizationState {
        CalendarAuthorizationState(status: EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccessIfNeeded() async throws -> CalendarAuthorizationState {
        let current = authorizationState()
        guard current == .notDetermined else {
            return current
        }

        _ = try await store.requestFullAccessToEvents()
        return authorizationState()
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
    let supportedMethods = ["list_events"]

    private let calendarService: CalendarService

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        let request = try decodePlatformParams(CalendarListRequest.self, from: params)
        let response = try await calendarService.listEvents(request: request)
        return try AnyCodable.fromEncodable(response)
    }
}
