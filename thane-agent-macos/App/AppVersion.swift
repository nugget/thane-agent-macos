import Foundation

/// App version constants stamped at compile time by `just stamp`.
///
/// The git describe string (e.g. "v0.0.2-3-gcfd7ec6") is the source of
/// truth. The bundle's MARKETING_VERSION in the pbxproj is set to the
/// base semver for App Store/Finder display, but all internal version
/// logic uses the stamped values.
enum AppVersion {
    /// Full git describe version, e.g. "v0.0.2", "v0.0.2-3-gcfd7ec6-dirty".
    static let current: String = BuildInfo.version

    /// The build number from the bundle (auto-incremented by agvtool on archive).
    static let build: String =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    /// Display string, e.g. "v0.0.2-3-gcfd7ec6 (42)".
    static let displayVersion: String = "\(current) (\(build))"

    /// Git commit hash stamped at build time.
    static let gitCommit: String = BuildInfo.gitCommit

    /// Who built this binary, e.g. "nugget@studio".
    static let builtBy: String = BuildInfo.builtBy

    /// When the binary was built, stamped at compile time.
    static let buildDate: Date? = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: BuildInfo.buildTimestamp)
    }()

    /// Parsed semantic version from the git describe string.
    static let semver: SemanticVersion? = SemanticVersion(current)
}
