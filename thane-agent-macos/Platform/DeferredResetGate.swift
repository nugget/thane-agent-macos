import Foundation

/// Holds a cache reset back until the work that would be invalidated by it
/// has finished.
///
/// `EKEventStore.reset()` invalidates every object fetched from the store.
/// A service whose fetch hands results to a completion handler running on
/// EventKit's own queue is therefore unsafe to reset while that handler is
/// mapping: the actor is suspended across the fetch, so a change
/// notification arriving in that window is free to pull the objects out from
/// under code actively reading them.
///
/// The rule is that a deferred reset is never a skipped one — it lands the
/// moment the last outstanding piece of work ends, so the next query still
/// sees the database as it stands.
///
/// A separate value type rather than a pair of fields on the service,
/// because a concurrency invariant that can only be checked by reading the
/// code around it is one that quietly stops holding.
nonisolated struct DeferredResetGate: Equatable, Sendable {
    /// Work that has started and not yet finished. Counted rather than
    /// flagged because nothing stops two requests overlapping, and a flag
    /// cleared by the first would expose the second.
    private(set) var inFlight = 0

    /// Whether a reset arrived while work was outstanding.
    private(set) var isResetPending = false

    /// Records that a piece of invalidatable work has begun.
    mutating func beginWork() {
        inFlight += 1
    }

    /// Records that a piece of work has finished, and reports whether a
    /// reset was waiting on it. Returns true at most once per deferral.
    mutating func endWork() -> Bool {
        guard inFlight > 0 else {
            return false
        }
        inFlight -= 1
        guard inFlight == 0, isResetPending else {
            return false
        }
        isResetPending = false
        return true
    }

    /// Records a reset request, and reports whether it can be applied now.
    /// When it cannot, it is remembered and released by a later `endWork`.
    mutating func requestReset() -> Bool {
        guard inFlight == 0 else {
            isResetPending = true
            return false
        }
        return true
    }
}
