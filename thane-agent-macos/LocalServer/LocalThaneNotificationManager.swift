import AppKit
import CryptoKit
import Foundation
import os
@preconcurrency import UserNotifications

nonisolated enum LocalNotificationAuthorization: String, Sendable {
    case notRequested
    case allowed
    case denied
    case unavailable

    var title: String {
        switch self {
        case .notRequested: "Not Requested"
        case .allowed: "Allowed"
        case .denied: "Not Allowed"
        case .unavailable: "Unavailable"
        }
    }
}

nonisolated enum LocalNotificationRepeatInterval: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveMinutes: "5 Minutes"
        case .fifteenMinutes: "15 Minutes"
        case .oneHour: "1 Hour"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        }
    }
}

nonisolated enum WarningNotificationLifetime: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case fourHours
    case untilDismissed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: "1 Hour"
        case .fourHours: "4 Hours"
        case .untilDismissed: "Until Dismissed"
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .oneHour: 60 * 60
        case .fourHours: 4 * 60 * 60
        case .untilDismissed: nil
        }
    }
}

nonisolated struct LocalNotificationPreferences: Equatable, Sendable {
    static let warningKey = "localNotificationsWarnings"
    static let errorKey = "localNotificationsErrors"
    static let errorSoundKey = "localNotificationsErrorSound"
    static let foregroundKey = "localNotificationsWhileActive"
    static let detailsKey = "localNotificationsIncludeDetails"
    static let repeatIntervalKey = "localNotificationsRepeatInterval"
    static let warningLifetimeKey = "localNotificationsWarningLifetime"
    static let muteUntilKey = "localNotificationsMuteUntil"

    var notifyOnWarnings: Bool
    var notifyOnErrors: Bool
    var playSoundForErrors: Bool
    var notifyWhileAppIsActive: Bool
    var includeLogDetails: Bool
    var repeatInterval: LocalNotificationRepeatInterval
    var warningLifetime: WarningNotificationLifetime

    static let defaults = LocalNotificationPreferences(
        notifyOnWarnings: false,
        notifyOnErrors: false,
        playSoundForErrors: true,
        notifyWhileAppIsActive: false,
        includeLogDetails: true,
        repeatInterval: .fifteenMinutes,
        warningLifetime: .oneHour
    )

    static func load(from defaults: UserDefaults) -> LocalNotificationPreferences {
        var preferences = Self.defaults
        if defaults.object(forKey: warningKey) != nil {
            preferences.notifyOnWarnings = defaults.bool(forKey: warningKey)
        }
        if defaults.object(forKey: errorKey) != nil {
            preferences.notifyOnErrors = defaults.bool(forKey: errorKey)
        }
        if defaults.object(forKey: errorSoundKey) != nil {
            preferences.playSoundForErrors = defaults.bool(forKey: errorSoundKey)
        }
        if defaults.object(forKey: foregroundKey) != nil {
            preferences.notifyWhileAppIsActive = defaults.bool(forKey: foregroundKey)
        }
        if defaults.object(forKey: detailsKey) != nil {
            preferences.includeLogDetails = defaults.bool(forKey: detailsKey)
        }
        if let raw = defaults.string(forKey: repeatIntervalKey),
           let interval = LocalNotificationRepeatInterval(rawValue: raw) {
            preferences.repeatInterval = interval
        }
        if let raw = defaults.string(forKey: warningLifetimeKey),
           let lifetime = WarningNotificationLifetime(rawValue: raw) {
            preferences.warningLifetime = lifetime
        }
        return preferences
    }

    func save(to defaults: UserDefaults) {
        defaults.set(notifyOnWarnings, forKey: Self.warningKey)
        defaults.set(notifyOnErrors, forKey: Self.errorKey)
        defaults.set(playSoundForErrors, forKey: Self.errorSoundKey)
        defaults.set(notifyWhileAppIsActive, forKey: Self.foregroundKey)
        defaults.set(includeLogDetails, forKey: Self.detailsKey)
        defaults.set(repeatInterval.rawValue, forKey: Self.repeatIntervalKey)
        defaults.set(warningLifetime.rawValue, forKey: Self.warningLifetimeKey)
    }

    func includes(_ level: BinaryManager.RuntimeLogLevel) -> Bool {
        switch level {
        case .warn: notifyOnWarnings
        case .error: notifyOnErrors
        case .trace, .debug, .info: false
        }
    }

    var isEnabled: Bool {
        notifyOnWarnings || notifyOnErrors
    }
}

nonisolated struct RuntimeNotificationDescriptor: Equatable, Sendable {
    enum Delivery: Sendable {
        case passive
        case active
    }

    static let threadIdentifier = "local-thane-runtime"

    let requestIdentifier: String
    let title: String
    let subtitle: String
    let body: String
    let level: BinaryManager.RuntimeLogLevel
    let delivery: Delivery
    let playSound: Bool
    let expirationDate: Date?

    static func make(
        entry: BinaryManager.RuntimeLogEntry,
        preferences: LocalNotificationPreferences,
        repeatedCount: Int,
        now: Date
    ) -> RuntimeNotificationDescriptor {
        let includesDetails = preferences.includeLogDetails
        let title: String
        let subtitle: String
        var bodyParts: [String] = []

        if includesDetails {
            title = bounded(entry.message, maxLength: 110)
            subtitle = entry.level == .error ? "Local Thane · Error" : "Local Thane · Warning"

            let context = notificationContext(from: entry.fields)
            if !context.isEmpty {
                bodyParts.append(context)
            }
        } else {
            title = entry.level == .error
                ? "Local Thane needs attention"
                : "Local Thane reported a warning"
            subtitle = "Log details are hidden"
            bodyParts.append("Open Local Thane to review the event.")
        }

        if repeatedCount > 0 {
            let noun = repeatedCount == 1 ? "time" : "times"
            bodyParts.append("Repeated \(repeatedCount) \(noun) since the last notification.")
        }

        let fallbackBody = entry.level == .error
            ? "Open Local Thane to review this error."
            : "Open Local Thane to review this warning."
        let expirationDate = entry.level == .warn
            ? preferences.warningLifetime.duration.map { now.addingTimeInterval($0) }
            : nil

        return RuntimeNotificationDescriptor(
            requestIdentifier: requestIdentifier(for: entry),
            title: title,
            subtitle: subtitle,
            body: bounded(bodyParts.isEmpty ? fallbackBody : bodyParts.joined(separator: "\n"), maxLength: 280),
            level: entry.level,
            delivery: entry.level == .error ? .active : .passive,
            playSound: entry.level == .error && preferences.playSoundForErrors,
            expirationDate: expirationDate
        )
    }

    static func requestIdentifier(for entry: BinaryManager.RuntimeLogEntry) -> String {
        let source = entry.source ?? ""
        let input = "\(entry.level.rawValue)\u{1f}\(entry.message)\u{1f}\(source)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let shortDigest = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "local-thane-\(entry.level.rawValue)-\(shortDigest)"
    }

    static func makeBurstSummary(
        level: BinaryManager.RuntimeLogLevel,
        suppressedCount: Int,
        preferences: LocalNotificationPreferences,
        now: Date
    ) -> RuntimeNotificationDescriptor {
        let noun = level == .error ? "errors" : "warnings"
        let expirationDate = level == .warn
            ? preferences.warningLifetime.duration.map { now.addingTimeInterval($0) }
            : nil

        return RuntimeNotificationDescriptor(
            requestIdentifier: "local-thane-\(level.rawValue)-burst",
            title: "\(suppressedCount) additional Thane \(noun)",
            subtitle: "Grouped over the last minute",
            body: "Open Local Thane to review the complete activity window.",
            level: level,
            delivery: level == .error ? .active : .passive,
            playSound: false,
            expirationDate: expirationDate
        )
    }

    private static let contextKeys: Set<String> = [
        "attempt",
        "code",
        "component",
        "duration",
        "duration_ms",
        "model",
        "module",
        "operation",
        "provider",
        "retry_after",
        "retry_in",
        "status",
        "subsystem",
    ]

    private static func notificationContext(from fields: [BinaryManager.RuntimeLogField]) -> String {
        fields
            .filter { contextKeys.contains($0.key.lowercased()) }
            .prefix(3)
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "  •  ")
    }

    private static func bounded(_ value: String, maxLength: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maxLength else { return singleLine }
        return String(singleLine.prefix(maxLength - 1)) + "…"
    }
}

nonisolated struct RuntimeNotificationThrottle: Sendable {
    enum Decision: Equatable, Sendable {
        case deliver(repeatedCount: Int)
        case suppressDuplicate
        case suppressBurst
    }

    private struct Incident: Sendable {
        var lastDeliveredAt: Date
        var lastSeenAt: Date
        var suppressedDuplicates: Int
    }

    private var incidents: [String: Incident] = [:]
    private var recentWarningDeliveries: [Date] = []
    private var recentErrorDeliveries: [Date] = []
    private let maximumDeliveriesPerMinute: Int

    var trackedIncidentCount: Int { incidents.count }

    init(maximumDeliveriesPerMinute: Int = 4) {
        precondition(maximumDeliveriesPerMinute > 0)
        self.maximumDeliveriesPerMinute = maximumDeliveriesPerMinute
    }

    mutating func evaluate(
        identifier: String,
        level: BinaryManager.RuntimeLogLevel,
        at now: Date,
        repeatInterval: TimeInterval
    ) -> Decision {
        prune(at: now, repeatInterval: repeatInterval)

        if var incident = incidents[identifier] {
            incident.lastSeenAt = now
            if now.timeIntervalSince(incident.lastDeliveredAt) < repeatInterval {
                incident.suppressedDuplicates += 1
                incidents[identifier] = incident
                return .suppressDuplicate
            }

            guard reserveBurstSlot(for: level, at: now) else {
                incident.suppressedDuplicates += 1
                incidents[identifier] = incident
                return .suppressBurst
            }

            let repeatedCount = incident.suppressedDuplicates
            incidents[identifier] = Incident(
                lastDeliveredAt: now,
                lastSeenAt: now,
                suppressedDuplicates: 0
            )
            return .deliver(repeatedCount: repeatedCount)
        }

        guard reserveBurstSlot(for: level, at: now) else {
            return .suppressBurst
        }

        incidents[identifier] = Incident(
            lastDeliveredAt: now,
            lastSeenAt: now,
            suppressedDuplicates: 0
        )
        return .deliver(repeatedCount: 0)
    }

    mutating func reset() {
        incidents.removeAll(keepingCapacity: true)
        recentWarningDeliveries.removeAll(keepingCapacity: true)
        recentErrorDeliveries.removeAll(keepingCapacity: true)
    }

    private mutating func reserveBurstSlot(
        for level: BinaryManager.RuntimeLogLevel,
        at now: Date
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-60)
        switch level {
        case .warn:
            recentWarningDeliveries.removeAll { $0 < cutoff }
            guard recentWarningDeliveries.count < maximumDeliveriesPerMinute else { return false }
            recentWarningDeliveries.append(now)
        case .error:
            recentErrorDeliveries.removeAll { $0 < cutoff }
            guard recentErrorDeliveries.count < maximumDeliveriesPerMinute else { return false }
            recentErrorDeliveries.append(now)
        case .trace, .debug, .info:
            return false
        }
        return true
    }

    private mutating func prune(at now: Date, repeatInterval: TimeInterval) {
        let incidentCutoff = now.addingTimeInterval(-max(repeatInterval * 2, 60 * 60))
        incidents = incidents.filter { $0.value.lastSeenAt >= incidentCutoff }

        let deliveryCutoff = now.addingTimeInterval(-60)
        recentWarningDeliveries.removeAll { $0 < deliveryCutoff }
        recentErrorDeliveries.removeAll { $0 < deliveryCutoff }
    }
}

@Observable
@MainActor
final class LocalThaneNotificationManager {
    static let categoryIdentifier = "LOCAL_THANE_RUNTIME_EVENT"
    static let muteActionIdentifier = "MUTE_LOCAL_THANE_ONE_HOUR"
    static let levelUserInfoKey = "localThaneLevel"
    static let expirationUserInfoKey = "localThaneExpiresAt"
    static let maximumDeliveredIncidentCount = 40

    private(set) var preferences: LocalNotificationPreferences
    private(set) var authorization: LocalNotificationAuthorization = .notRequested
    private(set) var systemAlertsEnabled = false
    private(set) var systemSoundsEnabled = false
    private(set) var muteUntil: Date?
    private(set) var lastDeliveryError: String?

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: "info.nugget.thane-agent-macos",
        category: "local-notifications"
    )
    private var throttle = RuntimeNotificationThrottle()
    private var warningExpirations: [String: Date] = [:]
    private var expirationTask: Task<Void, Never>?
    private var muteTask: Task<Void, Never>?
    private var suppressedBurstCounts: [BinaryManager.RuntimeLogLevel: Int] = [:]
    private var burstDigestTasks: [
        BinaryManager.RuntimeLogLevel: Task<Void, Never>
    ] = [:]

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        preferences = LocalNotificationPreferences.load(from: defaults)
        muteUntil = defaults.object(forKey: LocalNotificationPreferences.muteUntilKey) as? Date
        normalizeMuteState()
        scheduleAutomaticResume()
    }

    static func registerNotificationCategory(
        center: UNUserNotificationCenter = .current()
    ) {
        let muteAction = UNNotificationAction(
            identifier: muteActionIdentifier,
            title: "Mute for 1 Hour",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "bell.slash")
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [muteAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "A local Thane event",
            options: []
        )
        center.setNotificationCategories([category])
    }

    func setWarningsEnabled(_ enabled: Bool) {
        preferences.notifyOnWarnings = enabled
        preferences.save(to: defaults)
        if !enabled {
            cancelBurstDigest(for: .warn)
        }
        requestAuthorizationWhenNeeded(afterEnabling: enabled)
    }

    func setErrorsEnabled(_ enabled: Bool) {
        preferences.notifyOnErrors = enabled
        preferences.save(to: defaults)
        if !enabled {
            cancelBurstDigest(for: .error)
        }
        requestAuthorizationWhenNeeded(afterEnabling: enabled)
    }

    func setErrorSoundEnabled(_ enabled: Bool) {
        preferences.playSoundForErrors = enabled
        preferences.save(to: defaults)
        requestAuthorizationWhenNeeded(afterEnabling: enabled && preferences.notifyOnErrors)
    }

    func setNotifyWhileActive(_ enabled: Bool) {
        preferences.notifyWhileAppIsActive = enabled
        preferences.save(to: defaults)
    }

    func setIncludeLogDetails(_ enabled: Bool) {
        preferences.includeLogDetails = enabled
        preferences.save(to: defaults)
    }

    func setRepeatInterval(_ interval: LocalNotificationRepeatInterval) {
        preferences.repeatInterval = interval
        preferences.save(to: defaults)
        throttle.reset()
    }

    func setWarningLifetime(_ lifetime: WarningNotificationLifetime) {
        preferences.warningLifetime = lifetime
        preferences.save(to: defaults)
    }

    func mute(for duration: TimeInterval) {
        mute(until: Date().addingTimeInterval(duration))
    }

    func mute(until date: Date) {
        muteUntil = date
        defaults.set(date, forKey: LocalNotificationPreferences.muteUntilKey)
        cancelAllBurstDigests()
        scheduleAutomaticResume()
        logger.info("Local Thane notifications muted until \(date, privacy: .public)")
    }

    func resumeNotifications() {
        muteTask?.cancel()
        muteTask = nil
        muteUntil = nil
        defaults.removeObject(forKey: LocalNotificationPreferences.muteUntilKey)
        throttle.reset()
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        apply(settings)
        await reconcileDeliveredWarnings()
        await trimDeliveredRuntimeNotifications()
    }

    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(
                options: [.alert, .sound, .providesAppNotificationSettings]
            )
            lastDeliveryError = nil
        } catch {
            lastDeliveryError = error.localizedDescription
            logger.error("Notification authorization failed: \(error.localizedDescription)")
        }
        await refreshAuthorization()
    }

    func handle(_ entry: BinaryManager.RuntimeLogEntry) {
        normalizeMuteState()
        guard preferences.includes(entry.level),
              authorization == .allowed,
              systemAlertsEnabled,
              muteUntil == nil,
              preferences.notifyWhileAppIsActive || !NSApp.isActive
        else {
            return
        }

        let now = Date()
        let identifier = RuntimeNotificationDescriptor.requestIdentifier(for: entry)
        let decision = throttle.evaluate(
            identifier: identifier,
            level: entry.level,
            at: now,
            repeatInterval: preferences.repeatInterval.duration
        )
        switch decision {
        case .deliver(let repeatedCount):
            let descriptor = RuntimeNotificationDescriptor.make(
                entry: entry,
                preferences: preferences,
                repeatedCount: repeatedCount,
                now: now
            )
            Task { [weak self] in
                await self?.deliver(descriptor)
            }
        case .suppressBurst:
            recordSuppressedBurst(for: entry.level)
        case .suppressDuplicate:
            break
        }
    }

    func openSystemNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func requestAuthorizationWhenNeeded(afterEnabling enabled: Bool) {
        guard enabled else { return }
        Task { [weak self] in
            await self?.requestAuthorization()
        }
    }

    private func deliver(_ descriptor: RuntimeNotificationDescriptor) async {
        let settings = await center.notificationSettings()
        apply(settings)
        guard authorization == .allowed, systemAlertsEnabled else {
            logger.info("Local Thane notification skipped because system alerts are unavailable")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = descriptor.title
        content.subtitle = descriptor.subtitle
        content.body = descriptor.body
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = RuntimeNotificationDescriptor.threadIdentifier
        content.targetContentIdentifier = "process-health"
        content.interruptionLevel = descriptor.delivery == .active ? .active : .passive
        content.relevanceScore = descriptor.delivery == .active ? 1 : 0.5
        if descriptor.playSound {
            content.sound = .default
        }

        var userInfo: [String: Any] = [
            Self.levelUserInfoKey: descriptor.level.rawValue,
        ]
        if let expirationDate = descriptor.expirationDate {
            userInfo[Self.expirationUserInfoKey] = expirationDate.timeIntervalSince1970
        }
        content.userInfo = userInfo

        do {
            let request = UNNotificationRequest(
                identifier: descriptor.requestIdentifier,
                content: content,
                trigger: nil
            )
            try await center.add(request)
            lastDeliveryError = nil
            if let expirationDate = descriptor.expirationDate {
                warningExpirations[descriptor.requestIdentifier] = expirationDate
            } else {
                warningExpirations.removeValue(forKey: descriptor.requestIdentifier)
            }
            scheduleExpirationSweep()
            await trimDeliveredRuntimeNotifications()
        } catch {
            lastDeliveryError = error.localizedDescription
            logger.error("Could not deliver local Thane notification: \(error.localizedDescription)")
        }
    }

    private func apply(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .notDetermined:
            authorization = .notRequested
        case .denied:
            authorization = .denied
        case .authorized, .provisional, .ephemeral:
            authorization = .allowed
        @unknown default:
            authorization = .unavailable
        }
        systemAlertsEnabled = settings.alertSetting == .enabled
        systemSoundsEnabled = settings.soundSetting == .enabled
    }

    private func normalizeMuteState() {
        guard let muteUntil else { return }
        if muteUntil <= Date() {
            resumeNotifications()
        }
    }

    private func scheduleAutomaticResume() {
        muteTask?.cancel()
        guard let muteUntil else {
            muteTask = nil
            return
        }

        let delay = max(0, muteUntil.timeIntervalSinceNow)
        muteTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.resumeNotifications()
        }
    }

    private func recordSuppressedBurst(for level: BinaryManager.RuntimeLogLevel) {
        suppressedBurstCounts[level, default: 0] += 1
        guard burstDigestTasks[level] == nil else { return }

        burstDigestTasks[level] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            await self?.deliverBurstDigest(for: level)
        }
    }

    private func deliverBurstDigest(for level: BinaryManager.RuntimeLogLevel) async {
        burstDigestTasks[level] = nil
        let count = suppressedBurstCounts.removeValue(forKey: level) ?? 0
        guard count > 0,
              preferences.includes(level),
              authorization == .allowed,
              systemAlertsEnabled,
              muteUntil == nil,
              preferences.notifyWhileAppIsActive || !NSApp.isActive
        else {
            return
        }

        let descriptor = RuntimeNotificationDescriptor.makeBurstSummary(
            level: level,
            suppressedCount: count,
            preferences: preferences,
            now: Date()
        )
        await deliver(descriptor)
    }

    private func cancelBurstDigest(for level: BinaryManager.RuntimeLogLevel) {
        burstDigestTasks.removeValue(forKey: level)?.cancel()
        suppressedBurstCounts.removeValue(forKey: level)
    }

    private func cancelAllBurstDigests() {
        for task in burstDigestTasks.values {
            task.cancel()
        }
        burstDigestTasks.removeAll(keepingCapacity: true)
        suppressedBurstCounts.removeAll(keepingCapacity: true)
    }

    private func reconcileDeliveredWarnings() async {
        let delivered = await center.deliveredNotifications()
        let now = Date()
        var expiredIdentifiers: [String] = []
        warningExpirations.removeAll(keepingCapacity: true)

        for notification in delivered {
            let identifier = notification.request.identifier
            guard identifier.hasPrefix("local-thane-warn-"),
                  let expiration = notification.request.content.userInfo[
                    Self.expirationUserInfoKey
                  ] as? TimeInterval
            else {
                continue
            }

            let expirationDate = Date(timeIntervalSince1970: expiration)
            if expirationDate <= now {
                expiredIdentifiers.append(identifier)
            } else {
                warningExpirations[identifier] = expirationDate
            }
        }

        if !expiredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: expiredIdentifiers)
        }
        scheduleExpirationSweep()
    }

    private func trimDeliveredRuntimeNotifications() async {
        let delivered = await center.deliveredNotifications()
        let runtimeNotifications = delivered
            .filter { $0.request.identifier.hasPrefix("local-thane-") }
            .sorted { $0.date > $1.date }
        let excess = runtimeNotifications.dropFirst(Self.maximumDeliveredIncidentCount)
        guard !excess.isEmpty else { return }

        let identifiers = excess.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        for identifier in identifiers {
            warningExpirations.removeValue(forKey: identifier)
        }
        scheduleExpirationSweep()
    }

    private func scheduleExpirationSweep() {
        expirationTask?.cancel()
        guard let nextExpiration = warningExpirations.values.min() else {
            expirationTask = nil
            return
        }

        let delay = max(0, nextExpiration.timeIntervalSinceNow)
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.removeExpiredWarnings()
        }
    }

    private func removeExpiredWarnings() {
        let now = Date()
        let identifiers = warningExpirations.compactMap { identifier, expiration in
            expiration <= now ? identifier : nil
        }
        guard !identifiers.isEmpty else {
            scheduleExpirationSweep()
            return
        }

        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        for identifier in identifiers {
            warningExpirations.removeValue(forKey: identifier)
        }
        scheduleExpirationSweep()
    }
}
