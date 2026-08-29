import Foundation
import Testing
@testable import thane_agent_macos

/// These tests are the drift guard the registrar relies on: every authored
/// tool schema must decode the payloads the model will produce into the
/// paired `Codable` request struct. A schema that names a field the struct
/// can't decode fails here rather than silently failing every call in
/// production — the exact class of bug behind the calendar_names regression.
struct PlatformToolDefinitionTests {
    // MARK: - Structural invariants

    @Test
    @MainActor
    func authoredToolsAreWellFormed() throws {
        let suiteName = "PlatformToolDefinitionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let handlers: [(String, PlatformServiceHandler)] = [
            ("macos.contacts", ContactsPlatformHandler(contactsService: ContactsService())),
            ("macos.calendar", CalendarPlatformHandler(calendarService: CalendarService())),
            ("macos.reminders", RemindersPlatformHandler(remindersService: RemindersService())),
            (
                "macos.system-context",
                SystemContextPlatformHandler(
                    service: SystemContextService(
                        preferences: SystemContextPreferences(
                            defaults: defaults
                        )
                    )
                )
            ),
        ]
        for (capability, handler) in handlers {
            #expect(!handler.toolDefinitions.isEmpty, "\(capability) authors no tools")
            for def in handler.toolDefinitions {
                // Method routes to a real capability method.
                #expect(handler.supportedMethods.contains(def.method),
                        "\(def.name) routes to unsupported method \(def.method)")
                // The .make factory decoded the schema (did not fall to [:]).
                #expect(!def.inputSchema.isEmpty, "\(def.name) has an empty input schema")
                #expect(def.inputSchema["type"] != nil, "\(def.name) schema missing type")
                #expect(!def.name.isEmpty)
                #expect(!def.description.isEmpty)
            }
        }
    }

    @Test
    @MainActor
    func calendarKeepsLegacyToolNameForShadowing() {
        let handler = CalendarPlatformHandler(calendarService: CalendarService())
        let names = handler.toolDefinitions.map(\.name)
        // Must keep the legacy name so it shadows the server's hand-coded
        // tool rather than adding a second calendar tool.
        #expect(names.contains("macos_calendar_events"))
        // Write stays unexposed until the operator policy lands.
        #expect(!handler.toolDefinitions.contains { $0.method == "create_event" })
    }

    // MARK: - Decode round-trips (schema shape -> Codable request)

    @Test
    func contactsSearchRequestDecodesSchemaPayloads() throws {
        // Full payload.
        let full: [String: AnyCodable] = [
            "query": AnyCodable("bob"),
            "limit": AnyCodable(10),
        ]
        let parsed = try decodePlatformParams(ContactsSearchRequest.self, from: full)
        #expect(parsed.query == "bob")
        #expect(parsed.limit == 10)

        // Both optionals omitted (the "list everything" call).
        let empty = try decodePlatformParams(ContactsSearchRequest.self, from: [:])
        #expect(empty.query == nil)
        #expect(empty.limit == nil)
    }

    @Test
    func calendarListRequestDecodesSchemaPayloads() throws {
        let full: [String: AnyCodable] = [
            "start": AnyCodable("2026-06-23T00:00:00Z"),
            "end": AnyCodable("2026-06-24T00:00:00Z"),
            "calendar_names": AnyCodable(["Work", "Home"]),
            "query": AnyCodable("standup"),
            "limit": AnyCodable(5),
        ]
        let parsed = try decodePlatformParams(CalendarListRequest.self, from: full)
        #expect(parsed.start == "2026-06-23T00:00:00Z")
        #expect(parsed.calendarNames == ["Work", "Home"])
        #expect(parsed.query == "standup")
        #expect(parsed.limit == 5)

        // Only the required fields (calendar_names/query/limit omitted).
        let minimal: [String: AnyCodable] = [
            "start": AnyCodable("2026-06-23T00:00:00Z"),
            "end": AnyCodable("2026-06-24T00:00:00Z"),
        ]
        let parsedMinimal = try decodePlatformParams(CalendarListRequest.self, from: minimal)
        #expect(parsedMinimal.calendarNames == nil)
        #expect(parsedMinimal.query == nil)
        #expect(parsedMinimal.limit == nil)
    }

    @Test
    func remindersListRequestDecodesSchemaPayloads() throws {
        let full: [String: AnyCodable] = [
            "list_names": AnyCodable(["Groceries"]),
            "completed": AnyCodable(false),
            "due_start": AnyCodable("2026-06-23T00:00:00Z"),
            "due_end": AnyCodable("2026-06-30T00:00:00Z"),
            "query": AnyCodable("milk"),
            "limit": AnyCodable(20),
        ]
        let parsed = try decodePlatformParams(RemindersListRequest.self, from: full)
        #expect(parsed.listNames == ["Groceries"])
        #expect(parsed.completed == false)
        #expect(parsed.dueStart == "2026-06-23T00:00:00Z")
        #expect(parsed.query == "milk")
        #expect(parsed.limit == 20)

        // All optionals omitted.
        let empty = try decodePlatformParams(RemindersListRequest.self, from: [:])
        #expect(empty.listNames == nil)
        #expect(empty.completed == nil)
        #expect(empty.dueStart == nil)
    }

    // MARK: - Router folds tools into capabilities

    @Test
    @MainActor
    func routerCapabilitiesCarryAuthoredTools() {
        let router = PlatformServiceRouter()
        router.register(capability: "macos.contacts",
                        handler: ContactsPlatformHandler(contactsService: ContactsService()))

        let caps = router.capabilities
        #expect(caps.count == 1)
        let tools = caps.first?.tools
        #expect(tools != nil)
        #expect(tools?.contains { $0.name == "macos_contacts_search" } == true)
    }
}
