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
///
/// A lock rather than an actor, because the lifetime is the point. A
/// registration must be removable from `deinit`, and a nonisolated `deinit`
/// cannot reach actor-isolated state. The mutable state here is one token;
/// `center` and `onChange` are immutable, and `NotificationCenter` is itself
/// thread-safe — which is what `@unchecked Sendable` is asserting.
nonisolated final class EventKitChangeObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let onChange: @Sendable () async -> Void

    private let lock = NSLock()
    /// Guarded by `lock`, except in `deinit` where no other reference to
    /// this object can exist.
    ///
    /// `nonisolated(unsafe)` because the concurrency checker cannot see the
    /// lock, and an opaque `NSObjectProtocol` is not Sendable. The safety
    /// argument is the lock plus the deinit rule above, stated here rather
    /// than assumed.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init(center: NotificationCenter = .default, onChange: @escaping @Sendable () async -> Void) {
        self.center = center
        self.onChange = onChange
    }

    /// Begins watching. Calling this more than once is a no-op, so a caller
    /// that cannot easily tell whether startup already ran does not end up
    /// resetting its store twice per change.
    func start() {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        if let token {
            center.removeObserver(token)
        }
        token = nil
    }

    /// Whether this observer currently holds a registration.
    var isObserving: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    /// Removes the registration if the owner never did.
    ///
    /// A block-based registration is retained by the notification center,
    /// and the block holds the handler rather than this observer — so
    /// releasing an observer without stopping it leaves a registration
    /// nothing can reach and nothing will remove, spawning a task on every
    /// EventKit notification for the rest of the process. Correct code calls
    /// stop(); this is here so code that merely goes out of scope does not
    /// leak. No lock: deinit runs only once no other reference exists.
    deinit {
        if let token {
            center.removeObserver(token)
        }
    }
}
