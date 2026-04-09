import Foundation

/// App version constants, derived from the Xcode build settings.
enum AppVersion {
    /// The marketing version string (e.g. "0.0.2"), read from the app bundle's
    /// Info.plist at runtime.
    static let current: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

    /// Parsed semantic version, if the marketing version is valid semver.
    static let semver: SemanticVersion? = SemanticVersion(current)
}
