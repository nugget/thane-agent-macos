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
        pollTask = pollLoop(every: 3) { [weak self] in await self?.refresh(client()) }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

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
