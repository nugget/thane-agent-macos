import AppKit
import EventKit
import Foundation

enum CalendarServiceError: PlatformServiceError, Sendable {
    case invalidTimestamp(String, String)
    case invalidWindow
    case invalidLimit(Int)
    case sharingDisabled
    case noSharedCalendars
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
        case .invalidLimit:
            "invalid_limit"
        case .sharingDisabled:
            "calendar_sharing_disabled"
        case .noSharedCalendars:
            "calendar_no_shared_calendars"
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
        case .invalidLimit(let value):
            "Calendar request limit must be positive (got \(value)); omit it for the default of \(CalendarService.defaultEventLimit)."
        case .sharingDisabled:
            "Calendar sharing is disabled in the macOS companion app. The operator can enable it in Settings > Calendar."
        case .noSharedCalendars:
            "Calendar sharing is enabled, but the operator has not selected any available calendars to share."
        case .accessDenied:
            "Calendar access was denied."
        case .restricted:
            "Calendar access is restricted on this Mac."
        case .writeOnlyAccess:
            "Calendar access is write-only; read access is required."
        case .noMatchingCalendars(let names):
            "No operator-shared calendars matched: \(names.joined(separator: ", "))"
        case .noWritableCalendar:
            "No operator-shared writable calendar is available for new events."
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
    /// Zone-less shapes accepted for a window bound, tried after the forms
    /// that carry their own offset and read in `zone`.
    ///
    /// A model asked what is on the calendar this afternoon writes the hour
    /// it means. Rejecting that outright — which is what requiring a full
    /// RFC3339 offset did — spends a turn on a rejection when the intent was
    /// never in doubt. Reading it as UTC instead would be worse: that is the
    /// silent shift this whole contract exists to remove, so the zone is
    /// stated in the tool description rather than left to be inferred.
    static let zonelessLayouts = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
    ]

    static func parse(_ value: String, field: String, zonelessIn zone: TimeZone? = nil) throws -> Date {
        if let date = formatter(fractionalSeconds: false).date(from: value) {
            return date
        }
        if let date = formatter(fractionalSeconds: true).date(from: value) {
            return date
        }
        if let zone {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            for layout in zonelessLayouts {
                if let date = zonelessFormatter(layout: layout, zone: zone).date(from: trimmed) {
                    return date
                }
            }
        }
        throw CalendarServiceError.invalidTimestamp(field, value)
    }

    private static func zonelessFormatter(layout: String, zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = layout
        return formatter
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

    /// The calendar date an all-day bound names, in `zone`.
    ///
    /// Accepts either a bare `yyyy-MM-dd` or a full RFC3339 timestamp whose
    /// clock is ignored — an all-day event occupies the date that was
    /// written, whatever time of day rode along with it.
    ///
    /// A timestamp is validated in full before its clock is discarded.
    /// Truncating first and parsing the remainder would accept
    /// `2026-09-02garbage` as September 2, quietly widening the contract to
    /// "anything whose first ten characters look like a date".
    static func parseAllDayDate(_ value: String, field: String, in zone: TimeZone) throws -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDateOnly(trimmed) {
            return try parseDate(trimmed, field: field, in: zone)
        }
        _ = try parse(trimmed, field: field)
        return try parseDate(String(trimmed.prefix(10)), field: field, in: zone)
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
    /// Exact EventKit identifiers returned by `macos_calendars_list`.
    /// Identifiers take precedence over display names when both are present.
    let calendarIdentifiers: [String]?
    let query: String?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case calendarNames = "calendar_names"
        case calendarIdentifiers = "calendar_ids"
        case query
        case limit
    }

    init(
        start: String,
        end: String,
        calendarNames: [String]?,
        calendarIdentifiers: [String]? = nil,
        query: String?,
        limit: Int?
    ) {
        self.start = start
        self.end = end
        self.calendarNames = calendarNames
        self.calendarIdentifiers = calendarIdentifiers
        self.query = query
        self.limit = limit
    }

    /// Resolves the requested window. A bound carrying its own offset is
    /// taken at face value; one without is read in `zone`, this Mac's zone,
    /// which is the frame a caller writing a bare local time means.
    nonisolated func dateInterval(zonelessIn zone: TimeZone = .current) throws -> DateInterval {
        let startDate = try CalendarTimestamp.parse(start, field: "start", zonelessIn: zone)
        let endDate = try CalendarTimestamp.parse(end, field: "end", zonelessIn: zone)
        guard endDate > startDate else {
            throw CalendarServiceError.invalidWindow
        }
        return DateInterval(start: startDate, end: endDate)
    }

    /// The number of events to return, or a thrown error when the request
    /// asked for a count that cannot mean anything.
    ///
    /// Zero and negative counts are rejected rather than quietly treated as
    /// "no limit" or "the default": both readings are guesses at what a
    /// caller meant, and a wrong guess here silently changes how much of the
    /// calendar comes back.
    nonisolated func resolvedLimit() throws -> Int {
        guard let limit else {
            return CalendarService.defaultEventLimit
        }
        guard limit > 0 else {
            throw CalendarServiceError.invalidLimit(limit)
        }
        return min(limit, CalendarService.maxEventLimit)
    }
}

nonisolated struct CalendarCatalogResponse: Codable, Equatable, Sendable {
    let calendars: [CalendarMetadata]
}

nonisolated struct CalendarSourceMetadata: Codable, Equatable, Sendable {
    let identifier: String
    let title: String
    let type: String
    let isDelegate: Bool

    enum CodingKeys: String, CodingKey {
        case identifier
        case title
        case type
        case isDelegate = "is_delegate"
    }
}

/// Calendar identity and operator-authored context exposed to Thane.
/// Descriptions are app-owned metadata, not EventKit or Calendar.app notes.
nonisolated struct CalendarMetadata: Codable, Equatable, Identifiable, Sendable {
    var id: String { calendarIdentifier }

    let calendarIdentifier: String
    let title: String
    let description: String?
    let source: CalendarSourceMetadata
    let type: String
    let allowsContentModifications: Bool
    let isSubscribed: Bool
    let isImmutable: Bool
    let color: String?
    let supportedAvailability: [String]
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case calendarIdentifier = "calendar_id"
        case title
        case description
        case source
        case type
        case allowsContentModifications = "allows_content_modifications"
        case isSubscribed = "is_subscribed"
        case isImmutable = "is_immutable"
        case color
        case supportedAvailability = "supported_availability"
        case isDefault = "is_default"
    }
}

nonisolated struct CalendarListResponse: Codable, Equatable, Sendable {
    let events: [CalendarEventSummary]
    /// Whether the window held more events than were returned.
    ///
    /// Without this a capped result is indistinguishable from a complete
    /// one, and a reader that sees twenty events concludes there are twenty.
    /// Silent truncation reads as full coverage, which is the one thing a
    /// calendar answer must never do.
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case events
        case truncated
    }
}

// Marked `nonisolated` so the test target can decode/read these under the
// app's MainActor-default isolation (see ContactsService for the rationale).
nonisolated struct CalendarCreateEventRequest: Codable, Equatable, Sendable {
    let title: String
    let calendarName: String?
    let calendarIdentifier: String?
    let start: String
    let end: String
    let allDay: Bool?
    let location: String?
    let notes: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case title
        case calendarName = "calendar_name"
        case calendarIdentifier = "calendar_id"
        case start
        case end
        case allDay = "all_day"
        case location
        case notes
        case url
    }

    init(
        title: String,
        calendarName: String?,
        calendarIdentifier: String? = nil,
        start: String,
        end: String,
        allDay: Bool?,
        location: String?,
        notes: String?,
        url: String?
    ) {
        self.title = title
        self.calendarName = calendarName
        self.calendarIdentifier = calendarIdentifier
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.url = url
    }

    /// Resolves the interval to store, in the zone the event will live in.
    ///
    /// An all-day event is given as inclusive dates and becomes the
    /// midnight-to-midnight span covering them; both bounds are resolved in
    /// `zone` rather than UTC, so the days written are the days meant. A
    /// timed event keeps the instants it was given.
    nonisolated func dateInterval(in zone: TimeZone = .current) throws -> DateInterval {
        if allDay == true {
            let firstDay = try CalendarTimestamp.parseAllDayDate(start, field: "start", in: zone)
            let lastDay = try CalendarTimestamp.parseAllDayDate(end, field: "end", in: zone)
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
    let calendarIdentifier: String
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
        case calendarIdentifier = "calendar_id"
        case start
        case end
        case allDay = "all_day"
        case timeZone = "time_zone"
        case location
        case notesExcerpt = "notes_excerpt"
        case url
    }

    init(
        title: String,
        calendar: String,
        calendarIdentifier: String = "",
        start: String,
        end: String,
        allDay: Bool,
        timeZone: String?,
        location: String?,
        notesExcerpt: String?,
        url: String?
    ) {
        self.title = title
        self.calendar = calendar
        self.calendarIdentifier = calendarIdentifier
        self.start = start
        self.end = end
        self.allDay = allDay
        self.timeZone = timeZone
        self.location = location
        self.notesExcerpt = notesExcerpt
        self.url = url
    }
}

actor CalendarService {
    /// How many events come back when a request does not say.
    ///
    /// Matches the ceiling the server's hand-coded tool used to enforce.
    /// That enforcement became unreachable the moment the Mac started
    /// authoring its own tool — the authored definition shadows the legacy
    /// handler by name — so the bound has to live on the side that owns the
    /// schema, which is this one.
    static let defaultEventLimit = 20

    /// The most events any single request can return, however many it asks
    /// for. A calendar window is unbounded in principle; a model's context
    /// is not.
    static let maxEventLimit = 100

    private let store: EKEventStore
    private let sharingPreferences: CalendarSharingPreferences
    private var changeObserver: EventKitChangeObserver?

    init(
        store: EKEventStore = EKEventStore(),
        sharingPreferences: CalendarSharingPreferences
    ) {
        self.store = store
        self.sharingPreferences = sharingPreferences
    }

    /// Starts refreshing this service's store whenever EventKit reports a
    /// change made outside this process. Idempotent.
    ///
    /// Explicitly started rather than wired up in `init` so constructing a
    /// service — which tests do freely — never registers a process-wide
    /// observer as a side effect.
    func startObservingChanges() {
        guard changeObserver == nil else {
            return
        }
        let observer = EventKitChangeObserver { [weak self] in
            await self?.discardCachedState()
        }
        changeObserver = observer
        observer.start()
    }

    /// Stops refreshing on external changes. Present so a caller that
    /// creates a short-lived service can tear its observer down explicitly
    /// rather than relying on deallocation.
    func stopObservingChanges() {
        changeObserver?.stop()
        changeObserver = nil
    }

    /// Drops everything the store has cached, so the next query reads the
    /// database as it stands rather than as it stood at launch.
    ///
    /// Unlike the reminders service this needs no in-flight guard. Events
    /// are fetched synchronously — `store.events(matching:)` returns, and
    /// the sort, filter, and summary mapping all run in the same actor step
    /// — so there is no suspension between reading the objects and finishing
    /// with them for a reset to slip into.
    private func discardCachedState() {
        store.reset()
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

    /// All event calendars visible to the app, for local Settings only. This
    /// deliberately bypasses the export gate so the operator can configure the
    /// allowlist while sharing is disabled.
    func availableCalendars() async throws -> [CalendarMetadata] {
        try await ensureReadAccess()
        let sharing = await sharingPreferences.snapshot()
        return metadata(
            for: store.calendars(for: .event),
            sharing: sharing
        )
    }

    /// Operator-approved calendar identities and context for model discovery.
    func listSharedCalendars() async throws -> CalendarCatalogResponse {
        let sharing = try await requireSharingPolicy()
        try await ensureReadAccess()
        let calendars = try currentSharedCalendars(sharing: sharing)
        return CalendarCatalogResponse(
            calendars: metadata(for: calendars, sharing: sharing)
        )
    }

    func listEvents(request: CalendarListRequest) async throws -> CalendarListResponse {
        let sharing = try await requireSharingPolicy()
        try await ensureReadAccess()

        let interval = try request.dateInterval()
        let sharedCalendars = try currentSharedCalendars(sharing: sharing)
        let calendars = try selectedCalendars(
            identifiers: request.calendarIdentifiers ?? [],
            names: request.calendarNames ?? [],
            from: sharedCalendars
        )
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

        let limit = try request.resolvedLimit()
        let truncated = events.count > limit
        if truncated {
            events = Array(events.prefix(limit))
        }

        return CalendarListResponse(events: events.map(makeSummary), truncated: truncated)
    }

    func createEvent(request: CalendarCreateEventRequest) async throws -> CalendarCreateEventResponse {
        let sharing = try await requireSharingPolicy()
        try await ensureWriteAccess()

        let calendars = try currentSharedCalendars(sharing: sharing)
        let calendar = try targetCalendar(
            identifier: request.calendarIdentifier,
            named: request.calendarName,
            from: calendars
        )
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

    private func requireSharingPolicy() async throws -> CalendarSharingSnapshot {
        let sharing = await sharingPreferences.snapshot()
        guard sharing.isEnabled else {
            throw CalendarServiceError.sharingDisabled
        }
        guard !sharing.sharedCalendarIdentifiers.isEmpty else {
            throw CalendarServiceError.noSharedCalendars
        }
        return sharing
    }

    private func currentSharedCalendars(
        sharing: CalendarSharingSnapshot
    ) throws -> [EKCalendar] {
        let sharedIdentifiers = sharing.sharedCalendarIdentifiers
        let calendars = store.calendars(for: .event).filter {
            sharedIdentifiers.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else {
            throw CalendarServiceError.noSharedCalendars
        }
        return calendars
    }

    private func targetCalendar(
        identifier: String?,
        named name: String?,
        from calendars: [EKCalendar]
    ) throws -> EKCalendar {
        if let identifier = Self.normalizedOrNil(identifier) {
            if let match = calendars.first(where: { $0.calendarIdentifier == identifier }) {
                return match
            }
            throw CalendarServiceError.noMatchingCalendars([identifier])
        }

        if let trimmed = Self.normalizedOrNil(name) {
            let normalized = trimmed.lowercased()
            if let match = calendars.first(where: { $0.title.lowercased() == normalized }) {
                return match
            }
            throw CalendarServiceError.noMatchingCalendars([trimmed])
        }

        guard let defaultCalendar = store.defaultCalendarForNewEvents,
              calendars.contains(where: {
                  $0.calendarIdentifier == defaultCalendar.calendarIdentifier
              }) else {
            throw CalendarServiceError.noWritableCalendar
        }
        return defaultCalendar
    }

    private func selectedCalendars(
        identifiers: [String],
        names: [String],
        from calendars: [EKCalendar]
    ) throws -> [EKCalendar] {
        let normalizedIdentifiers = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalizedIdentifiers.isEmpty {
            let requested = Set(normalizedIdentifiers)
            let matches = calendars.filter {
                requested.contains($0.calendarIdentifier)
            }
            let matched = Set(matches.map(\.calendarIdentifier))
            let missing = requested.subtracting(matched).sorted()
            guard missing.isEmpty else {
                throw CalendarServiceError.noMatchingCalendars(missing)
            }
            return matches
        }

        let normalizedNames = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !normalizedNames.isEmpty else {
            return calendars
        }

        let requested = Set(normalizedNames)
        let matches = calendars.filter { calendar in
            requested.contains(calendar.title.lowercased())
        }

        let matched = Set(matches.map { $0.title.lowercased() })
        let missing = requested.subtracting(matched).sorted()
        guard missing.isEmpty else {
            throw CalendarServiceError.noMatchingCalendars(missing)
        }

        return matches
    }

    private func makeSummary(event: EKEvent) -> CalendarEventSummary {
        // EKEvent.calendar is implicitly unwrapped and is nil on an event
        // that has not been filed yet, so read it defensively rather than
        // trapping on a shape the type system claims cannot happen.
        let calendarTitle = Self.normalizedOrNil(event.calendar?.title) ?? "(unknown calendar)"
        let calendarIdentifier = event.calendar?.calendarIdentifier ?? ""
        let common = (
            title: Self.normalizedOrNil(event.title) ?? "(untitled event)",
            calendar: calendarTitle,
            calendarIdentifier: calendarIdentifier,
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
                calendarIdentifier: common.calendarIdentifier,
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
            calendarIdentifier: common.calendarIdentifier,
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

    private func metadata(
        for calendars: [EKCalendar],
        sharing: CalendarSharingSnapshot
    ) -> [CalendarMetadata] {
        let defaultIdentifier = store.defaultCalendarForNewEvents?.calendarIdentifier
        return calendars.map { calendar in
            let source: CalendarSourceMetadata
            if let eventSource = calendar.source {
                source = CalendarSourceMetadata(
                    identifier: eventSource.sourceIdentifier,
                    title: Self.normalizedOrNil(eventSource.title) ?? "(unnamed source)",
                    type: Self.sourceTypeName(eventSource.sourceType),
                    isDelegate: eventSource.isDelegate
                )
            } else {
                source = CalendarSourceMetadata(
                    identifier: "",
                    title: "(unknown source)",
                    type: "unknown",
                    isDelegate: false
                )
            }

            return CalendarMetadata(
                calendarIdentifier: calendar.calendarIdentifier,
                title: Self.normalizedOrNil(calendar.title) ?? "(untitled calendar)",
                description: sharing.description(for: calendar.calendarIdentifier),
                source: source,
                type: Self.calendarTypeName(calendar.type),
                allowsContentModifications: calendar.allowsContentModifications,
                isSubscribed: calendar.isSubscribed,
                isImmutable: calendar.isImmutable,
                color: Self.colorHex(calendar.color),
                supportedAvailability: Self.supportedAvailabilityNames(
                    calendar.supportedEventAvailabilities
                ),
                isDefault: calendar.calendarIdentifier == defaultIdentifier
            )
        }
        .sorted {
            let sourceOrder = $0.source.title.localizedCaseInsensitiveCompare($1.source.title)
            if sourceOrder != .orderedSame {
                return sourceOrder == .orderedAscending
            }
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return $0.calendarIdentifier < $1.calendarIdentifier
        }
    }

    private static func calendarTypeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: "local"
        case .calDAV: "caldav"
        case .exchange: "exchange"
        case .subscription: "subscription"
        case .birthday: "birthday"
        @unknown default: "unknown"
        }
    }

    private static func sourceTypeName(_ type: EKSourceType) -> String {
        switch type {
        case .local: "local"
        case .exchange: "exchange"
        case .calDAV: "caldav"
        case .mobileMe: "mobileme"
        case .subscribed: "subscribed"
        case .birthdays: "birthdays"
        @unknown default: "unknown"
        }
    }

    private static func supportedAvailabilityNames(
        _ mask: EKCalendarEventAvailabilityMask
    ) -> [String] {
        var values: [String] = []
        if mask.contains(.busy) { values.append("busy") }
        if mask.contains(.free) { values.append("free") }
        if mask.contains(.tentative) { values.append("tentative") }
        if mask.contains(.unavailable) { values.append("unavailable") }
        return values
    }

    private static func colorHex(_ color: NSColor?) -> String? {
        guard let color = color?.usingColorSpace(.sRGB) else {
            return nil
        }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
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
    let version = "2"
    let supportedMethods = ["list_calendars", "list_events", "create_event"]

    // Only read tools are authored. create_event stays a supported method but
    // is intentionally not exposed as an LLM tool until the operator read/write
    // policy lands; advertising no write tool is how a read-only posture is
    // enforced. The event tool keeps the established
    // macos_calendar_events name so it shadows the server's legacy hand-coded
    // tool (and inherits its prose result formatting) rather than adding a
    // second calendar tool.
    let toolDefinitions: [PlatformToolDefinition] = [
        .make(
            name: "macos_calendars_list",
            description: "List the macOS calendars the operator explicitly shares with Thane, including exact local identifiers, operator-authored descriptions, source/account, type, color, and modification capabilities. Use this before choosing calendar scope when the operator's intent matters.",
            method: "list_calendars",
            tags: ["macos", "calendar", "read"],
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {}
            }
            """
        ),
        .make(
            name: "macos_calendar_events",
            description: "List events from calendars the operator explicitly shares in the macOS companion app. Use macos_calendars_list first when calendar scope or operator-authored descriptions matter.",
            method: "list_events",
            tags: ["macos", "calendar", "read"],
            schemaJSON: """
            {
              "type": "object",
              "properties": {
                "start": {
                  "type": "string",
                  "description": "Required. Inclusive start of the window. Prefer RFC3339 with an explicit offset (2026-06-23T00:00:00-05:00). A bare YYYY-MM-DD or YYYY-MM-DD HH:MM is read in the companion Mac's own timezone, which is not necessarily the household one."
                },
                "end": {
                  "type": "string",
                  "description": "Required. Exclusive end of the window, in the same forms as start."
                },
                "calendar_names": {
                  "type": "array",
                  "items": {"type": "string"},
                  "description": "Shared calendar display names to include. Omit for every calendar the operator selected. Prefer calendar_ids when names may be duplicated."
                },
                "calendar_ids": {
                  "type": "array",
                  "items": {"type": "string"},
                  "description": "Exact shared calendar identifiers returned by macos_calendars_list. Takes precedence over calendar_names when present."
                },
                "query": {
                  "type": "string",
                  "description": "Case-insensitive term matched against event title, location, and notes."
                },
                "limit": {
                  "type": "integer",
                  "minimum": 1,
                  "maximum": 100,
                  "description": "Maximum number of events to return. Defaults to 20, capped at 100. When more events fall in the window than are returned, the result says so — narrow the window rather than assuming you saw everything."
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
        case "list_calendars":
            return try AnyCodable.fromEncodable(try await calendarService.listSharedCalendars())
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
