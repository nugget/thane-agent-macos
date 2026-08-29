import Foundation
import Testing
@testable import thane_agent_macos

struct CalendarSharingPreferencesTests {
    @Test
    @MainActor
    func sharingDefaultsOffAndPersistsSelectionsAndDescriptions() throws {
        let suiteName = "CalendarSharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = CalendarSharingPreferences(defaults: defaults)
        #expect(!preferences.isEnabled)
        #expect(preferences.sharedCalendarCount == 0)

        preferences.isEnabled = true
        preferences.setShared(true, for: "calendar-work")
        preferences.setDescription(
            "Client work, deadlines, and meetings. Do not use for personal appointments.",
            for: "calendar-work"
        )

        let restored = CalendarSharingPreferences(defaults: defaults)
        #expect(restored.isEnabled)
        #expect(restored.isShared("calendar-work"))
        #expect(restored.sharedCalendarCount == 1)
        #expect(restored.description(for: "calendar-work").contains("Client work"))

        let snapshot = restored.snapshot()
        #expect(snapshot.sharedCalendarIdentifiers == ["calendar-work"])
        #expect(snapshot.description(for: "calendar-work")?.contains("deadlines") == true)
    }

    @Test
    @MainActor
    func deselectingACalendarKeepsItsOperatorDescription() throws {
        let suiteName = "CalendarSharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = CalendarSharingPreferences(defaults: defaults)
        preferences.setShared(true, for: "calendar-travel")
        preferences.setDescription("Travel holds and confirmed itineraries.", for: "calendar-travel")
        preferences.setShared(false, for: "calendar-travel")

        let restored = CalendarSharingPreferences(defaults: defaults)
        #expect(!restored.isShared("calendar-travel"))
        #expect(restored.description(for: "calendar-travel") == "Travel holds and confirmed itineraries.")
    }

    @Test
    @MainActor
    func descriptionsAreBoundedBeforePersistenceAndExport() throws {
        let suiteName = "CalendarSharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = CalendarSharingPreferences(defaults: defaults)
        preferences.setDescription(
            String(repeating: "x", count: CalendarSharingPreferences.maxDescriptionLength + 100),
            for: "calendar-large"
        )

        #expect(
            preferences.description(for: "calendar-large").count
                == CalendarSharingPreferences.maxDescriptionLength
        )
        #expect(
            preferences.snapshot().description(for: "calendar-large")?.count
                == CalendarSharingPreferences.maxDescriptionLength
        )
    }

    @Test
    @MainActor
    func persistedDescriptionsAreBoundedOnLoadAndRepaired() throws {
        let suiteName = "CalendarSharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let stored = [
            CalendarShareConfiguration(
                calendarIdentifier: "calendar-large",
                isShared: true,
                description: String(
                    repeating: "x",
                    count: CalendarSharingPreferences.maxDescriptionLength + 100
                )
            ),
        ]
        defaults.set(
            try JSONEncoder().encode(stored),
            forKey: "calendarSharing.configurations"
        )

        let preferences = CalendarSharingPreferences(defaults: defaults)

        #expect(
            preferences.snapshot().description(for: "calendar-large")?.count
                == CalendarSharingPreferences.maxDescriptionLength
        )
        let repairedData = try #require(
            defaults.data(forKey: "calendarSharing.configurations")
        )
        let repaired = try JSONDecoder().decode(
            [CalendarShareConfiguration].self,
            from: repairedData
        )
        #expect(repaired.first?.description.count == CalendarSharingPreferences.maxDescriptionLength)
    }

    @Test
    @MainActor
    func disabledSharingStopsAPlatformRequestBeforeEventKitAccess() async throws {
        let suiteName = "CalendarSharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = CalendarSharingPreferences(defaults: defaults)
        let router = PlatformServiceRouter()
        router.register(
            capability: "macos.calendar",
            handler: CalendarPlatformHandler(
                calendarService: CalendarService(sharingPreferences: preferences)
            )
        )

        let response = await router.handle(
            request: PlatformRequest(
                id: 1,
                type: "platform_request",
                capability: "macos.calendar",
                method: "list_calendars",
                params: [:]
            )
        )

        #expect(!response.success)
        #expect(response.error?.code == "calendar_sharing_disabled")
    }

    @Test
    @MainActor
    func enabledSharingWithoutSelectionsReturnsADistinctError() async throws {
        let suiteName = "CalendarSharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = CalendarSharingPreferences(defaults: defaults)
        preferences.isEnabled = true
        let service = CalendarService(sharingPreferences: preferences)

        do {
            _ = try await service.listSharedCalendars()
            Issue.record("Expected an enabled but empty allowlist to be rejected.")
        } catch let error as CalendarServiceError {
            #expect(error.code == "calendar_no_shared_calendars")
        } catch {
            Issue.record("Expected calendar_no_shared_calendars, got \(error.localizedDescription)")
        }
    }
}
