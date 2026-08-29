import EventKit
import Foundation

enum RemindersServiceError: PlatformServiceError, Sendable {
    case invalidTimestamp(String, String)
    case invalidWindow
    case accessDenied
    case restricted
    case noMatchingLists([String])

    nonisolated var code: String {
        switch self {
        case .invalidTimestamp:
            "invalid_timestamp"
        case .invalidWindow:
            "invalid_window"
        case .accessDenied:
            "reminders_access_denied"
        case .restricted:
            "reminders_access_restricted"
        case .noMatchingLists:
            "reminders_list_not_found"
        }
    }

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidTimestamp(let field, let value):
            "Invalid \(field) timestamp: \(value)"
        case .invalidWindow:
            "Reminders request due_end must be after due_start."
        case .accessDenied:
            "Reminders access was denied."
        case .restricted:
            "Reminders access is restricted on this Mac."
        case .noMatchingLists(let names):
            "No matching reminder lists found for: \(names.joined(separator: ", "))"
        }
    }
}

// Marked `nonisolated` so the test target can decode/read these under the
// app's MainActor-default isolation (see ContactsService for the rationale).
nonisolated struct RemindersListRequest: Codable, Equatable, Sendable {
    let listNames: [String]?
    /// nil = all, true = completed only, false = incomplete only.
    let completed: Bool?
    let dueStart: String?
    let dueEnd: String?
    let query: String?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case listNames = "list_names"
        case completed
        case dueStart = "due_start"
        case dueEnd = "due_end"
        case query
        case limit
    }

    nonisolated func validatedDueBounds() throws -> (start: Date?, end: Date?) {
        let start = try dueStart.map { try Self.parseTimestamp($0, field: "due_start") }
        let end = try dueEnd.map { try Self.parseTimestamp($0, field: "due_end") }
        if let start, let end, end <= start {
            throw RemindersServiceError.invalidWindow
        }
        return (start, end)
    }

    nonisolated private static func parseTimestamp(_ value: String, field: String) throws -> Date {
        if let date = makeTimestampFormatter(fractionalSeconds: false).date(from: value) {
            return date
        }
        if let date = makeTimestampFormatter(fractionalSeconds: true).date(from: value) {
            return date
        }
        throw RemindersServiceError.invalidTimestamp(field, value)
    }

    nonisolated private static func makeTimestampFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

nonisolated struct RemindersListResponse: Codable, Equatable, Sendable {
    let reminders: [ReminderSummary]
}

nonisolated struct ReminderSummary: Codable, Equatable, Sendable {
    let title: String
    let list: String
    let completed: Bool
    let due: String?
    let priority: Int?
    let notesExcerpt: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case title
        case list
        case completed
        case due
        case priority
        case notesExcerpt = "notes_excerpt"
        case url
    }
}

actor RemindersService {
    private let store: EKEventStore
    private var changeObserver: EventKitChangeObserver?

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// Starts refreshing this service's store whenever EventKit reports a
    /// change made outside this process. Idempotent.
    ///
    /// Explicitly started rather than wired up in `init` so constructing a
    /// service — which tests do freely — never registers a process-wide
    /// observer as a side effect.
    func startObservingChanges() async {
        guard changeObserver == nil else {
            return
        }
        let observer = EventKitChangeObserver { [weak self] in
            await self?.discardCachedState()
        }
        changeObserver = observer
        await observer.start()
    }

    /// Drops everything the store has cached, so the next query reads the
    /// database as it stands rather than as it stood at launch.
    private func discardCachedState() {
        store.reset()
    }

    func authorizationState() -> EventKitAuthorizationState {
        EventKitAuthorizationState(status: EKEventStore.authorizationStatus(for: .reminder))
    }

    func requestAccessIfNeeded() async throws -> EventKitAuthorizationState {
        let current = authorizationState()
        guard current == .notDetermined else {
            return current
        }

        // The TCC dialog needs the main run loop to be servicing events. Use a
        // dedicated store on the main actor so we don't send the actor-isolated
        // store across boundaries (mirrors CalendarService).
        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            Task { @MainActor in
                let requestStore = EKEventStore()
                requestStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        return granted ? .fullAccess : .denied
    }

    func listReminders(request: RemindersListRequest) async throws -> RemindersListResponse {
        try await ensureReadAccess()

        let calendars = try selectedCalendars(named: request.listNames ?? [])
        let bounds = try request.validatedDueBounds()
        let normalizedQuery = request.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let completedFilter = request.completed
        let limit = request.limit
        let predicate = store.predicateForReminders(in: calendars)

        // Filter and map inside the completion handler so only Sendable
        // ReminderSummary values cross the continuation boundary — EKReminder
        // is not Sendable.
        let summaries: [ReminderSummary] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                var matched = (reminders ?? []).filter { reminder in
                    if let completedFilter, reminder.isCompleted != completedFilter {
                        return false
                    }
                    if let due = Self.dueDate(reminder) {
                        if let start = bounds.start, due < start { return false }
                        if let end = bounds.end, due > end { return false }
                    } else if bounds.start != nil || bounds.end != nil {
                        return false
                    }
                    if let normalizedQuery, !normalizedQuery.isEmpty,
                       !Self.matches(reminder: reminder, query: normalizedQuery) {
                        return false
                    }
                    return true
                }

                matched.sort { lhs, rhs in
                    let lhsDue = Self.dueDate(lhs) ?? .distantFuture
                    let rhsDue = Self.dueDate(rhs) ?? .distantFuture
                    if lhsDue != rhsDue {
                        return lhsDue < rhsDue
                    }
                    return (lhs.title ?? "") < (rhs.title ?? "")
                }

                if let limit, limit > 0, matched.count > limit {
                    matched = Array(matched.prefix(limit))
                }

                continuation.resume(returning: matched.map(Self.makeSummary))
            }
        }

        return RemindersListResponse(reminders: summaries)
    }

    private func ensureReadAccess() async throws {
        switch authorizationState() {
        case .fullAccess:
            return
        case .notDetermined:
            let updatedState = try await requestAccessIfNeeded()
            if updatedState != .fullAccess {
                throw RemindersServiceError.accessDenied
            }
        case .denied:
            throw RemindersServiceError.accessDenied
        case .restricted:
            throw RemindersServiceError.restricted
        case .writeOnly, .unknown:
            throw RemindersServiceError.accessDenied
        }
    }

    private func selectedCalendars(named names: [String]) throws -> [EKCalendar]? {
        let normalizedNames = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !normalizedNames.isEmpty else {
            return nil
        }

        let matches = store.calendars(for: .reminder).filter { calendar in
            normalizedNames.contains(calendar.title.lowercased())
        }

        guard !matches.isEmpty else {
            throw RemindersServiceError.noMatchingLists(names)
        }

        return matches
    }

    nonisolated static func makeSummary(_ reminder: EKReminder) -> ReminderSummary {
        ReminderSummary(
            title: normalizedOrNil(reminder.title) ?? "(untitled reminder)",
            list: reminder.calendar.title,
            completed: reminder.isCompleted,
            due: dueDate(reminder).map(formatTimestamp),
            priority: reminder.priority == 0 ? nil : reminder.priority,
            notesExcerpt: truncateNotes(reminder.notes),
            url: reminder.url?.absoluteString
        )
    }

    nonisolated static func dueDate(_ reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else {
            return nil
        }
        // Honor a calendar/time zone embedded in the components so the resolved
        // instant doesn't shift for reminders anchored to another time zone.
        // Calendar.date(from:) already respects components.timeZone when set.
        let calendar = components.calendar ?? Calendar.current
        return calendar.date(from: components)
    }

    nonisolated static func matches(reminder: EKReminder, query: String) -> Bool {
        let haystack = [
            reminder.title,
            reminder.notes,
            reminder.calendar.title,
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: "\n")

        return haystack.contains(query)
    }

    // Shared formatter: ISO8601DateFormatter is immutable after configuration
    // and safe for concurrent formatting, so we reuse one instance instead of
    // allocating a new formatter per reminder summary.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    nonisolated static func normalizedOrNil(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func truncateNotes(_ notes: String?) -> String? {
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

struct RemindersPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_reminders"]

    let toolDefinitions: [PlatformToolDefinition] = [
        .make(
            name: "macos_reminders_list",
            description: "List reminders from the user's macOS Reminders, optionally filtered by list name, completion state, due-date window, or a text query. Served by a connected macOS companion app.",
            method: "list_reminders",
            schemaJSON: """
            {
              "type": "object",
              "properties": {
                "list_names": {
                  "type": "array",
                  "items": {"type": "string"},
                  "description": "Reminder list names to include. Omit for all lists."
                },
                "completed": {
                  "type": "boolean",
                  "description": "Filter by completion: true for completed, false for incomplete. Omit for both."
                },
                "due_start": {
                  "type": "string",
                  "description": "Inclusive lower bound on due date, RFC3339. Omit for no lower bound."
                },
                "due_end": {
                  "type": "string",
                  "description": "Inclusive upper bound on due date, RFC3339. Omit for no upper bound."
                },
                "query": {
                  "type": "string",
                  "description": "Case-insensitive term matched against reminder title and notes."
                },
                "limit": {
                  "type": "integer",
                  "description": "Maximum number of reminders to return."
                }
              }
            }
            """
        ),
    ]

    private let remindersService: RemindersService

    init(remindersService: RemindersService) {
        self.remindersService = remindersService
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        let request = try decodePlatformParams(RemindersListRequest.self, from: params)
        let response = try await remindersService.listReminders(request: request)
        return try AnyCodable.fromEncodable(response)
    }
}
