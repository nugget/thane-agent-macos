import Foundation

/// Pure display formatters for the Server panels. `nonisolated` so they are
/// unit-testable off the main actor and callable from any view context.
nonisolated enum ServerFormat {
    /// Human uptime from seconds, e.g. "5d 13h", "13h 30m", "45m", "—".
    static func uptime(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "—" }
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        let minutes = (s % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Compact integer, e.g. 1_284_532 → "1.3M", 9123 → "9.1K", 42 → "42".
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }

    static func usd(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    /// A 0...1 fraction as a whole percent, e.g. 0.765 → "77%". "—" if not finite.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return String(format: "%.0f%%", fraction * 100)
    }

    /// One-line description of a schedule spec, e.g. "every 15m0s", "0 8 * * *".
    static func schedule(_ s: ScheduleSpec) -> String {
        switch s.kind {
        case "every": "every \(s.every ?? "?")"
        case "cron": s.cron ?? "cron"
        case "at": s.at.map(relative) ?? "once"
        default: s.kind
        }
    }

    /// Relative time from an ISO8601 timestamp, e.g. "in 5 min", "2h ago".
    /// Returns the raw string if it can't be parsed.
    static func relative(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return iso }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Parses an RFC3339/ISO8601 timestamp, with or without fractional seconds.
    /// One formatter instance, reusing it for the fallback parse.
    static func parseISO(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
