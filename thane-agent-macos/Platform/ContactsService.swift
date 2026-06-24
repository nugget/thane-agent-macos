import Contacts
import Foundation

enum ContactsAuthorizationState: String, Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case fullAccess
    case limited
    case unknown

    nonisolated init(status: CNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorized:
            self = .fullAccess
        case .limited:
            self = .limited
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
        case .limited:
            "Limited"
        case .unknown:
            "Unknown"
        }
    }

    /// Whether the state permits reading contacts.
    nonisolated var allowsRead: Bool {
        self == .fullAccess || self == .limited
    }
}

enum ContactsServiceError: PlatformServiceError, Sendable {
    case accessDenied
    case restricted

    nonisolated var code: String {
        switch self {
        case .accessDenied:
            "contacts_access_denied"
        case .restricted:
            "contacts_access_restricted"
        }
    }

    nonisolated var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Contacts access was denied."
        case .restricted:
            "Contacts access is restricted on this Mac."
        }
    }
}

// These data models are marked `nonisolated` so the test target — which runs
// without the app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default — can
// decode and read them from a nonisolated context without tripping "main
// actor-isolated property/conformance can not be referenced" errors.
nonisolated struct ContactsSearchRequest: Codable, Equatable, Sendable {
    let query: String?
    let limit: Int?
}

nonisolated struct ContactsSearchResponse: Codable, Equatable, Sendable {
    let contacts: [ContactSummary]
}

nonisolated struct ContactLabeledValue: Codable, Equatable, Sendable {
    let label: String?
    let value: String
}

nonisolated struct ContactSummary: Codable, Equatable, Sendable {
    let name: String
    let givenName: String?
    let familyName: String?
    let nickname: String?
    let organization: String?
    let jobTitle: String?
    let emails: [ContactLabeledValue]
    let phones: [ContactLabeledValue]
    let postalAddresses: [String]
    let birthday: String?

    enum CodingKeys: String, CodingKey {
        case name
        case givenName = "given_name"
        case familyName = "family_name"
        case nickname
        case organization
        case jobTitle = "job_title"
        case emails
        case phones
        case postalAddresses = "postal_addresses"
        case birthday
    }
}

actor ContactsService {
    // Bound the result set so an omitted or oversized `limit` can't return the
    // entire address book in one request (exfiltration risk + slow on large
    // stores). Mirrors the calendar tool's default/clamp pattern.
    private static let defaultSearchLimit = 50
    private static let maxSearchLimit = 200

    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func authorizationState() -> ContactsAuthorizationState {
        ContactsAuthorizationState(status: CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAccessIfNeeded() async throws -> ContactsAuthorizationState {
        let current = authorizationState()
        guard current == .notDetermined else {
            return current
        }

        // Present the TCC dialog from the main actor (mirrors CalendarService),
        // using the async requestAccess so there's no completion-handler bridge
        // and no actor-isolated store crossing the boundary.
        let granted = try await Task { @MainActor in
            try await CNContactStore().requestAccess(for: .contacts)
        }.value

        // A grant may resolve to either full or limited access. Re-read the
        // status to distinguish; fall back to full access if tccd hasn't
        // committed the row yet.
        let resolved = authorizationState()
        if granted {
            return resolved == .notDetermined ? .fullAccess : resolved
        }
        return .denied
    }

    func search(request: ContactsSearchRequest) async throws -> ContactsSearchResponse {
        try await ensureReadAccess()

        let normalizedQuery = request.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Always bound the result set. An omitted or non-positive limit falls
        // back to the default page size; anything larger is clamped to the max.
        let requestedLimit = request.limit ?? Self.defaultSearchLimit
        let effectiveLimit = requestedLimit > 0
            ? min(requestedLimit, Self.maxSearchLimit)
            : Self.defaultSearchLimit

        let fetchRequest = CNContactFetchRequest(keysToFetch: Self.keysToFetch())
        fetchRequest.sortOrder = .userDefault

        var summaries: [ContactSummary] = []
        try store.enumerateContacts(with: fetchRequest) { contact, stop in
            let summary = Self.makeSummary(from: contact)
            if let normalizedQuery, !normalizedQuery.isEmpty,
               !Self.matches(summary: summary, query: normalizedQuery) {
                return
            }
            summaries.append(summary)
            if summaries.count >= effectiveLimit {
                stop.pointee = true
            }
        }

        return ContactsSearchResponse(contacts: summaries)
    }

    private func ensureReadAccess() async throws {
        switch authorizationState() {
        case .fullAccess, .limited:
            return
        case .notDetermined:
            let updatedState = try await requestAccessIfNeeded()
            if !updatedState.allowsRead {
                throw ContactsServiceError.accessDenied
            }
        case .denied:
            throw ContactsServiceError.accessDenied
        case .restricted:
            throw ContactsServiceError.restricted
        case .unknown:
            throw ContactsServiceError.accessDenied
        }
    }

    // Note keys (CNContactNoteKey) are intentionally omitted — reading them
    // requires the restricted com.apple.developer.contacts.notes entitlement,
    // which Apple grants only by request.
    nonisolated static func keysToFetch() -> [any CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
        ]
    }

    nonisolated static func makeSummary(from contact: CNContact) -> ContactSummary {
        let formattedName = normalizedOrNil(CNContactFormatter.string(from: contact, style: .fullName))
        let name = formattedName
            ?? normalizedOrNil(contact.nickname)
            ?? normalizedOrNil(contact.organizationName)
            ?? "(no name)"

        let emails = contact.emailAddresses.map { labeled in
            ContactLabeledValue(label: localizedLabel(labeled.label), value: labeled.value as String)
        }
        let phones = contact.phoneNumbers.map { labeled in
            ContactLabeledValue(label: localizedLabel(labeled.label), value: labeled.value.stringValue)
        }
        let postalAddresses = contact.postalAddresses.map { labeled in
            formatPostalAddress(labeled.value)
        }

        return ContactSummary(
            name: name,
            givenName: normalizedOrNil(contact.givenName),
            familyName: normalizedOrNil(contact.familyName),
            nickname: normalizedOrNil(contact.nickname),
            organization: normalizedOrNil(contact.organizationName),
            jobTitle: normalizedOrNil(contact.jobTitle),
            emails: emails,
            phones: phones,
            postalAddresses: postalAddresses,
            birthday: formatBirthday(contact.birthday)
        )
    }

    nonisolated static func matches(summary: ContactSummary, query: String) -> Bool {
        let fields = [
            summary.name,
            summary.givenName,
            summary.familyName,
            summary.nickname,
            summary.organization,
            summary.jobTitle,
        ].compactMap { $0 }
            + summary.emails.map(\.value)
            + summary.phones.map(\.value)
            + summary.postalAddresses

        let haystack = fields.joined(separator: "\n").lowercased()
        return haystack.contains(query)
    }

    nonisolated static func localizedLabel(_ label: String?) -> String? {
        guard let label else {
            return nil
        }
        return normalizedOrNil(CNLabeledValue<NSString>.localizedString(forLabel: label))
    }

    nonisolated static func formatPostalAddress(_ address: CNPostalAddress) -> String {
        CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
            .replacingOccurrences(of: "\n", with: ", ")
    }

    nonisolated static func formatBirthday(_ components: DateComponents?) -> String? {
        guard let components, let month = components.month, let day = components.day else {
            return nil
        }
        let monthDay = String(format: "%02d-%02d", month, day)
        if let year = components.year, year != NSDateComponentUndefined, year > 0 {
            return String(format: "%04d-%@", year, monthDay)
        }
        return "--\(monthDay)"
    }

    nonisolated static func normalizedOrNil(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ContactsPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["search_contacts"]

    let toolDefinitions: [PlatformToolDefinition] = [
        .make(
            name: "macos_contacts_search",
            description: "Search the user's macOS Contacts by name, organization, email, or phone number. Omit query to list all contacts, bounded by limit. Served by a connected macOS companion app.",
            method: "search_contacts",
            schemaJSON: """
            {
              "type": "object",
              "properties": {
                "query": {
                  "type": "string",
                  "description": "Case-insensitive term matched against name, organization, email, and phone. Omit to return all contacts (bounded by limit)."
                },
                "limit": {
                  "type": "integer",
                  "description": "Maximum number of contacts to return."
                }
              }
            }
            """
        ),
    ]

    private let contactsService: ContactsService

    init(contactsService: ContactsService) {
        self.contactsService = contactsService
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        let request = try decodePlatformParams(ContactsSearchRequest.self, from: params)
        let response = try await contactsService.search(request: request)
        return try AnyCodable.fromEncodable(response)
    }
}
