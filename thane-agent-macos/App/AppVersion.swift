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

    /// When the current executable was built, derived from the binary's
    /// modification timestamp. Useful for operators to anchor a build in
    /// time without tracking release tags.
    static let buildDate: Date? = {
        guard let execURL = Bundle.main.executableURL else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: execURL.path))?[.modificationDate] as? Date
    }()

    /// Parsed semantic version, if the marketing version is valid semver.
    static let semver: SemanticVersion? = SemanticVersion(current)
}
