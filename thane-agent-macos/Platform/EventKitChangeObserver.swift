import EventKit
import Foundation

/// Watches for changes made to the EventKit database outside this process
/// and tells its owner to drop what it has cached.
///
/// `EKEventStore` caches aggressively, and its caches go stale the moment
/// anything else writes to the database — an edit in Calendar.app, a sync
/// landing from iCloud, another app entirely. Apple's contract for a store
/// that outlives a single query is to observe `EKEventStoreChanged` and call
/// `reset()`; a store that never does keeps answering from whatever it read
/// first.
///
/// This app holds one store per provider for the life of the process, which
/// on a menu-bar app is measured in weeks. Without this it would answer
/// today's questions from a snapshot taken at launch, and — worse than being
/// wrong — would be confidently wrong, because a stale read is
/// indistinguishable from a fresh one at the call site.
///
/// The notification carries no useful payload and is observed for any store
/// rather than one in particular: `reset()` is cheap, and a store that
/// discards its cache once too often is merely slightly slower, while one
/// that discards it once too rarely is incorrect.
actor EventKitChangeObserver {
    private let center: NotificationCenter
    private let onChange: @Sendable () async -> Void
    private var token: NSObjectProtocol?

    init(center: NotificationCenter = .default, onChange: @escaping @Sendable () async -> Void) {
        self.center = center
        self.onChange = onChange
    }

    /// Begins watching. Calling this more than once is a no-op, so a caller
    /// that cannot easily tell whether startup already ran does not end up
    /// resetting its store twice per change.
    func start() {
        guard token == nil else {
            return
        }
        let handler = onChange
        token = center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in
            Task { await handler() }
        }
    }

    /// Stops watching. Safe to call when never started.
    func stop() {
        if let token {
            center.removeObserver(token)
        }
        token = nil
    }

    /// Whether this observer currently holds a registration.
    var isObserving: Bool {
        token != nil
    }
}
