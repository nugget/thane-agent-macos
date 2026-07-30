import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

nonisolated enum SystemContextCategory: String, CaseIterable, Identifiable, Sendable {
    case application
    case activity
    case power
    case displays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "Frontmost Application"
        case .activity: "User Activity"
        case .power: "Power & Thermal State"
        case .displays: "Displays"
        }
    }

    var detail: String {
        switch self {
        case .application:
            "Shares the active app’s name and bundle identifier."
        case .activity:
            "Shares how long this Mac has been idle."
        case .power:
            "Shares battery, charging, Low Power Mode, and thermal state."
        case .displays:
            "Shares connected display names, count, and the primary display."
        }
    }
}

@Observable
@MainActor
final class SystemContextPreferences {
    private nonisolated static let keyPrefix = "systemContext."
    private let defaults: UserDefaults

    var applicationEnabled: Bool {
        didSet { persist(applicationEnabled, category: .application) }
    }
    var activityEnabled: Bool {
        didSet { persist(activityEnabled, category: .activity) }
    }
    var powerEnabled: Bool {
        didSet { persist(powerEnabled, category: .power) }
    }
    var displaysEnabled: Bool {
        didSet { persist(displaysEnabled, category: .displays) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        applicationEnabled = defaults.bool(forKey: Self.key(for: .application))
        activityEnabled = defaults.bool(forKey: Self.key(for: .activity))
        powerEnabled = defaults.bool(forKey: Self.key(for: .power))
        displaysEnabled = defaults.bool(forKey: Self.key(for: .displays))
    }

    var enabledCategories: Set<SystemContextCategory> {
        Set(SystemContextCategory.allCases.filter(isEnabled))
    }

    var hasEnabledCategories: Bool {
        !enabledCategories.isEmpty
    }

    func isEnabled(_ category: SystemContextCategory) -> Bool {
        switch category {
        case .application: applicationEnabled
        case .activity: activityEnabled
        case .power: powerEnabled
        case .displays: displaysEnabled
        }
    }

    func bindingValue(for category: SystemContextCategory) -> Bool {
        isEnabled(category)
    }

    func setEnabled(_ enabled: Bool, for category: SystemContextCategory) {
        switch category {
        case .application: applicationEnabled = enabled
        case .activity: activityEnabled = enabled
        case .power: powerEnabled = enabled
        case .displays: displaysEnabled = enabled
        }
    }

    private func persist(_ enabled: Bool, category: SystemContextCategory) {
        defaults.set(enabled, forKey: Self.key(for: category))
    }

    private nonisolated static func key(for category: SystemContextCategory) -> String {
        keyPrefix + category.rawValue
    }
}

nonisolated struct SystemContextSnapshot: Codable, Equatable, Sendable {
    let capturedAt: String
    let application: FrontmostApplicationContext?
    let activity: UserActivityContext?
    let power: PowerContext?
    let displays: DisplayContext?

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case application
        case activity
        case power
        case displays
    }
}

nonisolated struct FrontmostApplicationContext: Codable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let isHidden: Bool
    let ownsMenuBar: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case bundleIdentifier = "bundle_identifier"
        case isHidden = "is_hidden"
        case ownsMenuBar = "owns_menu_bar"
    }
}

nonisolated struct UserActivityContext: Codable, Equatable, Sendable {
    let idleSeconds: Int

    enum CodingKeys: String, CodingKey {
        case idleSeconds = "idle_seconds"
    }
}

nonisolated struct PowerContext: Codable, Equatable, Sendable {
    let source: String
    let batteryPercent: Int?
    let charging: Bool?
    let lowPowerMode: Bool
    let thermalState: String

    enum CodingKeys: String, CodingKey {
        case source
        case batteryPercent = "battery_percent"
        case charging
        case lowPowerMode = "low_power_mode"
        case thermalState = "thermal_state"
    }
}

nonisolated struct DisplayContext: Codable, Equatable, Sendable {
    let count: Int
    let names: [String]
    let primaryName: String?

    enum CodingKeys: String, CodingKey {
        case count
        case names
        case primaryName = "primary_name"
    }
}

enum SystemContextServiceError: PlatformServiceError, Sendable {
    case noCategoriesEnabled
    case unsupportedMethod(String)

    nonisolated var code: String {
        switch self {
        case .noCategoriesEnabled: "system_context_disabled"
        case .unsupportedMethod: "unknown_method"
        }
    }

    nonisolated var errorDescription: String? {
        switch self {
        case .noCategoriesEnabled:
            "System Context sharing is disabled in the macOS companion app."
        case .unsupportedMethod(let method):
            "Unsupported System Context method: \(method)"
        }
    }
}

@MainActor
final class SystemContextService {
    private let preferences: SystemContextPreferences

    init(preferences: SystemContextPreferences) {
        self.preferences = preferences
    }

    func snapshot() throws -> SystemContextSnapshot {
        let enabled = preferences.enabledCategories
        guard !enabled.isEmpty else {
            throw SystemContextServiceError.noCategoriesEnabled
        }

        return SystemContextSnapshot(
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            application: enabled.contains(.application) ? applicationContext() : nil,
            activity: enabled.contains(.activity) ? activityContext() : nil,
            power: enabled.contains(.power) ? Self.powerContext() : nil,
            displays: enabled.contains(.displays) ? displayContext() : nil
        )
    }

    private func applicationContext() -> FrontmostApplicationContext? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let menuBarOwner = NSWorkspace.shared.menuBarOwningApplication
        return FrontmostApplicationContext(
            name: application.localizedName ?? application.bundleIdentifier ?? "Unknown",
            bundleIdentifier: application.bundleIdentifier,
            isHidden: application.isHidden,
            ownsMenuBar: application.processIdentifier == menuBarOwner?.processIdentifier
        )
    }

    private func activityContext() -> UserActivityContext {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
        return UserActivityContext(idleSeconds: max(0, Int(seconds.rounded(.down))))
    }

    private func displayContext() -> DisplayContext {
        let screens = NSScreen.screens
        return DisplayContext(
            count: screens.count,
            names: screens.map(\.localizedName),
            primaryName: screens.first?.localizedName
        )
    }

    private nonisolated static func powerContext() -> PowerContext {
        let processInfo = ProcessInfo.processInfo
        let battery = batteryState()
        return PowerContext(
            source: battery.source,
            batteryPercent: battery.percent,
            charging: battery.charging,
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateLabel(processInfo.thermalState)
        )
    }

    private nonisolated static func batteryState() -> (
        source: String,
        percent: Int?,
        charging: Bool?
    ) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else {
            return ("unknown", nil, nil)
        }

        let current = description[kIOPSCurrentCapacityKey as String] as? Int
        let maximum = description[kIOPSMaxCapacityKey as String] as? Int
        let percent: Int? = if let current, let maximum, maximum > 0 {
            Int((Double(current) / Double(maximum) * 100).rounded())
        } else {
            nil
        }
        let state = description[kIOPSPowerSourceStateKey as String] as? String
        let charging = description[kIOPSIsChargingKey as String] as? Bool
        return (
            state == kIOPSACPowerValue ? "ac" : state == kIOPSBatteryPowerValue ? "battery" : "unknown",
            percent,
            charging
        )
    }

    private nonisolated static func thermalStateLabel(
        _ state: ProcessInfo.ThermalState
    ) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

@MainActor
struct SystemContextPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["get_snapshot"]
    let toolDefinitions = [
        PlatformToolDefinition.make(
            name: "macos_system_context",
            description: "Read the current, operator-approved context of the Mac running the companion app. Only categories enabled in the app are returned.",
            method: "get_snapshot",
            tags: ["macos", "context", "read"],
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {}
            }
            """
        ),
    ]

    private let service: SystemContextService

    init(service: SystemContextService) {
        self.service = service
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        guard method == "get_snapshot" else {
            throw SystemContextServiceError.unsupportedMethod(method)
        }
        return try AnyCodable.fromEncodable(service.snapshot())
    }
}
