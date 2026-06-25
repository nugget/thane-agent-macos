import Foundation
import os

private let serverLog = Logger(subsystem: "info.nugget.thane-agent-macos", category: "native-api")

/// Runs `tick` immediately, then every `seconds` until the returned task is
/// cancelled. Mirrors `BinaryManager`'s stats polling. `@MainActor` so the
/// managers mutate their `@Observable` state without actor hops.
@MainActor
func pollLoop(every seconds: Double, _ tick: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        while !Task.isCancelled {
            await tick()
            do { try await Task.sleep(for: .seconds(seconds)) } catch { break }
        }
    }
}

// Per-domain observable managers. Each polls the native REST API while its panel
// is visible (started in `.task`, stopped in `.onDisappear`) so nothing hits the
// server while no panel is shown. The `client` closure is re-read each tick so a
// reconnect (new token/URL) is picked up without restarting the poll.

@Observable @MainActor
final class SystemStatusManager {
    private(set) var status: SystemStatus?
    private(set) var lastError: String?
    private(set) var isLoading = false
    private var pollTask: Task<Void, Never>?

    func start(client: @escaping @MainActor () -> NativeAPIClient?) {
        stop()
        pollTask = pollLoop(every: 5) { [weak self] in await self?.refresh(client()) }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh(_ client: NativeAPIClient?) async {
        guard let client else { return }
        if status == nil { isLoading = true }
        do {
            status = try await client.get("v1/system")
            lastError = nil
        } catch {
            serverLog.error("system refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}

@Observable @MainActor
final class SessionsManager {
    private(set) var stats: SessionStats?
    private(set) var lastError: String?
    private(set) var isLoading = false
    private var pollTask: Task<Void, Never>?

    func start(client: @escaping @MainActor () -> NativeAPIClient?) {
        stop()
        pollTask = pollLoop(every: 5) { [weak self] in await self?.refresh(client()) }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh(_ client: NativeAPIClient?) async {
        guard let client else { return }
        if stats == nil { isLoading = true }
        do {
            stats = try await client.get("v1/sessions/stats")
            lastError = nil
        } catch {
            serverLog.error("sessions refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}

@Observable @MainActor
final class LoopsManager {
    private(set) var loops: [LoopStatus] = []
    private(set) var loaded = false
    private(set) var lastError: String?
    private(set) var isLoading = false
    private var pollTask: Task<Void, Never>?

    func start(client: @escaping @MainActor () -> NativeAPIClient?) {
        stop()
        pollTask = Task { @MainActor [weak self] in await self?.run(client) }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    /// Prefer the SSE lifecycle stream as a low-latency wake signal — re-fetch the
    /// full list on each event. The stream is chatty, so two mechanisms keep
    /// re-fetches sane: `.bufferingNewest(1)` collapses a burst to the latest
    /// event, and a ~1s throttle caps `/v1/loops` re-fetches at roughly once a
    /// second while staying responsive (and still firing one trailing refresh
    /// after a burst). Falls back to fixed-interval polling if the stream is
    /// unavailable or ends.
    private func run(_ client: @escaping @MainActor () -> NativeAPIClient?) async {
        await refresh(client())
        if let api = client() {
            do {
                for try await _ in api.stream("v1/loops/events", as: LoopEvent.self, bufferingPolicy: .bufferingNewest(1)) {
                    if Task.isCancelled { return }
                    await refresh(client())
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                if Task.isCancelled { return }
                serverLog.error("loops stream ended, falling back to polling: \(error.localizedDescription, privacy: .public)")
            }
        }
        while !Task.isCancelled {
            await refresh(client())
            do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
    }

    func refresh(_ client: NativeAPIClient?) async {
        guard let client else { return }
        if !loaded { isLoading = true }
        do {
            loops = try await client.get("v1/loops")
            loaded = true
            lastError = nil
        } catch {
            serverLog.error("loops refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}

/// Minimum log level to request. `.all` omits the `level` query param.
enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all, trace, debug, info, warn, error
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var apiValue: String? { self == .all ? nil : rawValue }
}

/// System logs are pulled on demand (manual refresh + level filter), not polled.
@Observable @MainActor
final class LogsManager {
    var level: LogLevelFilter = .info
    private(set) var entries: [LogEntry] = []
    private(set) var loaded = false
    private(set) var lastError: String?
    private(set) var isLoading = false

    func refresh(_ client: NativeAPIClient?) async {
        guard let client else { return }
        isLoading = true
        var query = [URLQueryItem(name: "limit", value: "200")]
        if let level = level.apiValue {
            query.append(URLQueryItem(name: "level", value: level))
        }
        do {
            entries = try await client.get("v1/system/logs", query: query)
            loaded = true
            lastError = nil
        } catch {
            serverLog.error("logs refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}

@Observable @MainActor
final class SchedulesManager {
    private(set) var tasks: [ScheduledTask] = []
    private(set) var loaded = false
    private(set) var lastError: String?
    private(set) var isLoading = false
    private var pollTask: Task<Void, Never>?

    func start(client: @escaping @MainActor () -> NativeAPIClient?) {
        stop()
        pollTask = pollLoop(every: 30) { [weak self] in await self?.refresh(client()) }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh(_ client: NativeAPIClient?) async {
        guard let client else { return }
        if !loaded { isLoading = true }
        do {
            tasks = try await client.get("v1/schedules")
            loaded = true
            lastError = nil
        } catch {
            serverLog.error("schedules refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}

/// Conversations are loaded on demand (the page is heavier than the polled
/// panels): one keyset-paginated page at a time, with manual refresh.
@Observable @MainActor
final class ConversationsManager {
    private(set) var conversations: [ConversationSummary] = []
    private(set) var total = 0
    private(set) var loaded = false
    private(set) var lastError: String?
    private(set) var isLoading = false
    private var nextCursor: String?

    var canLoadMore: Bool { nextCursor != nil }

    func loadFirstPage(_ client: NativeAPIClient?) async {
        guard let client else { return }
        isLoading = true
        do {
            let page: ConversationPage = try await client.get(
                "v1/conversations", query: [URLQueryItem(name: "limit", value: "50")])
            conversations = page.conversations
            total = page.total
            nextCursor = page.nextCursor
            loaded = true
            lastError = nil
        } catch {
            serverLog.error("conversations load failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore(_ client: NativeAPIClient?) async {
        guard let client, let cursor = nextCursor else { return }
        do {
            let page: ConversationPage = try await client.get("v1/conversations", query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "cursor", value: cursor),
            ])
            conversations.append(contentsOf: page.conversations)
            total = page.total
            nextCursor = page.nextCursor
            lastError = nil
        } catch {
            serverLog.error("conversations load-more failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }
}
