import EventKit
import Foundation

/// Shared authorization state for EventKit-backed providers (Calendar and
/// Reminders). EventKit reports both through `EKAuthorizationStatus`; the
/// `.writeOnly` case only ever occurs for calendar events.
enum EventKitAuthorizationState: String, Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case fullAccess
    case writeOnly
    case unknown

    nonisolated init(status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorized:
            self = .fullAccess
        case .fullAccess:
            self = .fullAccess
        case .writeOnly:
            self = .writeOnly
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
        case .writeOnly:
            "Write only"
        case .unknown:
            "Unknown"
        }
    }
}
