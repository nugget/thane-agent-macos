import Foundation

/// App version constants, derived from the Xcode build settings.
enum AppVersion {
    /// The marketing version string (e.g. "0.0.2"), read from the app bundle's
    /// Info.plist at runtime.
    static let current: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

    /// The build number (e.g. "42"), auto-incremented on each archive.
    static let build: String =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    /// Display string including build number, e.g. "0.0.2 (42)".
    static let displayVersion: String = "\(current) (\(build))"

    /// Git commit hash stamped at build time.
    static let gitCommit: String = BuildInfo.gitCommit

    /// When the binary was built, stamped at compile time by `just stamp`.
    static let buildDate: Date? = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: BuildInfo.buildTimestamp)
    }()

    /// Parsed semantic version, if the marketing version is valid semver.
    static let semver: SemanticVersion? = SemanticVersion(current)
}
