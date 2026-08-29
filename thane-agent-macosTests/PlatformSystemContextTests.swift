import Foundation
import Testing
@testable import thane_agent_macos

struct PlatformSystemContextTests {
    @Test
    @MainActor
    func sharingCategoriesDefaultOffAndPersistIndependently() throws {
        let suiteName = "PlatformSystemContextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = SystemContextPreferences(defaults: defaults)
        #expect(preferences.enabledCategories.isEmpty)

        preferences.setEnabled(true, for: .application)
        preferences.setEnabled(true, for: .power)

        let restored = SystemContextPreferences(defaults: defaults)
        #expect(restored.enabledCategories == [.application, .power])
        #expect(!restored.activityEnabled)
        #expect(!restored.displaysEnabled)
    }

    @Test
    func snapshotEncodingOmitsCategoriesThatWereNotShared() throws {
        let snapshot = SystemContextSnapshot(
            capturedAt: "1970-01-01T00:00:00Z",
            application: FrontmostApplicationContext(
                name: "Xcode",
                bundleIdentifier: "com.apple.dt.Xcode",
                isHidden: false,
                ownsMenuBar: true
            ),
            activity: nil,
            power: nil,
            displays: nil
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["application"] != nil)
        #expect(object["activity"] == nil)
        #expect(object["power"] == nil)
        #expect(object["displays"] == nil)
        #expect(object["captured_at"] != nil)
    }

    @Test
    @MainActor
    func disabledContextReturnsAStablePlatformError() async throws {
        let suiteName = "PlatformSystemContextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = SystemContextPreferences(defaults: defaults)
        let router = PlatformServiceRouter()
        router.register(
            capability: "macos.system-context",
            handler: SystemContextPlatformHandler(
                service: SystemContextService(preferences: preferences)
            )
        )

        let response = await router.handle(
            request: PlatformRequest(
                id: 1,
                type: "platform_request",
                capability: "macos.system-context",
                method: "get_snapshot",
                params: [:]
            )
        )

        #expect(!response.success)
        #expect(response.error?.code == "system_context_disabled")
    }
}
