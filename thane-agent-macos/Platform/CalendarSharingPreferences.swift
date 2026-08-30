import Foundation
import os

/// One operator-authored sharing decision. Calendar identifiers are local
/// EventKit identifiers: a full account re-sync may replace one, in which case
/// the replacement calendar is deliberately unshared until the operator opts
/// it in.
nonisolated struct CalendarShareConfiguration: Codable, Equatable, Sendable {
    let calendarIdentifier: String
    var isShared: Bool
    var description: String

    enum CodingKeys: String, CodingKey {
        case calendarIdentifier = "calendar_identifier"
        case isShared = "is_shared"
        case description
    }
}

/// Immutable policy read by CalendarService at the start of each request.
nonisolated struct CalendarSharingSnapshot: Equatable, Sendable {
    let isEnabled: Bool
    let configurations: [String: CalendarShareConfiguration]

    var sharedCalendarIdentifiers: Set<String> {
        Set(
            configurations.values.lazy
                .filter(\.isShared)
                .map(\.calendarIdentifier)
        )
    }

    func description(for calendarIdentifier: String) -> String? {
        guard let value = configurations[calendarIdentifier]?.description
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// App-owned calendar sharing policy. EventKit permission establishes what the
/// app may read; this allowlist independently establishes what may leave the
/// app over the authenticated Thane connection.
@Observable
@MainActor
final class CalendarSharingPreferences {
    static let maxDescriptionLength = 2_000

    private nonisolated static let enabledKey = "calendarSharing.enabled"
    private nonisolated static let configurationsKey = "calendarSharing.configurations"
    private nonisolated static let logger = Logger(
        subsystem: "info.nugget.thane-agent-macos",
        category: "calendar"
    )

    private let defaults: UserDefaults
    private var configurations: [String: CalendarShareConfiguration]

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false

        guard let data = defaults.data(forKey: Self.configurationsKey) else {
            configurations = [:]
            return
        }

        do {
            let stored = try JSONDecoder().decode([CalendarShareConfiguration].self, from: data)
            let normalized = stored.map { configuration in
                var configuration = configuration
                configuration.description = String(
                    configuration.description.prefix(Self.maxDescriptionLength)
                )
                return configuration
            }
            configurations = Dictionary(
                normalized.map { ($0.calendarIdentifier, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            if normalized != stored {
                persistConfigurations()
            }
        } catch {
            configurations = [:]
            Self.logger.error("Could not decode calendar sharing preferences: \(error.localizedDescription)")
        }
    }

    var sharedCalendarCount: Int {
        configurations.values.lazy.filter(\.isShared).count
    }

    func isShared(_ calendarIdentifier: String) -> Bool {
        configurations[calendarIdentifier]?.isShared ?? false
    }

    func description(for calendarIdentifier: String) -> String {
        configurations[calendarIdentifier]?.description ?? ""
    }

    func setShared(_ shared: Bool, for calendarIdentifier: String) {
        update(calendarIdentifier: calendarIdentifier) { configuration in
            configuration.isShared = shared
        }
    }

    func setDescription(_ description: String, for calendarIdentifier: String) {
        update(calendarIdentifier: calendarIdentifier) { configuration in
            configuration.description = String(description.prefix(Self.maxDescriptionLength))
        }
    }

    func snapshot() -> CalendarSharingSnapshot {
        CalendarSharingSnapshot(
            isEnabled: isEnabled,
            configurations: configurations
        )
    }

    private func update(
        calendarIdentifier: String,
        mutation: (inout CalendarShareConfiguration) -> Void
    ) {
        var configuration = configurations[calendarIdentifier]
            ?? CalendarShareConfiguration(
                calendarIdentifier: calendarIdentifier,
                isShared: false,
                description: ""
            )
        mutation(&configuration)

        if !configuration.isShared && configuration.description.isEmpty {
            configurations.removeValue(forKey: calendarIdentifier)
        } else {
            configurations[calendarIdentifier] = configuration
        }
        persistConfigurations()
    }

    private func persistConfigurations() {
        let stored = configurations.values.sorted {
            $0.calendarIdentifier < $1.calendarIdentifier
        }
        do {
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.configurationsKey)
        } catch {
            Self.logger.error("Could not encode calendar sharing preferences: \(error.localizedDescription)")
        }
    }
}
