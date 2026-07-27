import Foundation
import Testing
@testable import thane_agent_macos

struct LocalThaneNotificationTests {
    @Test
    func warningAndErrorChoicesAreIndependent() {
        var preferences = LocalNotificationPreferences.defaults

        #expect(!preferences.includes(.warn))
        #expect(!preferences.includes(.error))

        preferences.notifyOnWarnings = true
        #expect(preferences.includes(.warn))
        #expect(!preferences.includes(.error))

        preferences.notifyOnErrors = true
        #expect(preferences.includes(.warn))
        #expect(preferences.includes(.error))
        #expect(!preferences.includes(.info))
    }

    @Test
    func preferencesRoundTripThroughUserDefaults() {
        let suiteName = "LocalThaneNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = LocalNotificationPreferences(
            notifyOnWarnings: true,
            notifyOnErrors: false,
            playSoundForErrors: false,
            notifyWhileAppIsActive: true,
            includeLogDetails: false,
            repeatInterval: .oneHour,
            warningLifetime: .fourHours
        )
        expected.save(to: defaults)

        #expect(LocalNotificationPreferences.load(from: defaults) == expected)
    }

    @Test
    func detailedErrorUsesOperationalContextWithoutArbitraryMetadata() {
        let entry = makeEntry(
            message: "model request failed",
            level: .error,
            source: "internal/provider/openai.go:91",
            fields: [
                .init(key: "component", value: "inference"),
                .init(key: "model", value: "gpt-5"),
                .init(key: "request_id", value: "secret-request-id"),
                .init(key: "path", value: "/Users/example/private"),
            ]
        )
        var preferences = LocalNotificationPreferences.defaults
        preferences.notifyOnErrors = true
        let now = Date(timeIntervalSince1970: 1_000)

        let descriptor = RuntimeNotificationDescriptor.make(
            entry: entry,
            preferences: preferences,
            repeatedCount: 2,
            now: now
        )

        #expect(descriptor.title == "model request failed")
        #expect(descriptor.subtitle == "Local Thane · Error")
        #expect(descriptor.body.contains("component: inference"))
        #expect(descriptor.body.contains("model: gpt-5"))
        #expect(descriptor.body.contains("Repeated 2 times"))
        #expect(!descriptor.body.contains("secret-request-id"))
        #expect(!descriptor.body.contains("/Users/example/private"))
        #expect(descriptor.delivery == .active)
        #expect(descriptor.playSound)
        #expect(descriptor.expirationDate == nil)
    }

    @Test
    func hiddenDetailsDoNotLeakTheLogMessage() {
        let entry = makeEntry(
            message: "private path /Users/example/Secret failed",
            level: .error
        )
        var preferences = LocalNotificationPreferences.defaults
        preferences.notifyOnErrors = true
        preferences.includeLogDetails = false

        let descriptor = RuntimeNotificationDescriptor.make(
            entry: entry,
            preferences: preferences,
            repeatedCount: 0,
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(descriptor.title == "Local Thane needs attention")
        #expect(descriptor.subtitle == "Log details are hidden")
        #expect(!descriptor.body.contains("Secret"))
    }

    @Test
    func warningIsPassiveSilentAndExpires() {
        let entry = makeEntry(message: "queue is backing up", level: .warn)
        var preferences = LocalNotificationPreferences.defaults
        preferences.notifyOnWarnings = true
        preferences.warningLifetime = .oneHour
        let now = Date(timeIntervalSince1970: 10_000)

        let descriptor = RuntimeNotificationDescriptor.make(
            entry: entry,
            preferences: preferences,
            repeatedCount: 0,
            now: now
        )

        #expect(descriptor.delivery == .passive)
        #expect(!descriptor.playSound)
        #expect(descriptor.expirationDate == now.addingTimeInterval(60 * 60))
    }

    @Test
    func burstSummaryPreservesSeverityWithoutAnotherSound() {
        var preferences = LocalNotificationPreferences.defaults
        preferences.notifyOnErrors = true
        preferences.playSoundForErrors = true

        let descriptor = RuntimeNotificationDescriptor.makeBurstSummary(
            level: .error,
            suppressedCount: 8,
            preferences: preferences,
            now: Date(timeIntervalSince1970: 10_000)
        )

        #expect(descriptor.title == "8 additional Thane errors")
        #expect(descriptor.delivery == .active)
        #expect(!descriptor.playSound)
        #expect(descriptor.expirationDate == nil)
    }

    @Test
    func incidentIdentifierIsStableAndSeveritySpecific() {
        let first = makeEntry(message: "disk pressure", level: .warn, source: "storage.go:12")
        let sameIncident = makeEntry(message: "disk pressure", level: .warn, source: "storage.go:12")
        let error = makeEntry(message: "disk pressure", level: .error, source: "storage.go:12")

        #expect(
            RuntimeNotificationDescriptor.requestIdentifier(for: first)
                == RuntimeNotificationDescriptor.requestIdentifier(for: sameIncident)
        )
        #expect(
            RuntimeNotificationDescriptor.requestIdentifier(for: first)
                != RuntimeNotificationDescriptor.requestIdentifier(for: error)
        )
    }

    @Test
    func duplicateIncidentIsCollapsedUntilItsRepeatInterval() {
        var throttle = RuntimeNotificationThrottle()
        let start = Date(timeIntervalSince1970: 100)

        #expect(
            throttle.evaluate(
                identifier: "incident",
                level: .error,
                at: start,
                repeatInterval: 15 * 60
            ) == .deliver(repeatedCount: 0)
        )
        #expect(
            throttle.evaluate(
                identifier: "incident",
                level: .error,
                at: start.addingTimeInterval(60),
                repeatInterval: 15 * 60
            ) == .suppressDuplicate
        )
        #expect(
            throttle.evaluate(
                identifier: "incident",
                level: .error,
                at: start.addingTimeInterval(15 * 60),
                repeatInterval: 15 * 60
            ) == .deliver(repeatedCount: 1)
        )
    }

    @Test
    func warningBurstDoesNotConsumeErrorBudget() {
        var throttle = RuntimeNotificationThrottle(maximumDeliveriesPerMinute: 2)
        let now = Date(timeIntervalSince1970: 100)

        #expect(delivers(&throttle, identifier: "warn-1", level: .warn, at: now))
        #expect(delivers(&throttle, identifier: "warn-2", level: .warn, at: now))
        #expect(
            throttle.evaluate(
                identifier: "warn-3",
                level: .warn,
                at: now,
                repeatInterval: 60
            ) == .suppressBurst
        )
        #expect(delivers(&throttle, identifier: "error-1", level: .error, at: now))
    }

    @Test
    func staleIncidentsArePruned() {
        var throttle = RuntimeNotificationThrottle()
        let start = Date(timeIntervalSince1970: 100)

        #expect(delivers(&throttle, identifier: "old", level: .warn, at: start))
        #expect(throttle.trackedIncidentCount == 1)
        #expect(
            delivers(
                &throttle,
                identifier: "new",
                level: .warn,
                at: start.addingTimeInterval(2 * 60 * 60)
            )
        )
        #expect(throttle.trackedIncidentCount == 1)
    }

    private func delivers(
        _ throttle: inout RuntimeNotificationThrottle,
        identifier: String,
        level: BinaryManager.RuntimeLogLevel,
        at date: Date
    ) -> Bool {
        if case .deliver = throttle.evaluate(
            identifier: identifier,
            level: level,
            at: date,
            repeatInterval: 15 * 60
        ) {
            return true
        }
        return false
    }

    private func makeEntry(
        message: String,
        level: BinaryManager.RuntimeLogLevel,
        source: String? = nil,
        fields: [BinaryManager.RuntimeLogField] = []
    ) -> BinaryManager.RuntimeLogEntry {
        BinaryManager.RuntimeLogEntry(
            date: Date(timeIntervalSince1970: 100),
            message: message,
            level: level,
            source: source,
            fields: fields
        )
    }
}
